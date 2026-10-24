/*
 * Glue with whisper.cpp and ggml: CPU backend selection, the model,
 * transcription in chunks as decoding proceeds. Audio decoding lives in
 * mdw_decode.c and mdw_platform_*.
 */
#include "mdw.h"
#include "mdw_internal.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "ggml-backend.h"
#include "ggml.h"
#include "whisper.h"

const char *mdw_version(void) { return whisper_version(); }

/* whisper.cpp and ggml write everything to the app process's stderr —
 * model loading, timings, system info. None of this is shown to the user,
 * and it clutters the console of a Windows build. */
static void mdw_quiet_log(enum ggml_log_level level, const char *text,
                          void *user_data) {
  (void)level;
  (void)text;
  (void)user_data;
}

static int mdw_initialized = 0;

/* CPU backend variants for Android, from the most capable to the baseline
 * (names from ggml_add_cpu_backend_variant in ggml/src/CMakeLists.txt). The
 * ggml loader rejects a variant the processor can't handle
 * (ggml_backend_score() == 0), so the first one that loads is the best. */
static const char *const mdw_android_variants[] = {
    "libggml-cpu-android_armv9.2_2.so", "libggml-cpu-android_armv9.2_1.so",
    "libggml-cpu-android_armv9.0_1.so", "libggml-cpu-android_armv8.6_1.so",
    "libggml-cpu-android_armv8.2_2.so", "libggml-cpu-android_armv8.2_1.so",
    "libggml-cpu-android_armv8.0_1.so",
};

int mdw_init(const char *dir) {
  if (!mdw_initialized) {
    mdw_initialized = 1;
    whisper_log_set(mdw_quiet_log, NULL);
    ggml_log_set(mdw_quiet_log, NULL);
    if (dir != NULL && dir[0] != '\0') {
      /* Iterates ggml-cpu-*.dll / libggml-cpu-*.so in the directory and
       * picks the variant with the highest ggml_backend_score(). The path
       * is UTF-8 (inside fs::u8path); Cyrillic in the path on Windows is
       * not a problem. */
      ggml_backend_load_all_from_path(dir);
    } else {
      /* Android: the .so files sit uncompressed inside the APK and are
       * opened by name — there's no directory on disk to enumerate. */
      size_t count = sizeof(mdw_android_variants) / sizeof(*mdw_android_variants);
      for (size_t i = 0; i < count; i++) {
        if (ggml_backend_load(mdw_android_variants[i]) != NULL) break;
      }
    }
  }
  return (int)ggml_backend_dev_count();
}

typedef struct mdw_segment {
  int64_t start_ms;
  int64_t end_ms;
  char *text;
} mdw_segment;

/* A session: the model (loaded on the first chunk) and the result of the
 * last transcription, accumulated across chunks. */
typedef struct mdw_session {
  char *model_path;
  struct whisper_context *ctx;
  mdw_segment *segments;
  int count;
  int capacity;
  int64_t processed; /* samples that went through transcription */
  char language[16];
} mdw_session;

static char *mdw_strdup(const char *text) {
  size_t length = strlen(text);
  char *copy = (char *)malloc(length + 1);
  if (copy != NULL) memcpy(copy, text, length + 1);
  return copy;
}

void *mdw_session_new(const char *model_path) {
  mdw_session *session = (mdw_session *)calloc(1, sizeof(mdw_session));
  if (session == NULL) return NULL;
  session->model_path = mdw_strdup(model_path);
  if (session->model_path == NULL) {
    free(session);
    return NULL;
  }
  return session;
}

static void mdw_session_reset(mdw_session *session) {
  for (int i = 0; i < session->count; i++) free(session->segments[i].text);
  session->count = 0;
  session->processed = 0;
  session->language[0] = '\0';
}

void mdw_session_free(void *handle) {
  mdw_session *session = (mdw_session *)handle;
  if (session == NULL) return;
  mdw_session_reset(session);
  free(session->segments);
  if (session->ctx != NULL) whisper_free(session->ctx);
  free(session->model_path);
  free(session);
}

static int mdw_session_load(mdw_session *session) {
  if (session->ctx != NULL) return MDW_OK;
  struct whisper_context_params cparams = whisper_context_default_params();
  cparams.use_gpu = false;
  /* whisper.cpp itself converts the path from UTF-8 to UTF-16 on MSVC —
   * the model opens fine even from C:\Users\<cyrillic>\…, unlike
   * Tesseract. */
  session->ctx = whisper_init_from_file_with_params(session->model_path, cparams);
  return session->ctx != NULL ? MDW_OK : MDW_ERR_MODEL;
}

static int mdw_session_add(mdw_session *session, int64_t start_ms,
                           int64_t end_ms, const char *text) {
  if (session->count == session->capacity) {
    int capacity = session->capacity > 0 ? session->capacity * 2 : 256;
    mdw_segment *grown = (mdw_segment *)realloc(
        session->segments, (size_t)capacity * sizeof(mdw_segment));
    if (grown == NULL) return MDW_ERR_NOMEM;
    session->segments = grown;
    session->capacity = capacity;
  }
  char *copy = mdw_strdup(text != NULL ? text : "");
  if (copy == NULL) return MDW_ERR_NOMEM;
  session->segments[session->count++] = (mdw_segment){start_ms, end_ms, copy};
  return MDW_OK;
}

/* One call to mdw_transcribe_*: parameters and state carried between
 * chunks. */
typedef struct mdw_job {
  mdw_session *session;
  const char *language; /* requested: a code, or "auto" */
  const char *vad_model_path;
  int threads;
  mdw_control *control;
  int64_t expected;    /* expected length in samples; 0 — unknown */
  int64_t chunk_start; /* offset of the current chunk, in samples */
  int64_t chunk_length;
  /* whisper was interrupted by the flag. The flag alone doesn't say that:
   * "Stop" pressed after the last window is already transcribed doesn't
   * make a complete transcript incomplete. */
  int aborted;
} mdw_job;

/* Chunk progress → file progress. Capped at 99: the expected length from
 * metadata can be inexact, and 100 only once everything is done. */
static void mdw_on_progress(struct whisper_context *ctx,
                            struct whisper_state *state, int progress,
                            void *user_data) {
  (void)ctx;
  (void)state;
  mdw_job *job = (mdw_job *)user_data;
  if (job->expected <= 0) return;
  int64_t done = job->chunk_start + job->chunk_length * progress / 100;
  int64_t percent = done * 100 / job->expected;
  job->control->progress = (int32_t)(percent < 99 ? percent : 99);
}

/* Checked before every 30-second window (and before language detection):
 * cancellation never waits longer than one window. */
static bool mdw_on_encoder_begin(struct whisper_context *ctx,
                                 struct whisper_state *state, void *user_data) {
  (void)ctx;
  (void)state;
  mdw_job *job = (mdw_job *)user_data;
  if (job->control->cancel == 0) return true;
  job->aborted = 1;
  return false;
}

/* And this one is inside the ggml graph computation itself: it interrupts
 * the window in progress too. */
static bool mdw_on_abort(void *user_data) {
  mdw_job *job = (mdw_job *)user_data;
  if (job->control->cancel == 0) return false;
  job->aborted = 1;
  return true;
}

/* A chunk of audio from the sink (mdw_sink) → session segments, offset to
 * the start of the chunk. */
static int mdw_on_chunk(void *user, const float *samples, int64_t n) {
  mdw_job *job = (mdw_job *)user;
  mdw_session *session = job->session;
  mdw_control *control = job->control;
  job->chunk_start = session->processed;
  job->chunk_length = n;
  session->processed += n;
  if (control != NULL && control->cancel != 0) {
    job->aborted = 1;
    return MDW_ERR_CANCELLED;
  }
  /* A click, not speech: whisper.cpp errors out on audio shorter than
   * ~0.1 s. Shorter than half a second can only happen for the whole file
   * or its tail. */
  if (n < MDW_SAMPLE_RATE / 2) return MDW_OK;
  int status = mdw_session_load(session);
  if (status != MDW_OK) return status;

  /* Greedy search, not beam search (whisper-cli uses 5 beams): twice as
   * fast, and on a phone's CPU that's the difference between "minutes" and
   * "tens of minutes". On a dubious result whisper retries the window with
   * temperature on its own. */
  struct whisper_full_params params =
      whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  params.n_threads = job->threads > 0 ? job->threads : 1;
  /* One language per file, same as Whisper on a single call: once
   * detected from the first chunk with speech, it's fixed afterwards
   * rather than guessed again. */
  params.language =
      session->language[0] != '\0' ? session->language : job->language;
  params.detect_language = false;
  params.translate = false;
  params.print_special = false;
  params.print_progress = false;
  params.print_realtime = false;
  params.print_timestamps = false;
  /* Don't invent "[music]", "(laughs)", and musical notes — speech only. */
  params.suppress_nst = true;
  if (job->vad_model_path != NULL && job->vad_model_path[0] != '\0') {
    params.vad = true;
    params.vad_model_path = job->vad_model_path;
    params.vad_params = whisper_vad_default_params();
  }
  if (control != NULL) {
    params.progress_callback = mdw_on_progress;
    params.progress_callback_user_data = job;
    params.encoder_begin_callback = mdw_on_encoder_begin;
    params.encoder_begin_callback_user_data = job;
    params.abort_callback = mdw_on_abort;
    params.abort_callback_user_data = job;
  }

  /* A chunk is 10 minutes plus up to a 15-second tail, so it fits in an
   * int. */
  int result = whisper_full(session->ctx, params, samples, (int)n);

  /* Whatever was transcribed before stopping still counts as a result.
   * whisper's time is in hundredths of a second from the start of the
   * chunk. */
  int64_t offset_ms = job->chunk_start * 1000 / MDW_SAMPLE_RATE;
  int segments = whisper_full_n_segments(session->ctx);
  for (int i = 0; i < segments; i++) {
    status = mdw_session_add(
        session, offset_ms + whisper_full_get_segment_t0(session->ctx, i) * 10,
        offset_ms + whisper_full_get_segment_t1(session->ctx, i) * 10,
        whisper_full_get_segment_text(session->ctx, i));
    if (status != MDW_OK) return status;
  }
  /* With no segments, the language was never detected: whisper falls back
   * to its own "default" — English, which would make wordless music
   * "English". */
  if (session->language[0] == '\0' && segments > 0) {
    int lang_id = whisper_full_lang_id(session->ctx);
    const char *lang = lang_id >= 0 ? whisper_lang_str(lang_id) : NULL;
    if (lang != NULL) {
      strncpy(session->language, lang, sizeof(session->language) - 1);
      session->language[sizeof(session->language) - 1] = '\0';
    }
  }

  if (job->aborted) return MDW_ERR_CANCELLED;
  return result == 0 ? MDW_OK : MDW_ERR_TRANSCRIBE;
}

/* Shared between memory and file: data != NULL means the portable
 * decoders, otherwise the platform decoder via path. */
static int mdw_transcribe_from(void *handle, const uint8_t *data, int64_t size,
                               const char *path, int64_t expected_samples,
                               const char *language, const char *vad_model_path,
                               int threads, mdw_control *control) {
  mdw_session *session = (mdw_session *)handle;
  mdw_session_reset(session);
  if (control != NULL) control->progress = 0;
  /* If it was stopped before starting, don't decode or load the model at
   * all. */
  if (control != NULL && control->cancel != 0) return MDW_ERR_CANCELLED;

  mdw_job job = {session,          language, vad_model_path, threads, control,
                 expected_samples, 0,        0,              0};
  mdw_sink *sink = mdw_sink_new_chunked(mdw_on_chunk, &job,
                                        control != NULL ? &control->cancel : NULL);
  if (sink == NULL) return MDW_ERR_NOMEM;
  int status = data != NULL ? mdw_decode_memory_to(data, size, sink)
                            : mdw_platform_decode_file(path, sink);
  int stopped = mdw_sink_status(sink);
  int64_t total = mdw_sink_count(sink);
  if (stopped == MDW_OK) {
    /* Not a single sample — transcription never started, and the caller
     * may try a different decoder. A failure mid-stream — transcribe
     * whatever was decoded, the same way a player plays a corrupt file up
     * to the point where it breaks. */
    if (total == 0) {
      mdw_sink_free(sink);
      return status != MDW_OK ? status : MDW_ERR_NO_AUDIO;
    }
    stopped = mdw_sink_flush(sink);
  }
  mdw_sink_free(sink);
  if (stopped == MDW_ERR_CANCELLED || job.aborted) return MDW_ERR_CANCELLED;
  if (stopped != MDW_OK) return stopped;
  if (control != NULL) control->progress = 100;
  return MDW_OK;
}

int mdw_transcribe_memory(void *session, const uint8_t *data, int64_t size,
                          int64_t expected_samples, const char *language,
                          const char *vad_model_path, int threads,
                          mdw_control *control) {
  if (data == NULL || size <= 0) return MDW_ERR_DECODE;
  return mdw_transcribe_from(session, data, size, NULL, expected_samples,
                             language, vad_model_path, threads, control);
}

int mdw_transcribe_file(void *session, const char *path,
                        int64_t expected_samples, const char *language,
                        const char *vad_model_path, int threads,
                        mdw_control *control) {
  return mdw_transcribe_from(session, NULL, 0, path, expected_samples, language,
                             vad_model_path, threads, control);
}

int mdw_segment_count(void *handle) { return ((mdw_session *)handle)->count; }

const char *mdw_segment_text(void *handle, int i) {
  return ((mdw_session *)handle)->segments[i].text;
}

int64_t mdw_segment_start_ms(void *handle, int i) {
  return ((mdw_session *)handle)->segments[i].start_ms;
}

int64_t mdw_segment_end_ms(void *handle, int i) {
  return ((mdw_session *)handle)->segments[i].end_ms;
}

const char *mdw_language(void *handle) {
  return ((mdw_session *)handle)->language;
}

int64_t mdw_processed_ms(void *handle) {
  return ((mdw_session *)handle)->processed * 1000 / MDW_SAMPLE_RATE;
}

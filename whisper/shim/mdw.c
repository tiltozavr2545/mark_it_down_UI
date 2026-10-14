/*
 * Склейка с whisper.cpp и ggml: выбор CPU-бэкенда, модель, распознавание
 * кусками по мере декодирования. Декодирование звука — mdw_decode.c и
 * mdw_platform_*.
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

/* whisper.cpp и ggml пишут в stderr процесса приложения всё подряд —
 * загрузку модели, тайминги, системную информацию. Пользователю это не
 * показывается, а консоль Windows-сборки засоряет. */
static void mdw_quiet_log(enum ggml_log_level level, const char *text,
                          void *user_data) {
  (void)level;
  (void)text;
  (void)user_data;
}

static int mdw_initialized = 0;

/* Варианты CPU-бэкенда для Android от самого способного к базовому (имена —
 * ggml_add_cpu_backend_variant в ggml/src/CMakeLists.txt). Загрузчик ggml
 * отказывается от варианта, который процессор не тянет
 * (ggml_backend_score() == 0), поэтому первый загрузившийся — лучший. */
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
      /* Перебирает ggml-cpu-*.dll / libggml-cpu-*.so в каталоге и берёт
       * вариант с наибольшим ggml_backend_score(). Путь — UTF-8 (внутри
       * fs::u8path), кириллица в пути на Windows не мешает. */
      ggml_backend_load_all_from_path(dir);
    } else {
      /* Android: .so лежат в APK несжатыми и открываются по имени, каталога
       * для перебора на диске нет. */
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

/* Сеанс: модель (грузится при первом куске) и накопленный по кускам
 * результат последнего распознавания. */
typedef struct mdw_session {
  char *model_path;
  struct whisper_context *ctx;
  mdw_segment *segments;
  int count;
  int capacity;
  int64_t processed; /* отсчётов прошло через распознавание */
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
  /* whisper.cpp сам переводит путь из UTF-8 в UTF-16 на MSVC — модель
   * открывается и из C:\Users\<кириллица>\…, в отличие от Tesseract. */
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

/* Один вызов mdw_transcribe_*: параметры и состояние между кусками. */
typedef struct mdw_job {
  mdw_session *session;
  const char *language; /* запрошенный: код или "auto" */
  const char *vad_model_path;
  int threads;
  mdw_control *control;
  int64_t expected;    /* ожидаемая длина в отсчётах; 0 — неизвестна */
  int64_t chunk_start; /* смещение текущего куска в отсчётах */
  int64_t chunk_length;
  /* whisper прервался по флагу. Сам флаг этого не говорит: «Остановить»,
   * нажатая, когда последнее окно уже распознано, не делает полную
   * расшифровку неполной. */
  int aborted;
} mdw_job;

/* Прогресс куска → прогресс файла. До 99: ожидаемая длина из метаданных
 * бывает неточной, а 100 — только когда всё готово. */
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

/* Проверяется перед каждым 30-секундным окном (и перед определением
 * языка): дольше одного окна отмена не ждёт. */
static bool mdw_on_encoder_begin(struct whisper_context *ctx,
                                 struct whisper_state *state, void *user_data) {
  (void)ctx;
  (void)state;
  mdw_job *job = (mdw_job *)user_data;
  if (job->control->cancel == 0) return true;
  job->aborted = 1;
  return false;
}

/* А это — внутри вычисления графа ggml: прерывает и само окно. */
static bool mdw_on_abort(void *user_data) {
  mdw_job *job = (mdw_job *)user_data;
  if (job->control->cancel == 0) return false;
  job->aborted = 1;
  return true;
}

/* Кусок звука из приёмника (mdw_sink) → сегменты сеанса со сдвигом на
 * начало куска. */
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
  /* Щелчок, а не речь: whisper.cpp на звуке короче ~0,1 с отвечает
   * ошибкой. Короче полсекунды бывает только весь файл или его хвост. */
  if (n < MDW_SAMPLE_RATE / 2) return MDW_OK;
  int status = mdw_session_load(session);
  if (status != MDW_OK) return status;

  /* Жадный поиск, а не beam search (5 лучей у whisper-cli): вдвое быстрее,
   * а на CPU телефона это разница между «минуты» и «десятки минут». При
   * сомнительном результате whisper сам повторяет окно с температурой. */
  struct whisper_full_params params =
      whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  params.n_threads = job->threads > 0 ? job->threads : 1;
  /* Один язык на файл, как у Whisper на одном вызове: определился по
   * первому куску с речью — дальше задан, а не угадывается заново. */
  params.language =
      session->language[0] != '\0' ? session->language : job->language;
  params.detect_language = false;
  params.translate = false;
  params.print_special = false;
  params.print_progress = false;
  params.print_realtime = false;
  params.print_timestamps = false;
  /* Не выдумывать «[музыка]», «(смеётся)» и ноты — только речь. */
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

  /* Кусок — 10 минут с хвостом до 15 секунд, в int помещается. */
  int result = whisper_full(session->ctx, params, samples, (int)n);

  /* Распознанное до остановки — тоже результат. Время whisper — в сотых
   * долях секунды от начала куска. */
  int64_t offset_ms = job->chunk_start * 1000 / MDW_SAMPLE_RATE;
  int segments = whisper_full_n_segments(session->ctx);
  for (int i = 0; i < segments; i++) {
    status = mdw_session_add(
        session, offset_ms + whisper_full_get_segment_t0(session->ctx, i) * 10,
        offset_ms + whisper_full_get_segment_t1(session->ctx, i) * 10,
        whisper_full_get_segment_text(session->ctx, i));
    if (status != MDW_OK) return status;
  }
  /* Без сегментов язык не определялся: whisper отдаёт свой «по умолчанию»
   * — английский, и музыка без слов стала бы «английской». */
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

/* Общее для памяти и файла: data != NULL — переносимые декодеры, иначе
 * декодер платформы по path. */
static int mdw_transcribe_from(void *handle, const uint8_t *data, int64_t size,
                               const char *path, int64_t expected_samples,
                               const char *language, const char *vad_model_path,
                               int threads, mdw_control *control) {
  mdw_session *session = (mdw_session *)handle;
  mdw_session_reset(session);
  if (control != NULL) control->progress = 0;
  /* Остановленное до старта не декодируем и не грузим модель вовсе. */
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
    /* Ни одного отсчёта — распознавание не начиналось, и вызывающий может
     * попробовать другой декодер. Сбой посреди потока — распознаём, что
     * успели, как плеер играет битый файл до места поломки. */
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

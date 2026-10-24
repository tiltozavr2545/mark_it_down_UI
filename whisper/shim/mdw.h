/*
 * mdw — a thin C layer between core/ (Dart FFI) and whisper.cpp.
 *
 * Why this instead of FFI straight onto whisper.h: whisper_full_params is a
 * struct with a hundred-odd fields that changes from version to version;
 * mirroring its layout in Dart means silently reading garbage after the
 * next update. Here the parameters are filled in C against the header of
 * the version it was built with, and Dart sees a dozen functions with
 * simple types.
 *
 * Plus things whisper.cpp doesn't have at all: decoding audio to 16 kHz
 * mono (mdw_decode.c) and picking the ggml CPU backend variant for the
 * processor.
 *
 * Strings are UTF-8. Returned string pointers live until the next call to
 * mdw_transcribe_* or mdw_session_free on the same session.
 */
#ifndef MDW_H
#define MDW_H

#include <stdint.h>

#ifdef _WIN32
#define MDW_API __declspec(dllexport)
#else
#define MDW_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Sample rate Whisper expects. */
#define MDW_SAMPLE_RATE 16000

/* Return codes. */
#define MDW_OK 0
#define MDW_ERR_UNSUPPORTED 1 /* this decoder can't read the format/codec */
#define MDW_ERR_DECODE 2      /* format recognized, but the stream is corrupt */
#define MDW_ERR_NO_AUDIO 3    /* container has no audio track */
#define MDW_ERR_NOMEM 4
#define MDW_ERR_CANCELLED 5   /* stopped by the cancel flag */
#define MDW_ERR_TRANSCRIBE 6  /* whisper_full returned an error */
#define MDW_ERR_IO 7          /* file failed to open */
#define MDW_ERR_MODEL 8       /* Whisper model failed to open */

/*
 * Shared memory between the conversion isolate and the app's main isolate:
 * the main isolate writes cancel and reads progress, native code does the
 * opposite. The struct's address is passed to the isolate as a number;
 * volatile because the other party is on a different thread, and no
 * further synchronization is needed (one writer per field, int32 is
 * written atomically on every target ABI).
 */
typedef struct mdw_control {
  volatile int32_t cancel;   /* != 0 — stop as soon as possible */
  volatile int32_t progress; /* 0–100, written by mdw_transcribe_* */
} mdw_control;

/* The whisper.cpp version the library was built with (e.g. "1.9.5"). */
MDW_API const char *mdw_version(void);

/*
 * Loads the best ggml CPU backend for this processor. dir is the directory
 * with ggml-cpu-*.dll / libggml-cpu-*.so; NULL means look up by bare names
 * (Android: libraries from jniLibs are loaded by name straight from the
 * APK). A repeat call does nothing. Returns the number of available
 * devices (0 — no backend, nothing to recognize with). Also silences
 * whisper/ggml logging on stderr.
 */
MDW_API int mdw_init(const char *dir);

/*
 * Audio in memory → float 16 kHz mono: WAV, MP3, FLAC, Ogg Vorbis, Ogg
 * Opus. No more than max_samples samples (the rest is discarded). The
 * result is freed with mdw_free_samples. Transcription doesn't need this —
 * it decodes on its own, in chunks (mdw_transcribe_*); this is here to
 * exercise the decoders end to end.
 */
MDW_API int mdw_decode_memory(const uint8_t *data, int64_t size,
                              int64_t max_samples, float **out,
                              int64_t *n_out);

/*
 * The same, for a file, via the platform decoder (Windows: Media
 * Foundation, Android: NDK MediaCodec). Needed for AAC in MP4/M4A: there's
 * no free AAC decoder under our license, but the platform always has one.
 * On other OSes — MDW_ERR_UNSUPPORTED.
 */
MDW_API int mdw_decode_file(const char *path, int64_t max_samples, float **out,
                            int64_t *n_out);

MDW_API void mdw_free_samples(float *samples);

/*
 * A transcription session with the Whisper (ggml) model at model_path. The
 * model is loaded on the first audio chunk, not here: a file that fails to
 * decode shouldn't cost the seconds it takes to load 264 MB, and a second
 * call to mdw_transcribe_* (with a different decoder) doesn't reload it.
 * NULL means out of memory.
 */
MDW_API void *mdw_session_new(const char *model_path);
MDW_API void mdw_session_free(void *session);

/*
 * Decodes audio and transcribes it in 10-minute chunks as decoding
 * proceeds: memory doesn't grow with recording length (otherwise an hour
 * would be ≈0.6 GB: the samples, their copy after VAD, and the
 * mel-spectrogram of the whole file). A chunk is cut at the quietest point
 * in the last 15 seconds, to avoid tearing a word in half. The language
 * ("ru", "en", "it", or "auto") — with "auto" it's detected from the first
 * chunk containing speech and held for the whole file.
 *
 * expected_samples is the expected length (from metadata) for progress; 0
 * means unknown, progress stays at 0. vad_model_path is Silero VAD or
 * NULL. control may be NULL.
 *
 * MDW_ERR_UNSUPPORTED/MDW_ERR_DECODE/MDW_ERR_NO_AUDIO — the decoder didn't
 * produce a single sample, transcription never started (a different
 * decoder can be tried on the same session). A decoder failure mid-stream
 * is not an error: whatever was decoded so far gets transcribed.
 * MDW_ERR_CANCELLED — stopped by the cancel flag; what's already been
 * transcribed is available via mdw_segment_*. A flag raised after the last
 * window doesn't spoil the result — that's still MDW_OK.
 */
MDW_API int mdw_transcribe_memory(void *session, const uint8_t *data,
                                  int64_t size, int64_t expected_samples,
                                  const char *language,
                                  const char *vad_model_path, int threads,
                                  mdw_control *control);

/* The same, for a file, via the platform decoder (see mdw_decode_file). */
MDW_API int mdw_transcribe_file(void *session, const char *path,
                                int64_t expected_samples, const char *language,
                                const char *vad_model_path, int threads,
                                mdw_control *control);

MDW_API int mdw_segment_count(void *session);
MDW_API const char *mdw_segment_text(void *session, int i);
MDW_API int64_t mdw_segment_start_ms(void *session, int i);
MDW_API int64_t mdw_segment_end_ms(void *session, int i);

/* Language of the last transcription: "ru", "en", "it"… or "" — no speech
 * found. */
MDW_API const char *mdw_language(void *session);

/* How much audio has gone through transcription, in ms. */
MDW_API int64_t mdw_processed_ms(void *session);

#ifdef __cplusplus
}
#endif

#endif /* MDW_H */

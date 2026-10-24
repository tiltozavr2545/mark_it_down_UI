/*
 * Shared by the decoders (mdw_decode.c and mdw_platform_*): an audio
 * "sink" that mixes channels down, resamples to 16 kHz, and either
 * accumulates the result up to a duration limit or hands it off in chunks
 * for transcription.
 */
#ifndef MDW_INTERNAL_H
#define MDW_INTERNAL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mdw_sink mdw_sink;

/* NULL means out of memory. max is the limit in 16 kHz samples. */
mdw_sink *mdw_sink_new(int64_t max);

/* A chunk of audio to transcribe; not MDW_OK means stop decoding. */
typedef int (*mdw_chunk_fn)(void *user, const float *samples, int64_t n);

/*
 * An unlimited sink: every MDW_CHUNK_SAMPLES samples it hands a chunk to
 * on_chunk (the boundary is at the quietest point at the end of the
 * chunk), the tail via mdw_sink_flush. cancel != NULL and *cancel != 0 —
 * the sink stops with MDW_ERR_CANCELLED, without waiting for the chunk to
 * end.
 */
mdw_sink *mdw_sink_new_chunked(mdw_chunk_fn on_chunk, void *user,
                               const volatile int32_t *cancel);

/* Hand whatever is accumulated so far to on_chunk. */
int mdw_sink_flush(mdw_sink *sink);

/* MDW_OK, or the code that on_chunk or cancel stopped the sink with. */
int mdw_sink_status(const mdw_sink *sink);

/* Input sample rate. Can be called again: the platform decoder only learns
 * the real rate from the first output buffer. */
int mdw_sink_set_rate(mdw_sink *sink, uint32_t sample_rate);

/* Frames in float, channels interleaved; mixed down to mono by averaging. */
int mdw_sink_push(mdw_sink *sink, const float *frames, uint64_t count,
                  uint32_t channels);

/* The same for 16-bit PCM (what MediaCodec on Android produces). */
int mdw_sink_push_s16(mdw_sink *sink, const int16_t *frames, uint64_t count,
                      uint32_t channels);

/* The limit has been reached, or the sink has stopped — no point decoding
 * further. */
int mdw_sink_full(const mdw_sink *sink);

/* Total number of samples received, including ones already handed off in
 * chunks. */
int64_t mdw_sink_count(const mdw_sink *sink);

/* Hands back what's accumulated (free with mdw_free_samples) and destroys
 * the sink. */
void mdw_sink_finish(mdw_sink *sink, float **out, int64_t *n_out);

void mdw_sink_free(mdw_sink *sink);

/* Portable decoders (mdw_decode.c): Ogg Opus or miniaudio. */
int mdw_decode_memory_to(const uint8_t *data, int64_t size, mdw_sink *sink);

/* Platform decoder: mdw_platform_android.c, mdw_platform_windows.cpp, or
 * the stub in mdw_decode.c. */
int mdw_platform_decode_file(const char *path, mdw_sink *sink);

#ifdef __cplusplus
}
#endif

#endif /* MDW_INTERNAL_H */

/*
 * Общее для декодеров (mdw_decode.c и mdw_platform_*): «приёмник» звука,
 * который сводит каналы, передискретизирует в 16 кГц и либо копит
 * результат не дальше предела длительности, либо отдаёт его кусками на
 * распознавание.
 */
#ifndef MDW_INTERNAL_H
#define MDW_INTERNAL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mdw_sink mdw_sink;

/* NULL — не хватило памяти. max — предел в отсчётах 16 кГц. */
mdw_sink *mdw_sink_new(int64_t max);

/* Кусок звука на распознавание; не MDW_OK — остановить декодирование. */
typedef int (*mdw_chunk_fn)(void *user, const float *samples, int64_t n);

/*
 * Приёмник без предела: каждые MDW_CHUNK_SAMPLES отсчётов отдаёт кусок в
 * on_chunk (граница — в самом тихом месте конца куска), хвост — по
 * mdw_sink_flush. cancel != NULL и *cancel != 0 — приёмник останавливается
 * с MDW_ERR_CANCELLED, не дожидаясь конца куска.
 */
mdw_sink *mdw_sink_new_chunked(mdw_chunk_fn on_chunk, void *user,
                               const volatile int32_t *cancel);

/* Отдать в on_chunk то, что накоплено. */
int mdw_sink_flush(mdw_sink *sink);

/* MDW_OK или код, которым остановил приёмник on_chunk либо cancel. */
int mdw_sink_status(const mdw_sink *sink);

/* Частота входа. Можно звать повторно: декодер платформы узнаёт настоящую
 * частоту только из первого выходного буфера. */
int mdw_sink_set_rate(mdw_sink *sink, uint32_t sample_rate);

/* Кадры в float, каналы чередуются; сводятся в моно средним. */
int mdw_sink_push(mdw_sink *sink, const float *frames, uint64_t count,
                  uint32_t channels);

/* То же для 16-битного PCM (так отдаёт MediaCodec на Android). */
int mdw_sink_push_s16(mdw_sink *sink, const int16_t *frames, uint64_t count,
                      uint32_t channels);

/* Набран предел или приёмник остановлен — дальше декодировать незачем. */
int mdw_sink_full(const mdw_sink *sink);

/* Сколько отсчётов принято всего, включая отданные кусками. */
int64_t mdw_sink_count(const mdw_sink *sink);

/* Отдаёт накопленное (освобождать mdw_free_samples) и уничтожает sink. */
void mdw_sink_finish(mdw_sink *sink, float **out, int64_t *n_out);

void mdw_sink_free(mdw_sink *sink);

/* Переносимые декодеры (mdw_decode.c): Ogg Opus или miniaudio. */
int mdw_decode_memory_to(const uint8_t *data, int64_t size, mdw_sink *sink);

/* Декодер платформы: mdw_platform_android.c, mdw_platform_windows.cpp или
 * заглушка в mdw_decode.c. */
int mdw_platform_decode_file(const char *path, mdw_sink *sink);

#ifdef __cplusplus
}
#endif

#endif /* MDW_INTERNAL_H */

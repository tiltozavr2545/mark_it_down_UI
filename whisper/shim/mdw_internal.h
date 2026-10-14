/*
 * Общее для декодеров (mdw_decode.c и mdw_platform_*): «приёмник» звука,
 * который сводит каналы, передискретизирует в 16 кГц и копит результат
 * не дальше предела длительности.
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

/* Частота входа. Можно звать повторно: декодер платформы узнаёт настоящую
 * частоту только из первого выходного буфера. */
int mdw_sink_set_rate(mdw_sink *sink, uint32_t sample_rate);

/* Кадры в float, каналы чередуются; сводятся в моно средним. */
int mdw_sink_push(mdw_sink *sink, const float *frames, uint64_t count,
                  uint32_t channels);

/* То же для 16-битного PCM (так отдаёт MediaCodec на Android). */
int mdw_sink_push_s16(mdw_sink *sink, const int16_t *frames, uint64_t count,
                      uint32_t channels);

/* Набран предел — дальше декодировать незачем. */
int mdw_sink_full(const mdw_sink *sink);

int64_t mdw_sink_count(const mdw_sink *sink);

/* Отдаёт накопленное (освобождать mdw_free_samples) и уничтожает sink. */
void mdw_sink_finish(mdw_sink *sink, float **out, int64_t *n_out);

void mdw_sink_free(mdw_sink *sink);

/* Декодер платформы: mdw_platform_android.c, mdw_platform_windows.cpp или
 * заглушка в mdw_decode.c. */
int mdw_platform_decode_file(const char *path, mdw_sink *sink);

#ifdef __cplusplus
}
#endif

#endif /* MDW_INTERNAL_H */

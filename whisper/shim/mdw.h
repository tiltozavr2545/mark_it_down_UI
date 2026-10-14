/*
 * mdw — тонкая C-прослойка между core/ (Dart FFI) и whisper.cpp.
 *
 * Зачем она, а не FFI прямо на whisper.h: whisper_full_params — структура
 * на сотню полей, которая меняется от версии к версии; повторять её
 * раскладку в Dart — значит молча читать мусор после очередного обновления.
 * Здесь параметры заполняются в C по заголовку той версии, с которой
 * собрано, а Dart видит десяток функций с простыми типами.
 *
 * Плюс то, чего в whisper.cpp нет вовсе: декодирование звука в 16 кГц моно
 * (mdw_decode.c) и выбор варианта CPU-бэкенда ggml под процессор.
 *
 * Строки — UTF-8. Возвращаемые указатели на строки живут до следующего
 * вызова mdw_transcribe/mdw_close_model с тем же контекстом.
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

/* Частота, которую ждёт Whisper. */
#define MDW_SAMPLE_RATE 16000

/* Коды возврата. */
#define MDW_OK 0
#define MDW_ERR_UNSUPPORTED 1 /* формат/кодек этим декодером не читается */
#define MDW_ERR_DECODE 2      /* формат опознан, но поток битый */
#define MDW_ERR_NO_AUDIO 3    /* в контейнере нет звуковой дорожки */
#define MDW_ERR_NOMEM 4
#define MDW_ERR_CANCELLED 5   /* остановлено флагом cancel */
#define MDW_ERR_TRANSCRIBE 6  /* whisper_full вернул ошибку */
#define MDW_ERR_IO 7          /* файл не открылся */

/*
 * Общая память между изолятом конвертации и главным изолятом приложения:
 * главный пишет cancel и читает progress, нативный код — наоборот. Адрес
 * структуры пересылается в изолят числом; volatile — потому что второй
 * участник в другом потоке, а синхронизация больше не нужна (по одному
 * писателю на поле, int32 пишется атомарно на всех целевых ABI).
 */
typedef struct mdw_control {
  volatile int32_t cancel;   /* != 0 — остановить как можно скорее */
  volatile int32_t progress; /* 0–100, пишет mdw_transcribe */
} mdw_control;

/* Версия whisper.cpp, с которой собрана библиотека (например "1.9.5"). */
MDW_API const char *mdw_version(void);

/*
 * Загружает лучший CPU-бэкенд ggml для этого процессора. dir — каталог с
 * ggml-cpu-*.dll / libggml-cpu-*.so; NULL — искать по голым именам (Android:
 * библиотеки из jniLibs грузятся по имени прямо из APK). Повторный вызов
 * ничего не делает. Возвращает число доступных устройств (0 — бэкенда нет,
 * распознавать нечем). Заодно гасит логи whisper/ggml в stderr.
 */
MDW_API int mdw_init(const char *dir);

/*
 * Звук в памяти → float 16 кГц моно: WAV, MP3, FLAC, Ogg Vorbis, Ogg Opus.
 * Не больше max_samples отсчётов (остальное отбрасывается — это предел
 * длительности расшифровки). Результат освобождается mdw_free_samples.
 */
MDW_API int mdw_decode_memory(const uint8_t *data, int64_t size,
                              int64_t max_samples, float **out,
                              int64_t *n_out);

/*
 * То же для файла — декодером платформы (Windows: Media Foundation,
 * Android: NDK MediaCodec). Нужно для AAC в MP4/M4A: свободного декодера
 * AAC под нашу лицензию нет, а у платформы он есть всегда. На других ОС —
 * MDW_ERR_UNSUPPORTED.
 */
MDW_API int mdw_decode_file(const char *path, int64_t max_samples, float **out,
                            int64_t *n_out);

MDW_API void mdw_free_samples(float *samples);

/* Модель Whisper (ggml). NULL — не открылась. */
MDW_API void *mdw_open_model(const char *model_path);
MDW_API void mdw_close_model(void *model);

/*
 * Распознаёт samples. language — код ("ru", "en", "it") или "auto";
 * vad_model_path — модель Silero VAD или NULL (без VAD). control может
 * быть NULL. При отмене возвращает MDW_ERR_CANCELLED, а уже распознанные
 * сегменты остаются доступны mdw_segment_*.
 */
MDW_API int mdw_transcribe(void *model, const float *samples, int64_t n,
                           const char *language, const char *vad_model_path,
                           int threads, mdw_control *control);

MDW_API int mdw_segment_count(void *model);
MDW_API const char *mdw_segment_text(void *model, int i);
MDW_API int64_t mdw_segment_start_ms(void *model, int i);
MDW_API int64_t mdw_segment_end_ms(void *model, int i);

/* Язык последнего распознавания: "ru", "en", "it"… или "" */
MDW_API const char *mdw_language(void *model);

#ifdef __cplusplus
}
#endif

#endif /* MDW_H */

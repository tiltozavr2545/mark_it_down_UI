/*
 * Склейка с whisper.cpp и ggml: выбор CPU-бэкенда, модель, распознавание.
 * Декодирование звука — mdw_decode.c и mdw_platform_*.
 */
#include "mdw.h"

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

typedef struct mdw_model {
  struct whisper_context *ctx;
  char language[16];
} mdw_model;

void *mdw_open_model(const char *model_path) {
  struct whisper_context_params cparams = whisper_context_default_params();
  cparams.use_gpu = false;
  /* whisper.cpp сам переводит путь из UTF-8 в UTF-16 на MSVC — модель
   * открывается и из C:\Users\<кириллица>\…, в отличие от Tesseract. */
  struct whisper_context *ctx =
      whisper_init_from_file_with_params(model_path, cparams);
  if (ctx == NULL) return NULL;
  mdw_model *model = (mdw_model *)calloc(1, sizeof(mdw_model));
  if (model == NULL) {
    whisper_free(ctx);
    return NULL;
  }
  model->ctx = ctx;
  return model;
}

void mdw_close_model(void *handle) {
  mdw_model *model = (mdw_model *)handle;
  if (model == NULL) return;
  whisper_free(model->ctx);
  free(model);
}

static void mdw_on_progress(struct whisper_context *ctx,
                            struct whisper_state *state, int progress,
                            void *user_data) {
  (void)ctx;
  (void)state;
  ((mdw_control *)user_data)->progress = progress;
}

/* Проверяется перед каждым 30-секундным окном: дольше одного окна отмена
 * не ждёт. */
static bool mdw_on_encoder_begin(struct whisper_context *ctx,
                                 struct whisper_state *state, void *user_data) {
  (void)ctx;
  (void)state;
  return ((mdw_control *)user_data)->cancel == 0;
}

/* А это — внутри вычисления графа ggml: прерывает и само окно. */
static bool mdw_on_abort(void *user_data) {
  return ((mdw_control *)user_data)->cancel != 0;
}

int mdw_transcribe(void *handle, const float *samples, int64_t n,
                   const char *language, const char *vad_model_path,
                   int threads, mdw_control *control) {
  mdw_model *model = (mdw_model *)handle;
  model->language[0] = '\0';
  if (n > INT32_MAX) n = INT32_MAX; /* whisper_full берёт int; это 37 часов */

  /* Жадный поиск, а не beam search (5 лучей у whisper-cli): вдвое быстрее,
   * а на CPU телефона это разница между «минуты» и «десятки минут». При
   * сомнительном результате whisper сам повторяет окно с температурой. */
  struct whisper_full_params params =
      whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  params.n_threads = threads > 0 ? threads : 1;
  params.language = language;
  params.detect_language = false;
  params.translate = false;
  params.print_special = false;
  params.print_progress = false;
  params.print_realtime = false;
  params.print_timestamps = false;
  /* Не выдумывать «[музыка]», «(смеётся)» и ноты — только речь. */
  params.suppress_nst = true;
  if (vad_model_path != NULL && vad_model_path[0] != '\0') {
    params.vad = true;
    params.vad_model_path = vad_model_path;
    params.vad_params = whisper_vad_default_params();
  }
  if (control != NULL) {
    control->progress = 0;
    params.progress_callback = mdw_on_progress;
    params.progress_callback_user_data = control;
    params.encoder_begin_callback = mdw_on_encoder_begin;
    params.encoder_begin_callback_user_data = control;
    params.abort_callback = mdw_on_abort;
    params.abort_callback_user_data = control;
  }

  int result = whisper_full(model->ctx, params, samples, (int)n);

  int lang_id = whisper_full_lang_id(model->ctx);
  const char *lang = lang_id >= 0 ? whisper_lang_str(lang_id) : NULL;
  if (lang != NULL) {
    strncpy(model->language, lang, sizeof(model->language) - 1);
    model->language[sizeof(model->language) - 1] = '\0';
  }

  if (control != NULL && control->cancel != 0) return MDW_ERR_CANCELLED;
  if (result != 0) return MDW_ERR_TRANSCRIBE;
  if (control != NULL) control->progress = 100;
  return MDW_OK;
}

int mdw_segment_count(void *handle) {
  return whisper_full_n_segments(((mdw_model *)handle)->ctx);
}

const char *mdw_segment_text(void *handle, int i) {
  return whisper_full_get_segment_text(((mdw_model *)handle)->ctx, i);
}

/* whisper отдаёт время в сотых долях секунды. */
int64_t mdw_segment_start_ms(void *handle, int i) {
  return whisper_full_get_segment_t0(((mdw_model *)handle)->ctx, i) * 10;
}

int64_t mdw_segment_end_ms(void *handle, int i) {
  return whisper_full_get_segment_t1(((mdw_model *)handle)->ctx, i) * 10;
}

const char *mdw_language(void *handle) {
  return ((mdw_model *)handle)->language;
}

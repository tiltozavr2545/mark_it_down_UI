# Закреплённые версии и sha256 всего, что качают whisper/fetch.sh и
# whisper/build.sh. Поднимать версию — осознанное действие (новый sha256
# снимается руками после чтения changelog), а не фон: текст расшифровки
# зависит и от движка, и от модели.
#
# Движок на обеих платформах — whisper.cpp, собранный build.sh из одних
# исходников: на Windows (и хосте для тестов) — родным компилятором, на
# Android — NDK. Почему whisper.cpp, а не faster-whisper, — см.
# docs/format-coverage.md#решения-транскрипции-08.
# shellcheck shell=bash disable=SC2034

# --- модели: Hugging Face, закреплены коммитом репозитория ---
# small q8_0: многоязычная (русский, английский, итальянский — и ещё ~95),
# те же веса small, квантованные в 8 бит: вдвое легче f16 (264 МБ против
# 488) почти без потери качества и быстрее на CPU. Не small.en — та только
# английская.
MODEL_NAME="ggml-small-q8_0.bin"
MODEL_COMMIT="5359861c739e955e79d9a303bcbc70fb988958b1"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/${MODEL_COMMIT}/${MODEL_NAME}"
MODEL_SHA256="49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f"

# Silero VAD (0,9 МБ): режет тишину до распознавания. Без него Whisper на
# паузах «дописывает» текст, которого не было («Продолжение следует…»).
VAD_NAME="ggml-silero-v6.2.0.bin"
VAD_COMMIT="9ffd54a1e1ee413ddf265af9913beaf518d1639b"
VAD_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/${VAD_COMMIT}/${VAD_NAME}"
VAD_SHA256="2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"

# --- исходники для build.sh ---
WHISPER_VERSION="1.9.5"
WHISPER_URL="https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v${WHISPER_VERSION}.tar.gz"
WHISPER_SHA256="ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720"

# Декодеры звука (shim/mdw_decode.c): WAV, MP3, FLAC и Ogg Vorbis —
# miniaudio (dr_wav/dr_mp3/dr_flac + stb_vorbis), Ogg Opus — libopus.
MINIAUDIO_VERSION="0.11.25"
MINIAUDIO_URL="https://github.com/mackron/miniaudio/archive/refs/tags/${MINIAUDIO_VERSION}.tar.gz"
MINIAUDIO_SHA256="b900edcffe979816e2560a0580b9b1216d674b4f17fbadeca8f777a7f8ab0274"

OPUS_VERSION="1.6.1"
OPUS_URL="https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz"
OPUS_SHA256="6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"

# --- Android: тот же NDK, что у приложения (app/android/app/build.gradle.kts) ---
ANDROID_NDK_VERSION="27.0.12077973"
ANDROID_ABI="arm64-v8a"
ANDROID_PLATFORM="android-23"

# Общая для обоих скриптов загрузка с проверкой sha256. Кэш — в
# whisper/cache/ (в .gitignore), повторный запуск не качает заново.
download() {
  local url="$1" sha="$2" dest="$3"
  if [[ -f "${dest}" ]] && [[ "$(sha256_of "${dest}")" == "${sha}" ]]; then
    return
  fi
  mkdir -p "$(dirname "${dest}")"
  echo "whisper: качаю ${url}"
  curl -fsSL --retry 3 -o "${dest}.part" "${url}"
  local actual
  actual="$(sha256_of "${dest}.part")"
  if [[ "${actual}" != "${sha}" ]]; then
    echo "whisper: sha256 не совпал для ${url}: ${actual} != ${sha}" >&2
    rm -f "${dest}.part"
    exit 1
  fi
  mv "${dest}.part" "${dest}"
}

sha256_of() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

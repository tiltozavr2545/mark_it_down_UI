# Pinned versions and sha256 of everything downloaded by whisper/fetch.sh
# and whisper/build.sh. Bumping a version is a deliberate action (the new
# sha256 is taken by hand after reading the changelog), not a background
# task: the transcript text depends on both the engine and the model.
#
# The engine on both platforms is whisper.cpp, built by build.sh from the
# same sources: on Windows (and the test host) with the native compiler,
# on Android with the NDK. For why whisper.cpp rather than faster-whisper,
# see docs/format-coverage.md#transcription-decisions-08.
# shellcheck shell=bash disable=SC2034

# --- models: Hugging Face, pinned to a repository commit ---
# small q8_0: multilingual (Russian, English, Italian — and ~95 more),
# the same small weights quantized to 8 bits: half the size of f16 (264 MB
# vs 488) with almost no quality loss, and faster on CPU. Not small.en —
# that one is English only.
MODEL_NAME="ggml-small-q8_0.bin"
MODEL_COMMIT="5359861c739e955e79d9a303bcbc70fb988958b1"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/${MODEL_COMMIT}/${MODEL_NAME}"
MODEL_SHA256="49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f"

# Silero VAD (0.9 MB): cuts out silence before transcription. Without it,
# Whisper "fills in" text that was never said during pauses ("To be
# continued…").
VAD_NAME="ggml-silero-v6.2.0.bin"
VAD_COMMIT="9ffd54a1e1ee413ddf265af9913beaf518d1639b"
VAD_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/${VAD_COMMIT}/${VAD_NAME}"
VAD_SHA256="2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"

# --- sources for build.sh ---
WHISPER_VERSION="1.9.5"
WHISPER_URL="https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v${WHISPER_VERSION}.tar.gz"
WHISPER_SHA256="ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720"

# Audio decoders (shim/mdw_decode.c): WAV, MP3, FLAC and Ogg Vorbis go via
# miniaudio (dr_wav/dr_mp3/dr_flac + stb_vorbis), Ogg Opus via libopus.
MINIAUDIO_VERSION="0.11.25"
MINIAUDIO_URL="https://github.com/mackron/miniaudio/archive/refs/tags/${MINIAUDIO_VERSION}.tar.gz"
MINIAUDIO_SHA256="b900edcffe979816e2560a0580b9b1216d674b4f17fbadeca8f777a7f8ab0274"

OPUS_VERSION="1.6.1"
OPUS_URL="https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz"
OPUS_SHA256="6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"

# --- Android: the same NDK the app uses (app/android/app/build.gradle.kts) ---
ANDROID_NDK_VERSION="27.0.12077973"
ANDROID_ABI="arm64-v8a"
ANDROID_PLATFORM="android-23"

# A download-with-sha256-check shared by both scripts. The cache lives in
# whisper/cache/ (in .gitignore); running again doesn't re-download.
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

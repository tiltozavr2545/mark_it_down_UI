# Pinned versions and sha256 of everything downloaded by
# tesseract/fetch.sh and tesseract/build.sh. Bumping a version is a
# deliberate action (the new sha256 is taken by hand after reading the
# changelog), not a background task: the OCR result on the fixtures
# depends on the engine and model versions.
#
# The engine on both platforms is Tesseract 5.5.1: on Android it's built
# by Tesseract4Android 4.9.0, on desktop by build.sh from the same
# sources.
# shellcheck shell=bash disable=SC2034

# --- models (tessdata_fast: 4-5x lighter than tessdata_best, with almost
# the same quality on printed text) ---
TESSDATA_COMMIT="87416418657359cb625c412a48b6e1d6d41c29bd"
TESSDATA_URL="https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/${TESSDATA_COMMIT}"
TESSDATA_RUS_SHA256="e16e5e036cce1d9ec2b00063cf8b54472625b9e14d893a169e2b0dedeb4df225"
TESSDATA_ENG_SHA256="7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2"

# --- Android: prebuilt .so from Tesseract4Android. Only the native
# arm64-v8a libraries are taken from the AAR; the Java wrapper isn't
# needed — we call the C API via FFI from core/. The AAR itself comes from
# JitPack, but in October 2026 JitPack rebuilt the 4.9.0 tag with an error
# and the file disappeared (the author has no AAR in GitHub Releases). So
# we download a copy of the same file (same sha256) from this
# repository's own service prerelease; the original address was
# https://jitpack.io/com/github/adaptech-cz/Tesseract4Android/tesseract4android/4.9.0/tesseract4android-4.9.0.aar
# ---
T4A_VERSION="4.9.0"
T4A_URL="https://github.com/tiltozavr2545/mark_it_down_UI/releases/download/deps-tesseract4android-${T4A_VERSION}/tesseract4android-${T4A_VERSION}.aar"
T4A_SHA256="bce5d6413a1a5ae3d7240033fbbc851ba3217d0a08d9769400e17a077f42cb2a"

# --- desktop: sources for build.sh ---
ZLIB_VERSION="1.3.2"
ZLIB_URL="https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz"
ZLIB_SHA256="bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"

LIBPNG_VERSION="1.6.48"
LIBPNG_URL="https://github.com/pnggroup/libpng/archive/refs/tags/v${LIBPNG_VERSION}.tar.gz"
LIBPNG_SHA256="b17e99026055727e8cba99160c3a9a7f9af788e9f786daeadded5a42243f1dd0"

LIBJPEG_VERSION="3.2.0"
LIBJPEG_URL="https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/${LIBJPEG_VERSION}.tar.gz"
LIBJPEG_SHA256="980dd81f425082aa6d7c9e47fef27554ce7a9ffc8e2f6e863b97d263c5c50858"

LEPTONICA_VERSION="1.87.0"
LEPTONICA_URL="https://github.com/DanBloomberg/leptonica/releases/download/${LEPTONICA_VERSION}/leptonica-${LEPTONICA_VERSION}.tar.gz"
LEPTONICA_SHA256="c73363397f96eb1295602bf44d708a994ad42046c791bf03ea0505d829bdb6a7"

TESSERACT_VERSION="5.5.1"
TESSERACT_URL="https://github.com/tesseract-ocr/tesseract/archive/refs/tags/${TESSERACT_VERSION}.tar.gz"
TESSERACT_SHA256="a7a3f2a7420cb6a6a94d80c24163e183cf1d2f1bed2df3bbc397c81808a57237"

# A download-with-sha256-check shared by both scripts. The cache lives in
# tesseract/cache/ (in .gitignore); running again doesn't re-download.
download() {
  local url="$1" sha="$2" dest="$3"
  if [[ -f "${dest}" ]] && [[ "$(sha256_of "${dest}")" == "${sha}" ]]; then
    return
  fi
  mkdir -p "$(dirname "${dest}")"
  echo "tesseract: качаю ${url}"
  curl -fsSL --retry 3 -o "${dest}.part" "${url}"
  local actual
  actual="$(sha256_of "${dest}.part")"
  if [[ "${actual}" != "${sha}" ]]; then
    echo "tesseract: sha256 не совпал для ${url}: ${actual} != ${sha}" >&2
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

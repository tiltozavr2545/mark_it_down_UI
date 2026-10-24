#!/usr/bin/env bash
set -euo pipefail

# The fast part of OCR (seconds, not minutes like build.sh): what isn't
# built, only downloaded, by the pinned versions and sha256 from
# tesseract/versions.sh. Nothing downloaded is committed — the same
# arrangement as pdfium/fetch.sh.
#
#   tesseract/tessdata/{rus,eng}.traineddata  the models — for dart test in core/
#   app/assets/tessdata/                      the same models as app assets
#                                             (on Windows they end up as
#                                             files next to .exe, on
#                                             Android they're copied from
#                                             the APK on the first OCR)
#   app/android/app/src/main/jniLibs/arm64-v8a/
#     libtesseract.so libleptonica.so libjpeg.so libpngx.so
#                                             from the Tesseract4Android AAR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tesseract/versions.sh
source "${ROOT_DIR}/tesseract/versions.sh"

CACHE_DIR="${ROOT_DIR}/tesseract/cache"
TESSDATA_DIR="${ROOT_DIR}/tesseract/tessdata"
ASSETS_DIR="${ROOT_DIR}/app/assets/tessdata"
JNI_DIR="${ROOT_DIR}/app/android/app/src/main/jniLibs/arm64-v8a"

mkdir -p "${TESSDATA_DIR}" "${ASSETS_DIR}"
for lang in rus eng; do
  case "${lang}" in
    rus) sha="${TESSDATA_RUS_SHA256}" ;;
    eng) sha="${TESSDATA_ENG_SHA256}" ;;
  esac
  download "${TESSDATA_URL}/${lang}.traineddata" "${sha}" \
    "${TESSDATA_DIR}/${lang}.traineddata"
  cp "${TESSDATA_DIR}/${lang}.traineddata" "${ASSETS_DIR}/"
done

ANDROID_LIBS=(libtesseract.so libleptonica.so libjpeg.so libpngx.so)
missing=0
for lib in "${ANDROID_LIBS[@]}"; do
  [[ -f "${JNI_DIR}/${lib}" ]] || missing=1
done
if [[ "${missing}" == 1 ]]; then
  aar="${CACHE_DIR}/tesseract4android-${T4A_VERSION}.aar"
  download "${T4A_URL}" "${T4A_SHA256}" "${aar}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  mkdir -p "${JNI_DIR}"
  for lib in "${ANDROID_LIBS[@]}"; do
    unzip -q -o -j "${aar}" "jni/arm64-v8a/${lib}" -d "${tmp}"
    cp "${tmp}/${lib}" "${JNI_DIR}/${lib}"
  done
fi

echo "tesseract: модели и Android-библиотеки на месте"

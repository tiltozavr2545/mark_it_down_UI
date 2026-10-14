#!/usr/bin/env bash
set -euo pipefail

# Собирает распознавание речи из исходников закреплённых версий
# (whisper/versions.sh): whisper.cpp + ggml + libopus + miniaudio и нашу
# прослойку whisper/shim/ (mdw.h) — одним CMake-проектом.
#
#   ./whisper/build.sh            хост: Windows (Git Bash + VS 2022), macOS,
#                                 Linux → whisper/native/host/
#   ./whisper/build.sh --android  arm64-v8a через NDK →
#                                 app/android/app/src/main/jniLibs/arm64-v8a/
#
# Готовых сборок не берём по той же причине, что у Tesseract: решаем сами,
# что внутри, — без WHISPER_CURL (скачивание модели по URL) и без GGML_RPC
# (бэкенд по сети), а в конце grep по собранному на сетевые библиотеки.
#
# Несколько минут на 4 ядрах (вариантов CPU-бэкенда десяток); в CI
# результат кэшируется по хешу этого файла, versions.sh и whisper/shim/. Не
# входит в make verify — см. Makefile (`make whisper`).
#
# FORCE=1 ./whisper/build.sh — пересобрать, даже если результат есть.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=whisper/versions.sh
source "${ROOT_DIR}/whisper/versions.sh"

TARGET=host
if [[ "${1:-}" == "--android" ]]; then TARGET=android; fi

case "$(uname -s)" in
  Darwin) HOST=macos ;;
  Linux) HOST=linux ;;
  MINGW* | MSYS*) HOST=windows ;;
  *)
    echo "whisper: неизвестный хост $(uname -s)" >&2
    exit 1
    ;;
esac

CACHE_DIR="${ROOT_DIR}/whisper/cache"
WORK_DIR="${ROOT_DIR}/whisper/build/${TARGET}"
if [[ "${TARGET}" == android ]]; then
  OUT_DIR="${ROOT_DIR}/app/android/app/src/main/jniLibs/${ANDROID_ABI}"
else
  OUT_DIR="${ROOT_DIR}/whisper/native/host"
fi
# Хеш рецепта в штампе: правка shim/ или версии — пересборка, без FORCE.
RECIPE_HASH="$(cat "${ROOT_DIR}/whisper/versions.sh" "${ROOT_DIR}/whisper/build.sh" \
  "${ROOT_DIR}"/whisper/shim/* |
  { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; } |
  cut -c1-12)"
STAMP="${OUT_DIR}/.whisper-built-${RECIPE_HASH}"

if [[ -f "${STAMP}" && "${FORCE:-}" != "1" ]]; then
  echo "whisper: уже собрано в ${OUT_DIR} (FORCE=1 — пересобрать)"
  exit 0
fi

# CMake на Windows — нативная программа и не понимает путей вида /d/a/...
# из Git Bash; отдаём ему C:/... .
native_path() {
  if [[ "${HOST}" == windows ]]; then cygpath -m "$1"; else echo "$1"; fi
}

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}/src" "${CACHE_DIR}"

unpack() {
  local name="$1" url="$2" sha="$3"
  download "${url}" "${sha}" "${CACHE_DIR}/${name}.tar.gz"
  mkdir -p "${WORK_DIR}/src/${name}"
  tar xzf "${CACHE_DIR}/${name}.tar.gz" -C "${WORK_DIR}/src/${name}" --strip-components=1
}

unpack whisper "${WHISPER_URL}" "${WHISPER_SHA256}"
unpack miniaudio "${MINIAUDIO_URL}" "${MINIAUDIO_SHA256}"
unpack opus "${OPUS_URL}" "${OPUS_SHA256}"

ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  "-DMDW_WHISPER_DIR=$(native_path "${WORK_DIR}/src/whisper")"
  "-DMDW_MINIAUDIO_DIR=$(native_path "${WORK_DIR}/src/miniaudio")"
  "-DMDW_OPUS_DIR=$(native_path "${WORK_DIR}/src/opus")"
)
GENERATOR=()
if [[ "${HOST}" != windows ]] && command -v ninja >/dev/null; then
  GENERATOR=(-G Ninja)
fi

if [[ "${TARGET}" == android ]]; then
  NDK="${ANDROID_NDK_HOME:-}"
  if [[ -z "${NDK}" || ! -d "${NDK}" || "$(basename "${NDK}")" != "${ANDROID_NDK_VERSION}" ]]; then
    for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "${HOME}/Library/Android/sdk" "${HOME}/Android/Sdk"; do
      if [[ -n "${sdk}" && -d "${sdk}/ndk/${ANDROID_NDK_VERSION}" ]]; then
        NDK="${sdk}/ndk/${ANDROID_NDK_VERSION}"
        break
      fi
    done
  fi
  if [[ -z "${NDK}" || ! -f "${NDK}/build/cmake/android.toolchain.cmake" ]]; then
    echo "whisper: нет NDK ${ANDROID_NDK_VERSION} (sdkmanager \"ndk;${ANDROID_NDK_VERSION}\")" >&2
    exit 1
  fi
  ARGS+=(
    "-DCMAKE_TOOLCHAIN_FILE=${NDK}/build/cmake/android.toolchain.cmake"
    "-DANDROID_ABI=${ANDROID_ABI}"
    "-DANDROID_PLATFORM=${ANDROID_PLATFORM}"
    # Страницы 16 КБ: Android 15+ на новых телефонах и требование Play.
    -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON
  )
else
  case "${HOST}" in
    macos) ARGS+=(-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0) ;;
    windows) ARGS+=(-A x64) ;;
  esac
fi

echo "whisper: собираю ${TARGET} (whisper.cpp ${WHISPER_VERSION}, opus ${OPUS_VERSION}, miniaudio ${MINIAUDIO_VERSION})"
cmake -S "$(native_path "${ROOT_DIR}/whisper/shim")" -B "$(native_path "${WORK_DIR}/cmake")" \
  ${GENERATOR[@]+"${GENERATOR[@]}"} "${ARGS[@]}" >"${WORK_DIR}/configure.log" 2>&1 ||
  { tail -50 "${WORK_DIR}/configure.log"; exit 1; }
cmake --build "$(native_path "${WORK_DIR}/cmake")" --config Release \
  --target markitdown_whisper --parallel "${JOBS}" >"${WORK_DIR}/build.log" 2>&1 ||
  { grep -E -i -B2 -A8 'error' "${WORK_DIR}/build.log" | tail -80; exit 1; }

BUILT="${WORK_DIR}/cmake/bin"
# Многоконфигурационный генератор Visual Studio кладёт в bin/Release/.
[[ -d "${BUILT}/Release" ]] && BUILT="${BUILT}/Release"

# Каталог назначения на Android общий с PDFium и Tesseract — удаляем только
# своё, а не всё подряд.
mkdir -p "${OUT_DIR}"
rm -f "${OUT_DIR}"/.whisper-built-* "${OUT_DIR}"/*markitdown_whisper* \
  "${OUT_DIR}"/*whisper.* "${OUT_DIR}"/*whisper.so* "${OUT_DIR}"/*ggml*
# Варианты CPU-бэкенда — MODULE-библиотеки: на macOS тоже .so.
case "${TARGET}-${HOST}" in
  android-*) cp "${BUILT}"/lib{markitdown_whisper,whisper,ggml,ggml-base}.so \
    "${BUILT}"/libggml-cpu-*.so "${OUT_DIR}/" ;;
  host-windows) cp "${BUILT}"/{markitdown_whisper,whisper,ggml,ggml-base}.dll \
    "${BUILT}"/ggml-cpu-*.dll "${OUT_DIR}/" ;;
  host-macos) cp -a "${BUILT}"/libmarkitdown_whisper.dylib "${BUILT}"/lib{whisper,ggml,ggml-base}.*dylib \
    "${BUILT}"/libggml-cpu-*.so "${OUT_DIR}/" ;;
  host-linux) cp -a "${BUILT}"/libmarkitdown_whisper.so "${BUILT}"/lib{whisper,ggml,ggml-base}.so* \
    "${BUILT}"/libggml-cpu-*.so "${OUT_DIR}/" ;;
esac

# Главное обещание продукта: в собранном нет сетевых библиотек. Имена
# импортируемых библиотек лежат в бинарнике строками — grep их видит на всех
# ОС без objdump/otool/dumpbin.
if grep -l -a -i -E 'libcurl|ws2_32\.dll|winhttp|wininet' \
  "${OUT_DIR}"/*markitdown_whisper* "${OUT_DIR}"/*whisper* "${OUT_DIR}"/*ggml*; then
  echo "whisper: в сборке есть ссылка на сетевую библиотеку (см. выше)" >&2
  exit 1
fi

touch "${STAMP}"
echo "whisper: готово в ${OUT_DIR}:"
ls -la "${OUT_DIR}" | grep -E 'whisper|ggml'

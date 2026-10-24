#!/usr/bin/env bash
set -euo pipefail

# Builds speech recognition from the sources of pinned versions
# (whisper/versions.sh): whisper.cpp + ggml + libopus + miniaudio, plus our
# own layer whisper/shim/ (mdw.h) — as a single CMake project.
#
#   ./whisper/build.sh            host: Windows (Git Bash + VS 2022), macOS,
#                                 Linux → whisper/native/host/
#   ./whisper/build.sh --android  arm64-v8a via the NDK →
#                                 app/android/app/src/main/jniLibs/arm64-v8a/
#
# We don't take prebuilt binaries, for the same reason as Tesseract: we
# decide for ourselves what's inside — without WHISPER_CURL (downloading
# the model by URL) and without GGML_RPC (a networked backend), and at the
# end grep the build for networking libraries.
#
# A few minutes on 4 cores (there's about a dozen CPU backend variants); in
# CI the result is cached by the hash of this file, versions.sh, and
# whisper/shim/. Not part of make verify — see the Makefile (`make
# whisper`).
#
# FORCE=1 ./whisper/build.sh — rebuild even if the result already exists.

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
# Recipe hash in the stamp: editing shim/ or bumping a version triggers a
# rebuild, without needing FORCE.
RECIPE_HASH="$(cat "${ROOT_DIR}/whisper/versions.sh" "${ROOT_DIR}/whisper/build.sh" \
  "${ROOT_DIR}"/whisper/shim/* |
  { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; } |
  cut -c1-12)"
STAMP="${OUT_DIR}/.whisper-built-${RECIPE_HASH}"

if [[ -f "${STAMP}" && "${FORCE:-}" != "1" ]]; then
  echo "whisper: уже собрано в ${OUT_DIR} (FORCE=1 — пересобрать)"
  exit 0
fi

# CMake on Windows is a native program and doesn't understand paths like
# /d/a/... from Git Bash; we hand it C:/... instead.
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
    # 16 KB pages: Android 15+ on new phones, and a Play requirement.
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
# The Visual Studio multi-config generator puts things in bin/Release/.
[[ -d "${BUILT}/Release" ]] && BUILT="${BUILT}/Release"

# The destination directory on Android is shared with PDFium and
# Tesseract — we remove only our own files, not everything in sight.
mkdir -p "${OUT_DIR}"
rm -f "${OUT_DIR}"/.whisper-built-* "${OUT_DIR}"/*markitdown_whisper* \
  "${OUT_DIR}"/*whisper.* "${OUT_DIR}"/*whisper.so* "${OUT_DIR}"/*ggml*
# CPU backend variants are MODULE libraries: .so even on macOS.
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

# The product's core promise: the build contains no networking libraries.
# Imported library names sit in the binary as plain strings — grep can see
# them on every OS without objdump/otool/dumpbin.
if grep -l -a -i -E 'libcurl|ws2_32\.dll|winhttp|wininet' \
  "${OUT_DIR}"/*markitdown_whisper* "${OUT_DIR}"/*whisper* "${OUT_DIR}"/*ggml*; then
  echo "whisper: в сборке есть ссылка на сетевую библиотеку (см. выше)" >&2
  exit 1
fi

touch "${STAMP}"
echo "whisper: готово в ${OUT_DIR}:"
ls -la "${OUT_DIR}" | grep -E 'whisper|ggml'

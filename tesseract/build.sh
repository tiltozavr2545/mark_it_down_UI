#!/usr/bin/env bash
set -euo pipefail

# Builds Tesseract for the desktop host from the sources of pinned
# versions (tesseract/versions.sh) into tesseract/native/host/: two shared
# libraries — Leptonica (libpng, libjpeg-turbo, and on Windows zlib are
# statically linked in) and Tesseract on top of it. Nothing else: core/
# calls their C API via FFI.
#
# Why our own build instead of a prebuilt one: the vcpkg port and the UB
# Mannheim installer pull in libcurl (Tesseract can download an image by
# URL) — we don't put a networking library into an app that promises not
# to reach the network. Here we use DISABLE_CURL and DISABLE_ARCHIVE, and
# at the end there's a check that none of the built libraries reference
# networking ones. ENABLE_NATIVE is off: what's built in CI must run on
# any x86-64, not only the runner's own processor (Tesseract picks its
# vector branches itself at runtime).
#
# Hosts: macOS and Linux (cc/c++ + cmake), Windows via Git Bash with Visual
# Studio 2022 (the default CMake generator). About 10 minutes on 4 cores;
# in CI the result is cached by the hash of this file and versions.sh. Not
# part of make verify — see the Makefile (`make tesseract`).
#
# FORCE=1 ./tesseract/build.sh — rebuild even if the result already exists.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tesseract/versions.sh
source "${ROOT_DIR}/tesseract/versions.sh"

CACHE_DIR="${ROOT_DIR}/tesseract/cache"
WORK_DIR="${ROOT_DIR}/tesseract/build"
PREFIX="${WORK_DIR}/prefix"
OUT_DIR="${ROOT_DIR}/tesseract/native/host"
STAMP="${OUT_DIR}/.built-${TESSERACT_VERSION}-${LEPTONICA_VERSION}"

if [[ -f "${STAMP}" && "${FORCE:-}" != "1" ]]; then
  echo "tesseract: уже собрано в ${OUT_DIR} (FORCE=1 — пересобрать)"
  exit 0
fi

case "$(uname -s)" in
  Darwin) HOST=macos ;;
  Linux) HOST=linux ;;
  MINGW* | MSYS*) HOST=windows ;;
  *)
    echo "tesseract: неизвестный хост $(uname -s)" >&2
    exit 1
    ;;
esac

# CMake on Windows is a native program and doesn't understand paths like
# /d/a/... from Git Bash; we hand it C:/... instead.
native_path() {
  if [[ "${HOST}" == windows ]]; then cygpath -m "$1"; else echo "$1"; fi
}

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}/src" "${PREFIX}" "${CACHE_DIR}"

unpack() {
  local name="$1" url="$2" sha="$3"
  download "${url}" "${sha}" "${CACHE_DIR}/${name}.tar.gz"
  mkdir -p "${WORK_DIR}/src/${name}"
  tar xzf "${CACHE_DIR}/${name}.tar.gz" -C "${WORK_DIR}/src/${name}" --strip-components=1
}

COMMON=(
  -DCMAKE_BUILD_TYPE=Release
  "-DCMAKE_INSTALL_PREFIX=$(native_path "${PREFIX}")"
  "-DCMAKE_PREFIX_PATH=$(native_path "${PREFIX}")"
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
)
case "${HOST}" in
  macos)
    # The libraries reference each other via @rpath and look for their
    # neighbors right next to themselves — the directory can be moved as a
    # whole.
    COMMON+=(
      -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
      -DCMAKE_INSTALL_NAME_DIR=@rpath
      -DCMAKE_INSTALL_RPATH=@loader_path
    )
    ;;
  linux) COMMON+=("-DCMAKE_INSTALL_RPATH=\$ORIGIN") ;;
  windows) COMMON+=(-A x64) ;;
esac

build() {
  local name="$1"
  shift
  echo "tesseract: собираю ${name}"
  cmake -S "$(native_path "${WORK_DIR}/src/${name}")" \
    -B "$(native_path "${WORK_DIR}/build-${name}")" \
    "${COMMON[@]}" "$@" >"${WORK_DIR}/${name}.configure.log" ||
    { tail -50 "${WORK_DIR}/${name}.configure.log"; exit 1; }
  cmake --build "$(native_path "${WORK_DIR}/build-${name}")" \
    --config Release --parallel "${JOBS}" >"${WORK_DIR}/${name}.build.log" ||
    { tail -50 "${WORK_DIR}/${name}.build.log"; exit 1; }
  cmake --install "$(native_path "${WORK_DIR}/build-${name}")" \
    --config Release >/dev/null
}

# The first file in prefix/lib matching one of the names: static libraries
# are named differently across OSes and versions.
static_lib() {
  local candidate
  for candidate in "$@"; do
    if [[ -f "${PREFIX}/lib/${candidate}" ]]; then
      native_path "${PREFIX}/lib/${candidate}"
      return
    fi
  done
  echo "tesseract: не нашёл ни одной из $* в ${PREFIX}/lib" >&2
  exit 1
}

INCLUDE="$(native_path "${PREFIX}/include")"
# An empty array under set -u in bash 3.2 (macOS) is an "unbound
# variable", so below it's expanded as ${ZLIB_ARGS[@]+…}.
ZLIB_ARGS=()
if [[ "${HOST}" == windows ]]; then
  # On macOS and Linux zlib is a system library; on Windows there isn't
  # one, so we link it in statically.
  unpack zlib "${ZLIB_URL}" "${ZLIB_SHA256}"
  build zlib -DZLIB_BUILD_EXAMPLES=OFF
  ZLIB_ARGS=(
    "-DZLIB_LIBRARY=$(static_lib zs.lib zlibstatic.lib)"
    "-DZLIB_INCLUDE_DIR=${INCLUDE}"
  )
fi

unpack libpng "${LIBPNG_URL}" "${LIBPNG_SHA256}"
build libpng -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF \
  -DPNG_TOOLS=OFF -DPNG_FRAMEWORK=OFF ${ZLIB_ARGS[@]+"${ZLIB_ARGS[@]}"}

# SIMD in libjpeg-turbo requires NASM; without it decoding is slower, but
# against the backdrop of OCR itself (seconds) that's a fraction of a
# percent.
unpack libjpeg "${LIBJPEG_URL}" "${LIBJPEG_SHA256}"
build libjpeg -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_SIMD=OFF \
  -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF

unpack leptonica "${LEPTONICA_URL}" "${LEPTONICA_SHA256}"
build leptonica -DBUILD_SHARED_LIBS=ON -DBUILD_PROG=OFF -DSW_BUILD=OFF \
  -DENABLE_ZLIB=ON -DENABLE_PNG=ON -DENABLE_JPEG=ON -DENABLE_GIF=OFF \
  -DENABLE_TIFF=OFF -DENABLE_WEBP=OFF -DENABLE_OPENJPEG=OFF \
  "-DPNG_LIBRARY=$(static_lib libpng16.a libpng16_static.lib libpng.a)" \
  "-DPNG_PNG_INCLUDE_DIR=${INCLUDE}" \
  "-DJPEG_LIBRARY=$(static_lib libjpeg.a jpeg-static.lib)" \
  "-DJPEG_INCLUDE_DIR=${INCLUDE}" \
  ${ZLIB_ARGS[@]+"${ZLIB_ARGS[@]}"}

unpack tesseract "${TESSERACT_URL}" "${TESSERACT_SHA256}"
# On Windows, Tesseract's CMake links Ws2_32 unconditionally — for
# ScrollView (a socket-based debug viewer), which GRAPHICS_DISABLED
# already turns off anyway. We strip the library from the link step: if
# sockets are still used somewhere, the build fails at link time instead
# of shipping to the user.
sed -i.orig 's/set(LIB_Ws2_32 Ws2_32)/set(LIB_Ws2_32 "")/' \
  "${WORK_DIR}/src/tesseract/CMakeLists.txt"
grep -q 'set(LIB_Ws2_32 "")' "${WORK_DIR}/src/tesseract/CMakeLists.txt" ||
  { echo "tesseract: не нашёл Ws2_32 в CMakeLists — проверить рецепт" >&2; exit 1; }
build tesseract -DBUILD_SHARED_LIBS=ON -DSW_BUILD=OFF \
  -DBUILD_TRAINING_TOOLS=OFF -DBUILD_TESTS=OFF -DGRAPHICS_DISABLED=ON \
  -DOPENMP_BUILD=OFF -DENABLE_NATIVE=OFF -DENABLE_LTO=OFF \
  -DDISABLE_CURL=ON -DDISABLE_ARCHIVE=ON -DDISABLE_TIFF=ON \
  -DINSTALL_CONFIGS=OFF \
  "-DLeptonica_DIR=$(native_path "${PREFIX}/lib/cmake/leptonica")"

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"
case "${HOST}" in
  macos) cp -a "${PREFIX}"/lib/lib{leptonica,tesseract}*.dylib "${OUT_DIR}/" ;;
  linux) cp -a "${PREFIX}"/lib/lib{leptonica,tesseract}*.so* "${OUT_DIR}/" ;;
  windows) cp "${PREFIX}"/bin/{leptonica,tesseract}*.dll "${OUT_DIR}/" ;;
esac

# The product's core promise: the build contains no networking libraries.
# Imported library names sit in the binary as plain strings — grep can see
# them on all three OSes without objdump/otool/dumpbin.
if grep -l -a -i -E 'libcurl|ws2_32\.dll|winhttp|wininet' "${OUT_DIR}"/*; then
  echo "tesseract: в сборке есть ссылка на сетевую библиотеку (см. выше)" >&2
  exit 1
fi

touch "${STAMP}"
echo "tesseract: готово — $(ls "${OUT_DIR}" | tr '\n' ' ')"

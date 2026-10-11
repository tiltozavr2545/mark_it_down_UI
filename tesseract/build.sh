#!/usr/bin/env bash
set -euo pipefail

# Собирает Tesseract для десктопа-хоста из исходников закреплённых версий
# (tesseract/versions.sh) в tesseract/native/host/: две shared-библиотеки —
# Leptonica (libpng, libjpeg-turbo и, на Windows, zlib вшиты статически) и
# Tesseract поверх неё. Больше ничего: core/ зовёт их C API через FFI.
#
# Почему своя сборка, а не готовая: порт vcpkg и инсталлятор UB Mannheim
# тянут libcurl (Tesseract умеет качать картинку по URL) — сетевую библиотеку
# в приложение, которое обещает не ходить в сеть, не кладём. Здесь
# DISABLE_CURL и DISABLE_ARCHIVE, а в конце — проверка, что ни одна собранная
# библиотека не ссылается на сетевые. ENABLE_NATIVE выключен: собранное в CI
# должно запускаться на любом x86-64, а не только на процессоре раннера
# (векторные ветки Tesseract выбирает в рантайме сам).
#
# Хосты: macOS и Linux (cc/c++ + cmake), Windows — Git Bash с Visual Studio
# 2022 (генератор CMake по умолчанию). Около 10 минут на 4 ядрах; в CI
# результат кэшируется по хешу этого файла и versions.sh. Не входит в
# make verify — см. Makefile (`make tesseract`).
#
# FORCE=1 ./tesseract/build.sh — пересобрать, даже если результат есть.

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

# CMake на Windows — нативная программа и не понимает путей вида /d/a/...
# из Git Bash; отдаём ему C:/... .
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
    # Библиотеки ссылаются друг на друга через @rpath и ищут соседей рядом
    # с собой — каталог можно переносить целиком.
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

# Первый файл в prefix/lib, подходящий под одно из имён: статические
# библиотеки называются по-разному на разных ОС и версиях.
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
# Пустой массив под set -u в bash 3.2 (macOS) — «unbound variable»,
# поэтому ниже он раскрывается как ${ZLIB_ARGS[@]+…}.
ZLIB_ARGS=()
if [[ "${HOST}" == windows ]]; then
  # На macOS и Linux zlib — системная; на Windows её нет, вшиваем.
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

# SIMD у libjpeg-turbo требует NASM; без него декодирование медленнее, но
# на фоне самого OCR (секунды) это доли процента.
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
# На Windows CMake Tesseract линкует Ws2_32 безусловно — ради ScrollView
# (отладочный просмотрщик по сокету), который GRAPHICS_DISABLED и так
# выключает. Убираем библиотеку из линковки: если сокеты где-то всё же
# используются, сборка упадёт на линковке, а не уедет к пользователю.
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

# Главное обещание продукта: в собранном нет сетевых библиотек. Имена
# импортируемых библиотек лежат в бинарнике строками — grep их видит на всех
# трёх ОС без objdump/otool/dumpbin.
if grep -l -a -i -E 'libcurl|ws2_32\.dll|winhttp|wininet' "${OUT_DIR}"/*; then
  echo "tesseract: в сборке есть ссылка на сетевую библиотеку (см. выше)" >&2
  exit 1
fi

touch "${STAMP}"
echo "tesseract: готово — $(ls "${OUT_DIR}" | tr '\n' ' ')"

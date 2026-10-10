#!/usr/bin/env bash
set -euo pipefail

# Качает готовые shared-библиотеки PDFium из bblanchon/pdfium-binaries —
# не V8/XFA-вариант (он втрое тяжелее и не нужен для извлечения текста).
# См. docs/format-coverage.md#pdf-чем-извлекать-текст.
#
# Ничего из скачанного не коммитится — тот же порядок, что у
# python-build-standalone в sidecar/, см. docs/python-sidecar.md.
#
# Версия закреплена явно, а не "latest": бинарник, который сегодня гоняет
# CI и стоит на машине разработчика, не должен подмениться молча через
# месяц. Поднимать версию — осознанное действие, не фон.
PDFIUM_TAG="chromium%2F8086"
BASE_URL="https://github.com/bblanchon/pdfium-binaries/releases/download/${PDFIUM_TAG}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_DIR="${ROOT_DIR}/pdfium/native/host"
JNI_DIR="${ROOT_DIR}/app/android/app/src/main/jniLibs/arm64-v8a"

# subdir — где лежит библиотека внутри архива: у Windows-сборки DLL в bin/,
# у остальных — в lib/ (в lib/ Windows-архива — только import-библиотека
# pdfium.dll.lib для линковки, нам не нужная: грузим через FFI).
fetch() {
  local asset="$1" dest_dir="$2" lib_name="$3" subdir="${4:-lib}"
  if [[ -f "${dest_dir}/${lib_name}" ]]; then
    echo "pdfium: уже есть ${dest_dir}/${lib_name}"
    return
  fi
  mkdir -p "${dest_dir}"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  echo "pdfium: качаю ${asset}"
  curl -sL -o "${tmp}/pkg.tgz" "${BASE_URL}/${asset}"
  tar xzf "${tmp}/pkg.tgz" -C "${tmp}"
  cp "${tmp}/${subdir}/${lib_name}" "${dest_dir}/${lib_name}"
  echo "pdfium: готово ${dest_dir}/${lib_name}"
}

# Для dev/test на хост-машине — macOS (dart test), Linux (CI) или Windows
# (CI на windows-latest, Git Bash: uname -s там MINGW64_NT-…/MSYS_NT-…).
# Эту же копию app/windows/CMakeLists.txt кладёт в сборку рядом с .exe.
case "$(uname -s)" in
  Darwin) fetch "pdfium-mac-x64.tgz" "${HOST_DIR}" "libpdfium.dylib" ;;
  Linux) fetch "pdfium-linux-x64.tgz" "${HOST_DIR}" "libpdfium.so" ;;
  MINGW* | MSYS*) fetch "pdfium-win-x64.tgz" "${HOST_DIR}" "pdfium.dll" "bin" ;;
  *)
    echo "pdfium: неизвестная платформа для dev-сборки: $(uname -s)" >&2
    exit 1
    ;;
esac

# Для Android-сборки приложения — всегда arm64, независимо от хоста.
fetch "pdfium-android-arm64.tgz" "${JNI_DIR}" "libpdfium.so"

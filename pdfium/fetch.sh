#!/usr/bin/env bash
set -euo pipefail

# Downloads prebuilt PDFium shared libraries from bblanchon/pdfium-binaries
# — not the V8/XFA variant (it's three times heavier and not needed for
# text extraction). See docs/format-coverage.md#pdf-чем-извлекать-текст.
#
# Nothing downloaded gets committed — the same approach as
# python-build-standalone in sidecar/, see docs/python-sidecar.md.
#
# The version is pinned explicitly, not "latest": the binary that CI and a
# developer's machine run today shouldn't silently get swapped out in a
# month. Bumping the version is a deliberate action, not something that
# happens in the background.
PDFIUM_TAG="chromium%2F8086"
BASE_URL="https://github.com/bblanchon/pdfium-binaries/releases/download/${PDFIUM_TAG}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_DIR="${ROOT_DIR}/pdfium/native/host"
JNI_DIR="${ROOT_DIR}/app/android/app/src/main/jniLibs/arm64-v8a"

# subdir — where the library sits inside the archive: for the Windows
# build the DLL is in bin/, for the rest it's in lib/ (lib/ in the Windows
# archive has only the pdfium.dll.lib import library for linking, which we
# don't need: we load it via FFI).
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

# For dev/test on the host machine — macOS (dart test), Linux (CI), or
# Windows (CI on windows-latest, Git Bash: uname -s there is
# MINGW64_NT-…/MSYS_NT-…). app/windows/CMakeLists.txt places this same
# copy into the build next to the .exe.
case "$(uname -s)" in
  Darwin) fetch "pdfium-mac-x64.tgz" "${HOST_DIR}" "libpdfium.dylib" ;;
  Linux) fetch "pdfium-linux-x64.tgz" "${HOST_DIR}" "libpdfium.so" ;;
  MINGW* | MSYS*) fetch "pdfium-win-x64.tgz" "${HOST_DIR}" "pdfium.dll" "bin" ;;
  *)
    echo "pdfium: неизвестная платформа для dev-сборки: $(uname -s)" >&2
    exit 1
    ;;
esac

# For the app's Android build — always arm64, regardless of the host.
fetch "pdfium-android-arm64.tgz" "${JNI_DIR}" "libpdfium.so"

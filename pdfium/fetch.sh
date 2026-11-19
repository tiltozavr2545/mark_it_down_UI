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
PDFIUM_TAG="chromium%2F8165"
BASE_URL="https://github.com/bblanchon/pdfium-binaries/releases/download/${PDFIUM_TAG}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_DIR="${ROOT_DIR}/pdfium/native/host"
JNI_DIR="${ROOT_DIR}/app/android/app/src/main/jniLibs/arm64-v8a"

# subdir — where the library sits inside the archive: for the Windows
# build the DLL is in bin/, for the rest it's in lib/ (lib/ in the Windows
# archive has only the pdfium.dll.lib import library for linking, which we
# don't need: we load it via FFI).
fetch() (
  local asset="$1" expected_sha="$2" dest_dir="$3" lib_name="$4" subdir="${5:-lib}"
  local stamp="${dest_dir}/.pdfium-version"
  if [[ -f "${dest_dir}/${lib_name}" && -f "${stamp}" ]] &&
     [[ "$(<"${stamp}")" == "${expected_sha}" ]]; then
    echo "pdfium: уже есть ${dest_dir}/${lib_name}"
    return
  fi
  mkdir -p "${dest_dir}"
  local tmp actual_sha
  tmp="$(mktemp -d "${dest_dir}/.pdfium.XXXXXX")"
  trap 'rm -rf "${tmp}"' EXIT
  echo "pdfium: качаю ${asset}"
  curl -fsSL --retry 3 -o "${tmp}/pkg.tgz" "${BASE_URL}/${asset}"
  if command -v sha256sum >/dev/null; then
    actual_sha="$(sha256sum "${tmp}/pkg.tgz" | cut -d' ' -f1)"
  else
    actual_sha="$(shasum -a 256 "${tmp}/pkg.tgz" | cut -d' ' -f1)"
  fi
  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    echo "pdfium: SHA-256 не совпал для ${asset}: ${actual_sha} != ${expected_sha}" >&2
    exit 1
  fi
  tar xzf "${tmp}/pkg.tgz" -C "${tmp}"
  printf '%s\n' "${expected_sha}" > "${tmp}/version"
  rm -f "${stamp}"
  mv -f "${tmp}/${subdir}/${lib_name}" "${dest_dir}/${lib_name}"
  mv -f "${tmp}/version" "${stamp}"
  echo "pdfium: готово ${dest_dir}/${lib_name}"
)

# For dev/test on the host machine — macOS (dart test), Linux (CI), or
# Windows (CI on windows-latest, Git Bash: uname -s there is
# MINGW64_NT-…/MSYS_NT-…). app/windows/CMakeLists.txt places this same
# copy into the build next to the .exe.
case "$(uname -s)" in
  Darwin) fetch "pdfium-mac-x64.tgz" \
    "07285915b564e46a432a9909dbc1f15892885ca6489e3faeefc70dee77ed371a" \
    "${HOST_DIR}" "libpdfium.dylib" ;;
  Linux) fetch "pdfium-linux-x64.tgz" \
    "ba7865e16c0271daab75256790be06c26272190afe6e2a70eae0bb39bb99089c" \
    "${HOST_DIR}" "libpdfium.so" ;;
  MINGW* | MSYS*) fetch "pdfium-win-x64.tgz" \
    "ca7338ae7779b8b1b82f4580305c4d762d214f8df1d54b47647fe3cc75989ded" \
    "${HOST_DIR}" "pdfium.dll" "bin" ;;
  *)
    echo "pdfium: неизвестная платформа для dev-сборки: $(uname -s)" >&2
    exit 1
    ;;
esac

# For the app's Android build — always arm64, regardless of the host.
fetch "pdfium-android-arm64.tgz" \
  "ce4f17fea8881cdf163950748ab90854cf33f296309fab68de9441a1d41ff6cc" \
  "${JNI_DIR}" "libpdfium.so"

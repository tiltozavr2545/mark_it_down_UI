#!/usr/bin/env bash
# Shared sidecar settings: versions, host table, interpreter download.
# Sourced from build.sh, lock.sh, and sign.sh; does nothing by itself.
#
# Versions are pinned explicitly rather than "latest": the sidecar is the
# reference implementation for comparison against the Dart core, and a
# reference that changes silently isn't a reference at all. Bumping the
# version is a deliberate action, done together with re-checking fixtures
# and updating the lock file (make sidecar-lock, see docs/python-sidecar.md).
PBS_TAG="20260929"
PY_VERSION="3.12.14"
MARKITDOWN_VERSION="0.1.8"
MARKITDOWN_EXTRAS="pdf,docx,xlsx,xls,pptx,outlook"
# Formats the sidecar actually handles (the --format option in run.py).
# Goes into manifest.json; change only together with run.py and the check below.
FORMATS=(pdf docx xlsx xls pptx msg)

SIDECAR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${SIDECAR_DIR}/cache"
BASE_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}"

# Host -> asset and sha256. Checksums verified against the ${PBS_TAG}
# release's SHA256SUMS.
# PY_REL — the interpreter inside the unpacked python/: on Windows,
# python-build-standalone uses the same layout as the official installer
# (python.exe at the root, stdlib in Lib/), not bin/ + lib/python3.X/.
PY_REL="python/bin/python3"
case "$(uname -s)-$(uname -m)" in
  Darwin-x86_64)
    HOST="macos-x86_64"; TRIPLE="x86_64-apple-darwin"
    SHA256="f51ec8a7fa0ede129a5e2e942a2a453ba4830adaca2289da4449390e42443292" ;;
  Darwin-arm64)
    HOST="macos-arm64"; TRIPLE="aarch64-apple-darwin"
    SHA256="de6b8f94fa765639b423ea353ab340669704c7186f96ee3cab389dcfde770c3c" ;;
  Linux-x86_64)
    HOST="linux-x86_64"; TRIPLE="x86_64-unknown-linux-gnu"
    SHA256="06c90b93f419b63371c18f20fed0558a1a901f6518c3c24f755077e048447e7f" ;;
  Linux-aarch64)
    HOST="linux-aarch64"; TRIPLE="aarch64-unknown-linux-gnu"
    SHA256="9c797cf657f6dced51d3e74eeabd7c1ca742d5bf10f66080a290e424ced8edaf" ;;
  # Git Bash (CI on windows-latest, Stage 5): uname -s is MINGW64_NT-…/MSYS_NT-….
  MINGW*-x86_64 | MSYS*-x86_64)
    HOST="windows-x86_64"; TRIPLE="x86_64-pc-windows-msvc"
    SHA256="28728baf30b65e263f0b25c5a85be8226e7ab0d212fbadd6a8f0f796139fa804"
    PY_REL="python/python.exe" ;;
  *)
    echo "sidecar: неизвестный хост: $(uname -s)-$(uname -m)" >&2
    exit 1 ;;
esac

ASSET="cpython-${PY_VERSION}+${PBS_TAG}-${TRIPLE}-install_only.tar.gz"
DIST_DIR="${SIDECAR_DIR}/dist/${HOST}"
LOCK_FILE="${SIDECAR_DIR}/locks/${HOST}.txt"

# shasum is on macOS, sha256sum is on Linux and Git Bash; use whichever exists.
if command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
fi

# Embedded Python scripts (lock.sh, build.sh) are run with -X utf8: on
# Windows, stdout in a pipe is cp1252, and print with Cyrillic raises
# UnicodeEncodeError, while PYTHONUTF8/PYTHONIOENCODING are ignored under -I.

# Path for arguments to the native Windows process (python.exe): Git Bash
# itself translates /d/a/... to D:/a/..., but with forward slashes, and
# compileall -s compares the prefix via os.sep — so it would silently fail to
# strip the build path from the .pyc.
native_path() {
  if [[ "${HOST}" == windows-* ]]; then cygpath -w "$1"; else echo "$1"; fi
}

# Interpreter: download cache in sidecar/cache (in .gitignore). The result is
# a sha256-verified archive in ${ARCHIVE}.
fetch_interpreter() {
  mkdir -p "${CACHE_DIR}"
  ARCHIVE="${CACHE_DIR}/${ASSET}"
  if [[ -f "${ARCHIVE}" && "$(sha256_of "${ARCHIVE}")" != "${SHA256}" ]]; then
    echo "sidecar: кэш ${ASSET} повреждён, качаю заново"
    rm -f "${ARCHIVE}"
  fi
  if [[ ! -f "${ARCHIVE}" ]]; then
    echo "sidecar: качаю ${ASSET}"
    # '+' in the filename, in the URL — %2B.
    curl -fL --retry 3 -o "${ARCHIVE}.part" "${BASE_URL}/${ASSET//+/%2B}"
    mv "${ARCHIVE}.part" "${ARCHIVE}"
  fi
  ACTUAL="$(sha256_of "${ARCHIVE}")"
  if [[ "${ACTUAL}" != "${SHA256}" ]]; then
    echo "sidecar: sha256 ${ASSET} не совпал: ожидался ${SHA256}, получен ${ACTUAL}" >&2
    rm -f "${ARCHIVE}"
    exit 1
  fi
}

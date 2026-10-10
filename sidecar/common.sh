#!/usr/bin/env bash
# Общие настройки сайдкара: версии, таблица хостов, загрузка интерпретатора.
# Подключается (source) из build.sh, lock.sh и sign.sh; сам ничего не делает.
#
# Версии закреплены явно, а не "latest": сайдкар — эталон для сверки с
# Dart-ядром, и эталон, который меняется молча, ничего не эталонит. Поднимать
# версию — осознанное действие, вместе с пересверкой фикстур и обновлением
# lock-файла (make sidecar-lock, см. docs/python-sidecar.md).
PBS_TAG="20260929"
PY_VERSION="3.12.14"
MARKITDOWN_VERSION="0.1.8"
MARKITDOWN_EXTRAS="pdf,docx,xlsx,xls,pptx,outlook"
# Форматы, которые сайдкар реально берёт на себя (ключ --format в run.py).
# Попадает в manifest.json; менять только вместе с run.py и проверкой ниже.
FORMATS=(pdf docx xlsx xls pptx msg)

SIDECAR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${SIDECAR_DIR}/cache"
BASE_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}"

# Хост -> ассет и sha256. Суммы сверены с SHA256SUMS релиза ${PBS_TAG}.
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
  *)
    echo "sidecar: неизвестный хост: $(uname -s)-$(uname -m)" >&2
    exit 1 ;;
esac

ASSET="cpython-${PY_VERSION}+${PBS_TAG}-${TRIPLE}-install_only.tar.gz"
DIST_DIR="${SIDECAR_DIR}/dist/${HOST}"
LOCK_FILE="${SIDECAR_DIR}/locks/${HOST}.txt"

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Интерпретатор: кэш загрузок в sidecar/cache (в .gitignore). Результат —
# проверенный по sha256 архив в ${ARCHIVE}.
fetch_interpreter() {
  mkdir -p "${CACHE_DIR}"
  ARCHIVE="${CACHE_DIR}/${ASSET}"
  if [[ -f "${ARCHIVE}" && "$(sha256_of "${ARCHIVE}")" != "${SHA256}" ]]; then
    echo "sidecar: кэш ${ASSET} повреждён, качаю заново"
    rm -f "${ARCHIVE}"
  fi
  if [[ ! -f "${ARCHIVE}" ]]; then
    echo "sidecar: качаю ${ASSET}"
    # '+' в имени файла в URL — %2B.
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

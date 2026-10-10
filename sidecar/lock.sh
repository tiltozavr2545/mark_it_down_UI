#!/usr/bin/env bash
set -euo pipefail

# Пересоздаёт lock-файл зависимостей сайдкара для ТЕКУЩЕГО хоста:
# sidecar/locks/<host>.txt — все пакеты (включая транзитивные) с точными
# версиями и sha256 колёс, формат requirements.txt под
# `pip install --require-hashes --no-deps`.
#
# Файл на хост, а не один общий, потому что колёса у хостов разные (numpy и
# onnxruntime под macOS x86_64, arm64 и Linux — разные файлы с разными хешами),
# а `--require-hashes` проверяет именно файл.
#
# Как работает: pip из скачанного интерпретатора разрешает зависимости
# `markitdown[extras]==версия` в режиме --dry-run и отдаёт отчёт (--report) со
# всем, что поставил бы, включая URL и sha256 выбранных колёс. Ничего не
# устанавливается. Нужна сеть (метаданные и, если нет в кэше pip, сами колёса).
#
# Когда запускать: при смене MARKITDOWN_VERSION/PY_VERSION/PBS_TAG в common.sh
# или когда сознательно хочется поднять транзитивные зависимости. Дальше —
# посмотреть `git diff sidecar/locks/`, пересобрать (`make sidecar`), прогнать
# сверку фикстур. Lock меняется только этим скриптом и только осознанно.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

fetch_interpreter

WORK="$(mktemp -d "${CACHE_DIR}/lock.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
tar xzf "${ARCHIVE}" -C "${WORK}"
PY="${WORK}/${PY_REL}"

echo "sidecar: разрешаю зависимости markitdown[${MARKITDOWN_EXTRAS}]==${MARKITDOWN_VERSION} для ${HOST}"
"${PY}" -I -m pip install \
  --disable-pip-version-check --no-input --only-binary=:all: \
  --dry-run --ignore-installed --quiet \
  --report "$(native_path "${WORK}/report.json")" \
  "markitdown[${MARKITDOWN_EXTRAS}]==${MARKITDOWN_VERSION}"

mkdir -p "$(dirname "${LOCK_FILE}")"
"${PY}" -I -X utf8 - "$(native_path "${WORK}/report.json")" "$(native_path "${LOCK_FILE}")" "${HOST}" "${PY_VERSION}" \
  "${MARKITDOWN_VERSION}[${MARKITDOWN_EXTRAS}]" <<'PYEOF'
import json, sys

report, out, host, py, req = sys.argv[1:6]
items = json.load(open(report, encoding="utf-8"))["install"]
lines = []
for it in items:
    meta = it["metadata"]
    sha = it["download_info"]["archive_info"]["hashes"]["sha256"]
    lines.append((meta["name"].lower().replace("_", "-"), meta["version"], sha))
lines.sort()
with open(out, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(
        f"# Сгенерировано sidecar/lock.sh — руками не править.\n"
        f"# host={host} python={py} markitdown[extras]={req}\n"
        f"# Установка: pip install --require-hashes --no-deps -r <этот файл>\n"
    )
    for name, version, sha in lines:
        fh.write(f"{name}=={version} --hash=sha256:{sha}\n")
print(f"sidecar: {len(lines)} пакетов -> {out}")
PYEOF

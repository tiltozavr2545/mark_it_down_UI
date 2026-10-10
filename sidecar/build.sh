#!/usr/bin/env bash
set -euo pipefail

# Собирает Python-сайдкар: перемещаемый интерпретатор из python-build-standalone
# + настоящий markitdown с зависимостями + run.py + manifest.json.
# Результат — sidecar/dist/<host>/, раскладка и протокол описаны в
# docs/python-sidecar.md. Ничего отсюда не коммитится.
#
# Сборка качает сотни МБ (интерпретатор ~25 МБ, колёса numpy/pandas/onnxruntime
# и т.д. — ещё столько же), поэтому в `make verify` она НЕ входит: только
# `make sidecar`, руками.
#
# Версии закреплены явно, а не "latest": сайдкар — эталон для сверки с
# Dart-ядром, и эталон, который меняется молча, ничего не эталонит. Поднимать
# версию — осознанное действие, вместе с пересверкой фикстур.
#
#   FORCE=1 ./sidecar/build.sh   — пересобрать, даже если уже собрано
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

STAMP_FILE="${CACHE_DIR}/${HOST}.stamp"
LOCK_HASH="none"
[[ -f "${LOCK_FILE}" ]] && LOCK_HASH="$(shasum -a 256 "${LOCK_FILE}" | cut -d' ' -f1)"
# Всё, от чего зависит результат; изменился любой кусок — пересборка.
STAMP="lock=${LOCK_HASH} common=$(shasum -a 256 "${SIDECAR_DIR}/common.sh" | cut -d' ' -f1) pbs=${PBS_TAG} python=${PY_VERSION} markitdown=${MARKITDOWN_VERSION}[${MARKITDOWN_EXTRAS}] formats=${FORMATS[*]} run=$(shasum -a 256 "${SIDECAR_DIR}/run.py" | cut -d' ' -f1) build=$(shasum -a 256 "${SIDECAR_DIR}/build.sh" | cut -d' ' -f1)"

if [[ -z "${FORCE:-}" && -f "${DIST_DIR}/manifest.json" && -f "${STAMP_FILE}" \
      && "$(cat "${STAMP_FILE}")" == "${STAMP}" ]]; then
  echo "sidecar: уже собрано ${DIST_DIR} (FORCE=1 — пересобрать)"
  exit 0
fi

# 1. Интерпретатор (скачать и проверить sha256 — см. common.sh).
fetch_interpreter

# 2. Собираем во временный каталог рядом с dist, потом атомарно подменяем:
# оборванная сборка не оставляет полуготового сайдкара.
mkdir -p "${SIDECAR_DIR}/dist"
WORK="$(mktemp -d "${SIDECAR_DIR}/dist/.build-${HOST}.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

tar xzf "${ARCHIVE}" -C "${WORK}"   # внутри архива каталог python/
PY="${WORK}/python/bin/python3"
[[ -x "${PY}" ]] || { echo "sidecar: в архиве нет python/bin/python3" >&2; exit 1; }

# 3. markitdown pip'ом из СКАЧАННОГО интерпретатора (не системного).
# --only-binary: никакой сборки из исходников на машине — либо готовое колесо,
# либо ошибка. --no-compile: байткод делаем сами ниже, одним проходом.
# -I: окружение пользователя (PYTHONPATH, user site) не должно влиять на сборку.
#
# Воспроизводимость: ставится строго по lock-файлу sidecar/locks/<host>.txt —
# каждая зависимость закреплена версией и sha256 колеса, --require-hashes
# отвергает всё, чего в файле нет или чей хеш не совпал, --no-deps не даёт pip
# дотянуть что-то сверх. Обновляется lock.sh (make sidecar-lock). Для хоста
# без lock-файла сборка отказывается: молча собрать «как получится» значило бы
# потерять ровно то, ради чего эталон закреплён. ALLOW_UNLOCKED=1 — осознанный
# обход (так делается первый lock на новом хосте).
if [[ -f "${LOCK_FILE}" ]]; then
  echo "sidecar: ставлю по ${LOCK_FILE}"
  "${PY}" -I -m pip install \
    --disable-pip-version-check --no-input --no-compile --only-binary=:all: \
    --require-hashes --no-deps --target "${WORK}/lib" \
    -r "${LOCK_FILE}"
elif [[ -n "${ALLOW_UNLOCKED:-}" ]]; then
  echo "sidecar: ВНИМАНИЕ: нет ${LOCK_FILE}, ставлю без закрепления зависимостей" >&2
  "${PY}" -I -m pip install \
    --disable-pip-version-check --no-input --no-compile --only-binary=:all: \
    --target "${WORK}/lib" \
    "markitdown[${MARKITDOWN_EXTRAS}]==${MARKITDOWN_VERSION}"
else
  echo "sidecar: нет lock-файла для ${HOST}: ${LOCK_FILE}" >&2
  echo "sidecar: создать — make sidecar-lock (или ALLOW_UNLOCKED=1 для разовой сборки без закрепления)" >&2
  exit 1
fi

# 4. Чистка. Что не нужно в рантайме:
#  - lib/bin: скрипты pip с абсолютными путями сборочной машины;
#  - tests/test/__pycache__ в зависимостях: тесты и чужой байткод;
#  - из самого интерпретатора: pip/ensurepip (после установки не нужны),
#    Tk и IDLE, тесты stdlib, заголовки, man/share.
rm -rf "${WORK}/lib/bin"
# olefile2.py — Python-2-вариант в том же пакете, на py3 не компилируется
# (compileall падает на `0xFFFFFFFAL`) и нигде не импортируется.
rm -f "${WORK}/lib/olefile/olefile2.py"
find "${WORK}/lib" -depth -type d \( -name __pycache__ -o -name tests -o -name test \) \
  -prune -exec rm -rf {} +
PYLIB="$(echo "${WORK}"/python/lib/python3.*)"
rm -rf "${PYLIB}/test" "${PYLIB}/idlelib" "${PYLIB}/tkinter" "${PYLIB}/turtledemo" \
       "${PYLIB}/ensurepip" "${PYLIB}/site-packages/pip" \
       "${PYLIB}/site-packages/pip-"*.dist-info "${PYLIB}/config-"* \
       "${PYLIB}/lib2to3" \
       "${WORK}/python/include" "${WORK}/python/share"
rm -f "${PYLIB}/lib-dynload/_tkinter"*
rm -rf "${WORK}/python/lib/"{tcl*,tk*,libtcl*,libtk*,itcl*,Tix*,thread*}
# sympy и mpmath: onnxruntime объявляет их в Requires-Dist (они нужны его
# инструментам квантизации/трансформеров), но при инференсе, который делает
# magika, не импортируются. ~45 МБ мёртвого груза; самопроверка ниже гоняет
# настоящий инференс magika, так что если это станет неправдой — сборка упадёт.
# Код markitdown и его зависимостей не трогается, убираются только пакеты.
rm -rf "${WORK}/lib/sympy" "${WORK}/lib/sympy-"*.dist-info \
       "${WORK}/lib/mpmath" "${WORK}/lib/mpmath-"*.dist-info \
       "${WORK}/lib/isympy.py"
rm -rf "${WORK}/lib/onnxruntime/"{transformers,tools,quantization}
# libpython*.dylib/.a: исполняемый python3.12 из python-build-standalone
# собран статически и в них не нуждается (проверено otool -L); они нужны только
# тем, кто встраивает интерпретатор в свой процесс. ~18 МБ.
rm -rf "${WORK}/python/lib/"libpython3* "${WORK}/python/lib/pkgconfig"
# Скрипты из python/bin с shebang на сборочный путь: нужны только интерпретаторы.
find "${WORK}/python/bin" -mindepth 1 ! -name 'python*' -exec rm -f {} +
rm -f "${WORK}/python/bin/python3-config" "${WORK}/python/bin/python3."*-config
# Скрытые файлы метаданных сборки (не нужны, мешают обходу при подписи).
find "${WORK}/python" -name '.DS_Store' -delete

# 4b. macOS: часть колёс (onnxruntime, cryptography, charset-normalizer) —
# universal2, то есть в каждой .so лежат x86_64 и arm64. Бандл собирается под
# одну архитектуру (его хост), вторая половина — мёртвый груз: на onnxruntime
# и cryptography это десятки МБ. Режем lipo до архитектуры хоста.
if [[ "$(uname -s)" == "Darwin" ]]; then
  THIN_ARCH="$(uname -m)"
  thinned=0
  while IFS= read -r -d '' f; do
    archs="$(lipo -archs "${f}" 2>/dev/null || true)"
    if [[ "${archs}" == *" "* ]]; then
      [[ " ${archs} " == *" ${THIN_ARCH} "* ]] \
        || { echo "sidecar: ${f} без ${THIN_ARCH} (есть: ${archs})" >&2; exit 1; }
      lipo -thin "${THIN_ARCH}" "${f}" -output "${f}.thin"
      mv "${f}.thin" "${f}"
      thinned=$((thinned + 1))
    fi
  done < <(find "${WORK}/lib" "${WORK}/python" -type f \( -name '*.so' -o -name '*.dylib' \) -print0)
  echo "sidecar: lipo -thin ${THIN_ARCH}: ${thinned} файлов"
fi

# 5. Байткод. В рантайме запуск идёт с -B, и на macOS писать в подписанный
# бандл нельзя вовсе, поэтому .pyc кладём заранее. unchecked-hash: .pyc не
# сверяется с mtime исходника, а mtime при копировании в бандл/DMG легко
# меняется — с timestamp-вариантом интерпретатор молча перекомпилировал бы всё
# в памяти на каждом запуске.
echo "sidecar: компилирую байткод"
# -s: срезаем путь временной сборки из co_filename — иначе в каждый .pyc
# зашит абсолютный путь машины сборщика (утечка имени пользователя в бандл и
# невоспроизводимая сборка).
"${PY}" -I -m compileall -q -f --invalidation-mode unchecked-hash \
  -s "${WORK}/" "${WORK}/lib" "${WORK}/python/lib"

# 6. run.py и manifest.json
cp "${SIDECAR_DIR}/run.py" "${WORK}/run.py"
# run.py компилируется интерпретатором на каждый запуск (он скрипт, не модуль);
# это единицы миллисекунд, ради них отдельный .pyc не городим.

# Реальные версии берём у собранного, а не из констант выше.
"${PY}" -I - "${WORK}" "${FORMATS[*]}" <<'PYEOF'
import json, sys
from pathlib import Path

work, formats = Path(sys.argv[1]), sys.argv[2].split()
sys.path.insert(0, str(work / "lib"))
from importlib.metadata import version

manifest = {
    "schema": 1,
    "markitdown": version("markitdown"),
    "python": ".".join(map(str, sys.version_info[:3])),
    "formats": formats,
}
(work / "manifest.json").write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
PYEOF

# 7. Самопроверка: каждый заявленный формат должен быть реально импортируемым.
# Не прогон конвертации (для этого есть фикстуры), а проверка, что зависимости
# каждого конвертера на месте — иначе manifest врал бы про поддержку.
"${PY}" -I -B "${WORK}/run.py" --self-check

# 8. Подмена и отчёт.
rm -rf "${DIST_DIR}"
mv "${WORK}" "${DIST_DIR}"
trap - EXIT
echo "${STAMP}" > "${STAMP_FILE}"

echo
echo "sidecar: готово ${DIST_DIR}"
cat "${DIST_DIR}/manifest.json"
echo
echo "== размер =="
for d in "" /python /lib; do du -sh "${DIST_DIR}${d}"; done
echo "== крупнейшие пакеты в lib/ (со скрытыми .dylibs) =="
# du считает скрытые каталоги (numpy/.dylibs и т.п.) — глоб '*/' их не видит,
# поэтому идём по каждому пакету отдельно.
for pkg in "${DIST_DIR}"/lib/*/; do du -sk "${pkg}"; done | sort -rn | head -12 \
  | awk '{printf "%8.1f МБ  %s\n", $1/1024, $2}' | sed "s#${DIST_DIR}/lib/##"

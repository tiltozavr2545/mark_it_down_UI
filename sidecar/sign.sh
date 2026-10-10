#!/usr/bin/env bash
set -euo pipefail

# Подписывает собранный сайдкар (macOS) изнутри наружу.
#
#   sidecar/sign.sh <dir> <identity> [entitlements]
#
#   <dir>          — sidecar/dist/<host>/ (или уже скопированный в .app каталог)
#   <identity>     — "Developer ID Application: Имя (TEAMID)" или "-" (ad-hoc)
#   [entitlements] — plist для интерпретатора; по умолчанию
#                    sidecar/sidecar.entitlements
#
# ПОРЯДОК ВАЖЕН. Подпись хеширует содержимое файла, поэтому sign.sh запускается
# строго ПОСЛЕ build.sh целиком — после compileall, после всех чисток и lipo
# (любая правка подписанного файла ломает его подпись), и строго ДО подписи
# внешнего .app, чей ресурсный seal охватывает этот каталог. Сам sign.sh в
# дерево ничего кроме подписей не пишет.
#
# Что подписывается: каждый Mach-O внутри каталога (.so/.dylib в lib/ и
# python/lib/, интерпретатор python/bin/python3.12) — не по расширению, а по
# магическим байтам: так не проскочит ни .so с нестандартным именем, ни
# бинарник, о котором build.sh не знает. Библиотеки — первыми, исполняемый
# файл — последним и с entitlements (у библиотек entitlements не читаются).
# `--options runtime` включает Hardened Runtime, без него нотаризация
# отказывает. Неподписанный Mach-O — отказ нотаризации одной строкой среди
# многих, поэтому в конце каждый файл проверяется отдельно.
SIDECAR_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: sidecar/sign.sh <dir> <identity|-> [entitlements.plist]" >&2
  exit 1
fi
DIR="$(cd "$1" && pwd)"
IDENTITY="$2"
ENTITLEMENTS="${3:-${SIDECAR_SRC}/sidecar.entitlements}"

[[ "$(uname -s)" == "Darwin" ]] || { echo "sign: только macOS" >&2; exit 1; }
[[ -f "${ENTITLEMENTS}" ]] || { echo "sign: нет файла entitlements: ${ENTITLEMENTS}" >&2; exit 1; }
[[ -x "${DIR}/python/bin/python3" && -f "${DIR}/run.py" ]] \
  || { echo "sign: ${DIR} не похож на собранный сайдкар (нет python/bin/python3 или run.py)" >&2; exit 1; }

# Сеть в entitlements — ровно то, чего быть не должно (docs/offline-and-privacy.md).
if grep -q '<key>com.apple.security.network' "${ENTITLEMENTS}"; then
  echo "sign: в ${ENTITLEMENTS} есть com.apple.security.network.* — нельзя" >&2
  exit 1
fi

# Временная метка — с сервера Apple, нужна нотаризации; для ad-hoc её нет.
if [[ "${IDENTITY}" == "-" ]]; then
  TS=(--timestamp=none)
else
  TS=(--timestamp)
fi

# Поиск Mach-O по магическим байтам (fat и thin, оба порядка байт). Используется
# python из самого сайдкара: -I -B — ни окружения, ни записи .pyc.
MACHO_LIST="$(mktemp)"
trap 'rm -f "${MACHO_LIST}"' EXIT
"${DIR}/python/bin/python3" -I -B - "${DIR}" > "${MACHO_LIST}" <<'PYEOF'
import os, sys
MAGIC = {b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe",
         b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
for root, _dirs, files in os.walk(sys.argv[1]):
    for name in files:
        path = os.path.join(root, name)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        try:
            with open(path, "rb") as fh:
                head = fh.read(4)
        except OSError:
            continue
        # 0xCAFEBABE — ещё и класс Java; у нас таких нет, но лишнюю подпись
        # ему codesign не простит, поэтому отсеиваем по расширению.
        if head in MAGIC and not name.endswith(".class"):
            print(path)
PYEOF
TOTAL="$(wc -l < "${MACHO_LIST}" | tr -d ' ')"
[[ "${TOTAL}" -gt 0 ]] || { echo "sign: Mach-O не найдено" >&2; exit 1; }
echo "sign: найдено Mach-O файлов: ${TOTAL}"

EXECS=()
LIBS=()
while IFS= read -r f; do
  if [[ "${f}" == "${DIR}/python/bin/"* ]]; then EXECS+=("${f}"); else LIBS+=("${f}"); fi
done < "${MACHO_LIST}"

# 1. Библиотеки — без entitlements. --force: lipo/сборка оставляют недействительную
# подпись, а у ad-hoc-подписи в колёсах её перезапись обязательна.
# codesign на каждом файле пишет "replacing existing signature" — сотни строк
# шума; вывод показывается только при ошибке.
sign_one() {
  local out
  if ! out="$(codesign --force --sign "${IDENTITY}" --options runtime "${TS[@]}" "$@" 2>&1)"; then
    echo "sign: codesign упал на ${*: -1}: ${out}" >&2
    exit 1
  fi
}
for f in "${LIBS[@]}"; do
  sign_one "${f}"
done
echo "sign: подписано библиотек: ${#LIBS[@]}"

# 2. Исполняемые файлы — с entitlements.
for f in "${EXECS[@]}"; do
  sign_one --entitlements "${ENTITLEMENTS}" "${f}"
done
echo "sign: подписано исполняемых: ${#EXECS[@]}"

# 3. Проверка: каждый файл отдельно (--strict), интерпретатор ещё и --deep.
FAILED=0
while IFS= read -r f; do
  if ! out="$(codesign --verify --strict "${f}" 2>&1)"; then
    echo "sign: НЕ ПРОШЛА проверка: ${f}: ${out}" >&2
    FAILED=$((FAILED + 1))
  fi
done < "${MACHO_LIST}"
for f in "${EXECS[@]}"; do
  codesign --verify --deep --strict "${f}" || FAILED=$((FAILED + 1))
done
[[ "${FAILED}" -eq 0 ]] || { echo "sign: провалено проверок: ${FAILED}" >&2; exit 1; }

# 4. Итоговые entitlements интерпретатора — глазами и без сети.
for f in "${EXECS[@]}"; do
  echo "sign: entitlements ${f#"${DIR}"/}:"
  codesign -d --entitlements - --xml "${f}" 2>/dev/null | plutil -p - 2>/dev/null | sed 's/^/  /' || true
  if codesign -d --entitlements - --xml "${f}" 2>/dev/null | grep -q 'com.apple.security.network'; then
    echo "sign: у ${f} появился network.* entitlement" >&2
    exit 1
  fi
done

# 5. Дымовой прогон подписанного сайдкара: если Hardened Runtime что-то
# запретил (библиотека не загрузилась), узнаём здесь, а не у пользователя.
if [[ -z "${SKIP_SMOKE:-}" ]]; then
  "${DIR}/python/bin/python3" -I -B "${DIR}/run.py" --self-check
fi
echo "sign: готово (${DIR}, identity=${IDENTITY})"

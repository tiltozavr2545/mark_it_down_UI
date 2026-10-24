#!/usr/bin/env bash
set -euo pipefail

# Signs the built sidecar (macOS) from the inside out.
#
#   sidecar/sign.sh <dir> <identity> [entitlements]
#
#   <dir>          — sidecar/dist/<host>/ (or already copied into the .app directory)
#   <identity>     — "Developer ID Application: Name (TEAMID)" or "-" (ad-hoc)
#   [entitlements] — plist for the interpreter; defaults to
#                    sidecar/sidecar.entitlements
#
# ORDER MATTERS. Signing hashes the file's contents, so sign.sh runs strictly
# AFTER build.sh in full — after compileall, after all cleanup and lipo (any
# edit to a signed file breaks its signature) — and strictly BEFORE signing
# the outer .app, whose resource seal covers this directory. sign.sh itself
# writes nothing into the tree besides the signatures.
#
# What gets signed: every Mach-O inside the directory (.so/.dylib in lib/
# and python/lib/, the python/bin/python3.12 interpreter) — identified not
# by extension but by magic bytes: that way no .so with a nonstandard name
# slips through, nor any binary build.sh doesn't know about. Libraries are
# signed first, the executable last and with entitlements (libraries don't
# get their entitlements read). `--options runtime` enables Hardened
# Runtime; without it notarization is refused. An unsigned Mach-O is just
# one line of refusal among many during notarization, so at the end each
# file is verified individually.
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

# Network in entitlements is exactly what must not be there (docs/offline-and-privacy.md).
if grep -q '<key>com.apple.security.network' "${ENTITLEMENTS}"; then
  echo "sign: в ${ENTITLEMENTS} есть com.apple.security.network.* — нельзя" >&2
  exit 1
fi

# Timestamp — from Apple's server, needed for notarization; ad-hoc has none.
if [[ "${IDENTITY}" == "-" ]]; then
  TS=(--timestamp=none)
else
  TS=(--timestamp)
fi

# Finding Mach-O files by magic bytes (fat and thin, both byte orders). Uses
# the sidecar's own python: -I -B — no environment, no writing .pyc.
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
        # 0xCAFEBABE is also a Java class; we have none, but codesign
        # wouldn't forgive signing one anyway, so we filter by extension.
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

# 1. Libraries — without entitlements. --force: lipo/the build leave an
# invalid signature behind, and an ad-hoc signature in wheels must be
# overwritten.
# codesign prints "replacing existing signature" for every file — hundreds
# of lines of noise; the output is shown only on failure.
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

# 2. Executables — with entitlements.
for f in "${EXECS[@]}"; do
  sign_one --entitlements "${ENTITLEMENTS}" "${f}"
done
echo "sign: подписано исполняемых: ${#EXECS[@]}"

# 3. Verification: each file individually (--strict), the interpreter also --deep.
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

# 4. The interpreter's final entitlements — eyeballed, and no network.
for f in "${EXECS[@]}"; do
  echo "sign: entitlements ${f#"${DIR}"/}:"
  codesign -d --entitlements - --xml "${f}" 2>/dev/null | plutil -p - 2>/dev/null | sed 's/^/  /' || true
  if codesign -d --entitlements - --xml "${f}" 2>/dev/null | grep -q 'com.apple.security.network'; then
    echo "sign: у ${f} появился network.* entitlement" >&2
    exit 1
  fi
done

# 5. A smoke run of the signed sidecar: if Hardened Runtime blocked
# something (a library failed to load), we find out here, not the user.
if [[ -z "${SKIP_SMOKE:-}" ]]; then
  "${DIR}/python/bin/python3" -I -B "${DIR}/run.py" --self-check
fi
echo "sign: готово (${DIR}, identity=${IDENTITY})"

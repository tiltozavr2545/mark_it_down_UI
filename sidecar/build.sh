#!/usr/bin/env bash
set -euo pipefail

# Builds the Python sidecar: a relocatable interpreter from
# python-build-standalone + the real markitdown with its dependencies + run.py
# + manifest.json.
# Result — sidecar/dist/<host>/, the layout and protocol are described in
# docs/python-sidecar.md. Nothing from here gets committed.
#
# The build downloads hundreds of MB (the interpreter ~25 MB, the
# numpy/pandas/onnxruntime wheels etc. — about as much again), so it is NOT
# part of `make verify`: only `make sidecar`, by hand.
#
# Versions are pinned explicitly rather than "latest": the sidecar is the
# reference implementation for comparison against the Dart core, and a
# reference that changes silently isn't a reference at all. Bumping the
# version is a deliberate action, done together with re-checking fixtures.
#
#   FORCE=1 ./sidecar/build.sh   — rebuild even if already built
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

STAMP_FILE="${CACHE_DIR}/${HOST}.stamp"
LOCK_HASH="none"
[[ -f "${LOCK_FILE}" ]] && LOCK_HASH="$(sha256_of "${LOCK_FILE}")"
# Everything the result depends on; if any piece changes, rebuild.
STAMP="lock=${LOCK_HASH} common=$(sha256_of "${SIDECAR_DIR}/common.sh") pbs=${PBS_TAG} python=${PY_VERSION} markitdown=${MARKITDOWN_VERSION}[${MARKITDOWN_EXTRAS}] formats=${FORMATS[*]} run=$(sha256_of "${SIDECAR_DIR}/run.py") build=$(sha256_of "${SIDECAR_DIR}/build.sh")"

if [[ -z "${FORCE:-}" && -f "${DIST_DIR}/manifest.json" && -f "${STAMP_FILE}" \
      && "$(cat "${STAMP_FILE}")" == "${STAMP}" ]]; then
  echo "sidecar: уже собрано ${DIST_DIR} (FORCE=1 — пересобрать)"
  exit 0
fi

# 1. Interpreter (download and verify sha256 — see common.sh).
fetch_interpreter

# 2. Build into a temp directory next to dist, then swap it in atomically:
# an aborted build doesn't leave a half-built sidecar behind.
mkdir -p "${SIDECAR_DIR}/dist"
WORK="$(mktemp -d "${SIDECAR_DIR}/dist/.build-${HOST}.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

tar xzf "${ARCHIVE}" -C "${WORK}"   # the archive contains a python/ directory
PY="${WORK}/${PY_REL}"
[[ -x "${PY}" ]] || { echo "sidecar: в архиве нет ${PY_REL}" >&2; exit 1; }

# 3. markitdown via pip from the DOWNLOADED interpreter (not the system one).
# --only-binary: no building from source on this machine — either a ready
# wheel or an error. --no-compile: we do the bytecode ourselves below, in one
# pass. -I: the user's environment (PYTHONPATH, user site) must not affect
# the build.
#
# Reproducibility: installed strictly from the lock file
# sidecar/locks/<host>.txt — every dependency is pinned by version and wheel
# sha256, --require-hashes rejects anything not in the file or whose hash
# doesn't match, --no-deps keeps pip from pulling in anything extra. Updated
# via lock.sh (make sidecar-lock). The build refuses for a host without a
# lock file: silently building "whatever comes out" would mean losing
# exactly what the reference implementation is pinned for.
# ALLOW_UNLOCKED=1 is a deliberate bypass (used to create the first lock on
# a new host).
if [[ -f "${LOCK_FILE}" ]]; then
  echo "sidecar: ставлю по ${LOCK_FILE}"
  "${PY}" -I -m pip install \
    --disable-pip-version-check --no-input --no-compile --only-binary=:all: \
    --require-hashes --no-deps --target "$(native_path "${WORK}/lib")" \
    -r "$(native_path "${LOCK_FILE}")"
elif [[ -n "${ALLOW_UNLOCKED:-}" ]]; then
  echo "sidecar: ВНИМАНИЕ: нет ${LOCK_FILE}, ставлю без закрепления зависимостей" >&2
  "${PY}" -I -m pip install \
    --disable-pip-version-check --no-input --no-compile --only-binary=:all: \
    --target "$(native_path "${WORK}/lib")" \
    "markitdown[${MARKITDOWN_EXTRAS}]==${MARKITDOWN_VERSION}"
else
  echo "sidecar: нет lock-файла для ${HOST}: ${LOCK_FILE}" >&2
  echo "sidecar: создать — make sidecar-lock (или ALLOW_UNLOCKED=1 для разовой сборки без закрепления)" >&2
  exit 1
fi

# 4. Cleanup. What's not needed at runtime:
#  - lib/bin: pip scripts with absolute paths from the build machine;
#  - tests/test/__pycache__ in dependencies: tests and someone else's bytecode;
#  - from the interpreter itself: pip/ensurepip (not needed after install),
#    Tk and IDLE, stdlib tests, headers, man/share.
rm -rf "${WORK}/lib/bin"
# olefile2.py — the Python 2 variant in the same package, doesn't compile
# under py3 (compileall fails on `0xFFFFFFFAL`) and isn't imported anywhere.
rm -f "${WORK}/lib/olefile/olefile2.py"
find "${WORK}/lib" -depth -type d \( -name __pycache__ -o -name tests -o -name test \) \
  -prune -exec rm -rf {} +
# sympy and mpmath: onnxruntime declares them in Requires-Dist (needed by its
# quantization/transformers tooling), but they aren't imported during the
# inference that magika does. ~45 MB of dead weight; the self-check below
# runs real magika inference, so if this stops being true the build will fail.
# The code of markitdown and its dependencies is untouched — only packages
# are removed.
rm -rf "${WORK}/lib/sympy" "${WORK}/lib/sympy-"*.dist-info \
       "${WORK}/lib/mpmath" "${WORK}/lib/mpmath-"*.dist-info \
       "${WORK}/lib/isympy.py"
rm -rf "${WORK}/lib/onnxruntime/"{transformers,tools,quantization}
if [[ "${HOST}" == windows-* ]]; then
  # Windows layout: python.exe, Lib/, DLLs/, libs/, Scripts/, tcl/.
  # NTFS paths are case-insensitive: the Unix branch below, with its own
  # python/lib/{tcl*,tk*,thread*}, would end up matching Lib/ here and wipe
  # out threading.py — so the branches are kept separate rather than shared
  # with caveats.
  PYLIB="${WORK}/python/Lib"
  rm -rf "${PYLIB}/test" "${PYLIB}/idlelib" "${PYLIB}/tkinter" "${PYLIB}/turtledemo" \
         "${PYLIB}/ensurepip" "${PYLIB}/site-packages/pip" \
         "${PYLIB}/site-packages/pip-"*.dist-info "${PYLIB}/lib2to3" \
         "${WORK}/python/include" "${WORK}/python/libs" "${WORK}/python/Scripts" \
         "${WORK}/python/tcl"
  rm -f "${WORK}/python/DLLs/"{_tkinter.pyd,tcl86t.dll,tk86t.dll} \
        "${WORK}/python/"{pythonw.exe,python3.dll.lib}
else
  PYLIB="$(echo "${WORK}"/python/lib/python3.*)"
  rm -rf "${PYLIB}/test" "${PYLIB}/idlelib" "${PYLIB}/tkinter" "${PYLIB}/turtledemo" \
         "${PYLIB}/ensurepip" "${PYLIB}/site-packages/pip" \
         "${PYLIB}/site-packages/pip-"*.dist-info "${PYLIB}/config-"* \
         "${PYLIB}/lib2to3" \
         "${WORK}/python/include" "${WORK}/python/share"
  rm -f "${PYLIB}/lib-dynload/_tkinter"*
  rm -rf "${WORK}/python/lib/"{tcl*,tk*,libtcl*,libtk*,itcl*,Tix*,thread*}
  # libpython*.dylib/.a: the python3.12 executable from python-build-standalone
  # is statically linked and doesn't need them (verified with otool -L); they're
  # only needed by whoever embeds the interpreter in their own process. ~18 MB.
  rm -rf "${WORK}/python/lib/"libpython3* "${WORK}/python/lib/pkgconfig"
  # Scripts from python/bin with a shebang pointing at the build path: only the
  # interpreters themselves are needed.
  find "${WORK}/python/bin" -mindepth 1 ! -name 'python*' -exec rm -f {} +
  rm -f "${WORK}/python/bin/python3-config" "${WORK}/python/bin/python3."*-config
  # Hidden build-metadata files (not needed, get in the way when traversing
  # for signing).
  find "${WORK}/python" -name '.DS_Store' -delete
fi

# 4b. macOS: some wheels (onnxruntime, cryptography, charset-normalizer) are
# universal2, meaning each .so contains both x86_64 and arm64. The bundle is
# built for a single architecture (its host), so the other half is dead
# weight — tens of MB for onnxruntime and cryptography. Thin them down to the
# host architecture with lipo.
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

# 5. Bytecode. At runtime it's launched with -B, and on macOS you can't
# write into a signed bundle at all, so we lay down .pyc ahead of time.
# unchecked-hash: the .pyc isn't checked against the source's mtime, and
# mtime easily changes when copied into a bundle/DMG — with the
# timestamp-based mode the interpreter would silently recompile everything
# in memory on every run.
echo "sidecar: компилирую байткод"
# -s: strips the temp build path from co_filename — otherwise every .pyc
# has the build machine's absolute path baked in (a username leak into the
# bundle, and a non-reproducible build).
"${PY}" -I -m compileall -q -f --invalidation-mode unchecked-hash \
  -s "$(native_path "${WORK}")" "$(native_path "${WORK}/lib")" "$(native_path "${PYLIB%/python3.*}")"

# 6. run.py and manifest.json
cp "${SIDECAR_DIR}/run.py" "${WORK}/run.py"
# run.py gets compiled by the interpreter on every run (it's a script, not
# a module); that's a few milliseconds, not worth a separate .pyc for.

# We take the real versions from what was actually built, not from the constants above.
"${PY}" -I -X utf8 - "$(native_path "${WORK}")" "${FORMATS[*]}" <<'PYEOF'
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
    json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
    newline="\n",  # LF even on Windows, like everything in the repository
)
PYEOF

# 7. Self-check: every declared format must actually be importable. Not a
# conversion run (fixtures exist for that), but a check that every
# converter's dependencies are in place — otherwise the manifest would be
# lying about support.
"${PY}" -I -B "$(native_path "${WORK}/run.py")" --self-check

# 8. Swap-in and report.
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
echo "== python/ по каталогам =="
for d in "${DIST_DIR}"/python/*/; do du -sk "${d}"; done | sort -rn | awk 'NR <= 6' \
  | awk '{printf "%8.1f МБ  %s\n", $1/1024, $2}' | sed "s#${DIST_DIR}/##"
echo "== крупнейшие пакеты в lib/ (со скрытыми .dylibs) =="
# du counts hidden directories (numpy/.dylibs etc.) — the '*/' glob doesn't
# see them, so we walk each package separately.
for pkg in "${DIST_DIR}"/lib/*/; do du -sk "${pkg}"; done | sort -rn | head -12 \
  | awk '{printf "%8.1f МБ  %s\n", $1/1024, $2}' | sed "s#${DIST_DIR}/lib/##"

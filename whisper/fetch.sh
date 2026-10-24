#!/usr/bin/env bash
set -euo pipefail

# Speech recognition models — downloaded only, by the pinned commits and
# sha256 from whisper/versions.sh. Nothing downloaded is committed — the
# same arrangement as tesseract/fetch.sh.
#
#   whisper/models/                the models — for dart test in core/
#   app/assets/whisper/            the same models as app assets (on
#                                  Windows they end up as files next to
#                                  .exe, on Android they're copied from the
#                                  APK on the first audio file)
#                                  plus models.json — their manifest
#
# 265 MB, so unlike tessdata it isn't part of make test: without the
# models the transcription tests are skipped (`make whisper` downloads and
# builds them).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=whisper/versions.sh
source "${ROOT_DIR}/whisper/versions.sh"

MODELS_DIR="${ROOT_DIR}/whisper/models"
ASSETS_DIR="${ROOT_DIR}/app/assets/whisper"

mkdir -p "${MODELS_DIR}" "${ASSETS_DIR}"
download "${MODEL_URL}" "${MODEL_SHA256}" "${MODELS_DIR}/${MODEL_NAME}"
download "${VAD_URL}" "${VAD_SHA256}" "${MODELS_DIR}/${VAD_NAME}"

# Remove old model versions from assets: otherwise the app would ship both.
for file in "${ASSETS_DIR}"/*.bin; do
  [[ -e "${file}" ]] || continue
  case "$(basename "${file}")" in
    "${MODEL_NAME}" | "${VAD_NAME}") ;;
    *) rm -f "${file}" ;;
  esac
done
for name in "${MODEL_NAME}" "${VAD_NAME}"; do
  # cmp, not size: a different model version having the same length isn't rare.
  if ! cmp -s "${MODELS_DIR}/${name}" "${ASSETS_DIR}/${name}"; then
    cp "${MODELS_DIR}/${name}" "${ASSETS_DIR}/${name}"
  fi
done

# A manifest for the app: names, sizes, and sha256. Android uses it to
# decide whether to copy the model from the APK, without reading 265 MB
# into memory just to compare (the copy on disk is named by its hash, so a
# different model version of the same length won't be confused with the
# old one), and Dart doesn't keep file names of its own — there's one
# source of truth, versions.sh.
size_of() { wc -c <"$1" | tr -d ' '; }
cat >"${ASSETS_DIR}/models.json" <<JSON
{
  "model": {"file": "${MODEL_NAME}", "size": $(size_of "${ASSETS_DIR}/${MODEL_NAME}"), "sha256": "${MODEL_SHA256}"},
  "vad": {"file": "${VAD_NAME}", "size": $(size_of "${ASSETS_DIR}/${VAD_NAME}"), "sha256": "${VAD_SHA256}"}
}
JSON

echo "whisper: модели на месте ($(du -sh "${ASSETS_DIR}" | cut -f1))"

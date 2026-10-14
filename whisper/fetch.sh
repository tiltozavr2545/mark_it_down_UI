#!/usr/bin/env bash
set -euo pipefail

# Модели распознавания речи — только качаются, по закреплённым коммитам и
# sha256 из whisper/versions.sh. Ничего из скачанного не коммитится — тот
# же порядок, что у tesseract/fetch.sh.
#
#   whisper/models/                модели — для dart test в core/
#   app/assets/whisper/            они же — ассетами приложения (на Windows
#                                  лягут файлами рядом с .exe, на Android
#                                  копируются из APK при первом аудиофайле)
#                                  и models.json — их опись
#
# 265 МБ, поэтому, в отличие от tessdata, не входит в make test: без
# моделей тесты транскрипции пропускаются (`make whisper` — качает и
# собирает).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=whisper/versions.sh
source "${ROOT_DIR}/whisper/versions.sh"

MODELS_DIR="${ROOT_DIR}/whisper/models"
ASSETS_DIR="${ROOT_DIR}/app/assets/whisper"

mkdir -p "${MODELS_DIR}" "${ASSETS_DIR}"
download "${MODEL_URL}" "${MODEL_SHA256}" "${MODELS_DIR}/${MODEL_NAME}"
download "${VAD_URL}" "${VAD_SHA256}" "${MODELS_DIR}/${VAD_NAME}"

# Старые версии моделей из ассетов убираем: иначе приложение повезёт обе.
for file in "${ASSETS_DIR}"/*.bin; do
  [[ -e "${file}" ]] || continue
  case "$(basename "${file}")" in
    "${MODEL_NAME}" | "${VAD_NAME}") ;;
    *) rm -f "${file}" ;;
  esac
done
for name in "${MODEL_NAME}" "${VAD_NAME}"; do
  # cmp, а не размер: та же длина у другой версии модели — не редкость.
  if ! cmp -s "${MODELS_DIR}/${name}" "${ASSETS_DIR}/${name}"; then
    cp "${MODELS_DIR}/${name}" "${ASSETS_DIR}/${name}"
  fi
done

# Опись для приложения: имена, размеры и sha256. По ней Android решает,
# копировать ли модель из APK, не читая 265 МБ в память ради сравнения
# (копия на диске названа по хешу — другая версия модели не спутается с
# прежней той же длины), а Dart не держит имена файлов у себя — одна
# правда, versions.sh.
size_of() { wc -c <"$1" | tr -d ' '; }
cat >"${ASSETS_DIR}/models.json" <<JSON
{
  "model": {"file": "${MODEL_NAME}", "size": $(size_of "${ASSETS_DIR}/${MODEL_NAME}"), "sha256": "${MODEL_SHA256}"},
  "vad": {"file": "${VAD_NAME}", "size": $(size_of "${ASSETS_DIR}/${VAD_NAME}"), "sha256": "${VAD_SHA256}"}
}
JSON

echo "whisper: модели на месте ($(du -sh "${ASSETS_DIR}" | cut -f1))"

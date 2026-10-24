.PHONY: verify pub-get format analyze test fetch-pdfium fetch-tesseract tesseract whisper sidecar sidecar-lock sign-sidecar verify-version

# CI runs the same thing: the verify job via `make verify`, and the windows
# job via the same steps spelled out by hand (the runner's Git Bash has no
# make, and here the branches are Darwin/Linux only). If you change the list
# of checks, keep both this file and the windows job in
# .github/workflows/ci.yml in sync.
verify: pub-get format analyze test

pub-get:
	cd app && flutter pub get
	cd core && dart pub get

format:
	cd app && dart format --set-exit-if-changed .
	cd core && dart format --set-exit-if-changed .

analyze:
	cd app && flutter analyze
	cd core && dart analyze

# Downloads the PDFium shared library for the host (macOS/Linux) and for
# Android — see pdfium/fetch.sh. Not a separate CI step: it's called from
# test, and CI runs that same make verify.
fetch-pdfium:
	./pdfium/fetch.sh

# Tesseract models and the Android .so — seconds, so like PDFium they're
# downloaded from test. Building desktop Tesseract (`make tesseract`) takes
# minutes and isn't part of verify: without it the OCR tests
# (core/test/ocr_test.dart) are skipped, with it they run. CI on Linux takes
# Tesseract from distro packages (see ci.yml).
fetch-tesseract:
	./tesseract/fetch.sh

tesseract:
	./tesseract/build.sh

TESSERACT_HOST_DIR := $(CURDIR)/tesseract/native/host

# Speech recognition (0.8): building whisper.cpp takes minutes, the models
# are 265 MB, so like `make tesseract` it isn't part of verify: without it
# the transcription tests (core/test/speech_test.dart) are skipped, with it
# they run.
whisper:
	./whisper/build.sh
	./whisper/fetch.sh

WHISPER_HOST_DIR := $(CURDIR)/whisper/native/host

test: fetch-pdfium fetch-tesseract
	cd app && flutter test
	cd core && $(if $(wildcard $(TESSERACT_HOST_DIR)/*),MARKITDOWN_TESSERACT_DIR=$(TESSERACT_HOST_DIR)) $(if $(wildcard $(WHISPER_HOST_DIR)/*),MARKITDOWN_WHISPER_DIR=$(WHISPER_HOST_DIR)) MARKITDOWN_PDFIUM_PATH=$(CURDIR)/pdfium/native/host/libpdfium.$(if $(filter Darwin,$(shell uname -s)),dylib,so) dart test

# Builds the Python sidecar for the host into sidecar/dist/<host>/ — see
# docs/python-sidecar.md. Deliberately NOT part of verify/test: it
# downloads hundreds of MB and is only needed for Stage 4 (comparison
# against the reference, desktop packaging).
# FORCE=1 make sidecar — force a rebuild.
sidecar:
	./sidecar/build.sh

# Compares the Dart core against the sidecar across all fixtures (Stage 4,
# item 5): report in core/build/sidecar-compare/summary.md. NOT part of
# verify: CI has no sidecar. Run `make sidecar` first. A different sidecar
# directory: SIDECAR_DIR=/path make ...
SIDECAR_HOST := $(if $(filter Darwin,$(shell uname -s)),macos,linux)-$(if $(filter arm64 aarch64,$(shell uname -m)),$(if $(filter Darwin,$(shell uname -s)),arm64,aarch64),x86_64)
SIDECAR_DIR ?= $(CURDIR)/sidecar/dist/$(SIDECAR_HOST)

.PHONY: compare-sidecar
compare-sidecar: fetch-pdfium
	cd core && dart pub get && MARKITDOWN_SIDECAR_DIR=$(SIDECAR_DIR) MARKITDOWN_PDFIUM_PATH=$(CURDIR)/pdfium/native/host/libpdfium.$(if $(filter Darwin,$(shell uname -s)),dylib,so) dart run tool/compare_sidecar.dart

# Regenerates sidecar/locks/<host>.txt (versions and sha256 of all of the
# sidecar's dependencies). Only on a deliberate update — see
# docs/python-sidecar.md.
sidecar-lock:
	./sidecar/lock.sh

# Signs the built sidecar on macOS (Developer ID or ad-hoc: IDENTITY=-).
# Must run AFTER `make sidecar` and the last edit to the tree — see
# docs/operations.md. ENTITLEMENTS defaults to sidecar/sidecar.entitlements.
sign-sidecar:
	@test -n "$(IDENTITY)" || { echo "make sign-sidecar IDENTITY='Developer ID Application: …' (или IDENTITY=- для ad-hoc)"; exit 1; }
	./sidecar/sign.sh sidecar/dist/macos-$$(uname -m) "$(IDENTITY)" $(ENTITLEMENTS)

# Version bump in a PR (docs/operations.md#version): app/pubspec.yaml is
# compared against BASE_REF — format MAJOR.MINOR.PATCH+BUILD, the version
# changed, the build number went up. NOT part of verify: comparing against
# origin/main locally is pointless; it runs as a separate CI step only on
# pull_request.
verify-version:
	./tool/verify_version.sh $(or $(BASE_REF),origin/main)

.PHONY: verify pub-get format analyze test fetch-pdfium

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

# Качает shared-библиотеку PDFium для хоста (macOS/Linux) и для Android —
# см. pdfium/fetch.sh. Не отдельный шаг CI: вызывается из test, тот же
# make verify гоняет и CI.
fetch-pdfium:
	./pdfium/fetch.sh

test: fetch-pdfium
	cd app && flutter test
	cd core && MARKITDOWN_PDFIUM_PATH=$(CURDIR)/pdfium/native/host/libpdfium.$(if $(filter Darwin,$(shell uname -s)),dylib,so) dart test

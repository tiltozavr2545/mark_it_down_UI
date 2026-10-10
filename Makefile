.PHONY: verify pub-get format analyze test fetch-pdfium sidecar sidecar-lock sign-sidecar verify-version

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

# Собирает Python-сайдкар для хоста в sidecar/dist/<host>/ — см.
# docs/python-sidecar.md. Намеренно НЕ входит в verify/test: качает сотни МБ
# и нужна только для Этапа 4 (сверка с эталоном, упаковка десктопа).
# FORCE=1 make sidecar — пересобрать принудительно.
sidecar:
	./sidecar/build.sh

# Сверка Dart-ядра с сайдкаром на всех фикстурах (Этап 4, пункт 5): отчёт в
# core/build/sidecar-compare/summary.md. НЕ входит в verify: в CI сайдкара нет.
# Сначала `make sidecar`. Другой каталог сайдкара: SIDECAR_DIR=/путь make ...
SIDECAR_HOST := $(if $(filter Darwin,$(shell uname -s)),macos,linux)-$(if $(filter arm64 aarch64,$(shell uname -m)),$(if $(filter Darwin,$(shell uname -s)),arm64,aarch64),x86_64)
SIDECAR_DIR ?= $(CURDIR)/sidecar/dist/$(SIDECAR_HOST)

.PHONY: compare-sidecar
compare-sidecar: fetch-pdfium
	cd core && dart pub get && MARKITDOWN_SIDECAR_DIR=$(SIDECAR_DIR) MARKITDOWN_PDFIUM_PATH=$(CURDIR)/pdfium/native/host/libpdfium.$(if $(filter Darwin,$(shell uname -s)),dylib,so) dart run tool/compare_sidecar.dart

# Пересоздаёт sidecar/locks/<host>.txt (версии и sha256 всех зависимостей
# сайдкара). Только при осознанном обновлении — см. docs/python-sidecar.md.
sidecar-lock:
	./sidecar/lock.sh

# Подпись собранного сайдкара под macOS (Developer ID или ad-hoc: IDENTITY=-).
# Должна идти ПОСЛЕ `make sidecar` и последней правки дерева — см.
# docs/operations.md. ENTITLEMENTS по умолчанию sidecar/sidecar.entitlements.
sign-sidecar:
	@test -n "$(IDENTITY)" || { echo "make sign-sidecar IDENTITY='Developer ID Application: …' (или IDENTITY=- для ad-hoc)"; exit 1; }
	./sidecar/sign.sh sidecar/dist/macos-$$(uname -m) "$(IDENTITY)" $(ENTITLEMENTS)

# Бамп версии в PR (docs/operations.md#версия): app/pubspec.yaml сверяется с
# BASE_REF — формат MAJOR.MINOR.PATCH+BUILD, версия изменена, build вырос.
# НЕ входит в verify: локально сравнивать с origin/main бессмысленно, гоняется
# отдельным шагом CI только на pull_request.
verify-version:
	./tool/verify_version.sh $(or $(BASE_REF),origin/main)

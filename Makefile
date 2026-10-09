.PHONY: verify pub-get format analyze test

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

test:
	cd app && flutter test
	cd core && dart test

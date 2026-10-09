# Эксплуатация

Что собирается чем, где лежат ключи подписи и что делать руками при релизе.
Отдельно от [client-architecture.md](client-architecture.md), потому что это не
устройство приложения: тот файл отвечает «как работает», этот — «что нажать».

Пока проект на нуле, большая часть разделов — **заготовки**: они размечены
так, чтобы рабочие команды вписывались в них по ходу этапов, а не искались
заново. Где команды ещё не проверены, это сказано прямо.

---

## Одна команда перед сдачей

```bash
make verify
```

Прогоняет для `app/` и `core/`: `pub get`, `dart format
--set-exit-if-changed`, `flutter analyze`, `flutter test`, `dart test`. То же
самое гоняет CI — локальная команда существует, чтобы не узнавать о сломанном
формате из пайплайна.

## CI

GitHub Actions, два workflow:

| workflow | когда | что делает |
|---|---|---|
| `ci.yml` | push, PR | `make verify` + проверка «нет сети» + проверка бампа версии в PR |
| `release.yml` | тег `v*` | сборка macOS (DMG) и Android (`.aab`), прикрепление к GitHub Release |

**Проверка «нет сети»** — не формальность, а главная гарантия продукта (см.
[offline-and-privacy.md](offline-and-privacy.md)). Два шага, оба падающие:

```bash
# 1. сетевой пакет в дереве зависимостей
dart pub deps --style=list | grep -E '^- (http|dio|web_socket_channel|grpc|sentry|firebase)' && exit 1

# 2. разрешение INTERNET в собранном APK
aapt dump permissions build/app/outputs/flutter-apk/app-release.apk \
  | grep -q 'android.permission.INTERNET' && exit 1
```

Второй шаг гоняется на сборке, то есть в `release.yml`; первый — на каждом PR,
потому что именно там сетевая зависимость и приезжает транзитивно.

## Версия

Формат `name+build` в `pubspec.yaml`, бампается **в каждом PR** — тот же
порядок, что в Amicus:

```bash
make verify-version BASE_REF=origin/main
```

`build` обязан расти монотонно: Google Play и App Store Connect не принимают
повторный номер, и обнаруживается это в самый неподходящий момент.

## Ключи и секреты

Ничего из этого не лежит в репозитории, и ничего из этого не нужно самому
приложению в рантайме — у него нет ни одного ключа, потому что ему некуда
ходить. Всё перечисленное нужно только для подписи сборок.

| что | где лежит | для чего |
|---|---|---|
| Android keystore | вне репозитория, путь в `android/key.properties` (в `.gitignore`) | подпись `.aab` |
| Apple Developer ID cert | Keychain сборочной машины | подпись macOS-бандла |
| App-specific password / notarytool profile | Keychain (`xcrun notarytool store-credentials`) | нотаризация |
| те же в CI | GitHub Secrets | `release.yml` |

## Сборка

### macOS

```bash
cd app && flutter build macos --release
```

С этапа 4 перед этим собирается сайдкар (`make sidecar`), и дальше —
**подпись изнутри наружу**: каждый вложенный бинарник и каждая `.so` в
`site-packages`, потом бандл. Один неподписанный `.so` в зависимостях — отказ
нотаризации, и в отчёте он будет одной строкой среди многих.

Рабочие команды подписи **дописать сюда на этапе 4**, пока они в руках:
разбираться в этом второй раз дороже, чем записать один. Ориентиры — в
[python-sidecar.md](python-sidecar.md#подпись-и-нотаризация-на-macos):
`--options runtime`, `com.apple.security.cs.disable-library-validation`, и
**никакого** `com.apple.security.network.client`.

### Android

```bash
make fetch-pdfium  # кладёт libpdfium.so в jniLibs/arm64-v8a — один раз
cd app && flutter build appbundle --release
```

Без этого шага приложение всё равно собирается, но PDF падает в рантайме с
«не удалось прочитать файл»: `DynamicLibrary.open('libpdfium.so')` просто не
находит библиотеку. `make verify`/`make test` фетчат её сами для тестов
`core/`, но тестовый `.so` для хоста (macOS/Linux) не тот же файл, что нужен
в APK (Android-библиотека — `arm64`, кладётся туда же скриптом) — см.
`pdfium/fetch.sh`.

`compileSdk`/`targetSdk` держать на том, что требует Play; значения прибивать
числом в `android/app/build.gradle.kts`, а не через переменные — чтобы при
обновлении Flutter требование Play не поехало молча.

### iOS

В плане нет: собрать локально можно, подать в App Store — нельзя (Xcode на
macOS 12 слишком стар, `ITMS-90111`). Путь, если понадобится, — Xcode Cloud;
подробности и что к нему прицеплено — в
[future-development.md](future-development.md#ios).

## Релиз

1. `make verify` зелёный.
2. Версия бампнута, `CHANGELOG.md` дописан.
3. Тег `vX.Y.Z` → `release.yml` собирает и прикрепляет артефакты.
4. **Размер бандла по платформам записать в README.** Он — честная цена
   офлайна, и пользователь имеет право увидеть её до скачивания, а не после.
5. Android — в Play; macOS — DMG в GitHub Releases (Mac App Store — отдельное
   решение, см. [python-sidecar.md](python-sidecar.md#про-app-store)).

## Чего здесь нет

Ни расписаний, ни серверов, ни миграций, ни рассылок — в проекте нет
серверной части вообще. Если в этом файле однажды появится раздел про
бэкенд, значит продукт перестал быть тем, чем задумывался, и это повод
перечитать [offline-and-privacy.md](offline-and-privacy.md), а не дописать
раздел.

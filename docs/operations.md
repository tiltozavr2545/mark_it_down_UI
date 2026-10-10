# Эксплуатация

Что собирается чем, где лежат ключи подписи и что делать руками при релизе.
Отдельно от [client-architecture.md](client-architecture.md), потому что это не
устройство приложения: тот файл отвечает «как работает», этот — «что нажать».

Целевые платформы — Windows и Android; macOS вторична (разделы про неё
рабочие, но в приоритете не стоят). Windows собирается только в CI на
`windows-latest` — на машине разработки (Mac) Flutter его собрать не может.

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

GitHub Actions
([репозиторий](https://github.com/tiltozavr2545/mark_it_down_UI)), два
workflow; `release.yml` пока не написан:

| workflow | когда | что делает |
|---|---|---|
| `ci.yml` | push, PR | `make verify` + проверка «нет сети» + проверка бампа версии в PR (раннер ubuntu); **с Этапа 5** — отдельный джоб на `windows-latest`: проверки, `flutter build windows --release`, артефакт для скачивания |
| `release.yml` | тег `v*` | Windows (формат — решение Этапа 5, п. 6) и Android (`.aab`), прикрепление к GitHub Release; macOS (DMG) — только по отдельному запросу |

**Windows-джоб** (план — [implementation-plan.md](implementation-plan.md#этап-5--windows-05),
п. 2): шаги идут в `shell: bash` (Git Bash), потому что `run:` на Windows по
умолчанию PowerShell. Гонять ли в нём `make` или отдельные команды — решение
Этапа 5; пока рекомендация — отдельные шаги, потому что `make` на раннере может
не быть, а Makefile и `pdfium/fetch.sh` не знают `uname` Git Bash. Артефакт из
этого джоба и есть то, что автор скачивает и проверяет руками на своём
Windows-компьютере. Ручная проверка — чек-лист в п. 8 Этапа 5.

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
потому что именно там сетевая зависимость и приезжает транзитивно. Для
Windows аналог — шаг на манифест MSIX (нет `internetClient`), если упаковка
будет MSIX; без MSIX гарантии уровня ОС нет — см. Этап 5, п. 7, и
[offline-and-privacy.md](offline-and-privacy.md).

## Версия

Формат `name+build` в `pubspec.yaml`, бампается **в каждом PR** — тот же
порядок, что в Amicus:

```bash
make verify-version BASE_REF=origin/main
```

Цель зовёт `tool/verify_version.sh`: версия `app/pubspec.yaml` в рабочем дереве
сравнивается с `git show $BASE_REF:app/pubspec.yaml`. Падает, если формат не
`MAJOR.MINOR.PATCH+BUILD`, версия не изменилась или `build` не вырос строго.
`name` расти не обязан: допустим бамп одного `build`. `core/pubspec.yaml`
считается отдельно (версия без `build`) и здесь не проверяется. В `make verify`
цель не входит: локально сравнивать с `origin/main` незачем. В CI она идёт
отдельным шагом только на `pull_request` (базовая ветка подтягивается
`git fetch`).

`build` обязан расти монотонно: Google Play и App Store Connect не принимают
повторный номер, и обнаруживается это в самый неподходящий момент.

## Ключи и секреты

Ничего из этого не лежит в репозитории, и ничего из этого не нужно самому
приложению в рантайме — у него нет ни одного ключа, потому что ему некуда
ходить. Всё перечисленное нужно только для подписи сборок.

| что | где лежит | для чего |
|---|---|---|
| Android keystore | вне репозитория, путь в `android/key.properties` (в `.gitignore`) | подпись `.aab` |
| Сертификат Authenticode (Windows) | **нет** — открытый вопрос Этапа 5, п. 6 | подпись `.exe`/MSIX; без него SmartScreen предупреждает при первом запуске |
| Apple Developer ID cert | Keychain сборочной машины | подпись macOS-бандла |
| App-specific password / notarytool profile | Keychain (`xcrun notarytool store-credentials`) | нотаризация |
| те же в CI | GitHub Secrets | `release.yml` |

## Сборка

### Windows

Собирается **только в CI** на `windows-latest` (на Mac Flutter Windows не
собирает):

```bash
cd app && flutter build windows --release
# → app/build/windows/x64/runner/Release/  (markitdown_ui.exe + DLL + data/)
```

Рядом с `.exe` должны лежать `pdfium.dll` и `sidecar/` (см.
[implementation-plan.md](implementation-plan.md#этап-5--windows-05), п. 3–4;
сайдкар собирается отдельным джобом `make sidecar` на том же раннере).
Упаковка — zip, Inno Setup или MSIX — решение Этапа 5, п. 6; **не написано,
команды появятся здесь, когда решение будет принято**. Подписи Authenticode
нет (сертификата нет), SmartScreen на неподписанной сборке предупредит.

### macOS (вторичная платформа)

```bash
cd app && flutter build macos --release
```

С этапа 4 перед этим собирается сайдкар (`make sidecar`, см.
[python-sidecar.md](python-sidecar.md#сборка)), и дальше — **подпись изнутри
наружу**: сначала каждый Mach-O внутри сайдкара, потом фреймворки Flutter,
потом `.app`, потом DMG. Один неподписанный `.so` в зависимостях — отказ
нотаризации, и в отчёте он будет одной строкой среди многих.

#### Подпись и нотаризация: команды

**Статус проверки.** Проверено на этой машине: всё, что относится к
**ad-hoc подписи с Hardened Runtime** (`--options runtime`, идентичность `-`):
скрипт подписи, проверка `codesign --verify --strict --deep`, запуск `run.py`
по всем шести форматам из подписанного дерева, вложение подписанного сайдкара
в тестовый `.app` и подпись этого `.app` с `Release.entitlements`. **Не
проверено** (на машине нет Developer ID — `security find-identity -v -p
codesigning` пуст): подпись настоящей идентичностью, `--timestamp` с сервером
Apple, нотаризация, `stapler`, `spctl`, поведение под настоящей песочницей
`.app` и сборка самого Runner (нет Xcode). Команды ниже для этой части
написаны по документации и должны быть пройдены один раз вручную с реальным
сертификатом; что сломается — поправить здесь же.

Порядок строгий, потому что подпись хеширует содержимое: любая правка файла
после подписи её ломает.

```bash
ID="Developer ID Application: Имя Фамилия (TEAMID)"

# 1. Сайдкар — целиком, до подписи чего-либо ещё. Подпись только ПОСЛЕ
#    compileall и всех чисток, которые делает build.sh.
make sidecar
make sign-sidecar IDENTITY="$ID"        # = sidecar/sign.sh sidecar/dist/<host> "$ID"
#    Что делает: каждый Mach-O по магическим байтам (.so/.dylib — первыми,
#    python/bin/python3.12 — последним, с sidecar/sidecar.entitlements),
#    --options runtime --timestamp, затем codesign --verify --strict по каждому
#    файлу и --deep --strict по интерпретатору, затем run.py --self-check.

# 2. Собрать приложение и положить сайдкар в Contents/Resources/sidecar
#    (шаг Xcode-сборки не написан — см. «Встраивание» ниже). rsync -a сохраняет
#    подписи: они лежат внутри самих файлов.
cd app && flutter build macos --release
APP=build/macos/Build/Products/Release/MarkItDown.app
rsync -a --delete ../sidecar/dist/macos-$(uname -m)/ "$APP/Contents/Resources/sidecar/"

# 3. Фреймворки и dylib самого Flutter-приложения — изнутри наружу.
#    --deep НЕ использовать: он перезапишет подписи вложенного сайдкара без
#    entitlements интерпретатора.
find "$APP/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0 |
  xargs -0 -n1 codesign --force --sign "$ID" --options runtime --timestamp

# 4. Само приложение — с Release.entitlements (песочница, без сети).
codesign --force --sign "$ID" --options runtime --timestamp \
  --entitlements macos/Runner/Release.entitlements "$APP"

# 5. Проверки до отправки.
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP"      # app-sandbox есть, network.* нет
codesign -d --entitlements - "$APP/Contents/Resources/sidecar/python/bin/python3.12"
spctl -a -vv -t exec "$APP"              # до нотаризации: "rejected (Unnotarized Developer ID)" — это норма

# 6. DMG и нотаризация. Ключи notarytool — один раз:
#    xcrun notarytool store-credentials markitdown-notary \
#        --apple-id <id> --team-id <TEAMID> --password <app-specific-password>
hdiutil create -volname MarkItDown -srcfolder "$APP" -ov -format UDZO MarkItDown.dmg
codesign --sign "$ID" --timestamp MarkItDown.dmg
xcrun notarytool submit MarkItDown.dmg --keychain-profile markitdown-notary --wait
#    Если Invalid — причины построчно (обычно: неподписанный/без runtime Mach-O):
#    xcrun notarytool log <submission-id> --keychain-profile markitdown-notary

# 7. Степлинг и финальная проверка (нормальный результат: "accepted",
#    "source=Notarized Developer ID").
xcrun stapler staple MarkItDown.dmg
xcrun stapler validate MarkItDown.dmg
spctl -a -vv -t open --context context:primary-signature MarkItDown.dmg
```

Почему шаг 1 стоит особняком: сайдкар нужен также без приложения (сверка с
Dart-ядром, разработка), а скрипт подписи сам проверяет всё дерево и
отказывается, если нашёл Mach-O без подписи. Хуки в Xcode для того же —
вопрос будущей Build Phase (см. ниже), на команды это не влияет.

#### Entitlements: что и почему

| где | что | зачем |
|---|---|---|
| `Release.entitlements` (Runner) | `app-sandbox`, `files.user-selected.read-only` | **песочница включена намеренно**: «нет сети» на macOS — это не просто отсутствие `network.client`, а *песочница без него*. В несандбоксном приложении отсутствие этого ключа ничего не запрещает |
| `DebugProfile.entitlements` | то же + `allow-jit`, `network.server` | инструменты Flutter (hot reload, VM service); только debug/profile, в релиз не попадает |
| `sidecar/sidecar.entitlements` (интерпретатор) | `cs.disable-library-validation` | см. [python-sidecar.md](python-sidecar.md#подпись-проверено-ad-hoc-с-hardened-runtime) |
| нигде | `network.client`, `network.server` в Release | CI-шаг «нет com.apple.security.network.* в Release.entitlements и сайдкаре» |

Решение по Runner: **песочницу оставить**, сетевые ключи в Release не
добавлять. Аргументы: (а) распространение — DMG, не MAS, так что sandbox
формально не обязателен, но он единственное, что делает гарантию «нет сети»
проверяемой операционной системой; (б) сайдкар как подпроцесс наследует
песочницу родителя и потому тоже без сети — Python-зависимости не смогут
позвонить наружу, даже если очень захотят; (в) приложению хватает
`files.user-selected.read-only`: файл приходит через диалог или drag-and-drop
(в песочнице это выдаёт доступ), на запись пользователь ничего не просил, а
сайдкар читает копию из временной папки контейнера. Цена: подпроцесс в
песочнице нельзя проверить здесь — нужен живой `.app` (см. «Статус проверки» выше).

#### Встраивание сайдкара в macOS-бандл — открыто

Приложение ищет сайдкар в `<App>.app/Contents/Resources/sidecar`
(`SidecarConverter.discover`, см.
[conversion-pipeline.md](conversion-pipeline.md#сайдкар--просто-ещё-один-конвертер)),
а нужного шага сборки в `app/macos/` **нет**: Xcode на машине автора не
ставится (см. [../AGENTS.md](../AGENTS.md)), и править
`Runner.xcodeproj/project.pbxproj` вслепую, без возможности собрать и
проверить, не стали. Что нужно сделать, когда macOS-сборка заработает:

1. Build Phase типа Run Script в таргете `Runner`, после «Copy Bundle
   Resources»: скопировать результат `make sidecar` (каталог с `python/`,
   `lib/`, `run.py`, `manifest.json`) в
   `"$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources/sidecar"` (`rsync -a
   --delete`, симлинки внутри `python/` сохранять — `-a` это делает).
2. Входные/выходные файлы фазы указать явно (иначе Xcode будет пересобирать
   её каждый раз или, наоборот, не запускать), `ENABLE_USER_SCRIPT_SANDBOXING`
   для этой фазы выключить — скрипт читает каталог вне проекта.
3. Подпись вложенных `.so`/исполняемых файлов — отдельным шагом после
   копирования, см. выше; сам `Contents/Resources/sidecar` должен попасть в
   подпись бандла.
4. Без собранного сайдкара фаза не должна падать: приложение умеет работать
   без него (нет каталога — сайдкар не регистрируется), а `flutter build
   macos` для разработки Dart-части не обязан его требовать.
5. Проверить на машине с Xcode: «бросили `.xls` — получили Markdown», в
   `warnings` есть `converterId: sidecar`.

На Android ничего из этого не делается: сайдкар в APK не попадает — проверено
замером (APK 25,1 → 25,3 МБ, рост целиком из Dart-кода, см.
[format-coverage.md](format-coverage.md#android-не-потолстел-этап-4)).

### Android

```bash
make fetch-pdfium  # кладёт libpdfium.so в jniLibs/arm64-v8a — один раз
cd app && flutter build appbundle --release
```

Без этого шага приложение всё равно собирается, но PDF падает в рантайме с
«не удалось прочитать файл»: `DynamicLibrary.open('libpdfium.so')` просто не
находит библиотеку. `make verify`/`make test` фетчат её сами для тестов
`core/`, но тестовый `.so` для хоста (macOS/Linux; для Windows — `pdfium.dll`,
Этап 5) не тот же файл, что нужен
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
5. Android — в Play; Windows — в GitHub Releases в формате, выбранном в
   Этапе 5; macOS (вторичная) — DMG в GitHub Releases, только по отдельному
   запросу (Mac App Store — отдельное решение, см.
   [python-sidecar.md](python-sidecar.md#про-app-store)).

## Чего здесь нет

Ни расписаний, ни серверов, ни миграций, ни рассылок — в проекте нет
серверной части вообще. Если в этом файле однажды появится раздел про
бэкенд, значит продукт перестал быть тем, чем задумывался, и это повод
перечитать [offline-and-privacy.md](offline-and-privacy.md), а не дописать
раздел.

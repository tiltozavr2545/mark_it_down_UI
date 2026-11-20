# Operations

What gets built by what, where the signing keys live, and what to do by hand
at release time. Kept separate from
[client-architecture.md](client-architecture.md), because this isn't about
how the app is built: that file answers "how it works," this one answers
"what to click."

CI builds Windows on `windows-2022`, Android on `ubuntu-24.04`, and
macOS on separate Intel and Apple Silicon runners.

---

## One command before shipping

```bash
make verify
```

Runs, for both `app/` and `core/`: `pub get`, `dart format
--set-exit-if-changed`, `flutter analyze`, `flutter test`, `dart test`. CI
runs exactly the same thing — the local command exists so you don't find out
about a formatting break from the pipeline.

`make test` downloads PDFium and the OCR models itself (`tesseract/fetch.sh`).
On an Apple Silicon Mac, use the [macOS test commands](#local-macos-tests)
because the standalone macOS PDFium download is x64.
The OCR tests (`core/test/ocr_test.dart`) need a built Tesseract: run `make
tesseract` once (≈10 minutes, cmake plus a C/C++ compiler), and after that
`make test` finds it in `tesseract/native/host/` on its own. Without it,
those tests are skipped, not failed. CI on Linux takes Tesseract from Ubuntu
packages, CI on Windows builds it via `build.sh` with caching.

Speech recognition (0.8) works the same way, but is heavier: `make whisper`
builds whisper.cpp with its wrapper layer (`whisper/build.sh` →
`whisper/native/host/`, ≈10 minutes on an Intel Mac — a dozen CPU-backend
variants) and downloads the models into `whisper/models/` and
`app/assets/whisper/`. `make test` picks up the installed host libraries
and models. Speech tests skip when those are absent. Linux and Windows CI
cache the builds and models. The two AAC tests require a supported system
decoder and skip on the macOS host.

## CI

The [CI workflow](../.github/workflows/ci.yml) runs on pushes to `main`,
pull requests, release tag pushes and manual dispatch. A feature branch
gets automatic CI when it has a pull request. Use **Actions → CI → Run
workflow** for a manual run on a branch or to preview all four packages.

| Job | What it checks and builds |
|---|---|
| `verify` | Linux runs `make verify` and privacy checks. Pull requests also check the version bump. Tag pushes verify the release version, notes and commit ancestry. |
| `windows-sidecar` and `windows` | Build the x64 Python bundle, compare fixtures, run Windows tests and check the packaged app. |
| `android` | Build the arm64 APK and check its permissions, native libraries and models. |
| `macos` | Test the native engines and build, sign and verify DMGs for Intel and Apple Silicon. |
| `publish` | On a version tag push, wait for every job above and publish all four downloads in one GitHub Release. |

**Windows job** (plan — [implementation-plan.md](implementation-plan.md#stage-5--windows-05),
item 2): steps run under `shell: bash` (Git Bash), because `run:` on
Windows defaults to PowerShell. These are **separate steps, not `make`**:
the runner's Git Bash has no `make`, and the Makefile only has Darwin/Linux
branches. The cost is that the list of checks lives in two places; when
`make verify` is edited, the job must be edited too (a reminder for this
sits next to the `verify` target in the Makefile). Git Bash knows about
`pdfium/fetch.sh` (`MINGW*|MSYS*` → `pdfium.dll`). The job's first step
checks that the checkout came out with LF line endings (`.gitattributes`),
otherwise `dart format` and the byte-for-byte fixtures would fail for a
reason unrelated to the code. The artifact from this job is exactly what the
author downloads and checks by hand on their own Windows machine (Actions →
run → Artifacts → unzip → `markitdown_ui.exe`). The manual check is the
checklist in item 8 of Stage 5.

**The "network only via a link" check** is not a formality but the
product's main guarantee (see
[offline-and-privacy.md](offline-and-privacy.md)). Before 0.9 this was a
"no network" check (no `INTERNET` in the APK); with "link" mode, the
guarantee is held up by the code. Steps, each of which fails the build:

```bash
# 1. A networking package in the dependency tree — network access bypassing core/lib/src/web/
for package in app core; do
  if (cd "$package" && dart pub deps --no-dev --style=list) \
    | grep -E '^- (http|dio|grpc|sentry|firebase)[^a-zA-Z0-9_]'; then
    exit 1
  fi
done

# 2. Sockets and an HTTP client — only allowed in core/lib/src/web/
grep -rnE '\b(HttpClient|HttpServer|HttpOverrides|Socket|RawSocket|SecureSocket|ServerSocket|RawDatagramSocket|WebSocket|InternetAddress|NetworkInterface)\b' \
  app/lib core/lib --include='*.dart' | grep -v '^core/lib/src/web/' && exit 1

# 3. Among the network permissions in the built APK — only INTERNET
aapt dump permissions app/build/app/outputs/flutter-apk/app-release.apk \
  | grep -qE 'ACCESS_NETWORK_STATE|ACCESS_WIFI_STATE|CHANGE_NETWORK_STATE|CHANGE_WIFI_STATE' && exit 1
```

The third step runs in the Android job of `ci.yml` using `aapt` from the
runner's Android SDK. The first two run on every PR, because that's
exactly where a transitive network dependency would sneak in. The Windows
source check scans the runner for added networking libraries and
capabilities. Windows ZIP distribution relies on source checks and the
behavior of the bundled libraries. See
[offline-and-privacy.md](offline-and-privacy.md).

## Manual export checks

Use the Windows CI artifact, an APK on a physical Android device and
the DMG for the Mac's CPU. The Flutter tests cover the queue, previews
and duplicate filenames. Check the native dialogs and output directories
as follows.

1. Import two files with the same stem and different contents, such as
   `notes.txt` and `notes.csv`. On Windows and macOS, try the picker and
   drag-and-drop. On Android, try the picker and sharing several files
   together.
2. Open one ready row to see its Markdown. With **Separate files**
   selected, cancel **Save to folder** once, then choose a directory
   containing `notes.md`. Check that both new `.md` files match their
   previews and confirm the existing file was kept.
3. Add a truncated ZIP. When it fails, check that **Separate files**
   can still save the ready results. Switch to **One document**, remove
   the failed item, reorder the other two and check the merged headings.
4. Check the queue and export controls in the system's light and dark
   themes. On Windows and macOS, resize the window to exercise the narrow
   layout.

## Version

The `name+build` format in `pubspec.yaml`, bumped **on every PR** — the same
convention as in Amicus:

```bash
make verify-version BASE_REF=origin/main
```

The target calls `tool/verify_version.sh`: the version in the working
tree's `app/pubspec.yaml` is compared against `git show
$BASE_REF:app/pubspec.yaml`. It fails if the format isn't
`MAJOR.MINOR.PATCH+BUILD`, the version hasn't changed, or `build` hasn't
strictly increased. `name` isn't required to grow: bumping just the `build`
is fine. `core/pubspec.yaml` is counted separately (a version without
`build`) and isn't checked here. The target is not part of `make verify`:
there's no point comparing against `origin/main` locally. In CI it runs as
a separate step only on `pull_request` (the base branch is fetched via
`git fetch`).

`build` is the project's monotonic build number and becomes Android's
`versionCode`.

## Conversion dependencies

| Component | Pins for 0.11.0 | Build settings |
|---|---|---|
| PDFium for Windows, Android and standalone host tests | `160.0.8165.0` (`chromium/8165`) | [`pdfium/fetch.sh`](../pdfium/fetch.sh) |
| PDFium in the macOS DMGs | Native library from `pypdfium2==5.11.0` | [macOS wheel locks](../sidecar/locks/) and [`tool/package_macos.sh`](../tool/package_macos.sh) |
| Desktop OCR | Tesseract 5.5.4, Leptonica 1.87.0, libpng 1.6.59, libjpeg-turbo 3.2.1, zlib 1.4 on Windows | [`tesseract/versions.sh`](../tesseract/versions.sh) |
| Android OCR | Tesseract4Android 4.9.0 (Tesseract 5.5.1) | [`tesseract/versions.sh`](../tesseract/versions.sh) |
| Speech | whisper.cpp 1.9.5, Whisper small q8_0, Silero VAD 6.2.0, miniaudio 0.11.26, Opus 1.6.1 | [`whisper/versions.sh`](../whisper/versions.sh) |
| Desktop sidecar | MarkItDown 0.1.9, CPython 3.12.16 | [`sidecar/common.sh`](../sidecar/common.sh), [wheel locks](../sidecar/locks/) |
| Dart archives and images | `archive` ^4.7.1, `image` ^4.13.1 | [`core/pubspec.yaml`](../core/pubspec.yaml) |

After changing a native pin, rebuild the affected host libraries before
`make verify`. The PDFium fetch script verifies archives by SHA-256 and
refreshes installed files when the pinned archive changes. For a sidecar
update, regenerate the wheel locks, run its integration tests, and review
the [fixture comparison](python-sidecar.md#lock-file-reproducibility).

The dependency update was checked on macOS x86_64 with Dart and Flutter
tests, native OCR and speech tests, and the real Python sidecar. The
Android arm64 APK built with the updated native libraries. Windows wheels
were checked against the lock. The Windows build and device checks belong
to CI and the manual platform checklists.

## Keys and secrets

None of this lives in the repository, and none of it is needed by the
application itself at runtime — it has not a single key, because it has
nowhere to call. Everything listed below is only needed for signing builds.

| what | where it lives | what for |
|---|---|---|
| Android keystore | **none yet** — Stage 7; will live outside the repo (`android/key.properties` in `.gitignore`) and in GitHub Secrets | APK signing; without a stable key a new version can't install over an old one |
| Authenticode certificate (Windows) | **none yet** — open question (Stage 5, item 6 → Stage 7) | signing the `.exe`/MSIX; without it, SmartScreen warns on first run |

## Build

### Windows

Use Git Bash on Windows x64 with Flutter 3.32.8, Visual Studio 2022
with the C++ desktop workload, and CMake. Run from the repository root.
CI uses the same native build scripts on `windows-2022`.

```bash
./pdfium/fetch.sh
./tesseract/build.sh
./tesseract/fetch.sh
./whisper/build.sh
./whisper/fetch.sh
./sidecar/build.sh
(cd app && flutter build windows --release)
```

The app is in `app/build/windows/x64/runner/Release/`.

Next to the `.exe` go `pdfium.dll`, the Tesseract DLLs (`leptonica-*.dll`,
`tesseract*.dll`) and `sidecar/` — via `install(...)` rules in
`app/windows/CMakeLists.txt`; the OCR models (`*.traineddata`) travel as
Flutter assets, into `data/flutter_assets/assets/tessdata/`. The Tesseract
DLLs are mandatory, just like `pdfium.dll`: they're built by
`./tesseract/build.sh` (Git Bash + Visual Studio 2022, ≈10 minutes; cached
by recipe hash in CI), and the models plus Android `.so` files are
downloaded by `./tesseract/fetch.sh`. The speech-recognition DLLs are
equally mandatory (`markitdown_whisper.dll`, `whisper.dll`, `ggml*.dll`, the
various `ggml-cpu-*.dll` variants) — via `./whisper/build.sh`; the models
travel as assets into `data/flutter_assets/assets/whisper/`
(`./whisper/fetch.sh`, +265 MB to the zip). `pdfium.dll` is mandatory: without
`pdfium/native/host/pdfium.dll` (downloaded by `./pdfium/fetch.sh` in Git
Bash), CMake fails with a clear error rather than building an app without
PDF support. The sidecar is optional: without
`sidecar/dist/windows-x86_64/manifest.json`, you get a Dart-only build
(item 4 of the plan — the sidecar for Windows is built as a separate job).

CI uploads the `Release/` directory as an artifact. GitHub Releases
packages it in a ZIP with a versioned top-level folder. The executable
is unsigned, so SmartScreen may display a warning on first run.

### macOS

CI builds two packages targeting
macOS 12 Monterey and later. It uses `macos-15-intel` for `x64` and
`macos-26` for `arm64`. The workflow uploads `markitdown_ui-macos-x64`
and `markitdown_ui-macos-arm64` as artifacts. A successful tag build
attaches the matching
`markitdown_ui-X.Y.Z-macos-x64.dmg` and
`markitdown_ui-X.Y.Z-macos-arm64.dmg` to GitHub Releases.

On a Mac with full Xcode, build for the host architecture:

```bash
make tesseract fetch-tesseract whisper sidecar
(cd app && FLUTTER_XCODE_ARCHS="$(uname -m)" \
  FLUTTER_XCODE_MACOSX_DEPLOYMENT_TARGET=12.0 flutter build macos --release)
app_name="$(cat app/macos/Flutter/ephemeral/.app_filename)"
bash tool/package_macos.sh "app/build/macos/Build/Products/Release/$app_name" \
  dist/markitdown_ui-macos.dmg
```

The macOS packages use the PDFium binary from the locked `pypdfium2`
wheel for Monterey compatibility. CI tests the
bundled PDFium, OCR, speech and Python components. It uses short speech
fixtures on macOS. The full suite, including the long-transcription
fixtures, runs on Linux and Windows CI. Packaging checks the
declared minimum OS of the app and its Mach-O binaries for the packaged
architecture. It creates an HFS+ disk image with a shortcut to
**Applications** and verifies its checksum.

#### Local macOS tests

The standalone PDFium download used by `make test` is x64 and declares
macOS 13 as its minimum. Use the locked wheel to test the same PDFium as
the DMG on either Mac architecture. Run from the repository root.

```bash
make pub-get format analyze
make tesseract fetch-tesseract whisper sidecar
(cd app && flutter test)
export MARKITDOWN_TESSERACT_DIR="$PWD/tesseract/native/host"
export MARKITDOWN_WHISPER_DIR="$PWD/whisper/native/host"
export MARKITDOWN_SIDECAR_DIR="$PWD/sidecar/dist/macos-$(uname -m)"
export MARKITDOWN_PDFIUM_PATH="$MARKITDOWN_SIDECAR_DIR/lib/pypdfium2_raw/libpdfium.dylib"
(cd core && dart test)
```

#### Signing and sandbox

The packaging script places the native libraries in
`Contents/Frameworks` and the Python sidecar in `Contents/Resources/sidecar`.
It signs the interpreter and its libraries with `sidecar/sign.sh`,
runs the sidecar self-check, and seals the app with an ad-hoc signature.
GitHub Actions uses no Apple credentials. The app is distributed
without notarization; users can approve the first launch in macOS
settings. [Apple's guide](https://support.apple.com/en-us/102445)

The release app uses App Sandbox. `files.user-selected.read-write`
allows saving Markdown to a location selected by the user.
`network.client` is for outgoing connections in link mode. The sidecar
inherits the app's sandbox and reads input from the app's temporary
directory because access granted by a file picker belongs to the app.

#### macOS smoke checks

The Intel host passed the conversion tests with the bundled PDFium
and Python components. A test app with the native libraries and models
also passed signing and DMG checksum checks on macOS 12.7.6. GitHub
Actions built and verified both DMGs for 0.11.0. The following manual
checks on the automated artifacts are pending.

1. Install the matching DMG on an Intel Mac running Monterey and on an
   Apple Silicon Mac running a current version of macOS. Confirm the
   first launch using the [release instructions](../.github/release-notes.md).
2. Convert a PDF with a table, a scanned page, an `.xls` or `.msg` and a
   short WAV or MP3 file. Check the OCR text, transcript and whether
   the legacy file used the bundled sidecar.
3. Open the native save dialog for one result and run the
   [batch export checks](#manual-export-checks).

### Android

```bash
make fetch-pdfium     # verifies the pinned PDFium archive and refreshes older copies
make fetch-tesseract  # libtesseract/libleptonica/libjpeg/libpngx.so into the same place
                      # + rus/eng models in app/assets/tessdata/
./whisper/build.sh --android  # libmarkitdown_whisper/libwhisper/libggml*.so
                              # into the same place — NDK 27.0.12077973, ≈10 minutes
./whisper/fetch.sh    # Whisper models into app/assets/whisper/ (265 MB)
cd app && flutter build apk --release --target-platform android-arm64
```

Without `fetch-tesseract` the APK still builds (only a `.gitkeep` sits in
`assets/tessdata/`), but OCR is unavailable in it — the app says so
directly in a warning. The same applies to speech recognition without the
`whisper/` steps. The release job checks that the `.so` files and the
models are actually present in the APK. With the Whisper model, the APK
weighs ≈300 MB. Play's limit (200 MB for the base module) doesn't affect
us: we don't publish on Google Play, the APK is distributed via GitHub
Releases.

PDF conversion requires the Android arm64 `libpdfium.so` in
`app/android/app/src/main/jniLibs/arm64-v8a/`. The fetch script also
installs a separate library for host tests.

`app/android/app/build.gradle.kts` sets `compileSdk` to 36, `minSdk` to
23, and NDK to `27.0.12077973`. `targetSdk` follows the pinned Flutter
SDK. The release job uses JDK 17.

### iOS

Not in the plan: it can be built locally, but can't be submitted to the App
Store (Xcode on macOS 12 is too old, `ITMS-90111`). The path, if it's ever
needed, is Xcode Cloud; details and what that would entail are in
[future-development.md](future-development.md#ios).

## Release

Use the repository's [GitHub release skill](../.agents/skills/github-release/SKILL.md)
to prepare and publish one requested version.

1. Confirm the commit on `origin/main` and read its version from
   `app/pubspec.yaml`. Prepare the version's English **What's new** section
   in `CHANGELOG.md`. `tool/release_notes.sh X.Y.Z` renders that section
   with the shared install instructions from `.github/release-notes.md`.
2. After approval, create `vX.Y.Z` at the confirmed commit and push the
   tag. The tag starts one CI run. CI checks that the tag matches the app
   version and points to a commit on `main`, builds and checks the four
   packages, and publishes them with the rendered notes. A failed check
   blocks publication.
3. Follow the tag run through completion and check the published release
   for the Windows x64 ZIP, Android arm64 APK, Intel DMG and Apple Silicon
   DMG. Retry transient failures on the same tag run.

The Android APK uses the runner's debug key. Installing over an existing
APK requires matching signatures. Windows uses an unsigned ZIP, and macOS
uses an ad-hoc signature. First-launch instructions are in the release
notes for each platform.

## What's not here

No schedules, no servers, no migrations, no mailing lists — the project has
no backend at all. If a backend section ever shows up in this file, it means
the product has stopped being what it was meant to be, and that's a reason
to re-read [offline-and-privacy.md](offline-and-privacy.md), not to finish
writing the section.

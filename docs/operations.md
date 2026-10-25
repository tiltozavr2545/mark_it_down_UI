# Operations

What gets built by what, where the signing keys live, and what to do by hand
at release time. Kept separate from
[client-architecture.md](client-architecture.md), because this isn't about
how the app is built: that file answers "how it works," this one answers
"what to click."

Target platforms are Windows and Android; macOS is secondary (the sections
about it are maintained, but it's not a priority). Windows only builds in
CI on `windows-latest` — on the development machine (a Mac), Flutter can't
build it.

While the project is still at zero, most sections are **placeholders**: they
are laid out so that working commands can be filled in as the stages
progress, rather than having to be hunted for from scratch. Wherever commands
haven't been verified yet, that is stated outright.

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
The OCR tests (`core/test/ocr_test.dart`) need a built Tesseract: run `make
tesseract` once (≈10 minutes, cmake plus a C/C++ compiler), and after that
`make test` finds it in `tesseract/native/host/` on its own. Without it,
those tests are skipped, not failed. CI on Linux takes Tesseract from Ubuntu
packages, CI on Windows builds it via `build.sh` with caching.

Speech recognition (0.8) works the same way, but is heavier: `make whisper`
builds whisper.cpp with its wrapper layer (`whisper/build.sh` →
`whisper/native/host/`, ≈10 minutes on an Intel Mac — a dozen CPU-backend
variants) and downloads models (`whisper/fetch.sh`, 265 MB → into
`whisper/models/` and `app/assets/whisper/`). `make test` doesn't download
the models: beyond that, `make test` itself finds the libraries and runs
`core/test/speech_test.dart`, skipping it if they're absent. Both Linux and
Windows CI build and download with caching keyed on the recipe hash.

## CI

GitHub Actions
([repository](https://github.com/tiltozavr2545/mark_it_down_UI)), two
workflows:

| workflow | when | what it does |
|---|---|---|
| `ci.yml` | push to a branch, PR; also invoked from `release.yml` | `verify` job (ubuntu): `make verify` + "network only via a link" check + version-bump check on the PR; `windows` job (`windows-latest`): the same checks, `flutter build windows --release`, artifact `markitdown_ui-windows-x64` (a zip of the `Release/` directory) |
| `release.yml` | tag `v*` | the whole of `ci.yml` (via `workflow_call`) + an arm64 APK with a network-permissions check on the built file → a GitHub Release with `markitdown_ui-X.Y.Z-windows-x64.zip` (with the sidecar) and `markitdown_ui-X.Y.Z-android-arm64.apk`; macOS — only on separate request |

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
dart pub deps --style=list | grep -E '^- (http|dio|grpc|sentry|firebase)[^a-zA-Z0-9_]' && exit 1

# 2. Sockets and an HTTP client — only allowed in core/lib/src/web/
grep -rnE '\b(HttpClient|HttpServer|Socket|RawSocket|SecureSocket|ServerSocket|WebSocket|InternetAddress)\b' \
  app/lib core/lib --include='*.dart' | grep -v '^core/lib/src/web/' && exit 1

# 3. Among the network permissions in the built APK — only INTERNET
aapt dump permissions build/app/outputs/flutter-apk/app-release.apk \
  | grep -qE 'ACCESS_NETWORK_STATE|ACCESS_WIFI_STATE|CHANGE_NETWORK_STATE|CHANGE_WIFI_STATE' && exit 1
```

The third step runs at build time, i.e. in `release.yml` (using `aapt` from
the runner's Android SDK); the first two run on every PR, because that's
exactly where a transitive network dependency would sneak in. For Windows
there are no permissions at all: packaging is still a zip, and a zip knows
nothing about them. The step "no networking libraries in `app/windows/`"
only catches what we added ourselves (`ws2_32`, `winhttp`, `wininet`,
`internetClient`); if MSIX is chosen at Stage 7, a grep over its manifest
will be added. See Stage 5, item 7, and
[offline-and-privacy.md](offline-and-privacy.md).

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

`build` must grow monotonically: Google Play and App Store Connect won't
accept a repeated number, and that's discovered at the most inconvenient
moment.

## Keys and secrets

None of this lives in the repository, and none of it is needed by the
application itself at runtime — it has not a single key, because it has
nowhere to call. Everything listed below is only needed for signing builds.

| what | where it lives | what for |
|---|---|---|
| Android keystore | **none yet** — Stage 7; will live outside the repo (`android/key.properties` in `.gitignore`) and in GitHub Secrets | APK signing; without a stable key a new version can't install over an old one |
| Authenticode certificate (Windows) | **none yet** — open question (Stage 5, item 6 → Stage 7) | signing the `.exe`/MSIX; without it, SmartScreen warns on first run |
| Apple Developer ID cert | the build machine's Keychain | signing the macOS bundle |
| App-specific password / notarytool profile | Keychain (`xcrun notarytool store-credentials`) | notarization |
| the same, in CI | GitHub Secrets | `release.yml` |

## Build

### Windows

Only builds **in CI**, on `windows-latest` (Flutter can't build Windows on a
Mac):

```bash
cd app && flutter build windows --release
# → app/build/windows/x64/runner/Release/  (markitdown_ui.exe + DLLs + data/)
```

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

**Packaging is a zip** (the author's decision, Stage 5, item 6: "zip for
now, decide later"; Inno Setup or MSIX is a Stage 7 question). Right now the
zip is simply the CI artifact itself:
`actions/upload-artifact` hands back the `Release/` directory as an
archive. There's no Authenticode signature (no certificate yet): on first
run, SmartScreen will show "Windows protected your PC" → "More info" → "Run
anyway."

### macOS (secondary platform)

```bash
cd app && flutter build macos --release
```

Since Stage 4, the sidecar is built first (`make sidecar`, see
[python-sidecar.md](python-sidecar.md#build)), and after that comes
**signing from the inside out**: first every Mach-O inside the sidecar, then
the Flutter frameworks, then the `.app`, then the DMG. A single unsigned
`.so` among the dependencies means notarization is refused, and in the
report it will be just one line among many.

#### Signing and notarization: commands

**Verification status.** Verified on this machine: everything related to
**ad hoc signing with Hardened Runtime** (`--options runtime`, identity
`-`): the signing script, `codesign --verify --strict --deep` verification,
running `run.py` across all six formats from the signed tree, embedding the
signed sidecar in a test `.app` and signing that `.app` with
`Release.entitlements`. **Not verified** (there's no Developer ID on this
machine — `security find-identity -v -p codesigning` is empty): signing
with a real identity, `--timestamp` against Apple's server, notarization,
`stapler`, `spctl`, behavior under a real `.app` sandbox, and building
Runner itself (no Xcode). The commands below for that part are written from
the documentation and need to be run through once by hand with a real
certificate; whatever breaks should be fixed right here.

The order is strict, because signing hashes the content: any edit to a file
after signing breaks it.

```bash
ID="Developer ID Application: First Last (TEAMID)"

# 1. The sidecar — in full, before signing anything else. Sign only AFTER
#    compileall and all the cleanup steps that build.sh performs.
make sidecar
make sign-sidecar IDENTITY="$ID"        # = sidecar/sign.sh sidecar/dist/<host> "$ID"
#    What it does: every Mach-O, found by magic bytes (.so/.dylib first,
#    python/bin/python3.12 last, with sidecar/sidecar.entitlements),
#    --options runtime --timestamp, then codesign --verify --strict on each
#    file and --deep --strict on the interpreter, then run.py --self-check.

# 2. Build the app and place the sidecar into Contents/Resources/sidecar
#    (the Xcode build step isn't written yet — see "Embedding" below). rsync -a
#    preserves signatures: they live inside the files themselves.
cd app && flutter build macos --release
APP=build/macos/Build/Products/Release/MarkItDown.app
rsync -a --delete ../sidecar/dist/macos-$(uname -m)/ "$APP/Contents/Resources/sidecar/"

# 3. The Flutter app's own frameworks and dylibs — inside out.
#    Do NOT use --deep: it would overwrite the nested sidecar's signatures
#    without the interpreter's entitlements.
find "$APP/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0 |
  xargs -0 -n1 codesign --force --sign "$ID" --options runtime --timestamp

# 4. The application itself — with Release.entitlements (sandboxed, no network).
codesign --force --sign "$ID" --options runtime --timestamp \
  --entitlements macos/Runner/Release.entitlements "$APP"

# 5. Checks before submission.
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP"      # app-sandbox present, network.server absent
codesign -d --entitlements - "$APP/Contents/Resources/sidecar/python/bin/python3.12"
spctl -a -vv -t exec "$APP"              # before notarization: "rejected (Unnotarized Developer ID)" is expected

# 6. DMG and notarization. notarytool credentials — once:
#    xcrun notarytool store-credentials markitdown-notary \
#        --apple-id <id> --team-id <TEAMID> --password <app-specific-password>
hdiutil create -volname MarkItDown -srcfolder "$APP" -ov -format UDZO MarkItDown.dmg
codesign --sign "$ID" --timestamp MarkItDown.dmg
xcrun notarytool submit MarkItDown.dmg --keychain-profile markitdown-notary --wait
#    If Invalid — the reasons line by line (usually: an unsigned/no-runtime Mach-O):
#    xcrun notarytool log <submission-id> --keychain-profile markitdown-notary

# 7. Stapling and final check (a normal result is "accepted",
#    "source=Notarized Developer ID").
xcrun stapler staple MarkItDown.dmg
xcrun stapler validate MarkItDown.dmg
spctl -a -vv -t open --context context:primary-signature MarkItDown.dmg
```

Why step 1 stands apart: the sidecar is also needed without the app (for
cross-checking against the Dart core, and for development), and the signing
script itself verifies the whole tree and refuses if it finds an unsigned
Mach-O. Hooks in Xcode for the same purpose are a question for a future
Build Phase (see below) and don't affect the commands.

#### Entitlements: what and why

| where | what | why |
|---|---|---|
| `Release.entitlements` (Runner) | `app-sandbox`, `files.user-selected.read-only`, `network.client` (since 0.9) | **the sandbox is enabled deliberately**; `network.client` is for the "link" mode's outbound connections ([offline-and-privacy.md](offline-and-privacy.md)) |
| `DebugProfile.entitlements` | the same plus `allow-jit`, `network.server` | Flutter tooling (hot reload, VM service); debug/profile only, never shipped in release |
| `sidecar/sidecar.entitlements` (interpreter) | `cs.disable-library-validation` | see [python-sidecar.md](python-sidecar.md#signing-verified-ad-hoc-with-hardened-runtime) |
| nowhere | `network.server` in Release, any `network.*` for the sidecar | CI step "no network.server in Release.entitlements, no network for the sidecar" |

The decision on Runner (Stage 4, revisited at 0.9): **keep the sandbox**;
the only network key in Release is `network.client`. Below are the original
Stage 4 arguments; point (b) no longer holds as of 0.9: the sidecar inherits
`network.client` too, and what keeps it offline is the absence of network
converters, not the sandbox. The arguments: (a) distribution is a DMG, not
the MAS, so a sandbox isn't formally required, but it's the only thing that
makes the "no network" guarantee verifiable by the operating system itself;
(b) the sidecar, as a subprocess, inherits the parent's sandbox and is
therefore also without network access — the Python dependencies couldn't
phone out even if they really wanted to; (c) the application only needs
`files.user-selected.read-only`: the file arrives via a dialog or
drag-and-drop (which grants access inside the sandbox), the user never asked
for write access, and the sidecar reads a copy from the container's temp
folder. The cost: a sandboxed subprocess can't be verified here — it needs a
live `.app` (see "Verification status" above).

#### Embedding the sidecar into the macOS bundle — open

The app looks for the sidecar at
`<App>.app/Contents/Resources/sidecar`
(`SidecarConverter.discover`, see
[conversion-pipeline.md](conversion-pipeline.md#sidecar--just-another-converter)),
and the build step needed for that **doesn't exist** in `app/macos/`: Xcode
isn't installed on the author's machine (see [../AGENTS.md](../AGENTS.md)),
and editing `Runner.xcodeproj/project.pbxproj` blind, without being able to
build and verify it, wasn't an option. What needs to be done once the macOS
build works:

1. A Run Script Build Phase on the `Runner` target, after "Copy Bundle
   Resources": copy the output of `make sidecar` (the directory with
   `python/`, `lib/`, `run.py`, `manifest.json`) into
   `"$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources/sidecar"` (`rsync -a
   --delete`, keeping the symlinks inside `python/` — `-a` does that).
2. Declare the phase's input/output files explicitly (otherwise Xcode will
   either rebuild it every time or, conversely, never run it), and disable
   `ENABLE_USER_SCRIPT_SANDBOXING` for this phase — the script reads a
   directory outside the project.
3. Sign the nested `.so`/executable files in a separate step after copying,
   see above; `Contents/Resources/sidecar` itself must be covered by the
   bundle's signature.
4. The phase shouldn't fail without a built sidecar: the app can run without
   it (no directory means the sidecar just doesn't register), and `flutter
   build macos` for developing the Dart side shouldn't require it.
5. Verify on a machine with Xcode: "dropped an `.xls`, got Markdown," and
   `warnings` contains `converterId: sidecar`.

None of this happens on Android: the sidecar doesn't end up in the APK —
verified by measurement (APK 25.1 → 25.3 MB, the growth entirely from Dart
code, see
[format-coverage.md](format-coverage.md#android-didnt-get-fatter-stage-4)).

### Android

```bash
make fetch-pdfium     # libpdfium.so into jniLibs/arm64-v8a — once
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

Without this step the app still builds, but PDF fails at runtime with
"could not read the file": `DynamicLibrary.open('libpdfium.so')` simply
can't find the library. `make verify`/`make test` fetch it themselves for
`core/`'s tests, but the test `.so` for the host (macOS/Linux; for Windows —
`pdfium.dll`) isn't the same file needed in the APK (the Android library is
`arm64`, fetched into the same place by the script) — see
`pdfium/fetch.sh`.

`compileSdk`/`targetSdk` are pinned as plain numbers in
`android/app/build.gradle.kts`, rather than via variables — so they don't
drift silently on a Flutter upgrade. Play's `targetSdk` requirements don't
apply to us (we don't publish on Play), but a very old `targetSdk` makes
Android itself install with a Play Protect warning, or refuse to install at
all (Android 14+ refuses below `targetSdk` 23).

### iOS

Not in the plan: it can be built locally, but can't be submitted to the App
Store (Xcode on macOS 12 is too old, `ITMS-90111`). The path, if it's ever
needed, is Xcode Cloud; details and what that would entail are in
[future-development.md](future-development.md#ios).

## Release

1. `make verify` is green, changes are on main.
2. Version bumped, `CHANGELOG.md` updated.
3. Tag the commit on main — `release.yml` builds everything itself and
   publishes the release:

   ```bash
   git tag v0.5.0 && git push origin v0.5.0
   ```

   It fails if the version in `app/pubspec.yaml` doesn't match the tag, if
   the APK ended up with a network permission beyond `INTERNET`, or if the
   Windows build is missing the sidecar — a crippled release doesn't get
   published. The release text is built by `tool/release_notes.sh`:
   "What's new" — the version's own section of `CHANGELOG.md` (no section
   — the release fails), then `.github/release-notes.md` (install
   instructions for each platform). Both are hard-wrapped like all repo
   Markdown, but GitHub renders every line break in a release body as a
   real one, so the script joins paragraphs into single lines; preview it
   with `tool/release_notes.sh 0.10.0`. To fix the text of a published
   release: `tool/release_notes.sh X.Y.Z > /tmp/notes.md && gh release
   edit vX.Y.Z --notes-file /tmp/notes.md`.

   **Signing is still temporary.** The APK is signed with the runner's debug
   key (there's no own key yet) — enough for installing from a file, but
   the key is different for every release, so a new version can't be
   installed over an old one — the old one has to be removed first. This is
   fixed by a permanent key in GitHub Secrets (Play isn't needed for that).
   The Windows build isn't signed at all — SmartScreen warns. Both issues
   are Stage 7.
4. **Record the bundle size per platform in the README.** It's the honest
   price of being offline, and the user has the right to see it before
   downloading, not after.
5. Both platforms are distributed only via GitHub Releases (Windows — a
   zip, a Stage 5 decision; we don't publish on Google Play — the author's
   decision, 2026-10-14); macOS (secondary) — a DMG on GitHub Releases, only
   on separate request (the Mac App Store is a separate decision, see
   [python-sidecar.md](python-sidecar.md#about-the-app-store)).

## What's not here

No schedules, no servers, no migrations, no mailing lists — the project has
no backend at all. If a backend section ever shows up in this file, it means
the product has stopped being what it was meant to be, and that's a reason
to re-read [offline-and-privacy.md](offline-and-privacy.md), not to finish
writing the section.

# MarkItDown UI

> An app that turns a file into Markdown entirely on-device — or, given a
> link, a web page, a Wikipedia article, or a YouTube video with subtitles —
> so the result can be copied with one button and pasted into a chat with a
> model or into an editor.

## What this is and why

"Give me this PDF/DOCX/XLSX as Markdown" is an operation people do many
times a day, usually through converter websites — that is, by uploading a
work document to someone else's server. MarkItDown UI does the same thing
on the user's own machine:

1. **Open a file** — with the "Choose file" button, by dragging it onto the
   window (Windows), or via "Share" from another app (Android). Or a
   **link** — with the "Paste link" button (it will fill in the link from
   the clipboard) or by sharing a link from YouTube or a browser (Android).
2. **View the result** — raw Markdown on screen, with warnings alongside if
   something in the file couldn't be carried over (a scan with no text,
   merged table cells, a long PDF, and so on).
3. **Take it away** — "Copy" puts the text on the clipboard, "Save as .md"
   writes a file (UTF-8 without BOM). Nothing is put on the clipboard
   automatically — only on button press, so as not to overwrite whatever was
   already there.

**Several files into one** — choose or drop several at once (or "Add
files" on a result): they're converted into a list, reordered by
dragging, and merged into one Markdown document, each file under its own
heading. Links and audio can go into the list too.

The file type is detected from its content, not its extension: a file from
a messaging app with no extension, or a `.docx` renamed to `.pdf`, still
opens correctly. Text in scans and photos is recognized (OCR), speech in
audio is transcribed; both happen on-device as well.

**Files never leave the device — this is a verifiable property of the
code, not a promise.** The app reaches the internet only in "link" mode,
and only for what the link points to; all networking code lives in a
single module, and CI checks on every commit that there is no network
access outside it and that no networking packages have crept into the
dependencies. Before 0.9 the Android build had no `INTERNET` permission at
all; with "link" mode it now does. Details and honest caveats are in
[docs/offline-and-privacy.md](docs/offline-and-privacy.md).

The foundation is [microsoft/markitdown](https://github.com/microsoft/markitdown):
the decisions about how a document maps onto Markdown come from there. But
markitdown is a Python library and doesn't run on a phone, so there are
**two implementations** here: a homegrown conversion core in Dart (works
everywhere) and real markitdown, bundled together with Python in a
"sidecar" (desktop only). More on this in "How it's built" below.

## Platforms and status

The project proceeds in stages ([plan](docs/implementation-plan.md));
Stages 0–5 are closed, Stage 6 (images, audio, OCR) has shipped, and
**Stage 7 — polish** is in progress. 0.8 added offline speech recognition.
0.9 added "link" mode, 0.10 — merging several files into one `.md`.
Version — `0.10.0`.

| platform | status |
|---|---|
| **Windows** | works — verified on the author's machine (since 0.5); built in CI (GitHub Actions) with the sidecar. Speech recognition in 0.8 — verified in CI, pending manual check |
| **Android** | works, verified on the author's phone (APK). Speech recognition in 0.8 — APK builds in CI, pending manual check on the phone |
| macOS | secondary: the code exists, but Xcode won't install on the author's machine — will be built later on another Mac |
| iOS | deferred: the author's machine cannot produce a build the App Store will accept |
| Linux | deferred: no requests for it so far |

Why that is and what to do about it — [docs/future-development.md](docs/future-development.md).

## What it can convert

| format | Windows | Android | how |
|---|---|---|---|
| `txt`, `md`, `csv`/`tsv`, `json`, `xml`, `html` | ✅ | ✅ | Dart core; text in Windows-1251 without BOM is recognized |
| RSS and Atom feeds (`.rss`, `.atom`, `.xml`) | ✅ | ✅ | Dart core: channel, entries, dates, entry text |
| `docx`, `xlsx`, `pptx` | ✅ | ✅ | Dart core (lists, tables, footnotes, sheets, speaker notes) |
| `epub`, `ipynb`, `zip` (recursive, with zip-bomb protection) | ✅ | ✅ | Dart core |
| `pdf` with text | ✅ with tables (up to 50 pages) | ✅ without tables | sidecar up to 50 pages, beyond that and on Android — Dart core via PDFium |
| scanned `pdf` | ✅ | ✅ | OCR (Tesseract, Russian and English), up to 20 scanned pages |
| `xls` (Excel 95–2003), `msg` (Outlook) | ✅ | ✅ | on Windows — sidecar, falling back to the Dart core on failure and on Android |
| images: JPEG, PNG, BMP, GIF, WebP, TIFF | ✅ | ✅ | EXIF metadata + recognized text (OCR) |
| images: HEIC | ✅ | ✅ | metadata only, no OCR |
| audio: MP3, FLAC, Ogg/Opus, WAV, M4A; video MP4/MOV | ✅ | ✅ | duration, tags, lyrics + **speech transcription** (whisper.cpp, small model: Russian, English, Italian and ~95 other languages; no duration limit) |
| `doc`, `ppt` (legacy Office) | ❌ | ❌ | not supported — markitdown itself can't either |
| **via link:** page, file (PDF, docx, … — handled like a file from disk) | ✅ | ✅ | downloaded, then goes through the same pipeline; relative links on a page are resolved against its address |
| **via link:** Wikipedia article | ✅ | ✅ | article text only, no menus or "edit" buttons |
| **via link:** YouTube video | ✅ | ✅ | title, views, keywords, description, and subtitles (manual ones in the video's language are preferred over automatic ones) |
| Bing search, LLM-generated image captions, Azure | ❌ | ❌ | not implemented by design: fragile parsing of someone else's search results; paid clouds the document would have to be sent to |

There is no file-size limit. Archives have zip-bomb protection: up to 1 GB
of total uncompressed size, up to 2000 files, and up to 8 levels of nesting.
What's decided for each format and where the two implementations are known
to diverge is in [docs/format-coverage.md](docs/format-coverage.md).

## How to run it (for users)

Ready-made builds are on the
**[Releases](https://github.com/tiltozavr2545/mark_it_down_UI/releases/latest)**
page: a zip for Windows and an APK for Android.

### Windows

1. Download `markitdown_ui-X.Y.Z-windows-x64.zip` (≈370 MB, of which 265 MB
   is the speech-recognition model) and unpack it into any folder. Nothing
   needs to be installed, not even Python — it's already inside.
2. Run `markitdown_ui.exe`. Everything needed sits alongside it:
   `pdfium.dll`, the OCR DLLs (`tesseract*.dll`, `leptonica*.dll`) and the
   speech-recognition DLLs (`markitdown_whisper.dll`, `whisper.dll`,
   `ggml*.dll`), the `data\` folder (models live there too), and `sidecar\`
   (Python + markitdown, ≈300 MB unpacked) — don't break up the folder.
3. On first launch SmartScreen will show "Windows protected your PC":
   **"More info" → "Run anyway"**. That's because the build isn't signed
   (there's no certificate yet), not because anything is wrong with it.

The first `xls`/`msg`/`pdf` conversion may take a few seconds — Defender
scans Python on first run. Speech recognition takes minutes on a long
recording: a percentage is shown, and it can be stopped at any time. Works
on any 64-bit processor — AVX2/AVX-512 code paths only turn on if the
processor supports them.

A build from any commit (not just a release) is available as the
`markitdown_ui-windows-x64` artifact in
[Actions](https://github.com/tiltozavr2545/mark_it_down_UI/actions/workflows/ci.yml)
(requires a GitHub sign-in).

### Android

1. Download `markitdown_ui-X.Y.Z-android-arm64.apk` to the phone and open
   it; allow installation from this source if Android asks.
2. Requires Android 6.0+ and an arm64 processor (practically any phone from
   recent years). The APK weighs ≈300 MB — almost all of that is the
   speech-recognition model; on the first audio file it's copied to disk
   once (another ≈265 MB of space needed).
3. If the app was already installed from a build that isn't this release,
   uninstall it first — builds are currently signed with different debug
   keys and can't be installed over one another (there's no proper signing
   key yet — that's Stage 7).

To build the APK yourself, see "Development" below.

## Development

### What you need

- **Flutter 3.32.8** — exactly this version (newer requires macOS 14+, and
  the author's machine runs macOS 12; pinned in CI as well). Check with:
  `flutter --version`.
- `make`, `bash`, `curl` — available out of the box on macOS and Linux.
- For Android — the Android SDK (installed with Android Studio); to run it,
  a phone with USB debugging enabled.
- You **don't need** to install Python: the sidecar downloads its own, the
  system one isn't used.
- `cmake` and a C/C++ compiler — only to build OCR and speech recognition
  for tests on the computer (`make tesseract`, `make whisper`); without
  them those tests are skipped. For the Android speech-recognition build —
  NDK 27.0.12077973 (installed from Android Studio).
- No `.env` files, keys, or accounts: the app has nowhere to send data, and
  it has no secrets. Keys are only needed to sign releases —
  [docs/operations.md](docs/operations.md).

### First run

```bash
git clone https://github.com/tiltozavr2545/mark_it_down_UI.git
cd mark_it_down_UI
make verify
```

`make verify` runs the same thing CI does: `pub get`, a formatting check,
`flutter analyze`, and the tests for both the app and the core. Along the
way it downloads the PDFium library (`pdfium/fetch.sh`, ≈4 MB) and the OCR
models (`tesseract/fetch.sh`) — these aren't committed to the repository.
OCR and speech-recognition tests are skipped without `make tesseract` /
`make whisper` (see below). A green `make verify` means the environment is
set up correctly.

### Running and building

```bash
# Android: phone connected over USB
cd app && flutter run                      # debug run
cd app && flutter build apk --release      # APK (first run make fetch-pdfium
                                           # fetch-tesseract; speech
                                           # recognition — see below)

# macOS (secondary, needs full Xcode)
cd app && flutter run -d macos
```

**Windows can't be built locally** — Flutter only builds a Windows app on
Windows, while development happens on a Mac. So the Windows build and tests
run in CI on every push: the `windows` job runs the checks plus
`flutter build windows`, and the `windows-sidecar` job builds the Python
sidecar and cross-checks it against the Dart core. The result is the
`markitdown_ui-windows-x64` artifact (see "How to run it"). On a Windows
machine it can also be built by hand, in Git Bash: `./pdfium/fetch.sh`,
`./tesseract/build.sh && ./tesseract/fetch.sh`, `./whisper/build.sh &&
./whisper/fetch.sh` (without the OCR and speech-recognition DLLs, CMake
will stop with a clear error), then `cd app && flutter build windows
--release`; it needs Visual Studio 2022 — Flutter 3.32.8 doesn't know about
2026.

The Android emulator doesn't run on the author's machine (too weak) —
everything is verified on a real phone.

### OCR and speech recognition

```bash
make tesseract                 # Tesseract for OCR tests, ≈10 minutes
make whisper                   # whisper.cpp + models (265 MB), ≈10 minutes
./whisper/build.sh --android   # speech-recognition .so into jniLibs (NDK)
```

Without these, the app still builds, but OCR and speech recognition in it
are honestly reported as "unavailable," and the tests for them are
skipped. How this is built and why —
[docs/format-coverage.md](docs/format-coverage.md#transcription-decisions-08).

### Sidecar (real markitdown, desktop only)

```bash
make sidecar            # → sidecar/dist/<host>/, downloads ~hundreds of MB
make compare-sidecar    # cross-checks the Dart core against markitdown on all fixtures
```

Without the sidecar built, the app runs on the Dart core alone — everything
except `xls` and `msg`. It's not part of `make verify` precisely because
it's heavy. The versions of all Python dependencies are pinned by lock
files `sidecar/locks/<host>.txt` (sha256 of each package); updating them is
a deliberate act, via `make sidecar-lock`. How it's built, the protocol, and
the sizes — [docs/python-sidecar.md](docs/python-sidecar.md).

### Rules for working in this repository

Briefly (in full — in [AGENTS.md](AGENTS.md)):

- before committing — `make verify`; every PR bumps the version in
  `app/pubspec.yaml` (CI checks this);
- release — tag `vX.Y.Z` on main, after which `release.yml` builds and
  publishes everything ([docs/operations.md](docs/operations.md#release));
- `core/` does not import Flutter — in any file (checked by CI);
- a new format = a converter + a pair of "source + expected Markdown"
  fixtures in `core/test/fixtures/`, and the fixtures need to be "evil":
  an empty file, a file with no extension, a zip inside a zip,
  Windows-1251;
- Markdown is only ever assembled through
  `core/lib/src/markdown_writer.dart`;
- no networking dependencies at all — CI will fail on its own if there are.

## How it's built

```
file ─► type detection ─► converter registry ─► Markdown + warnings
        (by magic bytes,   (by priority: sidecar
         not extension)     first, then Dart core,
                             then generic text ones)
```

- **`core/`** — the conversion core: a plain Dart package without Flutter.
  Thanks to that, tests run fast (`dart test`), and conversion runs in a
  separate isolate so it doesn't freeze the window. Each format is a
  separate converter in the registry. Native functionality goes through
  `dart:ffi`, not plugins: PDF is read by PDFium, text in scans and photos
  by Tesseract, speech by whisper.cpp (the Whisper small model is bundled
  with the app; 16 kHz audio is decoded by its own shim layer
  `whisper/shim/`, AAC by the system decoder).
- **`app/`** — the Flutter app: file intake, the result screen, the
  clipboard (`super_clipboard` puts both `text/plain` and `text/markdown`
  at once); long-running speech recognition gets a percentage and a "Stop"
  button.
- **Sidecar** — on desktop, one more converter is added to the registry: a
  subprocess with a bundled Python and real markitdown. It goes first
  wherever it beats the Dart core: `xls`/`msg` (only it can handle these)
  and PDFs up to 50 pages (it can handle tables). If it crashes, hangs, or
  returns garbage, the Dart core supplies the result instead, and this is
  visible in the warnings. The sidecar can also handle
  `docx`/`xlsx`/`pptx`, but the app never routes to it there: the Dart core
  is no worse, and dozens of times faster.
- **Errors** — the user sees one of three clear cases ("format not
  supported," "file is corrupted," "limit exceeded"), never raw exception
  text. A partial result is better than a failure: a PDF where half the
  pages are scans still returns the text from the rest.

Details — [docs/conversion-pipeline.md](docs/conversion-pipeline.md) and
[docs/client-architecture.md](docs/client-architecture.md).

## Repository layout

```
app/                      Flutter app
  lib/src/home_screen.dart      screen: file selection, preview, copy
  lib/src/file_intake/          dialog, drag & drop, "Share" (Android)
  lib/src/merge/                the merge list: several files into one .md
  lib/src/conversion/           runs conversion in an isolate, OCR and
                                speech-recognition models
  lib/l10n/                     UI strings (ru, en)
  android/ windows/ macos/      platform-specific parts
core/                     conversion core — a Dart package without Flutter
  lib/src/type_detection/       content-based type detection
  lib/src/conversion/           registry, contracts, format converters,
                                FFI bindings for PDFium, Tesseract (ocr/),
                                and whisper (speech/), SidecarConverter
  lib/src/markdown_writer.dart  the only place Markdown is assembled
  test/fixtures/                "source + expected Markdown" pairs
  tool/compare_sidecar.dart     cross-checks the Dart core against markitdown
sidecar/                  Python + markitdown build for the desktop
  build.sh lock.sh common.sh    build, lock files, versions
  run.py                        wrapper: file → JSON with Markdown
  locks/                        pinned dependencies per platform
pdfium/fetch.sh           downloads PDFium (host, Android, Windows); not committed
tesseract/                OCR: build.sh (desktop), fetch.sh (models, Android)
whisper/                  speech recognition: build.sh (host and --android),
                          fetch.sh (models), shim/ — the mdw.h C shim layer
tool/verify_version.sh    checks the version bump in a PR
.github/workflows/        ci.yml — verify (Linux), windows-sidecar, windows;
                          release.yml — tag v* → GitHub Release (zip + APK)
docs/                     documentation (below)
```

## Documentation

- [Pipeline: file → Markdown](docs/conversion-pipeline.md) — the main
  document: type detection, the registry, the result contract, Markdown
  rules
- [Format coverage](docs/format-coverage.md) — what markitdown can do, what
  we cover, on which platform; cross-check of the two implementations
- [Client architecture](docs/client-architecture.md) — isolates, file
  inputs, clipboard, large files
- [Python sidecar](docs/python-sidecar.md) — packaging, protocol, Windows
  and macOS
- [Offline and privacy](docs/offline-and-privacy.md) — what's baked into
  the build and how to verify it
- [Operations](docs/operations.md) — build, signing, CI, release
- [Deferred work and open questions](docs/future-development.md)
- [Changelog](CHANGELOG.md) — what appeared in which version
- [AGENTS.md](AGENTS.md) — environment constraints, conventions, and
  gotchas (for the developer and the AI agent)

Historical — how the project was originally conceived:
[brief](docs/project-brief.md) and [stage-by-stage plan](docs/implementation-plan.md)
(a living document, until all stages are closed).

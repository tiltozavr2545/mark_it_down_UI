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

1. **Open files** — with the "Choose files" button, by dragging them onto the
   window (Windows and macOS), or via "Share" from another app (Android). Or a
   **link** — with the "Paste a link" button (it will fill in the link from
   the clipboard) or by sharing a link from YouTube or a browser (Android).
2. **View the result** — raw Markdown on screen, with warnings alongside if
   something in the file couldn't be carried over (for example, unreadable
   text on a scan or merged spreadsheet cells represented as HTML).
3. **Take it away** — "Copy" puts the text on the clipboard, "Save as .md"
   writes a file (UTF-8 without BOM). Nothing is put on the clipboard
   automatically — only on button press, so as not to overwrite whatever was
   already there.

**Convert several files at once.** Select multiple files, or use **Add
files** from a preview. The queue shows each conversion's status and
lets you open each ready result. It also accepts pasted links.

- **Separate files** is the default. After the queue finishes, use
  **Save to folder** to write one `.md` per successful conversion.
  Duplicate filenames get a numeric suffix, so existing files are kept.
- **One document** combines the same results in the order you set by
  dragging. Each source gets its own heading. Switch modes using the
  results already in the queue.

The workspace follows the system's light or dark theme. A wide window
shows the queue and output controls side by side. On a phone, the
controls sit below the queue.

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
0.9 added link conversion, 0.10 added merging, and 0.10.1 added PDF
tables to the Dart converter. The current source version is `0.11.0+15`.
The redesigned workspace and batch export are documented in the
[unreleased 0.11.0 notes](CHANGELOG.md#0110--new-workspace-and-batch-export).

| platform | status |
|---|---|
| **Windows** | works — verified on the author's machine (since 0.5); built in CI (GitHub Actions) with the sidecar. Speech recognition in 0.8 — verified in CI, pending manual check |
| **Android** | works, verified on the author's phone (APK). Speech recognition in 0.8 — APK builds in CI, pending manual check on the phone |
| **macOS** | Intel and Apple Silicon DMGs target macOS 12 Monterey and later. Both packages are built and checked in CI. Manual launch checks are pending. |
| iOS | deferred: the author's machine cannot produce a build the App Store will accept |
| Linux | deferred: no requests for it so far |

Why that is and what to do about it — [docs/future-development.md](docs/future-development.md).

## What it can convert

The Windows, Android and macOS apps use the same conversion pipeline.
Platform-specific behavior is listed below.

| Format | Output |
|---|---|
| `txt`, `md`, `csv`/`tsv`, `json`, `xml`, `html` | Markdown, including text in Windows-1251 without a BOM |
| RSS and Atom feeds (`.rss`, `.atom`, `.xml`) | Channel, entries, dates and entry text |
| `docx`, `xlsx`, `pptx` | Lists, tables, footnotes, sheets and speaker notes |
| `epub`, `ipynb`, `zip` | Books, notebooks and archive contents, including nested archives |
| PDF with text | Text and tables via PDFium |
| Scanned PDF | Russian and English OCR on up to 20 scanned pages |
| `xls` (Excel 95–2003), `msg` (Outlook) | Windows and macOS try bundled MarkItDown first and fall back to Dart. Android uses Dart directly. |
| JPEG, PNG, BMP, GIF, WebP, TIFF | Image metadata and recognized text |
| HEIC | Image metadata |
| MP3, FLAC, Ogg/Opus, WAV | Metadata and offline speech transcription in Russian, English, Italian and other languages, without a configured duration limit |
| M4A, MP4 and MOV | Metadata on all three platforms. AAC transcription uses system decoders on Windows and Android. |
| Link to a page or a file | A page or file converted by the same pipeline, with relative links resolved against the page address |
| Wikipedia link | Article text with navigation removed |
| YouTube link | Title, views, keywords, description and available subtitles, with manual subtitles preferred in the same language |

Legacy Word `.doc` and PowerPoint `.ppt`, Bing search, LLM image captions
and Azure conversion are outside the supported formats.

Local files have no configured size limit. Link downloads are capped at
1 GiB. Archives have limits of 1 GiB total uncompressed size, 2000 files
and 8 levels of nesting.
What's decided for each format and where the two implementations are known
to diverge is in [docs/format-coverage.md](docs/format-coverage.md).

## How to run it (for users)

Ready-made builds are on the
**[Releases](https://github.com/tiltozavr2545/mark_it_down_UI/releases/latest)**
page: a ZIP for Windows, an APK for Android and two DMGs for macOS.

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

The first `xls` or `msg` conversion may take a few seconds while Defender
scans Python. Speech recognition takes minutes on a long
recording: a percentage is shown, and it can be stopped at any time. Works
on any 64-bit processor — AVX2/AVX-512 code paths only turn on if the
processor supports them.

A build from a completed CI run is available as the
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
3. An in-place update requires the same signing key. The current workflow
   uses debug keys, so a signature mismatch requires uninstalling the
   previous build before installing the new one.

To build the APK yourself, see "Development" below.

### macOS

1. Download `markitdown_ui-X.Y.Z-macos-x64.dmg` for an Intel Mac or
   `markitdown_ui-X.Y.Z-macos-arm64.dmg` for a Mac with an Apple M chip.
   Both builds target macOS 12 Monterey and later.
2. Open the DMG and drag **MarkItDown UI** into **Applications**.
3. If macOS blocks the first launch, use **Open Anyway** in **Privacy &
   Security**. On Monterey, the button is under **System Preferences →
   Security & Privacy → General**. [Apple's guide](https://support.apple.com/en-us/102445)

PDFium, OCR, the speech models and Python are included. Speech
transcription on macOS supports MP3, FLAC, Ogg and WAV. AAC audio in M4A
and MP4 returns metadata only.

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

### First run on Linux or an Intel Mac

```bash
git clone https://github.com/tiltozavr2545/mark_it_down_UI.git
cd mark_it_down_UI
make verify
```

`make verify` runs dependency resolution, formatting, static analysis
and tests for the app and core. It fetches the pinned PDFium libraries,
OCR models and Android OCR libraries into local build directories.
OCR and speech-recognition tests are skipped without `make tesseract` /
`make whisper` (see below). A green `make verify` means the environment is
set up correctly.

On Apple Silicon, use the [macOS test commands](docs/operations.md#local-macos-tests).
For Windows, see the [Git Bash build recipe](docs/operations.md#windows).

### Running and building

```bash
# From the repository root
make fetch-pdfium fetch-tesseract
./whisper/build.sh --android
./whisper/fetch.sh
(cd app && flutter build apk --release --target-platform android-arm64)
```

For Android development, connect a physical phone over USB and run
`flutter run` from `app/`.

Windows builds run on the `windows-2022` CI runner. The `windows-sidecar`
job builds the Python bundle and compares its output with Dart. See
[Operations](docs/operations.md#windows) for the full Git Bash recipe,
including Visual Studio 2022 and native libraries.

The [macOS build instructions](docs/operations.md#macos) cover the Intel
and Apple Silicon runners and local packaging on a Mac with full Xcode.

### OCR and speech recognition

```bash
make tesseract                 # Tesseract for OCR tests, ≈10 minutes
make whisper                   # whisper.cpp + models (265 MB), ≈10 minutes
./whisper/build.sh --android   # speech-recognition .so into jniLibs (NDK)
```

The host builds enable OCR and speech tests. Android also needs the
native libraries and model assets for those features. The Windows ZIP
and macOS DMGs bundle the host libraries and models. See
[docs/format-coverage.md](docs/format-coverage.md#transcription-decisions-08).

### Sidecar (real markitdown, desktop only)

```bash
make sidecar            # → sidecar/dist/<host>/, downloads ~hundreds of MB
make compare-sidecar    # cross-checks the Dart core against markitdown on all fixtures
```

Dart handles `xls` and `msg` when the sidecar is absent. The sidecar
build is separate from `make verify`. Its Python dependencies are pinned
with SHA-256 hashes in `sidecar/locks/<host>.txt`. See
[Python sidecar](docs/python-sidecar.md#lock-file-reproducibility) for the
platform-specific lock and verification commands.

### Rules for working in this repository

Briefly (in full — in [AGENTS.md](AGENTS.md)):

- before committing — `make verify`; every PR bumps the version in
  `app/pubspec.yaml` (CI checks this);
- release — use the [GitHub release skill](.agents/skills/github-release/SKILL.md)
  to tag the approved commit on `main`. The same CI builds and verifies
  all four packages before [publishing](docs/operations.md#release);
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
        (signature first) (specific converter first, generic text last;
                           desktop sidecar preferred for xls/msg)
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
  wherever it beats the Dart core: `xls`/`msg`. If it crashes, hangs, or
  returns garbage, the Dart core supplies the result instead, and this is
  visible in the warnings. The sidecar can also handle
  `pdf`/`docx`/`xlsx`/`pptx`, but the app never routes to it there: the Dart core
  is no worse, and dozens of times faster.
- **Errors** — unsupported format, damaged file, exceeded limit and
  download failure each have their own message. A PDF can return text
  from readable pages together with warnings about the other pages.

Details — [docs/conversion-pipeline.md](docs/conversion-pipeline.md) and
[docs/client-architecture.md](docs/client-architecture.md).

## Repository layout

```
app/                      Flutter app
  lib/src/home_screen.dart      intake, queue, Markdown preview
  lib/src/workspace.dart        layout, intake panel, output controls
  lib/src/markdown_export.dart  filenames and batch saving
  lib/src/file_intake/          dialog, drag & drop, "Share" (Android)
  lib/src/merge/                sequential conversion queue and merging
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
tool/package_macos.sh     adds native dependencies and packages the macOS DMG
.github/workflows/        ci.yml — checks, platform builds and tag releases
.agents/skills/           repository release skill for Codex
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

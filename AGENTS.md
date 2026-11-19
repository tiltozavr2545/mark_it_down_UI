# AGENTS.md

Context for an AI agent working in this repository — shared by any tool
(Codex, Claude Code, etc.).

This file contains only what isn't in the code: environment constraints,
working conventions, and gotchas. Everything else lives where it should be
read:

| what | where |
|---|---|
| what the project is, the stack, the layout, how to run it | [README.md](README.md) |
| version history | [CHANGELOG.md](CHANGELOG.md) |
| **the conversion pipeline** — types, registry, contracts, Markdown rules | [docs/conversion-pipeline.md](docs/conversion-pipeline.md) |
| what's decided for each format and what covers it | [docs/format-coverage.md](docs/format-coverage.md) |
| how the Flutter app is built, default decisions | [docs/client-architecture.md](docs/client-architecture.md) |
| the Python sidecar: packaging, protocol, signing | [docs/python-sidecar.md](docs/python-sidecar.md) |
| what "offline" means and how to verify it | [docs/offline-and-privacy.md](docs/offline-and-privacy.md) |
| build, signing, release, CI checks | [docs/operations.md](docs/operations.md) |
| deferred work, open questions | [docs/future-development.md](docs/future-development.md) |
| **why** a decision was made the way it was | the comment next to the code, then `git log` |
| historical: the original concept and stage plan | [docs/project-brief.md](docs/project-brief.md), [docs/implementation-plan.md](docs/implementation-plan.md) |

## The project

MarkItDown UI converts local files to Markdown on Windows, Android and macOS.
The Dart core handles file conversion, including PDF tables and the
fallback for legacy Excel and Outlook files. Windows and macOS builds bundle a
Python sidecar for `xls` and `msg`. OCR and speech recognition run on
device with Tesseract and whisper.cpp.

The project ships through GitHub Releases as a Windows ZIP, an Android APK
and macOS DMGs for Intel and Apple Silicon. See [the README](README.md) for
current features and [the implementation plan](docs/implementation-plan.md)
for stage history.

## Environment constraints

- **The main constraint is product-driven, not technical: files never
  leave the device, and the network is reached only via an explicit
  link.** Since 0.9 (author's decision from 2026-10-15) there is a "link"
  mode: download the page/file/YouTube video that a pasted or shared link
  points to. All networking code lives in `core/lib/src/web/` (checked by
  CI). Any proposal that would need the network beyond that — analytics,
  crash reporting, update checks, downloading an ML model on demand, cloud
  OCR, LLM-generated captions (the last of which the author explicitly
  rejected) — conflicts with the product; see
  [docs/offline-and-privacy.md](docs/offline-and-privacy.md). Don't propose
  it; if it seems unavoidable, that's a reason to discuss it, not to work
  around it.
- **Windows and Android are the primary targets.** Development happens on an
  Intel MacBook Pro (macOS 12.7.6), and Flutter only builds a Windows app
  on Windows, so Windows is built and tested in CI on `windows-2022`
  ([Stage 5](docs/implementation-plan.md#stage-5--windows-05)). Manual
  verification ("dropped a file — saw the result") happens on the
  **author's own Windows machine**, using the CI artifact; it's fine and
  worth suggesting. Android is verified via APK on the author's phone.
  Linux is deferred.
- **There is no second pair of eyes reviewing the code** — that's why
  checks are pushed into CI rather than relying on agreements between
  people.
- **The Flutter version is pinned at 3.32.8.** This constraint carried
  over from Amicus (same machine): a newer version requires macOS 14+, and
  the Intel machine physically cannot run a newer macOS — this is a dead
  end, don't suggest upgrading. The number was verified at Stage 0
  (`flutter --version`) and still matches.
- **macOS release builds are configured in GitHub Actions** on Intel and
  Apple Silicon runners. Both DMGs target macOS 12 Monterey and use
  ad-hoc signing. The author's Mac can test the Intel artifact and has
  Command Line Tools 14.2. `flutter build macos` needs full Xcode. See
  [docs/operations.md](docs/operations.md#macos).
- **iOS is blocked by the machine, not by priorities.** macOS 12 can only
  install up to Xcode 14.2, and App Store Connect rejects a binary built
  with that SDK (`ITMS-90111`) — it bakes in the build machine's host OS
  version, not just the Xcode version. This is exactly the snag that led
  to setting up Xcode Cloud for Amicus (building on a stable Apple image
  independent of the local macOS). There's no such workaround here yet, so
  iOS isn't "the next step after Android" — it's a deferred platform.
  Running on the simulator and building locally still work; submitting
  does not.
- **OCR is Tesseract via FFI only, no network and no plugins.** Don't
  suggest ML Kit: it has no Cyrillic support. Don't use prebuilt desktop
  Tesseract builds (vcpkg, UB Mannheim): they bundle libcurl.
  `make tesseract` builds it locally (~10 minutes, needs cmake); without
  it, OCR tests are skipped, and `make verify` still passes.
- **Speech recognition is whisper.cpp via FFI only, with the model in the
  bundle.** Don't suggest faster-whisper (Python is desktop-only), nor
  downloading the model on demand (the network is only used for the
  user's own links, not for internal downloads). `make whisper` takes
  ≈10 minutes to build and 265 MB of models, and isn't part of
  `make verify`; without it, `speech_test.dart` is skipped.
- **Python is needed only for the sidecar, and only on desktop** (Stage 4;
  on Windows — Stage 5).
  The system Python isn't used — a relocatable one from
  python-build-standalone is used instead, see
  [docs/python-sidecar.md](docs/python-sidecar.md). There's no Python on
  mobile and there won't be: native wheels for `lxml`/`pandas`/`pillow`
  don't exist for mobile ABIs, and that's not something to work around.

## Working conventions

- **Write all repo-facing text in English**: commit messages, docs,
  code comments/docstrings, GitHub release bodies, and the repo
  description. Exception: anything genuinely user-facing that the app
  itself produces — error/warning strings, Markdown-output field labels
  — stays as-is, since changing it would alter behavior, not just
  internal language. `app/lib/l10n/app_ru.arb` is a real localization
  resource, not a comment — never touch it for this.
- **Run `make verify` before submitting anything**: `pub get`,
  `dart format --set-exit-if-changed`, `flutter analyze`, `flutter test`
  for `app/`, and `dart test` for `core/`. CI runs the same thing.
- **`core/` does not import `flutter/` in any file.** This is checked in
  CI and is not up for debate: fast tests, running inside an isolate, and
  the ability to build a CLI all depend on it. If you need something from
  Flutter, the code is in the wrong package.
- **The "network only via link" check has been in CI since the first
  commit, not once dependencies grew to thirty.** Failing steps: a
  networking package showing up in `dart pub deps`, an `HttpClient`/socket
  outside `core/lib/src/web/`, a networking permission beyond `INTERNET`
  in the built APK; the commands are in
  [docs/operations.md](docs/operations.md). A networking dependency can
  arrive transitively and silently, so it has to be caught automatically.
  A new place that touches the network means editing the CI step and
  getting the author's decision, not slipping it in along the way.
- **A new format = a new converter in the registry + fixtures.** A
  "source + expected Markdown" pair in `core/test/fixtures/` is mandatory:
  the project has **two implementations** (the Dart core and the
  sidecar), and the only way to notice them diverging is to run both
  against the same set. Discrepancies in shared formats are fixed or
  recorded in
  [docs/format-coverage.md](docs/format-coverage.md).
- **Fixtures need to be evil, not pretty.** A zip inside a zip, a `.docx`
  named `.pdf`, text in Windows-1251 without a BOM, an `xlsx` with merged
  cells, a PDF made of scans, a zero-length file, a file with no
  extension. Each such case is a piece of behavior someone chose on
  purpose; without a fixture it gets chosen at random.
- **Markdown is only ever assembled through `markdown_writer`.** Escaping,
  tables, headings — one module for every converter. This is personal: in
  Amicus, the visibility rule got duplicated across four copies, two of
  which fell out of sync and became holes. The same mistake here would
  produce converters that escape the same character differently.
- **`make sidecar` and `make compare-sidecar` are not part of
  `make verify`**: they download hundreds of MB and are only needed by
  someone touching the sidecar or the `pdf`/`docx`/`xlsx`/`pptx`
  converters. The sidecar's dependency versions are pinned by
  `sidecar/locks/<host>.txt`; update them deliberately
  (`make sidecar-lock`), not in passing.
- **The version is bumped in every PR**: `make verify-version
  BASE_REF=origin/main`, format `name+build`.
- **Localization:** strings live in `app/lib/l10n/app_{en,ru}.arb`,
  generated via `flutter gen-l10n`, and the generated files are committed.
  Edit the ARB files **as text** — rewriting them through `json.dump`
  swallows the blank lines that split the file into logical groups.
- **`CLAUDE.md` is a thin wrapper around this file.** Shared conventions
  and gotchas live only here — don't duplicate them.

## Gotchas

Some carried over from Amicus (same tools, same spots), some are known
properties of the formats. The list grows as work continues.

- **A file's extension can't be trusted.** A file from a messaging app is
  named `document` with no extension, a `.docx` arrives named `.pdf`, and
  on Android the system-supplied MIME type is
  `application/octet-stream`. Type is determined by magic bytes; the
  extension is only a hint when things are ambiguous.
- **`PK\x03\x04` doesn't mean "archive."** `docx`, `xlsx`, `pptx`, `epub`,
  `apk`, and a plain zip are all zip files. Distinguish by content
  (`[Content_Types].xml`, `mimetype` as the first file), otherwise a
  `docx` ends up going to the archive converter.
- **Generic converters must be asked last.** `html` and `plain text` will
  grab anything text-like, including the XML inside a `docx`. Hence the
  numeric priorities in the registry: 0.0 for a specific format, 10.0 for
  a generic one.
- **Text with no BOM that doesn't parse as UTF-8 isn't a corrupted
  file** — it's almost certainly Windows-1251. This is routine for
  Russian-language exports.
- **Platform plugins don't work from an isolate** — without
  `BackgroundIsolateBinaryMessenger` from `Isolate.run`, a plugin can't
  make its call. That's why OCR and speech recognition are FFI calls into
  their own native libraries (Tesseract, whisper.cpp), rather than
  plugins: FFI works fine inside an isolate.
- **`Isolate.run` can't be cancelled.** Long-running formats will need a
  long-lived isolate with a port; `ConversionLimits` should be designed so
  cancellation can be fitted in later. Speech recognition works around
  this with shared native memory (`TranscriptionControl`: a cancel flag
  and progress), which the native code checks itself — it should only be
  freed after the isolate ends.
- **`Clipboard.setData` only supports `text/plain`.** To also put
  `text/markdown` on the clipboard, you need `super_clipboard`.
- **Auto-copying the result is a mistake.** It looks convenient right up
  until the first time it overwrites whatever someone was already
  carrying on the clipboard. Copy only on button press.
- **Check an archive's uncompressed size as you go, not from the
  header.** The zip header can't be trusted — that's the whole point of
  the zip-bomb defense.
- **Merged cells can't be expressed in a Markdown table.** Emit that
  sheet as an HTML block and note it in `warnings`; silently breaking the
  grid is worse.
- **Base64 images in the output aren't needed.** Tens of thousands of
  tokens of noise in the prompt for something the model wouldn't see
  anyway. Images become `![alt](filename)` placeholders.
- **A scanned PDF contains no text at all.** Any engine will return
  nothing; that's not a bug or a conversion error, it's a warning in
  `warnings`.
- **A partial result is more useful than a failure.** A PDF where half
  the pages are scans should still return the text from the rest.
  Failing outright is only right when there's nothing to return at all.
- **Raw exception text is never shown to the user.** In Amicus this was
  fixed with a separate bugfix after release; here it's built in from the
  start — three clear cases, see
  [docs/conversion-pipeline.md](docs/conversion-pipeline.md#errors).
- **Delete temp files in a `finally`, not "at the end."** The error path
  is the main way a user's document ends up left behind in `/tmp`.
- **`dart test` in `core/` won't find `libpdfium` without
  `MARKITDOWN_PDFIUM_PATH`.** `make test`/`make verify` download the
  library themselves (`pdfium/fetch.sh`) and set the variable; when
  running `dart test` manually in `core/`, don't forget to do the same,
  or the PDF fixtures fail with "symbol not found" instead of a clear
  reason.
- **For PDFium, a character's "top" (`FPDFText_GetCharBox`) is the top of
  the glyph's bounding box, not the baseline.** Lines starting with a
  letter with no ascender (`c`, `e`, `o`) versus one with an ascender
  (`T`, `l`) produce a "top" that differs by 1–2pt for the same line
  spacing — handled with a margin of error in `pdf_converter.dart`, but
  that's not a bug if the numbers on a new fixture don't match exactly
  again.
- **Cross-checking against the sidecar is `make compare-sidecar`, not
  part of `make verify`.** It needs `make sidecar` built; the report lands
  in `core/build/sidecar-compare/`. Any new fixture for
  `pdf`/`docx`/`xlsx`/`pptx` must pass this comparison — a discrepancy
  gets fixed or recorded in
  [docs/format-coverage.md](docs/format-coverage.md#reconciliation-with-the-reference-stage-4).
  Integration tests with the real sidecar
  (`core/test/sidecar_integration_test.dart`) are skipped without
  `MARKITDOWN_SIDECAR_DIR`; run manually with that plus
  `MARKITDOWN_PDFIUM_PATH`.
- **"Hand-written" fixtures aren't the same as "valid."** A hand-written
  `pptx` with no `<p:spPr>`, and a package with absolute `Target` values
  in `.rels` (which is how openpyxl writes them), are only caught by the
  reference library. Source files that can't be hand-written (`xls`,
  `msg`, a valid `pptx`, an `xlsx` with types, a PDF with a table) are
  generated by `sidecar/samples/make_samples.py`.
- **The macOS sidecar is only signed after `build.sh` has fully
  finished** — after `compileall` and all cleanup: any edit to a file
  after signing breaks the signature.
- **The sidecar runtime runs with `-B`.** Writing `.pyc` files into a
  signed bundle breaks the signature; bytecode is compiled ahead of time
  instead.
- **Without `cs.disable-library-validation`, ad-hoc signing makes
  `import numpy` fail** ("mapped file has no Team ID"). This is the only
  entitlement in `sidecar/sidecar.entitlements`; there are no networking
  ones and there shouldn't be (checked by CI).
- **The sidecar is tens to hundreds of times slower than Dart on large
  files** (a 300-page PDF: 112s versus 1.2s). That's why in the app it
  only goes first for `xls`/`msg` — an author's decision (Stage 5, item 5;
  PDF taken out in 0.10.1). Expanding `appFormats` is again the author's
  decision, not something to slip in.
- **The Windows build can't be verified locally.** Anything touching
  `app/windows/`, `pdfium.dll`, or the steps of the `windows` job can only
  be verified by pushing to CI; the Makefile and the `windows` job are two
  lists of the same checks — keep them in sync.
- **In `sidecar/build.sh`, interpreter cleanup on Windows has its own
  branch.** NTFS is case-insensitive: `python/lib/` collides with
  `python/Lib/` there, and the Unix-style `rm -rf
  python/lib/{…,thread*}` would wipe out `threading.py`.
- **The sidecar's Python build scripts use `-X utf8`.** Under `-I`, the
  `PYTHONUTF8`/`PYTHONIOENCODING` variables are ignored, and stdout piped
  on Windows is cp1252: any `print` containing Cyrillic will crash.
- **`| head` in a CI step under `pipefail` yields exit code 141** (SIGPIPE
  for whoever is writing into the pipe). In `ci.yml`, use
  `awk 'NR <= N'` instead.
- **`ftyp` at the start of a file doesn't mean HEIC.** The same ISO BMFF
  container is also used by MP4, M4A, and MOV from a phone; HEIC is only
  distinguished by its brand (`heic`, `mif1`, `avif`…). Detect by brand,
  or video and voice messages will turn into "images" — this matters
  especially for audio metadata (Stage 6, item 3).
- **Offsets inside EXIF can't be trusted**, just like a zip header: an
  IFD can point at itself or past the end of the block. That's why parsing
  is homegrown, tracking visited IFDs and checking every length — the
  `exif` package gets stuck in a loop on such files. An image with a
  recognized signature never gets refused outright: the format and size
  are still returned even with broken EXIF.
- **`FPDFBitmap_BGRx` = 3, not 2.** 2 is `FPDFBitmap_BGR`, 3 bytes per
  pixel; Tesseract, told "4 bytes," reads such a bitmap past the end of
  the buffer — doubled text or a process segfault, not an exception.
  Check the constants in `fpdfview.h`, don't rely on memory.
- **OCR output in tests is compared by phrase, not byte-for-byte**
  (`ocr_test.dart`): it depends on the Tesseract version, and on Linux CI
  that comes from Ubuntu's packages. The general fixture set is run
  **without** OCR, so its reference outputs don't depend on the engine.
- **`tesseract/build.sh` under bash 3.2 (macOS):** an empty array under
  `set -u` is an "unbound variable"; expand it as
  `${arr[@]+"${arr[@]}"}`.
- **A path to a native library on Windows isn't UTF-8.** `fopen` from
  MSVC (which Tesseract uses to read models) expects a path in the
  system's ANSI codepage, while an unpacked zip may sit in
  `C:\Users\<Cyrillic>\Downloads\…`. Hence `_pathForFopen` in
  `tesseract_ocr.dart`: try the 8.3 short name first, then cp1251,
  otherwise OCR is unavailable. PDFium and Leptonica receive bytes from
  memory, so they're unaffected; any new native library that gets handed
  a path is at risk.
- **Tesseract's CMake unconditionally links `Ws2_32` on Windows** (for the
  debug ScrollView). `build.sh` strips it from the CMakeLists and, at the
  end, greps the built libraries for networking symbols — don't remove
  either step.
- **whisper.cpp writes all its libraries to `${CMAKE_BINARY_DIR}/bin`**,
  and its `cmake_minimum_required` predates 3.13: without `CMP0077=NEW`,
  its `option(BUILD_SHARED_LIBS …)` overwrites the value set in our own
  `whisper/shim/CMakeLists.txt`. Both spots are flagged with comments
  there.
- **The ggml CPU backend variants are separate libraries, loaded at
  startup** (`ggml-cpu-haswell.dll`, `libggml-cpu-android_armv8.2_2.so`…).
  Don't "simplify" to a single build targeting AVX2/dotprod: on a
  processor without them, the whole app crashes, not just conversion. On
  Android the `.so` files aren't extracted from the APK — the shim layer
  tries them by bare name (`mdw_init`); the list of names is in `mdw.c` —
  add any new ggml variant there too.
- **On Windows, the speech-recognition DLLs are opened in dependency
  order** (`ggml-base` → `ggml` → `whisper` → `markitdown_whisper`, see
  `loadWhisperLibrary`): LoadLibrary looks for imports next to the
  process's `.exe`, and for `dart test` that's `dart.exe`. Same trick as
  Leptonica.
- **Media Foundation picks a handler by file extension.** It won't open
  audio with no extension or with a mismatched one (`voice message` from
  a messaging app) — the temp file handed to the platform decoder is
  written with an extension based on its signature.
- **`mfplat.dll` isn't present everywhere** — it's missing from Windows
  "N" editions without the Media Feature Pack, and from Windows Server
  without the Media Foundation component. That's why it's loaded
  dynamically (`mdw_platform_windows.cpp`): a static import would bring
  down loading of the entire `markitdown_whisper.dll`, losing all speech
  recognition, not just AAC. On the `windows-2022` runner Media
  Foundation is present — AAC is checked in CI (`speech_test.dart`).
- **The AAC decoder in Media Foundation changes its output format after
  the first frame**
  (`MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED`) — sample rate and channel
  count need to be re-read, and the output type (float versus 16-bit PCM)
  needs to be checked. Without this, M4A on Windows "decoded" into noise
  and the transcription came out empty — caught by CI.
- **`yes | sdkmanager` under `pipefail` is exit code 141**, same as
  `| head`. In `release.yml`, use `(yes || true) | …`.
- **`archive` 4 doesn't throw on a corrupted zip — it returns an empty
  archive.** A corrupted file would silently become a "silently empty
  archive" — that's why all zip reads go through `decodeZip`
  (`zip_family.dart`), which treats such a result as a failure.
- **`package:xml` doesn't bind the `xml:` prefix to its namespace** —
  `getAttribute('base', namespace: …)` on `xml:base` returns `null`. In
  `rss_converter.dart` the attribute is also looked up by its full name.
- **A BIFF8 string split by a `CONTINUE` record mid-character resumes
  from a new flag byte** — and a compressed (Latin-1) string can resume
  as UTF-16. Formatting and phonetic run counters past the characters
  cross the boundary without such a byte. The evil fixture `xls/evil.xls`
  checks this; compare against `xlrd`.
- **`flutter create --platforms=…` rewrites `app/.metadata`** — it drops
  platforms already present from `migration.platforms`. Restore them by
  hand after running it.

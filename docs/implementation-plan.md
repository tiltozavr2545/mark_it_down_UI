# Implementation Plan (0.1 → 1.0)

Step-by-step plan from [project-brief.md](project-brief.md), with CI and builds
built into the stages rather than deferred to the end. Stages proceed in
increasing order of risk: first what's sure to work, and only then what has
open questions.

This document is **living while the plan is open**: status markers get updated
as work proceeds. What landed in which version — see
[../CHANGELOG.md](../CHANGELOG.md); what's decided per format — see
[format-coverage.md](format-coverage.md).

## Progress

- [x] Stage 0 — Scaffolding: project, CI, window, file intake
- [x] Stage 1 — Pipeline + text formats (0.1)
- [x] Stage 2 — Office: docx, xlsx, pptx, epub, zip (0.2)
- [x] Stage 3 — PDF (0.3)
- [x] Stage 4 — Python sidecar on desktop (0.4)
- [x] Stage 5 — Windows (0.5)
- [ ] Stage 6 — Images and audio (0.6) — released in `v0.6.0`: EXIF, OCR, and audio are done; manual verification (item 4) isn't checked off
- [ ] Stage 7 — Polish and release (1.0) — in progress: 0.7 removed the file-size limit
- [ ] Speech recognition (0.8) — outside the original plan, requested by the author: done, manual verification (item 6) isn't checked off

The plan's target platforms are **Windows and Android**. After Stage 4 was
closed, the author said: "what I actually need isn't really the Mac version,
it's Windows and Android." Before that, the plan was written with macOS
first — hence the macOS signing and notarization work in Stages 0–4; it's
done, but it's no longer a priority.

**macOS is a target platform, but a secondary one.** Code for it isn't
removed, and gets built later on a friend's Mac, where Xcode can be
installed; Xcode.app won't install on the author's machine (Intel Mac, macOS
12.7.6, see "Environment limitations" in [../AGENTS.md](../AGENTS.md)).
Investing in macOS specifics — notarization, embedding the sidecar into the
Xcode build — isn't needed without a separate request.

**Windows isn't built here.** Development happens on a Mac, and Flutter only
builds Windows on Windows. So Windows builds and tests run in CI on the
GitHub runner `windows-latest`, while manual verification ("dropped a
file — saw the result") happens on the author's own Windows machine, using
the CI artifact. Android is verified as before: APK and the author's phone,
no emulator is run.

iOS is blocked by the same machine (`ITMS-90111`, see
[future-development.md](future-development.md#ios)); Linux is deferred.
Details on each limitation are in [future-development.md](future-development.md).

---

## Stage 0 — Scaffolding

**Goal:** an empty window that accepts a file and shows its name, size, and
detected type. Stage zero is about infrastructure, not conversion.

1. `flutter create --platforms=macos,android` in `app/`, a separate
   Dart package `core/` (with no dependency on `flutter`), wired into `app/`
   via a local path.
2. CI (GitHub Actions): `dart format --set-exit-if-changed`,
   `flutter analyze`, `flutter test` for `app/`, `dart test` for `core/` —
   on every push and PR.
3. **A "no network" check in CI from day one**: a step that fails if a
   networking package shows up in the dependency tree, or if
   `android.permission.INTERNET` shows up in the Android manifest. Put this
   in place right away, not once there are thirty dependencies — see
   [offline-and-privacy.md](offline-and-privacy.md).
4. A `Makefile` with `make verify` (deps, format, analyze, both test
   suites) — one command before handing off work.
5. File intake: `file_picker` + `desktop_drop` on macOS, `intent-filter` +
   `receive_sharing_intent` on Android. All inputs funnel into a single
   `accept(source)` — see
   [client-architecture.md](client-architecture.md#file-intake-four-inputs-one-entry-point).
6. Type detection: magic bytes + refinement within the zip family + the
   extension as a hint. With tests for "evil" files from the start — a file
   with no extension, a `.docx` named `.pdf`, zero length.

**Done when:** you can drop/open a `.docx` on the window and it says "OOXML
Word, 184 KB" instead of "application/octet-stream". Currently verified on
Android (there's no working Xcode on macOS — see "Environment limitations" in
[../AGENTS.md](../AGENTS.md)); on macOS — the same way, once that's
resolved.

## Stage 1 — Pipeline and Text Formats (0.1)

**Goal:** the first complete end-to-end path — from file to clipboard.

1. `StreamInfo`, `DocumentConverter`, a priority-ordered registry,
   `ConversionResult`/`warnings`, `ConversionLimits` — all per
   [conversion-pipeline.md](conversion-pipeline.md).
2. A `markdown_writer` module: escaping, tables, headings, links.
   **One** for all converters, from the very start — duplicating it in every
   converter isn't allowed; that's the same way the visibility rule in
   Amicus drifted out of sync.
3. Converters: `plain text` (with encoding detection), `csv`/`tsv`, `json`,
   `xml`, `html`. Priority for `html` and `plain text` is 10.0, the rest 0.0.
4. Conversion runs inside `Isolate.run`, with a progress indicator in the
   window.
5. A preview screen: raw Markdown, in a monospace font; a truncated slice for
   large results.
6. Copying via `super_clipboard` as `text/plain` + `text/markdown`, a
   keyboard shortcut, "Save as `.md`" (UTF-8 without BOM, `\n`).
7. An error screen with three clear cases (unsupported / corrupt file /
   limit exceeded), with no raw exception text.
8. Localization for `en`/`ru` from the first screen — adding it later is
   more expensive.
9. `test/fixtures/`: a "source + expected Markdown" pair for each format.

**Done when:** a CSV export turns into a Markdown table and gets pasted into
a chat with one button, on macOS and on the phone.

## Stage 2 — Office (0.2)

**Goal:** the whole reason the product exists. It starts with `docx`,
because it's the most common format, and because the zip+xml scaffolding
built for it gets reused afterward.

1. A shared "OOXML" layer: `archive` → package parts → `xml`. Built on it:
2. **`docx`** — `word/document.xml`: paragraphs, heading styles, lists
   (including nested ones — via `numbering.xml`, otherwise levels get
   lost), tables, bold/italic, links, footnotes. Images become placeholders
   `![alt](name)`, not base64.
3. **`xlsx`** — `sharedStrings.xml` + sheets: each sheet becomes its own
   Markdown table under a heading with its name. Formulas are given as
   their **cached value**, not the formula text. Markdown can't express
   merged cells — such a sheet goes out as an HTML block, with a note added
   to `warnings`.
4. **`pptx`** — slides in order, slide title → `##`, block text, speaker
   notes as a separate block (they're often exactly what's needed).
5. **`epub`** — a `mimetype` check, `content.opf` for chapter ordering,
   then each chapter runs through Stage 1's html converter.
6. **`zip`** — recursion via `recurse` from `ConversionRequest`, with hard
   limits on depth, file count, and total unpacked size.
7. **`ipynb`** — code cells as fenced blocks with a language tag, markdown
   cells as-is, output as text, images as placeholders.
8. A set of "evil" fixtures: zip inside zip, xlsx with merged cells, docx
   with nested lists and a table inside a table.

## Stage 3 — PDF (0.3)

**Goal:** the most common format after Office, and the only one with an
open question about which tool to use.

1. **Choose an engine** — `syncfusion_flutter_pdf` (licensing) versus
   PDFium via FFI (bundle size). Decide by measuring; the reasoning is in
   [format-coverage.md](format-coverage.md#stage-3-decisions). Decided:
   PDFium — `syncfusion_flutter_pdf` fails on an architectural constraint
   (a Flutter package inside `core/`), not just on licensing.
2. Text extraction that preserves reading order; headings based on font
   size when the engine provides it, otherwise as flat text.
3. **Pages with no text layer** (scans) aren't an error: a warning
   "pages 3–7 look like images" goes into `warnings`, and the rest of the
   text is still returned.
4. Tables in PDFs — **not doing this**. That's a separate task on the scale
   of `pdfplumber`, and it's more honest to return plain text than a broken
   grid.
5. Measuring bundle size before and after — it'll go into the README.

## Stage 4 — Python Sidecar (0.4)

**Goal:** close out `.xls`/`.msg`, strengthen PDF, and get a reference
implementation to cross-check against. The whole stage follows
[python-sidecar.md](python-sidecar.md).

**Status: closed, with two deliberately unverified spots** (item 3). What's
done and how it's confirmed — item by item; the timeline is in
[../CHANGELOG.md](../CHANGELOG.md).

**Priorities shifted after the stage closed:** the macOS signing and
notarization work is done, but is no longer a priority — the target
platforms are now Windows and Android (see above and Stage 5). The
remaining unverified macOS spots are kept in
[future-development.md](future-development.md) under "secondary platform".

1. **Sidecar build script** — done. `sidecar/build.sh`:
   python-build-standalone + `markitdown[pdf,docx,xlsx,xls,pptx,outlook]`,
   `run.py`, `manifest.json`; versions are pinned via a lock file with
   sha256 (`make sidecar-lock`). macOS x86_64: 242 MB, cold start ≈1 s.
   Builds only for the host; there are no other lock files yet (see
   [future-development.md](future-development.md)).
2. **`SidecarConverter`** — done. Priority −1.0, a 120 s timeout, exit
   codes, a temp file removed in `finally`; falls back to the Dart
   converter on any failure; only registered on desktop. `xls`/`msg`/
   `doc`/`ppt` detection goes by the Compound File directory.
3. **macOS signing and notarization** — **partially verified.** Done and
   verified: `sidecar/sign.sh`, `sidecar.entitlements` (only
   `disable-library-validation`, no network), an ad-hoc signature with
   Hardened Runtime, the signed sidecar working across all six formats, a
   CI step for "no `network.*`". **Deliberately not verified:** Developer
   ID signing and notarization (no certificate), embedding the sidecar
   into the Xcode build (Xcode won't install — the Build Phase is
   described in [operations.md](operations.md), but not implemented), how
   the sidecar behaves under a real `.app`'s sandbox. The commands are
   recorded in [operations.md](operations.md) and need a first run against
   a real certificate.
4. **The code path without `pandas`** — checked, can't be avoided: it's
   needed for `xlsx`/`xls`, and isn't imported for the other formats.
   Stripping the extra weight brought it down to 242 MB from 355 (see
   [python-sidecar.md](python-sidecar.md)).
5. **Cross-checking the two implementations** — done. `make compare-sidecar`
   (`core/tool/compare_sidecar.dart`) found and fixed four bugs in the
   Dart core; the rest is recorded in
   [format-coverage.md](format-coverage.md#reconciliation-with-the-reference-stage-4).
   Integration tests against a real sidecar are skipped without
   `MARKITDOWN_SIDECAR_DIR`.
6. **Android didn't bloat** — checked. The APK has nothing from the
   sidecar, no `android.permission.INTERNET`; numbers are in
   [format-coverage.md](format-coverage.md#android-didnt-get-fatter-stage-4).

**What surfaced and remains open:** the sidecar is tried first, but on
large files it's two orders of magnitude slower than Dart (a 300-page PDF —
112 s versus 1.2 s). The decision is the author's —
[future-development.md](future-development.md#sidecar-performance-on-large-files).

## Stage 5 — Windows (0.5)

**Goal:** the same app on the second target desktop — Windows, with the
same pipeline and sidecar, built and verified without a single Windows
machine on the developer's side. You can't build the Windows version of
Flutter on a Mac, so "built" here means "built in CI on `windows-latest`",
and "verified" means "run through tests on the runner and poked by hand on
the author's Windows machine, using the artifact from CI". The repository
is [tiltozavr2545/mark_it_down_UI](https://github.com/tiltozavr2545/mark_it_down_UI),
the workflow is `.github/workflows/ci.yml`.

**Status:** the decisions for items 5 and 6 have been made; items 1–4 and
7 are done, CI is green (`verify`, `windows-sidecar`, `windows`); manual
verification (item 8) remains. The runner is `windows-2022`, not
`windows-latest`: the latter now ships VS 2026, which the pinned Flutter
3.32.8 doesn't know about (see the comment in `ci.yml`).

Order of work: first the Dart core on Windows (items 1–3, 7), because it's
verified quickly and doesn't depend on the 240 MB bundle; then the sidecar
(item 4); item 5 is decided by the author **before** item 4, item 6 —
before the first artifact is handed out; item 8 — on every intermediate
artifact, not just at the end.

1. **`flutter create --platforms=windows .` in `app/`.** Specifically with
   `--platforms`, on the existing project: `lib/`, `android/`, and `macos/`
   aren't overwritten, and `app/windows/` gets added. After running it,
   check `git status` — `flutter create` likes to touch `.metadata`.
   Verify that the app's plugins support Windows (`file_picker`,
   `desktop_drop`, `super_clipboard`, `shared_preferences`);
   `receive_sharing_intent` is mobile-only and already gated behind
   `Platform.isAndroid` (see `home_screen.dart`) — it must not be called
   on Windows. `super_clipboard` builds a Rust part on the build
   machine — the runner has Rust, and nothing needs installing on the
   author's machine, because the build happens in CI. **No network
   capability:** nothing that requests network access gets added to
   `windows/`, and a `.gitattributes` with `* text=auto eol=lf` is set up
   right away — without it, checkout on Windows turns `\n` into `\r\n` by
   default, and the byte-for-byte `expected.md` files, plus the binary
   fixture `windows1251.txt`, risk diverging from the expectation for a
   reason that has nothing to do with the converters.
   **Done:** `app/windows/` created; `.metadata` had to be restored by
   hand (`flutter create` dropped android/macos out of it); plugins —
   `desktop_drop` and `super_clipboard` are native on Windows,
   `file_picker` there is pure Dart; the window title is "MarkItDown UI".
   `.gitattributes`: `* text=auto eol=lf`, fixtures marked `-text`
   (byte-for-byte, no conversion).

2. **A CI job on `windows-latest`.** The equivalent of `make verify`:
   `pub get`, `dart format --set-exit-if-changed`, `flutter analyze`,
   `flutter test` in `app/`, `dart test` in `core/`; then
   `flutter build windows --release` and `actions/upload-artifact` with
   the `build/windows/x64/runner/Release` directory (on Windows,
   `dart format` must produce the same output as on Linux — one more
   reason for `.gitattributes`). **Decide: run `make`, or separate
   steps.** `run:` on a Windows runner defaults to PowerShell;
   `shell: bash` gives you Git Bash, where `make` may be missing (install
   via `choco install make`), and the Makefile and `pdfium/fetch.sh`
   parse `uname -s` and only know about `Darwin`/`Linux` — on Git Bash
   it's `MINGW64_NT-…`, and the branch would plug in `libpdfium.so`
   instead of `pdfium.dll`. Recommendation: **separate steps in
   `shell: bash`**, and don't hardwire a Windows branch into the Makefile
   or `fetch.sh` while it's only needed by CI — fewer moving parts on the
   runner. Cost: the list of checks lives in two places (Makefile and
   `ci.yml`), and drift between them has to be caught by eye; so note in
   the `make verify` comment that "the Windows job in `ci.yml` must be
   kept in sync".
   **Done:** separate steps in `shell: bash`, the Makefile comment is in
   place. The first step checks that the checkout used LF. The artifact
   is `markitdown_ui-windows-x64`.

3. **PDFium on Windows.** Three things. (a) `pdfium/fetch.sh` learns to
   download `pdfium-win-x64.tgz` from bblanchon/pdfium-binaries (the same
   pinned tag, not "latest") and gets a `MINGW*|MSYS*` branch in
   `uname -s`; the DLL in that archive sits in `bin/`, not `lib/` like the
   others — fix `fetch()` accordingly. (b) In the `core/` tests —
   `MARKITDOWN_PDFIUM_PATH` pointing at `pdfium.dll` (the same way as for
   `.dylib`/`.so`). (c) In the app — `loadPdfiumLibrary()` currently
   doesn't know about Windows and throws `UnsupportedError`; add a branch
   and put `pdfium.dll` **next to the `.exe`**: Windows looks for DLLs
   first in the executable's own directory, and placing it there during
   the build is done via an `install(...)` rule in
   `windows/CMakeLists.txt`, following the pattern the Flutter template
   already uses for plugin DLLs. PDFium itself stays uncommitted, same as
   everywhere else.
   **Done:** all three; the DLL is confirmed to be in the archive's
   `bin/`. Without `pdfium.dll`, CMake fails with a clear error instead
   of building the app without PDF support. `sidecar_converter_test.dart`
   (a fake at `/bin/sh`) is skipped on Windows via `@TestOn('!windows')`.
   Looking for the sidecar next to the `.exe` and the
   `install(DIRECTORY …)` rule from item 4 are also already in place —
   optional, so without a built sidecar you get a Dart-only build.

4. **The sidecar on Windows.** Built in CI, because there's nothing
   locally to run it on.
   - **Interpreter:** python-build-standalone for
     `x86_64-pc-windows-msvc`, the `install_only` variant, the same pinned
     release version and CPython 3.12.14; `sidecar/common.sh` gets a host
     branch for `windows-x86_64` and the sha256 of the new asset (checked
     against the release's `SHA256SUMS`, same as for the others). Wheels
     for `numpy`/`onnxruntime`/`pandas`/`lxml`/`cryptography`/`pillow` for
     `win_amd64` and cp312 exist — this is verified by `lock.sh` itself,
     not taken on faith.
   - **Lock file:** `sidecar/locks/windows-x86_64.txt`, **generated on the
     runner** (`ALLOW_UNLOCKED=1`, then `make sidecar-lock` — same as for
     any new host), published as an artifact of a manual workflow run,
     and committed after reading the diff. Don't write it by hand: the
     `win_amd64` wheel hashes are different.
   - **Build in CI:** a separate job, `build.sh` under Git Bash. The
     script has mac-specific bits (`lipo -thin`, `otool`) — on Windows
     these steps are skipped based on the host; symlinks in `python/`
     aren't needed on Windows. Not part of `make verify`, same as on Mac;
     the artifact is `sidecar/dist/windows-x86_64/`.
   - **Layout and directory discovery:** the interpreter is
     `python/python.exe` instead of `python/bin/python3`
     (`SidecarConverter.fromDirectory` already knows this). `discover()`
     currently only looks at `MARKITDOWN_SIDECAR_DIR` on Windows; teach
     it to also look for `sidecar/` **next to the `.exe`**
     (`Platform.resolvedExecutable`), the same way macOS looks for
     `Contents/Resources/sidecar`. In the Flutter Release directory, the
     sidecar gets placed there too, via an `install(DIRECTORY …)` rule in
     `windows/CMakeLists.txt`.
   - **Tests:** `core/test/sidecar_converter_test.dart` substitutes a
     `#!/bin/sh` script for the interpreter — that won't run on Windows;
     such tests should be skipped on Windows (or rewritten against
     `SidecarCommandBuilder`), while the real integration tests
     (`sidecar_integration_test.dart`, `MARKITDOWN_SIDECAR_DIR`) and
     `compare-sidecar` run on the runner against the sidecar built there.
     Expect differences: different line endings in `expected.md`,
     `\`-style paths, and longer paths in the `site-packages` tree (the
     260-character limit — check this against deeply nested files once
     installed into the final directory).
   - There's no macOS signing here, and there can't be: `sign.sh` and the
     entitlements aren't involved. Instead — Authenticode, see item 6.
   - **Done:** the `windows-sidecar` job (`windows-2022`), the lock
     committed after review, a 308 MB build, the longest path is 95
     characters; integration tests are green, and the cross-check against
     Dart matched macOS byte for byte (details —
     [python-sidecar.md](python-sidecar.md#windows-stage-5) and
     [format-coverage.md](format-coverage.md#reconciliation-on-windows-stage-5)).
     The `windows` job waits on it and places the sidecar next to the
     `.exe`; if it fails, the result is a Dart-only build, not a missing
     artifact.

5. **The "sidecar or Dart" order — the author's decision, needed at the
   start of the stage. Decided:** the recommendation below is approved,
   with a threshold of **50 pages**. Implemented in
   `SidecarConverter.appFormats`/`appMaxPdfPages` (applied in
   `discover()`, i.e. only in the app): above the threshold, PDF goes to
   Dart, with a warning that tables were extracted as text. The question
   moved here from
   [future-development.md](future-development.md#sidecar-performance-on-large-files),
   because on Windows it becomes impossible to ignore. Facts: the sidecar
   is slow — a 300-page PDF is 112 s versus 1.2 s for Dart; a 50k-row
   xlsx is 55 s and ~860 MB of RAM versus 4.4 s; per the cross-check
   (Stage 4), Dart isn't worse for `docx`/`xlsx`/`pptx`, and is in places
   cleaner; the sidecar is only better for PDF tables; only it can handle
   `xls`/`msg`. **The orchestrator's recommendation, not yet approved by
   the author:** try the sidecar first only for `pdf`/`xls`/`msg`; go
   straight to Dart for `docx`/`xlsx`/`pptx`, keeping the sidecar as a
   reference for cross-checking, not as the active path; for large
   PDFs — a threshold on the page count above which the sidecar isn't
   consulted at all. The threshold value, and what to do with PDF tables
   above it, are also the author's decision. Until that answer, the
   registry keeps Stage 4's behavior, and that's not a bug. (This was the
   state before the decision.)

6. **Packaging and distribution — a stage-level decision, made by the
   author against criteria. Decided: "zip for now, decide later"** — for
   verification and the first release, zip (the CI artifact already is a
   zip of the `Release/` directory); the choice between zip, Inno Setup,
   and MSIX is deferred to Stage 7. The MSIX experiment below isn't needed
   until then. Options: **zip** with a `Release/` directory (the cheapest
   option: unzip and run, nothing gets installed or written to the
   registry), an **Inno Setup installer** (`.exe`, a familiar wizard,
   shortcuts, removal from "Apps"), **MSIX** (a modern format, clean
   install and uninstall, a capability model). Criteria: (a) how
   verifiable "no network" is; (b) installing without administrator
   rights; (c) signing and SmartScreen; (d) size — the bundle with the
   sidecar is ≈250–300 MB, is a compressed distribution needed; (e) where
   the sidecar physically lives: MSIX installs into
   `C:\Program Files\WindowsApps\…`, a read-only directory with a long
   path — fine for the `-B` sidecar, but check against the
   260-character limit; (f) how the author distributes it: GitHub
   Releases or the Microsoft Store.
   - **The case for MSIX from a "no network" standpoint.** The MSIX
     manifest explicitly lists capabilities, and the absence of
     `internetClient` is a direct analog to the absence of
     `android.permission.INTERNET` in an APK: visible in the manifest and
     checkable with grep. **But**: an ordinary Flutter app packaged as
     MSIX runs with `runFullTrust`, and fully-trusted processes most
     likely aren't restricted by network capabilities — the manifest will
     be clean, but the socket will open anyway. So the first step of this
     item is an experiment (a minimal MSIX without `internetClient`,
     attempting a connection from it); if the connection succeeds, the
     argument is weaker than for the APK, and that should be recorded
     honestly in [offline-and-privacy.md](offline-and-privacy.md). An
     AppContainer mode for Win32 exists, but its compatibility with
     Flutter and a subprocess interpreter hasn't been checked.
   - **Authenticode signing and SmartScreen — an open question: there's
     no certificate.** Without a signature, MSIX won't install at all (a
     self-signed certificate would have to be added to the trusted list
     on every machine — fine for the author's own computer, not for
     distribution), while unsigned `.exe` files from a zip or an
     installer get a SmartScreen warning on first launch ("Windows
     protected your PC" → "More info" → "Run anyway"). The decision to
     buy a certificate or use cloud signing is the author's and doesn't
     block items 1–5 and 7–8: for verification on the author's own
     computer, an unsigned zip is enough.

7. **A "no network" check on Windows in CI, by analogy with the APK and
   entitlements checks.** What can honestly be checked: (a) `dart pub deps`
   has no networking packages — already in place, no need to duplicate
   it; (b) if MSIX is chosen — the final `AppxManifest.xml` has no
   `internetClient`, `internetClientServer`, `privateNetworkClientServer`
   (a failing step, like the grep over `AndroidManifest.xml`); (c) no
   networking components have been added in `windows/` or the sidecar.
   What honestly can't be checked: `.exe` imports (`ws2_32`/`winhttp`) —
   `flutter_windows.dll` itself and the Dart VM pull in sockets for the
   debug service, so such a check would always be red. For zip and the
   Inno installer there's no OS-level guarantee, and in
   [offline-and-privacy.md](offline-and-privacy.md), the "Windows" line
   stays "dependency review" — that needs to be stated plainly, not
   oversold.
   **Done:** (a) was already there; (b) not needed while packaging is
   zip; (c) — a step `no networking libraries in app/windows/`
   (`ws2_32`/`winhttp`/`wininet`/`urlmon`/`internetClient`); for the
   sidecar — the same line as on macOS (markitdown's networking
   converters aren't installed), checked in item 4. `offline-and-privacy.md`
   states plainly: there's no OS-level guarantee.

8. **Manual verification on the author's Windows machine** (using the CI
   artifact, the Dart part — after item 3, with the sidecar — after item
   4). What to poke at:
   - launching with no Python installed and no internet (turn off
     networking entirely — the app shouldn't notice);
   - dragging a file onto the window; opening it via the dialog; Cyrillic
     in the file name and the path, a space in the path;
   - `docx`, `xlsx`, `pptx`, `pdf` (with text, a scan, a table), `csv` in
     Windows-1251 — a result appears, the type is detected correctly;
   - `.xls` and `.msg` — Markdown comes back, `warnings` contains
     `converterId: sidecar` (on a Dart-only build — an honest "not
     supported");
   - a large PDF and a large `xlsx`: how long do we wait and what shows
     up in the window (these are the numbers for item 5);
   - the copy button and pasting into Notepad and a browser chat: the
     text arrives; "Save as `.md`" — UTF-8 without BOM, `\n`;
   - the first launch: what SmartScreen and the antivirus show (Defender
     scans `python.exe` and `.pyd` on first use — the sidecar's first
     call might be noticeably slower, and the timeout shouldn't trigger);
   - closing the window — `python.exe` shouldn't linger in Task Manager.

**Done when:** the CI artifact is downloaded onto the author's Windows
machine, and `docx`, `pdf`, and `.xls` from it turn into Markdown that gets
pasted into a chat with one button; the decisions for items 5 and 6 are
made and recorded; the `windows-latest` job is green on every PR.

**Status: closed.** Manual verification (item 8) — the author, 2026-10-11,
on release `v0.5.0`: "everything works on Windows." Results for individual
list items weren't recorded; in particular, there are no numbers for a
large PDF and a large `xlsx` on Windows — the 50-page threshold (item 5)
still rests on measurements taken on a Mac (see
[future-development.md](future-development.md#sidecar-performance-on-large-files)).

## Stage 6 — Images and Audio (0.6)

**Goal:** the area where staying offline costs the most. It splits into
three independent pieces, each of which can be closed out separately.

1. **EXIF** — cheap, done first: camera, date, geotag, orientation.
   **Done** (`ImageConverter`): PNG, JPEG, GIF, BMP, WebP, TIFF, HEIC —
   format, size from the header, and EXIF fields. The `exif` package
   wasn't used — a custom TIFF parser instead; why is explained in
   [format-coverage.md](format-coverage.md#stage-6-decisions).
2. **OCR** — ~~ML Kit on mobile, Tesseract on desktop~~. **Done
   differently, by the author's decision:** Tesseract on both
   platforms — ML Kit doesn't know Cyrillic. Via FFI from `core/` (like
   PDFium), so it runs right in the pipeline rather than off the main
   isolate: images (JPEG, PNG, BMP) and scanned PDF pages. The engine and
   its version are written to `warnings`. The libraries are
   Tesseract4Android on Android and a custom build without libcurl on
   desktop (`tesseract/`); the `rus+eng` models ship as assets. Details —
   [format-coverage.md](format-coverage.md#stage-6-decisions).
3. **Audio** — metadata and tags only, to start (cheap and immediately
   useful). **Done:** MP3, FLAC, Ogg (Vorbis, Opus), WAV,
   M4A/MP4/MOV/3GP — duration, audio parameters, tags, lyrics; for video,
   the frame size. Offline transcription (whisper.cpp / sherpa-onnx) moved
   to [future-development.md](future-development.md#large-audio-and-video):
   the model weighs anywhere from 40 MB to a gigabyte and a half, and
   that's a decision for a later stage.
4. **Manual verification** on the author's Windows machine and phone
   (using CI artifacts): a photo of a document taken on the phone
   (portrait — checks EXIF-based rotation), a screenshot, a PDF scan, a
   voice message from a messenger, an MP3 with Russian tags. Numbers — how
   long OCR on a page takes on the phone and on Windows.

**Done when:** a photo of a document and a PDF scan produce recognized
Russian text on Windows and Android; a voice message and MP3 produce
metadata; CI is green, including the Tesseract build for Windows.

## Speech Recognition (0.8)

Outside the original plan: after the 0.7 release, the author asked to "add
faster-whisper" — Russian, Italian, and English, Windows and Android, the
small model bundled directly into the build. Transcription used to sit in
[future-development.md](future-development.md#speech-recognition-whats-next)
with the question "is audio worth making the app ten times bigger?" — the
author answered "yes." All the "whys" are in
[format-coverage.md](format-coverage.md#transcription-decisions-08).

1. **Engine.** ~~faster-whisper~~ — Python, not available on Android;
   **the author's decision:** whisper.cpp on both platforms, a custom
   build (`whisper/build.sh`, host and `--android`), FFI from `core/`
   through a C shim at `whisper/shim/`. **Done.**
2. **Model** — small, multilingual, in the main bundle (the author's
   decision); q8_0 (264 MB) + Silero VAD. `whisper/fetch.sh`, with a
   manifest in `models.json`. **Done.**
3. **Decoding audio to 16 kHz:** WAV, MP3, FLAC, Ogg Vorbis/Opus —
   portably (miniaudio, libopus); AAC (M4A/MP4) — the platform decoder.
   **Done.**
4. **App:** a "Transcript" section with timestamps, detected language,
   progress and a "Stop" button, copying the model to disk on Android.
   **Done.**
5. **CI:** build and tests on Linux and Windows (`speech_test.dart`),
   building `.so` for Android, and checking the APK in `release.yml`.
   **Done**, green in PR #4; the first run caught AAC on Windows
   transcribing to nothing (the Media Foundation format wasn't being
   re-read) — fixed, and M4A is now checked on the `windows-2022` runner.
6. **Manual verification** on the author's Windows machine and phone: a
   voice message from Telegram/WhatsApp (Ogg Opus), a voice-recorder
   recording (M4A), an MP3 in Italian and English; the "Stop" button on a
   long recording. Numbers — how many minutes it takes to transcribe a
   minute of speech on the phone and on Windows, how much the APK weighs.

**Done when:** a voice message and a voice-recorder recording produce a
transcript on Windows and Android; CI is green, including the whisper.cpp
build for Windows and Android.

## Stage 7 — Polish and Release (1.0)

1. Keyboard shortcuts throughout, Tab-based focus, fully usable without a
   mouse.
2. Batch conversion: multiple files → either a single Markdown file with
   separators, or a folder of `.md` files.
3. Settings: language, theme, disabling history. ~~Limits~~ — **the
   author's decision (0.7):** there's no file-size limit at all, so
   there's nothing to configure; archive limits (zip-bomb protection)
   aren't a setting.
4. Linux — if there's ever something to build it on (Windows will already
   be past Stage 5 by this point).
5. Release — GitHub Releases only (**the author's decision, 14.10.2026:**
   not publishing to Google Play): a Windows build in the format chosen
   in Stage 5 (item 6), and an APK. A permanent APK signing key (right now
   it's the runner's debug key, and a new version won't install over an
   old one). The release notes and README state plainly what's going on
   with the clipboard (see [offline-and-privacy.md](offline-and-privacy.md)).
   A DMG and macOS notarization — only if a Mac with Xcode shows up by
   then, along with a separate request.
6. A README with screenshots and an honest bundle size per platform.

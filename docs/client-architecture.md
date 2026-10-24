# Client architecture

Decisions and behavior of the Flutter app: what it's built from, what the
client itself does, and why. Kept separate from
[conversion-pipeline.md](conversion-pipeline.md), because that one is pure
Dart without a single `flutter/` import, while this one covers everything
around it: the window, isolates, the clipboard, file entry points.

The list of technical decisions below is **living**: it's what the project
is built from right now, not what we planned to build it from. Deviations
get recorded here, otherwise the document starts lying silently.

---

## Default technical decisions

- **State management:** Riverpod
- **Navigation:** no router for now. In Stage 1 the entire flow (empty →
  file accepted → conversion → preview/error) fits into a single
  `HomeScreen` window that switches widgets based on the `FileIntakePhase`
  state — exactly the caveat "if this gets excessive, switch to Navigator,
  and note it here" that has stood here from the start. `go_router` will be
  needed once real deep links show up ("open with" on Windows and macOS, a
  settings screen) — it'll be wired in then.
- **Zip parsing:** `archive` · **XML:** `xml` · **CSV:** `csv` ·
  **HTML → Markdown:** `html` + `html2md`
- **Clipboard:** `super_clipboard` (several representations are needed at
  once; `Clipboard.setData` only supports `text/plain`)
- **File intake:** `file_picker` (dialog), `desktop_drop` (drag & drop),
  `receive_sharing_intent` (the system "Share" on Android/iOS)
- **Linting/formatting:** `flutter_lints` + `dart format`, in CI from the
  first commit
- **Localization:** `flutter_localizations` + ARB (`en`/`ru`), generated via
  `flutter gen-l10n`, generated files are committed — same approach as in
  Amicus
- **Repository structure:** `app/` — the Flutter project, `core/` — the
  conversion pipeline as a separate package, `sidecar/` — the Python bundle
  build, `docs/` — documentation; the full tree is in
  [../README.md](../README.md)
- **Flutter version:** pinned — see "Environment constraints" in
  [../AGENTS.md](../AGENTS.md)

### Why the pipeline is a separate package

`core/` doesn't import `flutter/` in a single file, and that's checked in
CI. Three reasons, all practical:

- its tests run as `dart test`, without an emulator and without
  `flutter_test` — that's seconds instead of minutes, and this is where
  most of the tests will live;
- code that moves to an isolate shouldn't have to drag platform bindings
  along with it;
- if a CLI (batch conversion from a terminal) is ever needed, it can be
  built from `core/` without a single change.

## Conversion in an isolate

All conversion runs through `Isolate.run`. This isn't an optimization, it's
a requirement: parsing a large `xlsx` or PDF is seconds of solid CPU work,
and on the main isolate that freezes the window along with the progress
indicator that's supposed to be showing that something's happening.

Three consequences follow from this, and they're easy to forget:

- **Only bytes and `StreamInfo` travel into the isolate.** No Riverpod
  providers, no `BuildContext`, no objects holding platform handles inside.
- **Platform plugins don't work from an isolate.** So everything native in
  the pipeline goes through FFI rather than plugins: PDFium (Stage 3) and
  Tesseract for OCR (Stage 6) are opened directly in the isolate
  (`DynamicLibrary.open`). The one platform-dependent part of OCR that
  remains is locating the models (assets; on Android they also need to be
  copied from the APK to disk), and the main isolate does that
  (`app/lib/src/conversion/ocr_data.dart`), while a path string
  (`OcrSettings`) goes into the isolate. The original plan called for ML Kit
  from the main isolate; ML Kit fell through because it doesn't know
  Cyrillic, see
  [format-coverage.md](format-coverage.md#stage-6-decisions). Speech
  recognition (0.8) is built the same way: whisper.cpp is FFI inside the
  isolate, the main isolate prepares the models (`speech_data.dart`, only
  when an audio file arrives), and `TranscriptionSettings` goes into the
  isolate.
- **Cancellation.** A user who drops a gigabyte-sized archive into the
  window needs to be able to press "Cancel." `Isolate.run` can't be
  cancelled — which means long-running formats need a long-lived isolate
  with a port and a flag check between files inside the archive. This isn't
  done at the first stage, but `ConversionLimits` is laid out so that
  cancellation can fit in later. **The first case was speech recognition
  (0.8)**, and there a port turned out not to be needed: the isolate is busy
  for minutes inside native `whisper_full` and doesn't read messages anyway.
  The cancellation flag and progress live in native memory
  (`TranscriptionControl`, two `int32`s): the main isolate writes the flag
  and reads the percentage every half second, and whisper.cpp checks the
  flag itself — before every 30-second window. The memory is only freed
  after the isolate ends. A new file accepted during conversion (drop,
  "Share") stops recognition of the old one, and the old result is
  discarded — tracked by intake number in `FileIntakeController`. For
  archives this approach only works if the flag check happens in Dart code
  between files.

## File intake: four inputs, one entry point

The four ways of handing over a file (dialog, drag & drop, "Share",
clipboard) all collapse into a **single** call to
`ConversionController.accept(source)`. The sources only differ in how the
bytes and name are obtained; branching beyond that point is forbidden —
otherwise the four paths start handling errors differently, and the
divergence gets discovered on the fourth one.

A link (0.9, "Paste link" and sharing a link on Android) is not a fifth
path but a preliminary step: `FileIntakeController.acceptUrl` downloads
whatever it points to (`downloadUrl` from the core), and hands the bytes to
that same `accept` — with the address in `PickedFile.url`. A download
failure is a `NetworkFailure`, a fourth kind of failure alongside the three
file-based ones.

Platform-specific details that have to be set up by hand in the native
projects:

- **Android:** an `intent-filter` with `ACTION_SEND` and `ACTION_VIEW` for
  the relevant MIME types — this is what adds the app to the system
  "Share" sheet. Without `android:mimeType="*/*"` in the list, a file
  without an extension won't get through.
- **iOS:** `CFBundleDocumentTypes` + Share Extension. The Share Extension
  is **a separate process**, with its own memory limit (much lower than
  the app's); conversion can't happen inside it, it only hands the file off
  to the main app.
- **Windows:** the dialog, drag & drop, and clipboard paste all work
  without native setup (there's no system "Share" on Windows); "Open with"
  and file-extension association are a job for the installer or MSIX; with
  the current zip packaging (Stage 5, item 6) they don't exist — the
  packaging decision is Stage 7. The same path would arrive into
  `accept()`. Paths with Cyrillic characters and spaces are a mandatory
  item for manual testing.
- **macOS:** `CFBundleDocumentTypes` for "Open with," plus
  `NSPasteboardTypeFileURL` for pasting a file from Finder.

## Clipboard

Two representations are placed at once: `text/plain` and `text/markdown`.
An editor that understands the latter gets the markup; the rest get the
same text, so nobody's worse off.

A behavior worth deciding up front rather than when it shows up in
reviews: **the app never copies anything on its own**. Auto-copying when
conversion finishes looks convenient right up until the first time it wipes
out something the person was carrying in the clipboard. Copying happens
only on an explicit action (button, `Cmd/Ctrl+C`, `Enter` on the preview
screen).

## Large files

The limits aren't protection against an attack, they're protection against
the app silently eating memory and getting killed by the system. This is
especially close to home on mobile.

- There's no limit on the file's own size — the author's decision: whatever
  a person chooses to pick, gets converted. The cost is that the file is
  read into memory in full, and a file too large for the device can crash
  the app; this is addressed by reading in chunks wherever the format
  allows it (see "Large audio and video" in `future-development.md`), not by
  reinstating a threshold.
- Archives: a limit on nesting depth (8), on the number of files (2000), and
  on the total unpacked size (1 GB, the archive itself doesn't count toward
  the total). The latter is the only defense against a zip bomb, and the
  **unpacked** size has to be checked as it goes, not the size claimed in
  the header: the header can't be trusted.
- A result that doesn't fit on the preview screen isn't rendered in full:
  the text field gets a slice, while the full text goes into the clipboard.
  Otherwise `SelectableText` on a ten-megabyte Markdown document locks up
  the frame solid.

## State and privacy

The app **does not store conversion content**. This isn't laziness, it's a
property of the product: the whole point is that the document never leaves,
and a local database holding copies of every file ever processed is the
same leak, just slower. A "recent files" history, if it ever gets added,
stores paths and names, not content, and it will be possible to turn off.

Temporary files (for the sidecar, for clipboard pasting) live in the
system's temp folder and are deleted right after conversion, including on
the error path — `try/finally`, not "we'll delete it at the end."

## Theme and localization

Light/dark follows the system, with the option to pin it explicitly — the
same way it's done in Amicus, and for the same reason: it's free and it's
the first thing people notice. Locales are `en` (default) and `ru`; ARB
files are edited **as text**: rewriting them through `json.dump`/an
autoformatter eats the blank lines that divide the file into semantic
groups.

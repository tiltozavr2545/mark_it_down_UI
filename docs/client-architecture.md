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
- **Navigation:** `HomeScreen` displays the current `FileIntakePhase`,
  the queue, or a Markdown preview. File intake and confirmation dialogs
  use the same screen.
- **Zip parsing:** `archive` · **XML:** `xml` · **CSV:** `csv` ·
  **HTML → Markdown:** `html` + `html2md`
- **Clipboard:** `super_clipboard` (several representations are needed at
  once; `Clipboard.setData` only supports `text/plain`)
- **File intake:** `file_picker` (dialog), `desktop_drop` (drag & drop),
  `receive_sharing_intent` (the Android "Share" flow)
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

- **The isolate receives the bytes, `StreamInfo` and optional model
  settings.** The UI and its Riverpod providers stay on the main isolate.
- **Platform plugins don't work from an isolate.** So everything native in
  the pipeline goes through FFI rather than plugins: PDFium (Stage 3) and
  Tesseract for OCR (Stage 6) are opened directly in the isolate
  (`DynamicLibrary.open`). The one platform-dependent part of OCR that
  remains is locating the models. The desktop apps read them in place.
  On Android the main isolate copies them from the APK to disk
  (`app/lib/src/conversion/ocr_data.dart`), while a path string
  (`OcrSettings`) goes into the isolate. The original plan called for ML Kit
  from the main isolate; ML Kit fell through because it doesn't know
  Cyrillic, see
  [format-coverage.md](format-coverage.md#stage-6-decisions). Speech
  recognition (0.8) is built the same way: whisper.cpp is FFI inside the
  isolate, the main isolate prepares the models (`speech_data.dart`, only
  when an audio file arrives), and `TranscriptionSettings` goes into the
  isolate. On macOS the libraries live in `Contents/Frameworks`, and both
  sets of models are read from `App.framework/Resources/flutter_assets`.
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
  and polls the percentage, and native code checks the flag while
  processing. The memory is only freed
  after the isolate ends. A new file accepted during conversion (drop,
  "Share") stops recognition of the old one, and the old result is
  discarded — tracked by intake number in `FileIntakeController`. For
  archives this approach only works if the flag check happens in Dart code
  between files.

## File intake

The file picker, desktop drop target and Android sharing provide
`PickedFile` values. `FileIntakeController.accept` handles a single file.
Multiple files go to `MergeController`. The clipboard is read when the
user opens **Paste a link** to prefill the dialog.

On an empty screen, **Paste a link** and Android link sharing use
`FileIntakeController.acceptUrl`. Links added to a queue are downloaded
when their turn comes. Both flows call the core's `downloadUrl`, record
the source address in `PickedFile.url`, and report download errors as
`NetworkFailure`.

Type detection, speech-recognition setup and polling, and the isolate live
in `convertPicked` (`app/lib/src/conversion/convert_picked.dart`), and both
`FileIntakeController.accept` and the queue call it, so a file in the
list is handled exactly like a file alone.

<a id="merging-files-010"></a>

## Batch conversion and merging

`MergeController` (`app/lib/src/merge/`) owns the queue and its results.
Selecting several files in the picker, dropping them on Windows or macOS, or
sharing them on Android opens the queue. **Add files** on a single
preview moves the existing result into the queue.

A drop or Android share over a ready result or an active queue asks
whether to add the sources or start over. A drop or share during a
single-file conversion replaces the in-progress input.

Sources are converted as soon as they are added, one at a time. This
limits the memory used by parsing and speech recognition. The queue
releases source bytes after conversion and retains file information,
statuses, results and warnings. Each ready row opens its own Markdown
preview with **Copy** and **Save as .md**.

The output selector is available on the start screen and in the queue.
Its selection is kept in `HomeScreen` for the session. Both modes use
the same completed results.

- **Separate files** is the default. **Save to folder** becomes
  available when every source has finished and at least one succeeded.
  The export writes each successful result as its own UTF-8 `.md` and
  reports successful saves and write failures.
- **One document** enables drag handles to set the document order.
  **Merge** requires every remaining item to have converted successfully.
  `mergeResults` in `core/lib/src/conversion/merge.dart` adds a heading
  for each source and a horizontal rule between them. It keeps the
  source heading levels and prefixes warnings with their source names.

### Platform file access

- **Android** accepts `ACTION_SEND`, `ACTION_SEND_MULTIPLE` and
  `ACTION_VIEW` for content URIs. The `*/*` filters accept files with
  unknown extensions or MIME types. For batch export, the
  `markitdown_ui/markdown_export` channel opens the system's
  `ACTION_OPEN_DOCUMENT_TREE` picker and creates documents in the
  selected directory through `DocumentsContract`.
- **Windows and macOS** accept the file picker and drag-and-drop. Batch export
  opens the directory picker through `file_picker`. The writer in
  `app/lib/src/markdown_export.dart` reserves a new pathname before
  writing and adds a suffix when a name is already taken. The macOS
  sandbox grants read and write access to destinations selected in a
  native dialog. For file intake, `infoFor` leaves `localPath` unset on
  macOS so the Python subprocess reads a temporary copy from the app's
  container. See the [conversion pipeline](conversion-pipeline.md#the-sidecar--just-another-converter).
- **iOS** and its Share Extension are deferred. Finder document
  associations and Quick Actions remain open. See
  [Future development](future-development.md).

Native file dialogs are covered by the
[manual export checks](operations.md#manual-export-checks).

## Clipboard

Two representations are placed at once: `text/plain` and `text/markdown`.
An editor that understands the latter gets the markup; the rest get the
same text, so nobody's worse off.

A behavior worth deciding up front rather than when it shows up in
reviews: **the app never copies anything on its own**. Auto-copying when
conversion finishes looks convenient right up until the first time it wipes
out something the person was carrying in the clipboard. Copying happens
only on an explicit action (the Copy button or `Cmd/Ctrl+C` while the
preview has focus).

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
- The preview shows at most 20,000 characters so large results remain
  responsive. Copy and Save use the full Markdown.

## State and privacy

The app **does not store conversion content**. This isn't laziness, it's a
property of the product: the whole point is that the document never leaves,
and a local database holding copies of every file ever processed is the
same leak, just slower. A "recent files" history, if it ever gets added,
stores paths and names, not content, and it will be possible to turn off.

The sidecar removes temporary input it creates, including on failure.
Android's share plugin can provide paths from its temporary cache. OCR
and speech models copied out of the APK are kept in application support
so later conversions can reuse them.

## Theme and localization

The theme and language follow the system. `app_theme.dart` defines the
light and dark palettes and uses Sofia Sans from the bundled font assets.
`workspace.dart` holds the shared layout and output selector. Wide
windows place the queue beside the export panel. Narrow layouts place
the export panel below the list.

Supported locales are `en` (default) and `ru`. Edit ARB files as text to
preserve the blank lines between groups, then run `flutter gen-l10n`
from `app/`.

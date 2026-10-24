# Pipeline: file → Markdown

The main document of the project. This is the path the bytes take from the
moment a file lands in the app to the string in the clipboard, and the
contracts that every converter relies on.

Kept separate from [client-architecture.md](client-architecture.md), because
this isn't about Flutter: the pipeline is pure Dart, without a single
`flutter/` import, and it must build and be tested like an ordinary console
library. This isn't a matter of taste but a requirement: conversion has to
run in an isolate and in CI without an emulator.

What was decided for each specific format and what covers it —
[format-coverage.md](format-coverage.md). How this differs from real
markitdown — [python-sidecar.md](python-sidecar.md).

---

## Where the contracts come from

The interface mirrors markitdown deliberately and almost literally:
`StreamInfo`, `accepts()`/`convert()`, the converters' numeric priorities, a
single result object. The reason is simple: **we need to check our output
against its output** on the same files, and the closer the design, the
cheaper it is to figure out why the output diverged. It also lets us, on
desktop, drop in the real markitdown behind the same interface — as just
another converter, see below.

Wherever we deviate from it, that is called out directly in the text.

## Stages

```
source (picker / drag&drop / share / clipboard)
   ↓  bytes + filename + mime from the OS (which cannot be trusted)
[1] type detection              → StreamInfo
   ↓
[2] converter selection         → registry, accepts() in ascending priority order
   ↓
[3] conversion in an isolate    → ConversionResult | ConversionFailure
   ↓
[4] preview                     → raw Markdown
   ↓
[5] clipboard / .md file
```

The boundaries between the stages are not decoration: 1–3 know nothing about
the UI, 4–5 know nothing about formats. The only thing connecting them is
`ConversionResult`.

## [1] Type detection

`StreamInfo` is what's known about the stream before it's parsed. The fields
are the same as in markitdown:

| field | source | how much it can be trusted |
|---|---|---|
| `filename` | from the source | the name can be anything |
| `extension` | from `filename` | **lies regularly** |
| `mimeType` | from the OS (share/picker) | on Android often `application/octet-stream` |
| `charset` | determined for text files | absent for binary ones |
| `localPath` | if the file is on disk (dialog, drag&drop) | needed by the sidecar, see below; Dart converters don't read it |

Detection order goes from cheap to expensive, and the first confident answer
wins:

1. **Magic bytes.** The first few kilobytes: `PK\x03\x04` → the zip family,
   `%PDF-` → PDF, `\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1` → OLE2
   (`.doc`/`.xls`/`.msg`/`.ppt`), image signatures. Cheap and more reliable
   than the extension.
2. **Refinement inside the container.** `PK` by itself says nothing: `docx`,
   `xlsx`, `pptx`, `epub`, `apk`, and a plain archive are all zip. They're
   distinguished by content: `[Content_Types].xml` (OOXML, then by the part
   type), `mimetype` as the first file (EPUB), otherwise a plain archive. The
   same goes for OLE2: all of its formats share one signature, and what
   distinguishes them is the Compound File directory
   (`type_detection/ole2_directory.dart` — a minimal parse, entry names only,
   no third-party packages): `Workbook`/`Book` → `xls`,
   `__properties_version1.0` or `__substg1.0_*` → `msg`, `WordDocument` →
   `doc`, `PowerPoint Document` → `ppt`. If the directory can't be read (a
   truncated file, a nonstandard container), it's left as an "OLE2
   container" with a hint from the extension.
3. **Extension** — only as a hint, when the bytes are ambiguous (`.csv` vs
   `.tsv`, `.md` vs `.txt`).
4. **Encoding** for text files: BOM, then a heuristic. Text without a BOM
   that doesn't parse as UTF-8 is not a "corrupt file" — it's most likely
   Windows-1251; that's common on Russian-language exports.

At this step markitdown uses `magika` — Google's ONNX model. We don't take it
on: that's a ~1 MB model plus runtime in the bundle for a job that signatures
already cover for our set of formats. **If** the set ever grows to include
formats that signatures can't distinguish, the decision should be revisited —
but deliberately, and with measurements.

## [2] Converter registry

```dart
abstract interface class DocumentConverter {
  String get id;                       // 'docx', 'html', 'sidecar'
  double get priority;                 // lower — asked earlier
  bool accepts(StreamInfo info, Uint8List head);
  Future<ConversionResult> convert(ConversionRequest request);
}
```

The registry holds converters sorted by `priority`, and hands the file to the
first one whose `accepts()` said "yes". Priorities are the same as in
markitdown:

- **0.0 — a specific format.** `docx`, `pdf`, `xlsx`: the converter knows
  exactly what it's looking at.
- **10.0 — a generic format.** `html` and `plain text`: they'll take anything
  text-like, so they're asked last. Otherwise the `html` converter would grab
  a `.docx` with XML peeking out of it.

`accepts()` receives `head` — the already-read first bytes, not a stream:
otherwise every converter in the chain would start reading the file from the
beginning, and on a hundred-megabyte mobile file that would cost noticeably.

**Difference from markitdown:** our `accepts()` is synchronous and isn't
allowed to touch disk. The "is this my file" decision is made from
`StreamInfo` and `head`; anything requiring parsing already belongs inside
`convert()`. That keeps the chain of checks predictably fast.

### The sidecar — just another converter

On desktop, `SidecarConverter` is added to the registry with priority
**-1.0** for the formats listed in its manifest — meaning it's asked before
the Dart converters wherever the real markitdown is known to be better, and
it stays out of the way where it isn't. The app above the registry doesn't
know about the sidecar at all; on mobile it simply isn't registered.

The only thing that leaks out: the sidecar needs a **file on disk**
(`localPath`), not bytes in memory — it receives the path as an argument. If
the file has a `StreamInfo.localPath` (dialog, drag&drop), that's what's
passed; for data without a path (clipboard, a file nested in an archive)
`SidecarConverter` writes the bytes to a temp folder with an extension based
on the format id, and removes it in `finally`. Deletion is the caller's (the
converter's) responsibility, not the sidecar's — otherwise it's unclear who
owns it; a file that came in via someone else's `localPath` is never deleted.

**Which formats it takes.** Only the ones listed in `manifest.json` and known
to the app (`pdf`, `docx`, `xlsx`, `xls`, `pptx`, `msg`; the `FileKind` ↔ id
mapping lives in `sidecar_manifest.dart`). `xls`/`msg` are recognized via the
OLE2 directory (see above) and **exist only through the sidecar**: there are
no Dart converters for them, so on mobile they remain "unsupported" — a
deliberate decision of the plan. If the manifest is corrupt or has an unknown
`schema`, the sidecar simply isn't registered; the app doesn't crash.

**In the app — only `pdf`/`xls`/`msg`, PDF up to 50 pages** (the author's
decision, Stage 5, item 5). `discover()` narrows the manifest down to
`SidecarConverter.appFormats` and sets `maxPdfPages = appMaxPdfPages`: the
sidecar is tens of times slower than Dart, and for `docx`/`xlsx`/`pptx` Dart
is no worse by comparison, so the sidecar goes first only where it provides
something missing — `xls`/`msg` and tables in PDFs. The sidecar rejects a PDF
longer than the threshold without launching Python (`countPdfPages` via
PDFium — the page tree, without parsing text), the registry hands the file to
the Dart converter, and `warnings` notes that the tables were extracted as
text. `fromDirectory()` without `onlyFormats` sees the whole manifest — that's
how the sidecar stays the reference for `make compare-sidecar` and the
integration tests.

**Where it's looked up.** `SidecarConverter.discover()`: on Android/iOS,
always `null`; on desktop — `MARKITDOWN_SIDECAR_DIR` (for development and
tests, following the pattern of `MARKITDOWN_PDFIUM_PATH`; if set, no other
locations are checked), otherwise on macOS `Contents/Resources/sidecar` next
to the bundle's executable, on Windows — `sidecar\` in the `.exe`'s directory
(placed there by `install(DIRECTORY …)` in `app/windows/CMakeLists.txt`). No
directory — it simply isn't registered. The lookup happens inside the
conversion isolate (`isolated_convert.dart`); the converter isn't passed
between isolates.

**Substitution in tests.** The launch command is assembled in one place —
`SidecarCommandBuilder` (input file path + format id → executable and
arguments). `SidecarConverter.fromDirectory` builds the standard one
(`python/bin/python3 -I -B run.py --in … --format …`, on Windows —
`python/python.exe`); tests either drop a shell script into the directory in
place of the interpreter, or pass their own builder into the constructor.

**Sidecar failure — fall back to the Dart converter.** The registry hands the
file to the first matching converter, and normally its refusal is final. The
sidecar is the exception: any failure of it (code 2, 3, 1, timeout, invalid
JSON with code 0, failed to start, output over the limit) throws
`ConversionDeclinedException`, and the registry moves on to the next
converter whose `accepts()` also said "yes" — i.e., the Dart implementation of
the same format (`pdf`, `docx`, `xlsx`, `pptx`). Why: the sidecar is an
enhancement on top of the Dart core, not a replacement for it; a hung or
crashed subprocess shouldn't take away a result the core can produce on its
own ("a partial result is more useful than a refusal"). That holds for code 3
too: `pdfminer` is stricter than PDFium, and a genuinely corrupt file will be
rejected by the Dart converter anyway — with its own, usually more precise,
description of where. If the fallback succeeds, the first line added to
`warnings` is "the sidecar failed to process the file (reason)", so the
discrepancy from the reference isn't a mystery. If there's no fallback
(`xls`/`msg`) or it also fails, the user gets the refusal described under
"Errors" below.

## [3] Conversion

```dart
class ConversionRequest {
  final Uint8List bytes;
  final StreamInfo info;
  final ConversionLimits limits;
  final Future<ConversionResult> Function(ConversionRequest) recurse;
}

class ConversionResult {
  final String markdown;
  final String? title;            // from document metadata, if present
  final List<ConversionWarning> warnings;
  final String converterId;
  final Duration elapsed;
}
```

`recurse` in the request is not decoration: `zip` and `epub` must run their
nested files through the same registry, and do it without importing the
registry directly, otherwise you get a dependency cycle. Alongside this comes
a hard rule: **recursion is bounded by depth and by the total number of
files** (`ConversionLimits`). A zip that contains itself isn't a theoretical
case — it's a well-known way to crash any unpacker.

`warnings` is a separate list rather than an exception, because **a partial
result is more useful than a refusal**. A PDF where half the pages are scans
should return the text from the rest and honestly say what's missing. A
complete refusal is acceptable only when there's nothing to return.

Conversion runs inside an isolate (`Isolate.run`). The reason isn't courtesy
to the UI, but that parsing a 50-megabyte `xlsx` is seconds of solid CPU, and
on the main isolate it would freeze the window along with the progress
animation. The consequences of this choice are in
[client-architecture.md](client-architecture.md#conversion-in-an-isolate).

## How the Markdown is assembled

Decisions about representation are the whole reason we look at markitdown in
the first place. Common to all converters:

- **The output is text for a human and for an LLM**, not an exact copy of
  the document. Formatting that carries no meaning (colors, fonts,
  alignment) is dropped on purpose.
- **Structure is preserved through headings.** A heading level in the
  document maps to `#` of the corresponding level; numbering isn't added by
  hand.
- **Tables become Markdown tables**, as long as they're rectangular. Markdown
  can't express merged cells: such a table is emitted as an HTML block, and
  this is recorded in `warnings`. Silently breaking the grid is worse than
  returning HTML.
- **Images inside documents become placeholder links**
  `![alt](filename)`, not base64. A base64 image in a prompt is tens of
  thousands of tokens of junk for something the model won't see anyway.
- **Text is not wrapped to a width.** Hard line breaks break pasting into
  editors that wrap the paragraph themselves.
- **Escaping.** Characters that mean something special in source text (`*`,
  `_`, `#`, `|`, `` ` ``) are escaped; this is the most common source of "why
  did the formatting break here."

These rules live in **one module** (`markdown_writer`) instead of being
repeated in every converter. There's a specific reason: in Amicus a
visibility rule drifted into four copies, two of which fell behind and became
holes — the same mistake here would produce converters that escape the same
character differently.

## Errors

A refusal is also a result, and it must be understandable: "failed to read
the file" is not a message. Three cases are distinguished, and they have
different texts and different UI actions:

| case | example | what we show |
|---|---|---|
| format not supported | `.sketch` | what format it is and what is supported |
| format supported, file corrupt | a truncated zip | that the file is corrupted, and where |
| limit exceeded | a zip bomb, 10,000 files in an archive | which limit exactly, and what its value is |

The raw exception text is never shown to the user — in Amicus that was fixed
with a separate bugfix after release; here it's built in from the start.

The sidecar fits into the same three cases, and its stderr is never shown at
all — it only lives in `ConversionDeclinedException.diagnostics` for the
developer:

| sidecar | case |
|---|---|
| code 2 | format not supported |
| code 3 | file corrupted |
| timeout (120 s by default, the process is killed with `SIGKILL`), output over the limit | limit exceeded — "sidecar processing time exceeded N s" |
| code 1, any other code, failed to start, invalid JSON with code 0 | file corrupted / failed to process (no details) |

Details of the fallback to the Dart converter are in "The sidecar — just
another converter" above.

## [4]–[5] Preview and clipboard

The preview shows **raw Markdown**, not rendered. The user is copying text,
and text is what they should see; a rendered version would create exactly
the "what I see" vs "what I get" mismatch that later makes it unclear who
broke the table.

**Two representations are placed on the clipboard at once**: `text/plain`
and `text/markdown` (on Windows, also `CF_UNICODETEXT`, which is the same
plain text). `Clipboard.setData` from `flutter/services` can only handle one,
so `super_clipboard` is used instead. Editors that understand `text/markdown`
get the markup; everything else gets exactly the same text as-is, so nothing
gets worse for anyone.

"Save as `.md`" writes UTF-8 **without a BOM** and with `\n` — including on
Windows: a BOM and `\r\n` in a Markdown file break more tools than they fix.

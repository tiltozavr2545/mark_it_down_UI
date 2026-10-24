# Format coverage

What markitdown can do, how we cover it, on which platform it works, and in
what state. The table is alive: it's a reference for the current state, not
a plan. The plan is in [implementation-plan.md](implementation-plan.md), the
pipeline's design is in [conversion-pipeline.md](conversion-pipeline.md).

**Statuses:** ✅ done · 🚧 in progress · 📋 planned · ⏸️ deferred ·
❌ not part of the product.

---

## Summary

The table is alive: five rows are marked ✅ as of Stage 1, six more as of
Stage 2, `pdf` as of Stage 3, `xls`/`msg` as of Stage 4, images (EXIF and
OCR), scanned PDFs and audio metadata as of Stage 6, Dart parsing of
`xls`/`msg`, RSS/Atom feeds and OCR for GIF/WebP/TIFF in 0.9, the rest is
still the target state.

| format | how markitdown does it | how we do it (Dart core) | sidecar | platforms | status |
|---|---|---|---|---|---|
| `txt`, `md`, `log` | `_plain_text_converter` | `dart:convert` + encoding detection | — | all | ✅ Stage 1 |
| `csv`, `tsv` | `_csv_converter` | `csv` + `markdown_writer.table` | — | all | ✅ Stage 1 |
| `json` | `_plain_text_converter` | `dart:convert`, ```json fenced block | — | all | ✅ Stage 1 |
| `xml` | `defusedxml` | `xml`, ```xml fenced block | — | all | ✅ Stage 1 |
| `html`, `htm` | `beautifulsoup4` + `markdownify` | `html` + `html2md` | — | all | ✅ Stage 1 |
| `docx` | `mammoth` + `lxml` | `archive` + `xml` (our own parsing of `word/document.xml`) | better on complex layouts | all | ✅ Stage 2 |
| `xlsx` | `pandas` + `openpyxl` | `archive` + `xml` (`sharedStrings` + sheets) | — | all | ✅ Stage 2 |
| `pptx` | `python-pptx` | `archive` + `xml` (slides + notes) | — | all | ✅ Stage 2 |
| `epub` | zip + html converter | `archive` + the Stage 1 `HtmlConverter` via `recurse` | — | all | ✅ Stage 2 |
| `ipynb` | `_ipynb_converter` | `dart:convert` + our own cell rendering | — | all | ✅ Stage 2 |
| `pdf` | `pdfminer.six`, `pdfplumber` | PDFium via our own FFI bindings, see below | better on tables (which we don't do), see the [reconciliation](#reconciliation-with-the-reference-stage-4) | all | ✅ Stage 3 |
| `xls` (BIFF8, BIFF5) | `xlrd` | our own CFB and BIFF parsing ([0.9 decisions](#09-decisions-xls-msg-rss)), sheet rendering shared with `xlsx` | goes first on desktop | all | ✅ Stage 4 (sidecar), 0.9 (Dart) |
| `doc` (OLE2) | — (not in markitdown either) | recognized as `.doc`, no converter | — | — | ❌ an honest "not supported" |
| `msg` (Outlook) | `olefile` | our own CFB parsing, output character-for-character matching markitdown | goes first on desktop | all | ✅ Stage 4 (sidecar), 0.9 (Dart); fixtures are synthetic |
| `zip` | `_zip_converter` | `archive` + recursion through the registry | — | all | ✅ Stage 2 |
| images: EXIF | `_exiftool` (external binary) | our own TIFF/EXIF parsing, size from the header; PNG, JPEG, GIF, BMP, WebP, TIFF, HEIC | — (exiftool is not bundled in the sidecar) | all | ✅ Stage 6 |
| images and scanned PDFs: OCR | via external OCR / LLM | Tesseract 5.5.1 via FFI, `rus+eng` (JPEG, PNG, BMP; GIF, WebP, TIFF — first frame via `package:image`; scanned PDF pages — rendered by PDFium) | — | all | ✅ Stage 6, 0.9 |
| images: LLM caption | `_llm_caption` → OpenAI | — | — | — | ❌ network |
| audio and video: metadata | `_audio_converter` (exiftool) | our own parsing: ID3v1/v2 + MPEG frames, FLAC, Ogg Vorbis/Opus, WAV, MP4/M4A/MOV/3GP | — | all | ✅ Stage 6 |
| audio: transcription | `SpeechRecognition` → **Google web API** | whisper.cpp 1.9.5 via FFI, small model (q8_0), multilingual; Silero VAD | — | all | ✅ 0.8 ([decisions](#transcription-decisions-08)) |
| PDF/documents via Azure DI | `_doc_intel_converter` | — | — | — | ❌ cloud |
| Azure Content Understanding | `_cu_converter` | — | — | — | ❌ cloud |
| YouTube | `_youtube_converter` + `youtube_transcript_api` | port: page metadata + captions via InnerTube ([decisions](#09-decisions-links)) | — | all, via link | ✅ 0.9 |
| Bing SERP | `_bing_serp_converter` | — | — | — | ❌ fragile parsing of someone else's search results |
| link to a page or file | `convert_uri` (`requests`) | `WebFetcher` (`dart:io`) → the same registry; type by `Content-Type`, name from `Content-Disposition` | — | all | ✅ 0.9 |
| Wikipedia | `_wikipedia_converter` | port: `#mw-content-text` without the "edit" buttons | — | all, via link | ✅ 0.9 |
| RSS / Atom | `_rss_converter` | port of `_rss_converter` on top of `xml` + `html2md` | — | all | ✅ 0.9 |

### Why four rows are marked ❌

This isn't "not done yet." LLM image captioning and both Azure converters
send document content to a third-party service — exactly what this product
was built to avoid — and on top of that they're paid (Azure has a free tier
with a monthly page limit); the author explicitly rejected them
(2026-10-15). Text from images and scans is covered by our own OCR instead.
Bing means parsing a search-results page: fragile (the results layout keeps
changing) and against Bing's terms. YouTube and Wikipedia were also here
before 0.9 — "they take a URL, not a file"; with the "link" mode they're now
done, see [0.9 decisions](#09-decisions-links) and
[offline-and-privacy.md](offline-and-privacy.md).

### Stage 1 decisions

- **`json`/`xml` are output as a fenced code block**, not turned into a
  markdown structure (tables/headings). Arbitrary JSON/XML doesn't fit into
  markdown without loss, and a fenced block is readable both for a human and
  for an LLM — and that's exactly how `markitdown` itself handles them in
  practice (`_plain_text_converter`, i.e. almost no transformation).
- **The `html` converter doesn't go through `markdown_writer`** — the whole
  conversion is delegated to `html2md`, the library chosen for this in
  [client-architecture.md](client-architecture.md). The rule "all markdown
  is assembled through one module" (see [../AGENTS.md](../AGENTS.md)) isn't
  violated here by accident: `markdown_writer` is mandatory where we build
  markdown ourselves (csv/tsv tables), not where a third-party library
  already does the conversion — reinventing HTML parsing just for
  consistency wasn't worth it.

### Stage 2 decisions

- **The `xlsx` table header is column letters (A, B, C…), not the first row
  of data.** Unlike `csv` (where the first row is almost always the
  header), on an `xlsx` sheet that's not guaranteed at all — passing off
  data as a header would be misleading. `docx` tables, conversely, take the
  first row as the header: that's the convention in most real-world
  documents.
- **Merged `xlsx` cells become a full HTML table, not a partial one.** The
  decision was already fixed in principle back in Stage 0/1; here it's the
  concrete implementation: `markdown_writer.htmlTable` with
  `colspan`/`rowspan`, the sheet is flagged with `warnings`.
- **A table nested inside a table (`docx`) collapses into flat text**,
  rather than recursive markdown — Markdown tables can't nest. For the same
  reason, formatting (bold/italic/links) inside cells isn't carried over:
  `markdown_writer.table` escapes cell content itself, and re-escaping
  already-rendered markup would break it.
- **`epub` chapters go through `request.recurse`, not a direct call to
  `HtmlConverter`.** This way a chapter is converted through the same
  registry as a top-level file — if a better HTML converter or sidecar for
  HTML shows up at a later stage, `epub` gets it for free, with no code
  change.
- **`zip` hard-fails on a nested file's `LimitExceededFailure`, `epub`
  doesn't.** For an archive, an exceeded limit means "it's unsafe to go
  further" for the whole file; for a book, one truncated/huge `.xhtml`
  shouldn't sink the entire rest of the book — `warnings` and the chapter is
  skipped, giving a partial result.
- **The recursion budget (`maxFilesInArchive`, total unpacked size) is
  shared across the whole zip-inside-zip tree, not per level** — otherwise
  an archive made of thousands of small nested archives would bypass the
  limit by staying "safe" at every single level. The total size is checked
  against the **actual number of bytes received after unpacking**, not the
  zip header — but unpacking a single file via the `archive` package isn't
  interruptible mid-way, so the protection isn't complete against a single
  zip-bomb file (see the comment in `zip_converter.dart`). For a project of
  this scale, that's a deliberate trade-off.

### Stage 3 decisions

- **PDF: PDFium via our own FFI bindings, not `syncfusion_flutter_pdf` and
  not the sidecar alone.** Three options were on the table at Stage 3 — see
  the background below. The decision was made by an architectural
  constraint, not taste: `core/` isn't allowed to import `flutter/` (checked
  in CI), and `syncfusion_flutter_pdf` is a Flutter package, so it simply
  can't live there. PDFium via `dart:ffi` is pure Dart, and works inside
  `Isolate.run` too (unlike a platform plugin like `pdfrx`, which can't be
  called from inside an isolate — the same reason mobile OCR can't be called
  from the pipeline, see
  [client-architecture.md](client-architecture.md#conversion-in-an-isolate)).
  This also sidesteps the licensing question: PDFium is used continuously in
  Chrome, and the license terms of its builds are BSD/MIT-like, with no
  commercial restrictions.
- **The bindings are our own, not a ready-made package.** At most ten
  functions are needed (`FPDF_LoadMemDocument`, `FPDFText_GetText`,
  `FPDFText_GetFontSize`, `FPDFPageObj_GetType` and a few neighbors) —
  reusing a heavy auto-generated binding just for these wasn't worth it. The
  native library itself isn't committed — it's downloaded by
  `pdfium/fetch.sh` (the same approach as `python-build-standalone` for the
  sidecar, see [python-sidecar.md](python-sidecar.md)), a non-V8/XFA build
  (`pdfium-mac-x64.tgz`/`pdfium-android-arm64.tgz`), which is a third the
  size of the V8 variant and isn't needed for plain text extraction.
- **Bundle-size measurement.** `libpdfium.so` (arm64, non-V8) weighs
  **6.3 MB** and takes up exactly that much in the APK — the Android Gradle
  Plugin stores `.so` files uncompressed (`Stored`, not `Deflated`) starting
  from `minSdk 23`, which is already our minimum anyway. On the arm64 build
  (`flutter build apk --target-platform android-arm64 --split-per-abi`)
  that's **25.1 MB out of 25.1 MB total** versus **≈18.6 MB** without PDF —
  so PDF support costs us almost a quarter of the APK size. The cost was
  accepted deliberately: PDF is the most common format after Office, and
  the alternative (sidecar only) simply wouldn't work on a phone at all.
- **Headings are determined by the font size of a line's first non-space
  character**, relative to the typical (most frequent, length-weighted) size
  in the document; if there's no text at all, there are no headings either,
  and all the text goes in flat. Adjacent lines with no vertical gap are
  merged into one paragraph rather than staying as separate lines — PDF
  wraps text to fit the page width, and preserving that wrap in Markdown
  would violate our own rule "text isn't wrapped to a fixed width"
  ([conversion-pipeline.md](conversion-pipeline.md#how-the-markdown-is-assembled)).
  The merge threshold has headroom (double the line's point size), because
  what PDFium reports as a character's "top" is the top of its bbox, not its
  baseline: a line starting with a letter with no ascender sits 1–2pt lower
  than one starting with a letter that has one, even with identical real
  line spacing. The comment in `pdf_converter.dart` sits right next to the
  code, with numbers taken from a real fixture.
- **A page with no text but with an image on it "looks like a scan"** — a
  warning by page ranges; a page with no text and no object at all is just
  a blank page, not a reason for a warning. The distinction is made via
  `FPDFPage_CountObjects`/`FPDFPageObj_GetType` against the fixed
  `FPDF_PAGEOBJ_IMAGE = 3` — part of PDFium's public ABI, a number that
  hasn't changed across releases.
- **Tables in PDF are not supported** — the decision was made earlier (see
  the plan), here it's simply implemented: PDFium gives us text and font
  size, but not table structure, and a heuristic for "which vertical lines
  are cell borders" is a separate task at the level of `pdfplumber`, not a
  one-evening job.

### Stage 4 decisions (client side)

- **`xls` and `msg` — sidecar only, there will be no Dart converters.** This
  is a plan decision, not an unfinished task: parsing BIFF8 and `.msg` MAPI
  properties isn't worth it for just two formats. On Android/iOS they
  remain "not supported" with the format name shown (`Excel 97–2003
  (.xls)`, `Outlook message (.msg)`), not a generic "OLE2 container."
- **OLE2 is distinguished by the Compound File directory, not by
  extension.** All four legacy Office formats share the signature
  `D0 CF 11 E0 A1 B1 1A E1`; `type_detection/ole2_directory.dart` reads only
  the directory entry names (directory sectors via the FAT chain, versions
  3 and 4, protection against looping chains). Legacy `.doc` and `.ppt` are
  now also recognized by name (`WordDocument`, `PowerPoint Document`), but
  there's no converter for them either in our code or in markitdown — an
  honest rejection with the format name shown.
- **If the sidecar fails, we fall back to the Dart implementation.** For
  `pdf`/`docx`/`xlsx`/`pptx`, where both implementations exist, any sidecar
  failure (including a timeout or garbage on stdout) doesn't cost us the
  result: the Dart converter kicks in, and the first line of `warnings`
  records that the sidecar failed. The rationale and mechanics are in
  [conversion-pipeline.md](conversion-pipeline.md#the-sidecar--just-another-converter).
- **Where the sidecar was used is visible in `warnings`**
  (`converterId: sidecar` with markitdown and Python version numbers), so a
  mismatch between a phone and a MacBook doesn't have to be guessed at.
- **`.xls`/`.msg` fixtures** — `xls/simple.xls`, `msg/simple.msg` and their
  `*.expected.md` siblings. The expected Markdown is the sidecar's output
  (there's no Dart converter for these), and the sources are generated by
  `sidecar/samples/make_samples.py`. `.msg` is synthetic (a minimal CFB
  writer inside the script itself, not Outlook): it exercises the
  `olefile` → `OutlookMsgConverter` path, but not attachments, ANSI
  encodings, or the RTF body of real-world messages. The
  `core/test/sidecar_integration_test.dart` test runs the real sidecar
  through the registry and is **skipped** if `MARKITDOWN_SIDECAR_DIR` isn't
  set (it isn't in CI). Core detection recognizes both file types by
  content, without relying on the extension: `.msg` is recognized by
  `__properties_version1.0`/`__substg1.0_*`. An empty
  `__recip_version1.0_#00000000` in the sample (which `olefile` doesn't
  enumerate) doesn't affect this; as in markitdown, the extension is only
  used as a fallback when the directory couldn't be read.

### Android didn't get fatter (Stage 4)

Item 6 of the stage plan. The sidecar doesn't end up on Android, and that's
verified by a build, not by confidence. Measured the same way as in Stage
3: `flutter build apk --target-platform android-arm64 --split-per-abi`
(release), with `libpdfium.so` already sitting in `jniLibs`; the emulator
wasn't launched. For a fair comparison, the Stage 3 build (commit
`9cf89ca`) was rebuilt on the same machine rather than taking the number
from memory.

| | Stage 3 | Stage 4 | difference |
|---|---|---|---|
| APK (arm64, release) | 25,136,199 B (**25.1 MB**) | 25,267,282 B (**25.3 MB**) | **+131,083 B** (≈128 KiB) |
| `libapp.so` (Dart AOT) | 5,702,560 B | 5,833,632 B | +131,072 B |
| `libflutter.so` | 11,277,384 B | 11,277,384 B | 0 |
| `libpdfium.so` | 6,563,456 B | 6,563,456 B | 0 |
| `classes.dex` | 531,672 B | 531,672 B | 0 |

The entire growth is in `libapp.so`, i.e. new Dart code: `SidecarConverter`,
reading the Compound File directory, `xlsx`/`docx` fixes from the
reconciliation. The other native libraries and `classes.dex` didn't change
by a single byte.

What was verified:

- **The APK contains nothing from the sidecar.** `unzip -l` for `python`,
  `run.py`, `manifest.json` (from the sidecar; the APK only has Flutter's
  own `AssetManifest.json`/`FontManifest.json`/`NativeAssetsManifest.json`),
  `site-packages`, `*.py`/`*.pyc`, `sidecar` — all empty. `assets/` only
  contains `flutter_assets` (a 1.8 KB icon font, a shader, `NOTICES.Z`) and
  `dexopt`.
- **`sidecar/` isn't wired in as an asset.** `app/pubspec.yaml` has no
  `assets:` section at all, and the sidecar isn't mentioned anywhere in the
  Gradle files under `app/android/`.
- **No `android.permission.INTERNET`.** `aapt dump permissions` returns a
  single permission — the internal androidx
  `<package>.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`. (As of 0.9,
  `INTERNET` is present — for the "link" mode; the measurement above is for
  Stage 4.)
- Version in the built APK: `versionName 0.4.0`, `versionCode 4`.

Why it couldn't be otherwise: on mobile, `SidecarConverter` simply doesn't
get registered (there's no sidecar directory there), and `sidecar/` holds
scripts and `dist/` that Flutter doesn't see unless they're named in
`pubspec.yaml`.

### Reconciliation with the reference (Stage 4)

Running every fixture that the sidecar handles through both the Dart core
and the real markitdown 0.1.8: **`make compare-sidecar`** (needs `make
sidecar`; not part of `make verify` — there's no sidecar in CI). The tool is
`core/tool/compare_sidecar.dart`; the report (a summary, `*.dart.md`,
`*.sidecar.md`, a line-by-line `*.diff`) lands in
`core/build/sidecar-compare/`, outside git. Only the shape is normalized:
line endings, trailing whitespace, trailing blank lines; `\f` and
everything else is left as is — that's exactly what counts as a
discrepancy. The Dart path runs through the registry without the sidecar,
the sidecar runs through a registry made of a single `SidecarConverter`
(falling back to Dart doesn't mask a failure).

**Rule:** the reference helps catch bugs, it doesn't dictate style. Every
discrepancy is one of: (a) a Dart core bug, now fixed; (b) a markitdown bug
or quirk that we deliberately don't replicate; (c) a stylistic difference
with no loss of meaning. There's no need to bend Dart to match markitdown
just for the sake of matching.

**(a) Fixed in the Dart core** (found specifically through reconciliation,
on fixtures that didn't exist before):

| format | before | now |
|---|---|---|
| `xlsx` | a package produced by openpyxl (and any writer with absolute `Target="/xl/worksheets/…"` in `.rels`) was read as **empty, with no warning at all**: the path was concatenated into `xl/xl/worksheets/…` | an absolute `Target` is trimmed relative to the package root; a sheet that fails to read produces a warning instead of silently disappearing |
| `xlsx` | dates came out as a serial number (`45352` instead of `2024-03-01`) | the cell style (`numFmtId` / custom format code) is used to recognize dates and times, output as `2024-03-01`, `2024-03-05 13:30:00`; accounts for `date1904` and the 1900 leap-year bug |
| `docx` | list items were separated by a blank line (a loose list: in Markdown renderers every item becomes its own paragraph, doubling the number of lines) | consecutive items form a tight list |
| `docx` | a nested item under a **numbered** parent was indented by 2 spaces, but `1. ` needs 3: CommonMark didn't treat it as nested | indentation matches the parent marker's width (`- ` → 2, `1. ` → 3, `10. ` → 4) |

**(b) A markitdown quirk or bug that we don't replicate** (treated as an
improvement):

| format | discrepancy | our choice | why |
|---|---|---|---|
| `xlsx`/`xls` | empty cells → `NaN`, empty dates → `NaT`, empty header → `Unnamed: N` | an empty cell is empty | an artifact of `pandas`: for a reader or an LLM, `NaN` reads as data that isn't actually in the file |
| `xlsx` | a merged cell: `Unnamed: 1` appears in the neighboring cell, the merge isn't marked anywhere | an HTML table with `colspan`/`rowspan` plus a warning | a Markdown grid can't express a merge; silently breaking it is worse |
| `xlsx` | booleans → `1.0`/`0.0`; integers in a column with decimals → `7.000` | `TRUE`/`FALSE`, the number as stored in the file | `pandas` coerces the whole column's type and distorts values |
| `xlsx` | `\|` in a cell isn't escaped — breaks the table; a line break in a cell becomes a literal `\n` | `\|` and `<br>` | `markdown_writer` escapes once, consistently for every converter |
| `xlsx` | an empty sheet → junk like `\|` and `\|  \|` | `*sheet is empty*` | — |
| `docx` | a table with no `<th>` gets an empty header row `\|  \|  \|`, the first row shifts into the data | the first row becomes the header | Stage 2 decision: that's how most real-world documents work |
| `docx` | a table nested in a table unrolls into one row with `\| --- \|` inside a cell — breaks the table | collapses into cell text via `<br>` | Markdown can't express nesting |
| `pdf` | no headings, lines wrapped to page width stay hard-wrapped (`two lines that⏎continue …`) | headings by font size, paragraph lines merged | Stage 3: wrapping to the printed page width is noise in Markdown |
| `pdf` | `\f` (form feed) between pages, three in a row on blank pages in `scanned.pdf` | `\f` is not output | it's a control character inside text; scanned pages get a warning instead |
| `pptx` | python-pptx rejects `pptx/no_sppr.pptx` (shapes missing the mandatory `<p:spPr>`, error code 3) | Dart tolerates it; the sidecar fails → falls back to Dart, which reads the file | see below |

**(c) Stylistic, with no loss of meaning**, left as is:

| format | discrepancy | our choice | why |
|---|---|---|---|
| `docx` | list marker `-` vs `*` | `-` | both are valid Markdown |
| `docx` | footnotes `[^1]` + `[^1]: …` vs `[[1]](#footnote-1)` + `1. … [↑](#footnote-ref-1)` | `[^1]` | more compact; the GFM extension doesn't render everywhere, but the footnote text still stays close by |
| `xlsx`/`xls` | the sheet's first row as header (`pandas`) vs column letters `A, B, C` + the data in full | column letters | Stage 2 decision: on a sheet the first row isn't necessarily a header, and passing off data as a header would be misleading |
| `xlsx`/`xls` | `0.500`, `2.000` (uniform decimal places per column) vs `0.5`, `2` | the value as stored in the file | `pandas` formats per column, Excel stores the cell's own value |
| `xlsx` | a date column that also has time values: `2024-03-01 00:00:00` for every row vs `2024-03-01` and `2024-03-05 13:30:00` | by the cell's own value | same reason |
| `xlsx`/`xls` | no blank line after `## Sheet` before the table | a blank line is present | consistent block assembly via `markdown_writer` |
| `pptx` | `<!-- Slide number: N -->`, slide title as `#`, notes as `### Notes:` vs `##` and `**Speaker notes:**` | ours | a slide is a section of the document, not the document itself; comments burn tokens |
| `pdf` | an empty PDF: warning "result is empty" vs "no text found in PDF" | ours | the Markdown is identical either way (empty) |

**Known core gap: tables in PDF.** For `pdf/table.pdf` (a ruled grid, three
columns, four rows) the sidecar produces a real Markdown table
(`pdfplumber`), while the Dart core produces the line `City Population
Country`, and merges the remaining three rows into a single paragraph
(a 24pt line pitch is below the "double point size" merge threshold). The
decision was made at Stage 3 ("no PDF tables"), and the reconciliation only
confirmed the cost; `pdf/table.expected.md` captures the **current**
behavior and will be updated once table support lands. That's why on
desktop the sidecar still goes first for PDF — but only up to 50 pages
(Stage 5, item 5: beyond that it's too slow, and such a PDF falls back to
Dart with a warning about tables), while on a phone a PDF table means lost
structure (the text itself is kept).

**`pptx/no_sppr.pptx`** used to be `pptx/simple.pptx`, hand-built for the
Dart parser: its shapes lack `<p:spPr>`, which is mandatory per the schema,
so real python-pptx can't open it (`InvalidXmlError`, code 3). It's kept as
a deliberately **malformed** fixture under an honest name, while
`pptx/simple.pptx` is now generated by python-pptx itself
(`make_samples.py`) and is valid. The Dart converter deliberately tolerates
such files: there are many presentation generators, some write non-strict
output, and a file the reference implementation can't open may still be
readable by our core — and when the sidecar fails, the registry falls back
precisely to that core (verified by the integration test).

**Fixtures added through reconciliation:** `docx/nested_numbered.docx`
(nested items under a numbered parent), `xlsx/types_and_gaps.xlsx` (dates,
booleans, gaps, `|` and line breaks in a cell, an empty sheet; openpyxl,
absolute `Target`), `pdf/table.pdf`, a valid `pptx/simple.pptx`,
`xls/simple.xls`, `msg/simple.msg`. Generated by
`sidecar/samples/make_samples.py`.

**Sidecar timing and the default timeout (120 s).** The fixtures are tiny
(the largest is 34 KB), so the measurement was done on synthetic input: a
multi-page PDF and a large sheet. Intel, macOS 12, a single call, a cold
process:

| input | sidecar | Dart core | sidecar RAM (peak) |
|---|---|---|---|
| any fixture (`pptx`, `pdf`) | 1.2 s | 2–550 ms | ~96 MB |
| 300-page PDF × 48 rows/page (1.8 MB, ~1.3 MB of text) | **111.6 s** | 1.2 s | ~117 MB |
| xlsx, 50,000 rows × 8 columns (2.4 MB) | **54.7 s** | 4.4 s | **~860 MB** |

The cold start measured was 1.2 s rather than the 0.65 s from
[python-sidecar.md](python-sidecar.md): the machine was busy with another
build at the time. Bottom line: the sidecar is 100–1000x slower on large
files (`pdfplumber` and `pandas`), roughly 0.37 s per dense PDF page.
**120 s is a reasonable ceiling, but not a margin:** 300 dense pages use up
93% of the timeout, and a bit more gets the call killed. For
`pdf`/`docx`/`xlsx`/`pptx` this isn't a disaster: the registry falls back to
the Dart converter (which finishes in seconds) with a warning "the sidecar
failed to process the file (120 s timeout exceeded)," but the person still
waits two minutes for nothing. For `xls`/`msg` there's no fallback, and the
timeout is an outright failure. The default is kept as is: it realistically
covers documents up to ~250 pages and tables up to tens of thousands of
rows; rarer cases are better served by the Dart core anyway. If tightening
it ever becomes necessary, the right move is to scale the timeout with file
size (not a single flat minimum) and show in the UI that a long-running
conversion is in progress. Separately: an 860 MB RAM peak on a 2.4 MB xlsx
— `pandas` unpacks the whole sheet into memory — is worth remembering when
setting limits for large tables.

---

### Reconciliation on Windows (Stage 5)

The same `compare_sidecar.dart`, but on `windows-2022` in CI (the
`windows-sidecar` job; the report is published as the
`sidecar-compare-windows-x86_64` artifact, with a summary in the run's job
summary), with the sidecar built on the same machine from
`sidecar/locks/windows-x86_64.txt`. **All 25 outputs — from both the Dart
core and the sidecar — matched the macOS Stage 4 run byte for byte**, even
though some dependency versions differ (`cryptography` 50.0.2 vs 48.0.1,
`onnxruntime` 1.20.1 vs 1.19.2, `pypdfium2` 5.14.0 vs 5.11.0: there are no
fresh wheels for Intel Mac, so the macOS lock stayed on older versions).
Windows didn't introduce any new discrepancies; the analysis above holds
for both platforms. The integration tests
(`sidecar_integration_test.dart`) are green on Windows too.

Sidecar timing on the runner is 0.65–1.1 s per fixture (a cold process on
every call) versus single-digit milliseconds for Dart: the same order of
magnitude as on Mac.

### Stage 6 decisions

- **EXIF — our own parsing, not the `exif` package.** The plan named
  `exif`, but it walks the IFD chain with a `while (i > 0)` loop that
  doesn't remember visited offsets: a file where "next IFD" points back to
  itself inflates the list until memory runs out, and `Isolate.run` can't
  be cancelled. The rest misses the mark too: strings are decoded as
  Latin-1 (`makeString`) or fall back to a `b'…'` representation, and it
  pulls in `args`/`sprintf`/`json_annotation` just to parse MakerNote,
  which we don't need. What's actually needed is ~20 tags from three
  IFDs — hence
  `core/lib/src/conversion/image/exif_reader.dart`: visited offsets, a cap
  of 1000 entries per IFD and 64 KB per value, every offset checked against
  the block length. The same reasoning as for our own PDFium bindings at
  Stage 3.
- **Where to look for EXIF** (`image_container.dart`): JPEG — the `APP1`
  segment with `Exif\0\0`; PNG — the `eXIf` chunk; WebP — the `EXIF` chunk
  (with and without the prefix); TIFF — the file itself; HEIC — **searching
  the content** for `Exif\0\0` plus a TIFF header, instead of parsing `meta`
  → `iinf` + `iloc`. HEIC size is the largest `ispe` inside `meta` (on an
  iPhone file there are also 512×512 tiles and a thumbnail). Both
  simplifications are documented in the code.
- **Strings — UTF-8, then Windows-1251**, same as text files
  (`decodeTextBytes`): the standard promises ASCII, but phones and Windows
  write UTF-8. `XPTitle`/`XPComment`/`XPAuthor`/`XPKeywords` (UTF-16LE,
  written by Windows Explorer's "Properties" dialog) are read: Windows is
  a target platform.
- **Output is a list of "field: value" pairs** in Russian, like the rest of
  the core's fixed strings ("Speaker notes"). markitdown with `exiftool`
  returns raw tag names (`DateTimeOriginal: 2024:07:14 …`); we return
  human-readable ones ("Taken: 2024-07-14 …") — the sidecar isn't the
  reference here, since `exiftool` isn't bundled with it, and without it
  markitdown returns nothing for an image. Default camera captions
  (`OLYMPUS DIGITAL CAMERA`, `SONY DSC`) are dropped; `0, 0` in GPS means
  "no satellite fix" and isn't written out.
- **Warnings.** A geolocation in the result gets its own separate warning:
  the text is going into a chat, and home coordinates aren't what someone
  expects to find in "photo metadata." Corrupt EXIF is a warning, not a
  failure: the format and size are already known. If text recognition
  wasn't attempted (OCR unavailable or wrong format), that's stated
  explicitly: otherwise someone who dropped in a photo of a document
  wouldn't understand why there's no text.
- **Images and audio never fail outright.** If the signature is recognized,
  there's at least a format to report. This is checked by
  `media_robustness_test.dart`: every image and audio fixture, truncated
  and with corrupted bytes, still produces a result rather than a
  `ConversionError`.
- **Fixtures** — `sidecar/samples/make_samples.py --only image` (Pillow
  from the sidecar; HEIC via the system `sips`, macOS only), including a
  malicious `evil_loop.jpg`: an IFD with a loop, an offset past the end of
  the block, and a GPS IFD claiming 65535 nonexistent entries.

- **Audio — also our own parsing, for the same reasons.** What's needed is
  duration, audio parameters, and a dozen tags; the parsing lives in
  `core/lib/src/conversion/audio/`. MP3: ID3v2.2–2.4 (synchsafe sizes,
  unsynchronisation, extended header, `COMM`/`USLT`) + ID3v1 + the first
  MPEG frame (two valid headers in a row — otherwise junk starting with
  `0xFFE…` would pass as a frame); duration from Xing/Info/VBRI, or from
  file size for CBR. FLAC — `STREAMINFO` and the Vorbis comment; Ogg —
  packets from pages, duration from the granule position of the last page
  (for Opus, at 48 kHz minus pre-skip); WAV — `fmt `/`data`/`LIST INFO`;
  MP4/M4A/MOV/3GP — `mvhd`, tracks (`hdlr`), `stsd`, `ilst` tags. Video in
  MP4 gets its frame size almost for free.
- **"Latin-1" in tags is almost always Windows-1251** (`decodeLegacyText`):
  valid UTF-8 → Windows-1251 if there are three or more consecutive bytes
  that look like Cyrillic letters → otherwise Latin-1. `Motörhead Café`
  stays Latin (fixture `audio/legacy.mp3`).
- **Lyrics (`USLT`, `LYRICS`) get their own section**: that's genuine text,
  the very reason someone might drop the file into the window in the first
  place. iTunes housekeeping comments (`iTunNORM`, `iTunSMPB`) are dropped.
- **`ftyp` doesn't mean HEIC.** MP4, M4A, MOV and HEIF all share the `ftyp`
  box; the distinction is made by brand (`heic`/`mif1`/`avif` → image,
  everything else → media). Messenger voice notes (`isom` with a single
  audio track) are labeled "MP4 (audio)," not video.
- **OCR — Tesseract on both platforms, not ML Kit** (the author's decision,
  2026-10-11). The plan proposed ML Kit on mobile, but ML Kit Text
  Recognition **doesn't know Cyrillic** (Latin, Chinese, Japanese, Korean,
  Devanagari) — useless for Russian documents. Tesseract gives us a single
  engine and a single result on both Windows and Android, `rus+eng`.
- **Via FFI from `core/`, not as a plugin** — same as PDFium. A platform
  plugin can't be called from the conversion isolate, but FFI works there,
  so OCR is wired directly into `ImageConverter` and `PdfConverter`: a
  scanned page is rendered by PDFium (300 dpi, BGRx, long side ≤ 5000 px)
  and handed to Tesseract as a pointer into the buffer, with no copy. The
  bindings are our own, on the C API (`TessBaseAPI*`) plus five Leptonica
  functions (`pixReadMem`, `pixRotateOrth`, `pixScale`, …).
- **Where the libraries come from.** Android — the `.so` from the
  Tesseract4Android 4.9.0 AAR (Tesseract 5.5.1, exports the C API; ≈7.5 MB
  on arm64; LOAD segments aligned to 16 KB, as required by Android 15).
  Desktop — `tesseract/build.sh` built from source, same version: the
  vcpkg port and the UB Mannheim installer both pull in **libcurl**
  (Tesseract can fetch an image by URL), and we don't put a networking
  library into a no-network product. The build uses `DISABLE_CURL`,
  `DISABLE_ARCHIVE`, no `Ws2_32` (which Tesseract's CMake links
  unconditionally on Windows for a debug ScrollView), plus a final check
  that no library references anything networking-related.
  `ENABLE_NATIVE` is off: a CI build must run on any x86-64 machine.
- **Models — `tessdata_fast` rus + eng (≈8 MB), pinned by commit and
  sha256** (`tesseract/versions.sh`), shipped as app assets: on Windows
  they sit as files next to the `.exe`, on Android they're copied from the
  APK into the app's directory on first OCR use
  (`app/lib/src/conversion/ocr_data.dart`). `tessdata_best` is 4–5x
  heavier for almost the same quality on printed text.
- **What the person gets.** For an image: a "Text in image" section after
  the metadata; a sideways shot is rotated according to the EXIF
  `Orientation`; a photo larger than 5000 px is downsized. For a PDF: the
  recognized text takes the place of the scanned page. `warnings` always
  states the engine and version ("recognition errors are possible"), and
  when average confidence is below 60 out of 100 it adds "please check the
  text." PDF-page OCR is capped at 20 pages
  (`OcrSettings.maxPdfPages`): `Isolate.run` can't be cancelled, and a page
  takes seconds even on a phone.
- **OCR text lines are merged into paragraphs**, same as for PDF (text
  isn't wrapped to a width); a hyphenated word break (`hyph-` / `enated`)
  is merged without the hyphen. The cost: `some-` / `thing` across a line
  break becomes `somethinelsewhere` — i.e. the hyphen is simply dropped at
  the join.
- **OCR only covers JPEG, PNG and BMP.** That's what Leptonica decodes in
  both builds (on Android without libtiff/libwebp/giflib; on desktop we
  don't build them either, to avoid piling on dependencies). GIF, WebP,
  TIFF, HEIC get metadata and an honest "recognition isn't supported for
  this format."
- **The sidecar yields to PDF-with-scans handling when OCR is available**
  (`SidecarConverter.scannedPdfToDart`). Otherwise, on Windows, a scanned
  PDF of up to 50 pages would have gone to the sidecar (the Stage 5, item 5
  decision), pdfminer would have returned emptiness as a "success," and OCR
  would never have run at all. The cost: tables on text pages of such a PDF
  are extracted as plain text; a warning notes this.
- **OCR tests compare phrases, not a byte-for-byte reference**
  (`ocr_test.dart`): the output depends on the engine version, and on CI
  Linux, Tesseract is the distro package (5.3), not our build. Fixtures
  that involve OCR are run without OCR as part of the general suite
  (`conversion_fixtures_test.dart`) — their output doesn't depend on the
  engine. Fixtures come from `make_samples.py --only ocr` (Arial on macOS,
  text containing "№", "ё" and guillemet quotes).

### Transcription decisions (0.8)

The author's request after 0.7 — "add faster-whisper" — with
clarifications: Russian, Italian and English; Windows and Android; the
small model; bundled in, not a separate package.

- **Why not markitdown's built-in path.** markitdown transcribes via
  `SpeechRecognition`, which by default calls **Google's web API**:
  "markitdown can do audio" and "markitdown can do audio offline" are two
  different claims, and only the first one is true. The sidecar doesn't
  give us this, and never will.
- **whisper.cpp, not faster-whisper.** faster-whisper is Python
  (CTranslate2 + PyAV), and Python only exists in the desktop sidecar:
  there's no Python on Android and there never will be (see "Environment
  constraints" in [../AGENTS.md](../AGENTS.md)). whisper.cpp is C/C++, the
  same approach as Tesseract: our own build (`whisper/build.sh`), FFI from
  `core/`, one engine on both Windows and Android — and identical results
  on both. faster-whisper is faster on CPU, but maintaining a second
  implementation for a single platform means double the maintenance and
  inconsistent results. Version 1.9.5 (the latest at the time of 0.8, at
  the author's request: a patch release, with fixes almost entirely in the
  GPU backends).
- **Our own C shim `whisper/shim/` (`mdw.h`), rather than FFI straight on
  `whisper.h`.** `whisper_full_params` is a struct with about a hundred
  fields that changes between versions; mapping its layout in Dart would
  silently read garbage after the next update. The shim fills in the
  parameters in C against the header of the version it was built with, and
  exposes a dozen functions with simple types to Dart.
- **Model — `ggml-small-q8_0.bin`, 264 MB, multilingual.** Small is the
  first model that understands Russian decently (tiny and base make
  noticeably more mistakes on it); Whisper recognizes Italian and English
  even more accurately than Russian. q8_0 is the same weights quantized to
  8 bits: half the size of f16 (488 MB) with almost no quality loss, and
  faster on CPU. Not `small.en` — that one is English-only. The language is
  auto-detected from the first 30 seconds of speech; the model and its
  commit on Hugging Face are pinned with sha256 in `whisper/versions.sh`.
- **Silero VAD (0.9 MB).** Whisper "finishes" text on silence that was
  never actually spoken: "To be continued…", "Subtitles by …". VAD trims
  silence before recognition — and speeds it up at the same time. Plus
  `suppress_nst`: no "[music]" or musical notes ending up in the
  transcript.
- **Greedy search, not beam search.** whisper-cli defaults to 5 beams —
  twice as slow, and on a phone's CPU the difference is "minutes" vs "tens
  of minutes." For an uncertain window whisper itself retries it with a
  different temperature.
- **CPU backend — a dozen variants, chosen at startup**
  (`GGML_BACKEND_DL` + `GGML_CPU_ALL_VARIANTS`). A build targeting AVX2
  crashes the whole app ("illegal instruction") on a CPU without AVX2 —
  and that still includes 2020s Pentium/Celeron chips — while a plain SSE
  build is several times slower on everything else. Variants: x86-64 from
  SSE4.2 up to AVX-512/AMX, arm64 from armv8.0 up to armv9.2 (SVE2, SME);
  ggml loads the best one the CPU can run (`ggml_backend_score`). On
  Windows they sit as files next to the `.exe` and are enumerated from the
  directory; on Android, `.so` files inside the APK aren't unpacked to
  disk, so the shim tries them by name, starting from the most capable
  (`mdw_init`). No OpenMP — our own ggml thread pool instead: otherwise
  Windows would need `vcomp140.dll`, and Android would need `libomp.so`.
- **Audio decoding — portable everywhere except AAC.** Whisper expects
  16 kHz mono float; WAV, MP3, FLAC and Ogg Vorbis are decoded by
  miniaudio (dr_wav/dr_mp3/dr_flac + stb_vorbis), Ogg Opus (messenger voice
  notes) by our own Ogg page parsing + libopus. The same code runs on
  Windows, Android and the test host. **AAC** (M4A from voice recorders,
  audio in MP4) uses the platform decoder: Media Foundation on Windows,
  NDK MediaCodec on Android. There's no freely licensable AAC decoder that
  fits our license, while the platform always has one — at zero size cost.
  VLC was considered (the author raised the question) and doesn't fit: it's
  a player weighing tens of megabytes with networking modules (http, rtsp,
  UPnP), and its AAC support comes from FFmpeg anyway. If a single AAC
  decoder across all platforms is ever needed, the right pick is a minimal
  FFmpeg build with only `aac` and `mov` (≈1–2 MB, LGPL, no networking),
  not VLC.
- **Media Foundation picks a handler by extension.** A voice note with no
  extension, or the wrong one, won't open — so for the platform decoder the
  file is written to a temp file with an extension inferred from the
  signature (deleted in a `finally`), and `localPath` is only used once
  the extension is confirmed correct.
- **Media Foundation is loaded dynamically**, from System32, rather than
  via a DLL import: on Windows "N" editions without the Media Feature Pack,
  and on Windows Server without the Media Foundation component,
  `mfplat.dll` doesn't exist, and a static import would have prevented all
  of `markitdown_whisper.dll` from loading — killing all transcription, not
  just AAC. This way M4A there gets "codec not supported," while everything
  else still gets recognized.
- **Media Foundation's output format is re-read as it goes.** The AAC
  decoder refines sample rate and channel count from the first frame
  (`MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED`); the first version kept the
  header's numbers and assumed float output without checking — M4A in CI
  "decoded" into noise with an empty transcript. The format is now re-read
  on change, and 16-bit PCM is also understood.
- **Progress and cancellation via shared memory, not messages.**
  `Isolate.run` can't be cancelled (see "Pitfalls" in
  [../AGENTS.md](../AGENTS.md)), and the isolate is busy inside
  `whisper_full` and isn't receiving messages. So `mdw_control` is two
  `int32`s in native memory: the main isolate writes `cancel` and reads
  `progress` roughly twice a second; whisper checks `cancel` before every
  30-second window and inside the graph computation. A stopped run returns
  whatever's already been recognized with a "transcript is incomplete"
  warning. The transcript is only marked "incomplete" if whisper actually
  stopped because of the flag: pressing "Stop" after the last window
  doesn't taint the result. The percentage comes from the file's own
  duration metadata; if that's missing, there's no percentage, just
  "Recognizing speech…".
- **No duration limit — audio is transcribed in 10-minute chunks
  (0.8.1).** In 0.8 there was a 180-minute cap: whisper.cpp holds the whole
  audio, its post-VAD copy, and the mel spectrogram of the entire file in
  one call — ≈0.6 GB per hour of recording plus 264 MB for the model, and
  Android doesn't turn a native out-of-memory into an exception, it just
  kills the process. Now `mdw_transcribe_*` decodes and recognizes
  simultaneously: a sink (`mdw_sink`) accumulates 10 minutes of samples,
  hands them to `whisper_full`, and keeps accumulating — memory for the
  audio stays ≈100 MB regardless of recording length. A chunk is cut at
  the quietest point in the last 15 seconds (0.1 s windows), so as not to
  cut a word in half; a test runs a phrase repeated six times across the
  boundary — all six come through intact. Segment timestamps are shifted
  to the start of the chunk. When `auto`, the language is detected from the
  first chunk containing speech and then fixed for the rest — one language
  per file, as before. whisper.cpp already doesn't carry context between
  windows (`no_context` by default), so the chunk boundary doesn't cost
  anything there. The model loads on the first chunk: a file that never
  decodes never triggers a model load. What remains unchanged: the whole
  file still sits in memory (a 0.7 decision) — plus its native copy, for
  the duration of recognition, for portable decoders.
- **Android: the model is copied from the APK to disk** on the first audio
  file (not at startup — someone converting a PDF shouldn't wait for a
  265 MB copy). The cost: the model exists twice on disk (≈530 MB
  combined), and the copy step reads it entirely into memory
  (`rootBundle.load`). Reading straight from the APK is only possible via
  `AAssetManager` (JNI, i.e. a plugin or Java code) — unusable for FFI from
  an isolate. To avoid re-reading 265 MB on every launch just for
  comparison, a manifest `models.json` sits next to the models (name,
  size, sha256 — written by `whisper/fetch.sh`), and the copy is named by
  its hash.
- **Networking.** whisper.cpp is built without `WHISPER_CURL` (downloading
  a model by URL) and without `GGML_RPC` (networked backend); `build.sh`
  finishes by grepping the build output for
  `libcurl`/`ws2_32`/`winhttp`/`wininet`, same as for Tesseract.
- **Risk: native decoders running in the app's process.** A corrupt file
  that crashes the decoder brings down the whole app, not just the
  conversion — same as with PDFium and Leptonica. dr_mp3/dr_flac/dr_wav and
  libopus are fuzzed upstream; stb_vorbis has historically been the
  weakest against malicious input — if that ever surfaces, it can be
  swapped for libvorbis. The `speech_test.dart` test runs truncated files
  through every decoder.
- **Tests compare words, not a byte-for-byte reference**
  (`speech_test.dart`), same as for OCR: the text depends on the engine
  version and even on the CPU backend variant. The `speech/` fixtures are
  synthesized speech (macOS `say`: Milena, Samantha, Alice), a 22 kHz WAV
  that also exercises the resampler; English and Italian additionally get
  50-second recordings across four voices with fast speech at the end
  (`en_long.flac`, `it_long.flac`). The 0.8 measurement on these recordings
  (12 files, including fast speech and white noise at ≈10 dB): the language
  was detected correctly every time; English WER was 0%, Italian 0–7%
  (errors were "ha" → "a", "caldaia" → "caldàia", "ti mando" →
  "stimando" on fast speech). Synthesized speech is cleaner than real
  speech, so this is a ceiling, not an expectation. **AAC is only tested in
  CI on Windows** (Media Foundation is available on the `windows-2022`
  runner): M4A transcription plus a direct decoder test — duration,
  loudness, peak. On Linux and macOS there's no AAC decoder — there, the
  honest warning is what's checked, and the test is marked skipped rather
  than passing. The Android path (MediaCodec) is manual-verification-only,
  on a real phone.
  The general fixture suite (`conversion_fixtures_test.dart`) runs without
  transcription.

### 0.9 decisions (xls, msg, RSS)

The author's request after 0.8 — "everything plain markitdown can do." What
was previously honestly unsupported on Android has now been implemented in
the Dart core.

- **`xls` and `msg` — our own OLE2 parsing (`ole2/compound_file.dart`), not
  a package.** There's no maintained CFB reader on pub.dev, and not much
  is actually needed: the directory as a tree, the FAT, the mini-FAT, and
  stream reading. Sector chains and the directory tree can't be trusted,
  same as a zip header — each is walked with a step limit
  (`ole2_robustness_test.dart` truncates and corrupts fixtures).
- **BIFF — only what the table needs** (`xls/biff_workbook.dart`): the SST
  with `CONTINUE` continuation (a break mid-string starts with a fresh
  flag byte — a compressed string can switch to UTF-16), `NUMBER`/`RK`/
  `MULRK`, `LABEL`/`LABELSST`, `BOOLERR`, the cached `FORMULA` value
  (+ `STRING`), `MERGEDCELLS`, dates via `FORMAT`/`XF`/`DATEMODE`. Excel 95
  (BIFF5, the `Book` stream) is read using the workbook's code page
  (`CODEPAGE`). A password (`FILEPASS`) and BIFF2–4 get a clear rejection.
- **An `xls` sheet looks like an `xlsx` sheet** — the rendering is shared
  (`spreadsheet/sheet_markdown.dart`): the header is column letters, merges
  become an HTML table. This is the same discrepancy from markitdown
  (pandas: first row as header, empty cells as `NaN`) as with `xlsx`; `make
  compare-sidecar` found no discrepancies in cell content (120 SST rows,
  some split across `CONTINUE`, all matched `xlrd`).
- **`msg` replicates `OutlookMsgConverter` character for character**: From
  is the sender's address, To is the recipient string, Subject;
  PT_UNICODE, otherwise PT_STRING8 in the message's own code page; the
  same output normalization (`normalizeLikeMarkitdown`). The one thing
  beyond markitdown: a message with no plain-text body returns the HTML
  body instead of an empty section. A body that only exists as RTF isn't
  read — same as markitdown.
- **On desktop the sidecar still goes first for `xls`/`msg`** (an author's
  decision from Stage 5): the Dart parser there is a fallback path.
  Removing them from `SidecarConverter.appFormats` is again the author's
  decision to make.
- **RSS/Atom — a port of `_rss_converter`**: the same fields, the same
  Atom-type rules for `text`/`html`/`xhtml` and `xml:base`, a feed is
  recognized even without an extension (by its `<rss>`/`<feed>` root
  element). Entry HTML goes through `html2md`, same as
  [`html`](#stage-1-decisions) — which is why headings there come out as
  setext-style and lists as `*   `: the structure matches markitdown, the
  styling matches the rest of HTML output in the app. An `xml` file with a
  feed-like root that turns out not to be a feed falls through to the
  regular XML converter (which has lower priority).
- **OCR for GIF/WebP/TIFF via `package:image`**, instead of rebuilding
  Leptonica with giflib/libwebp/libtiff on two platforms: the first frame
  is decoded by Dart and re-encoded as PNG for the same pipeline.
  Transparency is composited onto white — a WebP sticker's transparent
  background is "black," and black text on it would otherwise disappear.
  HEIC isn't decoded by either Leptonica or `package:image` — there, it's
  still metadata only.
- **`archive` 3 → 4** — together with `image` 4.12, which requires
  `archive` 4. Version 4 doesn't throw on a corrupt zip, it returns an
  empty archive instead, so `decodeZip` (`zip_family.dart`) treats an
  empty archive as corrupt whenever the file doesn't start with the
  end-of-central-directory signature (`PK\x05\x06`).

### 0.9 decisions: links

The author's request — "everything markitdown can do, … allowed with an
internet connection"; the answer to "how do we let networking in" was
"only via an explicit link."

- **Like markitdown's `convert_uri`: link → bytes → the same registry.**
  The type comes from `Content-Type` and the content itself, the name from
  `Content-Disposition` (`filename*` per RFC 5987 too) or from the path if
  it looks like a file (`report.pdf`, but not arXiv's `1706.03762`). The
  address is kept in `StreamInfo.url`: YouTube and Wikipedia use it to
  recognize their own pages, and HTML and feeds resolve relative links
  against it. In the app, a link is downloaded first (`downloadUrl`), then
  goes through `accept` just like a file — so audio by link gets the same
  recognition progress and "Stop" button.
- **`dart:io`, not the `http` package.** Networking lives in a single
  module (`core/lib/src/web/`), keeping the "no networking packages" check
  intact — a package would mean networking bypassing that module.
- **An honest `User-Agent`** (`MarkItDownUI (+link to the repository)`),
  not a fake "Chrome": a spoofed browser missing the rest of a real
  browser's headers gets a 403 from w3.org as a bot, Wikipedia's own rules
  ask for a descriptive UA, and YouTube serves the page either way
  (verified 2026-10-15).
- **HTML — only `<body>`, no `script`/`style`** — same as markitdown's
  `HtmlConverter`. Before 0.9, text from `<title>` inside `<head>` leaked
  into the result as an extra line, and on pages fetched from the network,
  CSS leaked in too; the `html/article` and `epub/simple` reference files
  had these duplicates removed. Relative links and images are resolved
  against the page's own address, Cyrillic in them is decoded
  (`/wiki/Грубер`, not `%D0%93…`), while structural ASCII characters stay
  encoded. Anchors (`#cite_note-1`) are left as is. Encoding comes from the
  response's `charset`.
- **YouTube — the same layout as markitdown's** (`# YouTube`, `##
  <title>`, `### Video Metadata`, `### Description`, `### Transcript`).
  View count comes from `videoDetails.viewCount` when the page has no
  `interactionCount` (currently it doesn't). markitdown gets captions via
  `youtube_transcript_api`; here it's the same path done by hand:
  `INNERTUBE_API_KEY` from the page → `POST /youtubei/v1/player` from the
  ANDROID client (the web client's caption links don't work without a
  token) → an XML track, with entities double-escaped inside it. Track
  priority: a manual track in the video's own language (the language used
  for the automatic track — YouTube recognizes speech in the original
  language), then a manual Russian track, then English, then the automatic
  track — markitdown picks the English one. The `SOCS=CAI` cookie means
  "decline non-essential," needed because otherwise a consent page shows
  up instead of the video page in Europe. A caption failure is a warning;
  the description is still returned.
- **Wikipedia — `#mw-content-text` under the article title**, same as
  markitdown, plus removal of the "[edit | edit source]" buttons.
- **Download limit — 1 GB** (same as for an unpacked archive), timeout —
  30 s for the connection and for each subsequent chunk of the response:
  otherwise an infinite stream would eat up memory.
- **Verified live** (2026-10-15, from the developer's machine): YouTube
  with English and with Russian automatic captions, `ru.wikipedia.org`, a
  PDF via a direct link, a Habr RSS feed, `example.com`, an arXiv page. In
  tests, the network is a local server plus a stubbed `WebFetcher`
  (`web_test.dart`).

## Open items

### OCR: what's left

Resolved at Stage 6 (see "Stage 6 decisions" above): Tesseract on both
platforms. Still open:

- **phone speed hasn't been measured** — on a Mac (Intel, 2019), a 1400 ×
  420 image is recognized in 0.3 s once models are loaded (≈2 s on the
  first call), an A4 page at 300 dpi takes about a second — a manual check
  is needed on the author's phone;
- **handwriting and poor-quality photos** are read poorly by Tesseract —
  this is an engine limitation, and a low-confidence warning won't fix it;
- **HEIC** has no OCR (GIF, WebP and TIFF got it in 0.9, see "0.9
  decisions"); HEIC is the most common photo format from an iPhone, but
  isn't the primary one on Android or Windows.

### Transcription: what's left

Resolved in 0.8 (see "Transcription decisions" above). Still open:

- **phone and Windows speed hasn't been measured** — needs a manual check
  by the author; on a Mac (Intel i7-6567U, 2 cores, AVX2), a 6-second
  phrase takes ≈15 s including model loading, a long recording runs at
  ≈0.4–0.5x real time;
- **one language per file** — a conversation mixing Russian with Italian
  is recognized worse; there's no manual language selector in the UI
  (though `TranscriptionSettings.language` supports one);
- **audio inside an archive** is recognized without speech transcription
  (metadata only): the app only passes recognition settings for a
  top-level audio file — otherwise a zip full of fifty voice notes would
  mean an hour of work with no progress indicator;
- **size**: the APK grew by ≈270 MB. The Play Store's 200 MB limit doesn't
  apply: we don't publish to Google Play, the APK ships via GitHub
  Releases.

---

## Reference files

Every format declared supported must have a "source + expected Markdown"
pair under `test/fixtures/`. This isn't a ritual: we have **two
implementations** (the Dart core and the sidecar), and the only way to
notice them diverging is to run both against the same set. The rule and the
process are in "Working conventions" in [../AGENTS.md](../AGENTS.md).

A set of **malicious** files is also needed, separately, and it matters
more than the well-behaved ones: a zip inside a zip, a `.docx` renamed to
`.pdf`, Windows-1251 text with no BOM, an `xlsx` with merged cells, a PDF
made of scans, a zero-length file, a file with no extension. Each of these
rows is a piece of behavior that someone had to decide on ahead of time.

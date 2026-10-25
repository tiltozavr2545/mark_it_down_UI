# Changelog

Version history of MarkItDown UI. Split out from [AGENTS.md](AGENTS.md) so
that file doesn't have to load in full into context every session — this
one is read on demand.

For the **why** behind a decision, look not here but at the comment next
to the code, or at `git log`. Here you'll find the timeline and what
appeared in which version.

Version format is `name+build` (`0.1.0+1`), with `build` increasing
monotonically. Bumped in every PR, see "Working conventions" in
[AGENTS.md](AGENTS.md).

---

## 0.10.0 — merging files into one `.md`

Author's request: "glue files into one md, a couple of PDFs and so on."

**How it starts.** Choose several files in the dialog, drop several onto
the window, or "Share" several on Android — they go straight into a merge
list. A single file opens as before, and its result now has an "Add
files" button that starts a merge with it. If a file or link arrives by
drop or "Share" while a result or the list is on screen, the app asks
whether to add it or start over.

**The list.** Each file is converted as soon as it's added, one at a
time — that's the check that it isn't corrupted. A file that fails shows
its error in its row, and "Merge" stays unavailable until it's removed:
an error stops the merge rather than leaving a gap in it. Order is
changed by dragging; links (pages, YouTube, Wikipedia) and audio with
speech recognition (percentage and "Stop" in the row) go in like files.

**The result.** Each file under a `# name` heading (a page by link: a
heading linking to it), files separated by `---`, each file's own
Markdown untouched. Warnings are prefixed with the file they came from.
"Save as .md" suggests `<first file>_and_N_more.md`.

## 0.9.0 — everything markitdown can do, plus links

Author's request: "do everything regular markitdown can do, … internet
access is fine." The network is reached only via an explicit link;
LLM-generated captions, Azure, and Bing search are not implemented.

**Offline, on all platforms.** `xls` (Excel 97–2003 and Excel 95) and
`msg` (Outlook) now open on Android too — via a homegrown Dart-core
parser; on Windows, the bundled markitdown still goes first, with the
Dart parser as a fallback if it fails. A message now looks exactly like
markitdown's output, character for character; a message with only an
HTML body is no longer empty. RSS and Atom feeds (`.rss`, `.atom`, `.xml`,
and no extension) — channel, entries, dates, entry text. Text is now also
recognized on GIF, WebP, and TIFF images, including on a transparent
background (stickers).

**Links.** A "Paste link" button (fills in the link from the clipboard),
and on Android also "Share" a link from YouTube or a browser. A YouTube
video gives title, view count, description, and subtitles (manual ones in
the video's language are preferred over automatic ones); a Wikipedia
article gives just the article text; any page comes through with no
scripts or styles, and its links are made absolute; a link to a file
(PDF, docx, audio…) is handled like the file itself, with on-device speech
recognition and OCR.

**Privacy.** The Android build now has the `INTERNET` permission — for
links. Files still never leave the device: all networking code lives in a
single module, and CI checks on every commit that there's no networking
outside it.
Details — `docs/offline-and-privacy.md`.

Also: plain HTML output no longer gets an extra line from `<title>`
leaking into the result; `archive` 4 and `image` 4.12. Tesseract4Android
(the `.so` used for OCR on Android) disappeared from JitPack — the build
now downloads the same file (same sha256) from this repository's own
`deps-tesseract4android-4.9.0` prerelease.

## 0.8.2 — GitHub Releases only

Author's decision: the app isn't published to Google Play, only
distributed via GitHub Releases. Docs updated to match: Play Asset
Delivery for the speech model was removed (a GitHub APK has no 200 MB
cap), and the Android build produces an APK, not an `.aab`. The main
remaining release item is now a persistent APK signing key, so a new
version installs over the old one. No code changes.

## 0.8.1 — transcription with no duration limit

Following a review of 0.8. A transcription no longer disappears entirely
because of a single character split between chunks (which can happen with
Cyrillic): the broken character now becomes `�`. Dropping a new file
while transcription is running now stops the old transcription, instead
of letting it keep running in the background for minutes or silently
swapping out the result. "Stop" now also works before transcription
starts — while the audio is still decoding and the model is loading — and
pressing it at the last moment no longer marks a complete transcript as
incomplete. The Windows build now fails if any of the required
speech-recognition DLLs is missing, not just when all of them are.

There's no longer a duration limit — not on Windows, not on Android (it
was 180 minutes in 0.8). Audio is transcribed in 10-minute chunks as
decoding proceeds, so memory no longer grows with recording length: an
hour-long recording used to cost ≈0.6 GB, now a chunk costs ≈100 MB
regardless of overall length. A chunk is cut at the quietest point so as
not to split a word; timestamps in the transcript and the detected
language stay consistent across the whole file. "Stop" now also halts
decoding. The percentage is computed from the duration in the file's
metadata; if that's missing, there's no percentage shown.

## 0.8 — speech recognition

Audio is no longer just metadata: speech is now transcribed on-device,
with no network — whisper.cpp 1.9.5 with the Whisper small model
(8-bit, 264 MB), the same on Windows and Android. The model is
multilingual: Russian, English, Italian, and about ninety other
languages; the language is auto-detected and written into the result
("Speech language"). The transcript appears under a "Transcript" section,
as paragraphs with a start timestamp; the warnings note the engine and
ask the user to check names and terms. Before transcription, Silero VAD
strips out silence — Whisper tends to hallucinate text over silence.

Everything the app could already open gets transcribed: voice messages
from messaging apps (Ogg Opus), MP3, FLAC, WAV, Ogg Vorbis — via a
portable decoder — plus M4A from a voice recorder and MP4 audio via the
system decoder. While transcription runs, a percentage and a "Stop"
button are shown; stopping returns what's already been transcribed, with
a note that the transcript is incomplete. Limit: 180 minutes of audio per
file.

The cost is size: the Windows zip and the APK grew by ≈270 MB (the whole
model ships with the app — there's nothing to download on demand). On
Android, the model is copied from the APK to disk once, on the first
audio file. faster-whisper, which was considered initially, needs Python,
and Python only exists in the desktop sidecar; whisper.cpp is C/C++ via
FFI, like Tesseract, and works on a phone the same way it does on
Windows. Speed on a phone hasn't been measured yet.

English and Italian were verified separately — 15-to-50-second
recordings, four voices, fast speech and noise: the language is detected
correctly, there are no errors in English, and only isolated word errors
in Italian ("caldaia" → "caldàia"). Both 50-second recordings are now in
the test suite and run in CI on Linux and Windows. Transcript paragraphs
now break at the end of a sentence, not mid-phrase.

## 0.7 — no file-size limit

The 50 MB file-size limit is gone, on both Windows and Android: whatever
is selected gets converted. The cost is that the file is still read into
memory in full, and a file too large for the device (a multi-gigabyte
video on a phone) can crash the app instead of giving a clean "limit
exceeded" message. Only the archive limits remain, protecting against
zip bombs: up to 1 GB of total uncompressed size (previously the same
50 MB, and the archive itself no longer counts toward the total), up to
2000 files, up to 8 levels of nesting.

`core`'s version caught up with the app's: 0.4.0 → 0.7.0.

## 0.6 — Stage 6: images and audio

Images are no longer "unsupported": PNG, JPEG, GIF, BMP, WebP, and now
also recognized TIFF and HEIC (iPhone photos) turn into a list of
metadata — format, size, camera and lens, capture date, exposure and
aperture, geolocation, orientation, captions and author, including
captions Windows writes into the file's "Properties." EXIF parsing is
homegrown rather than the `exif` package: that package loops forever on a
file where an IFD points at itself. If the result contains a geolocation,
a separate warning notes it — coordinates would travel into the chat
along with the text.

OCR arrived — Tesseract 5.5.1, Russian and English, on-device, the same
on Windows and Android. A photo of a document or a screenshot (JPEG, PNG,
BMP) gets a section with the recognized text, a sideways shot is rotated
per its EXIF data; a PDF with no text layer gets its scanned pages
recognized (up to 20 at a time). Warnings note the engine and version,
and when confidence is low, ask the user to double-check the text. The
plan originally called for ML Kit on the phone, but it has no Cyrillic
support. Tesseract for Windows is built from source
(`tesseract/build.sh`), because prebuilt versions pull in libcurl;
Android uses the libraries from Tesseract4Android. The APK grew by
≈11 MB (OCR models and libraries). On Windows, a scanned PDF now goes to
the Dart core with OCR rather than to the sidecar — otherwise a scan of
up to 50 pages would be sent to pdfminer and come back empty.

Audio is also no longer "unsupported": MP3, FLAC, Ogg (Vorbis and
Opus — voice messages from messaging apps), WAV, M4A, and MP4/MOV/3GP now
yield duration, audio parameters, tags, and lyrics; video also gets frame
size. Tags marked "Latin-1" that are actually Windows-1251 (old Russian
MP3s) are now read correctly in Russian. Speech isn't transcribed yet:
offline transcription, with a model ranging from 40 MB to a gigabyte and
a half, is deferred.

## 0.5 — Stage 5: Windows

The app now builds for Windows — in CI, on `windows-latest`: Flutter
doesn't build for Windows on a Mac. The `windows` job runs the same
checks as `make verify`, builds via
`flutter build windows --release`, and ships the `Release/` folder as a
zip artifact — that's the packaging for now ("ship as a zip now, decide
later," finalized at Stage 7). `pdfium.dll` is placed next to the `.exe`;
`.gitattributes` keeps LF line endings even on a Windows checkout. The
runner is `windows-2022`: `windows-latest` now ships Visual Studio 2026,
which the pinned Flutter version doesn't know about.

The Python sidecar is built for Windows too (the `windows-sidecar` job,
with its lock file generated on the runner and committed after review):
308 MB, placed in `sidecar\` next to the `.exe`. Integration tests pass on
Windows, and the comparison against the Dart core produced byte-for-byte
the same result as on macOS — the platform introduced no new
discrepancies.

Author's decision on converter order: in the app, the sidecar only goes
first for `pdf` (up to 50 pages) and for `xls`/`msg`; `docx`/`xlsx`/`pptx`
go straight to the Dart core — it's no worse, and dozens of times faster.
A PDF longer than 50 pages is handled by Dart, with a warning that tables
were extracted as plain text. For comparison purposes
(`make compare-sidecar`), the sidecar still handles every format.

First GitHub release: a `v*` tag triggers `release.yml`, which runs the
whole CI suite, builds the arm64 APK (checking that the built file
doesn't contain `android.permission.INTERNET`), and publishes a Windows
zip with the sidecar plus the APK. Signing is still provisional: the APK
uses a debug key, and the Windows build is unsigned.

## 0.4 — Stage 4: the Python sidecar

Real markitdown is wired in as a subprocess, desktop only.
`sidecar/build.sh` builds a relocatable CPython (python-build-standalone)
with `markitdown 0.1.8` and pinned dependency versions (`sidecar/locks/`);
on macOS x86_64 the bundle weighs 242 MB, with a cold start around one
second. `SidecarConverter` (priority −1.0, 120s timeout, temp file
deleted in `finally`) goes first for `pdf`/`docx`/`xlsx`/`pptx` and covers
`.xls` and `.msg`, which the Dart core doesn't and won't handle. Any
sidecar failure — timeout, garbage on stdout, a missing directory —
doesn't cost the result: the Dart converter kicks in, and `warnings`
notes that the sidecar failed. Where the sidecar succeeded is visible via
`converterId: sidecar`. It's absent from mobile and never registered
there.

Type detection learned to read the Compound File directory: `xls`, `msg`,
`doc`, and `ppt` share one signature and are told apart by their stream
names (`Workbook`, `__properties_version1.0`…).

Cross-checking the two implementations (`make compare-sidecar`) found and
fixed four bugs in the Dart core: an `xlsx` from openpyxl with absolute
`Target` values in `.rels` was read as empty; `xlsx` dates were output as
raw numbers; tightly packed `docx` lists; and nested list-item indentation
under a numbered list. The remaining discrepancies (PDF tables — the
core's one deliberate gap — and some style differences) are recorded in
`docs/format-coverage.md`. New fixtures, including `xls`/`msg`, are now
generated by `sidecar/samples/make_samples.py`; the old hand-written
`pptx` was renamed into the evil fixture `no_sppr.pptx`.

Signing for macOS: `sidecar/sign.sh`, `sidecar.entitlements` (just
`disable-library-validation`), `make sign-sidecar`. Verified with an
ad-hoc signature under Hardened Runtime; Developer ID, notarization, and
embedding the sidecar into an Xcode build are not verified (no
certificate or Xcode) — see `docs/future-development.md`. A new CI step:
checks that `Release.entitlements` and the sidecar contain no
`network.*` entitlements, and that the sandbox is enabled.

Android didn't get heavier: nothing from the sidecar is in the APK, and
there's no `android.permission.INTERNET` either — measurement in
`docs/format-coverage.md#android-didnt-get-heavier-stage-4`. There's an
open question about sidecar speed on large files (a 300-page PDF: 112s
versus 1.2s for Dart).

## 0.3 — Stage 3: PDF

Text extraction via PDFium (custom FFI bindings, not a plugin — works
inside `Isolate.run`): reading order matches the source, headings are
detected by font size relative to the document's typical size, and
adjacent lines wrapped across the page width are stitched back into
paragraphs. Tables in PDFs are deliberately not supported — that decision
was made upfront. Pages with no text layer aren't an error: a warning
("pages N–M look like images") goes into `warnings`, and the rest of the
text is returned as-is.

The engine was chosen among `syncfusion_flutter_pdf`, PDFium, and the
sidecar — the architectural constraint decided it (`core/` can't import
`flutter/`); details and a bundle-size measurement are in
`docs/format-coverage.md#stage-3-decisions`. The native `libpdfium`
isn't committed, it's downloaded by `pdfium/fetch.sh` — the same approach
as `python-build-standalone` in the sidecar.

Fixtures: plain text with headings, scanned pages mixed with text pages,
a PDF with not a single text character; plus a test for unreadable bytes
following `%PDF-` (`CorruptedFileFailure`).

## 0.2 — Stage 2: Office

A shared OOXML layer (`archive` + `xml`) and six formats built on it:
`docx` (paragraphs, heading styles, nested lists via `numbering.xml`,
tables, bold/italic, links, footnotes, image placeholders), `xlsx`
(`sharedStrings` + sheets, formulas returned as their cached value,
merged cells turned into an HTML block with `warnings`), `pptx` (slides
in order, title → `##`, speaker notes in a separate block), `epub`
(chapters by `spine` via Stage 1's `HtmlConverter` — through
`request.recurse`, not a direct call), `zip` (recursion through the
archive with a shared limits budget across the whole tree in
`ConverterRegistry`, rather than per level), `ipynb`.

Fixtures — including evil ones: nested lists, a table inside a table,
merged cells, a zip inside a zip, exceeded file-count/size and
recursion-depth limits.

## 0.1 — Stage 1: the pipeline and text formats

`DocumentConverter`/a registry with priorities/`ConversionLimits`/
`ConversionResult`, `markdown_writer` (escaping, tables, headings) — one
shared module for every converter. Five text converters: `plain text`
(with encoding detection), `csv`/`tsv`, `json`, `xml`, `html` (`html2md`).

In `app/`: auto-conversion in `Isolate.run`, preview and error screens,
the clipboard via `super_clipboard` (`text/plain` + `text/markdown`),
"Save as `.md`," `en`/`ru` localization.

## 0.0 — Stage 0: scaffolding

`flutter create` for macOS/Android in `app/`, a separate Dart package
`core/` with no dependency on `flutter`. CI on GitHub Actions
(`make verify` + a "no network" check). File intake (`file_picker`,
`desktop_drop`, `receive_sharing_intent`) through a single `accept()`
entry point. Type detection by magic bytes + refinement within the zip
family + extension as a hint, with tests against "evil" files.

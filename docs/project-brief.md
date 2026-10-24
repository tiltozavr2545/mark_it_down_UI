# Project brief: MarkItDown UI

> **Historical document.** The target platforms here are macOS and Android;
> after Stage 4 the author's priority shifted to **Windows and Android**,
> macOS became secondary. The stage numbering below is also outdated (Stage
> 5 — Windows — was added). The current version is in
> [implementation-plan.md](implementation-plan.md).

> An app that turns any file into Markdown entirely on the device, with no
> internet, and hands the result straight to the clipboard.

**Working title — MarkItDown UI** (named after the library everything is
built around: [microsoft/markitdown](https://github.com/microsoft/markitdown)).
An own name is an open question, see
[future-development.md](future-development.md): "MarkItDown" is the name
of Microsoft's project, and it's better not to carry it into store
publication.

**This document describes the intent**, not what came out of it: it was
written before the first line of code and won't be edited further. How
things are actually built is in
[conversion-pipeline.md](conversion-pipeline.md) and
[client-architecture.md](client-architecture.md); what's settled for each
format is in [format-coverage.md](format-coverage.md); how the work went is
in [implementation-plan.md](implementation-plan.md) and
[../CHANGELOG.md](../CHANGELOG.md).

---

## 1. Why this is needed

Markdown has become the format text is handed to machines in: an LLM
prompt, a ticket, an Obsidian note, a README. So "give me this
PDF/DOCX/XLSX as Markdown" is an operation people do many times a day, and
they do it through sites like "convert docx to markdown online": upload
the document to someone else's server, get a file back, download it, open
it, copy it.

This approach has two flaws, and both are fixed by the same solution:

- **Privacy.** The file being converted is usually work-related: a
  contract, an export, an internal document. Sending it to an unknown
  server isn't allowed, and often it's outright forbidden.
- **Extra steps.** What's needed isn't an `.md` file in the Downloads
  folder, but text in the clipboard — to paste into a chat with a model or
  into an editor.

From this come two requirements that make up the product: **conversion
entirely on the device** and **the result straight into the clipboard**.
Everything else is implementation detail.

"No internet" here doesn't mean "works on a plane" — it's a **verifiable
property of the build**: the app has no networking code and no network
permission — see [offline-and-privacy.md](offline-and-privacy.md). That's
something that can be shown, not just promised.

## 2. Product mechanics

**A file reaches the app** in one of four ways, and all four are on equal
footing:

- picking it through the system dialog (an "Open file" button);
- drag & drop into the window — the primary gesture on desktop;
- the system "Share" / "Open with" — the primary path on phones;
- pasting from the clipboard (a copied file or an HTML fragment).

**The app determines the type** — by extension, and if that's wrong or
missing, by the content's magic bytes. This isn't a formality: a file that
arrived from a messenger app is routinely named `document` with no
extension.

**The chosen converter turns the bytes into Markdown.** A converter isn't a
function but an entry in a registry that can say "this stream is mine" and
process it; how the registry is built and the result's contract are in
[conversion-pipeline.md](conversion-pipeline.md).

**The result is shown on a preview screen** — as raw Markdown with syntax
highlighting, not rendered. The user is copying text, not a picture, and
what they see should be exactly what they'll copy.

**Copying is a single action.** A big "Copy" button and a keyboard
shortcut. Both `text/plain` and `text/markdown` are placed in the
clipboard — editors that understand the latter get the latter. Next to it
is "Save as `.md`," for the cases where an actual file is still needed.

**What the product deliberately doesn't have:** editing the result (this
isn't an editor), a conversion history that stores content (that's a leak
in exactly the place where the whole point is not having one), cloud sync,
accounts.

## 3. What we convert with

The foundation is
[microsoft/markitdown](https://github.com/microsoft/markitdown): it covers
PDF, Office, HTML, EPUB, images, audio, archives, and, more importantly,
**it already embodies a large number of decisions about exactly how a
document maps onto Markdown** — how a table looks, how a heading looks,
what to do with footnotes. That's the library's real value: not the
parsing, but the choice of representation.

The problem is that markitdown is a **Python library** (3.10–3.14), with
dependencies, some of which are native (`lxml`, `pdfminer.six`,
`pdfplumber`, `pandas`, `magika` with an ONNX model). This doesn't build on
Android or iOS, and there's no clean way around it.

So the solution is two-layered, and deliberately asymmetric:

- **The conversion core is written in Dart** and works identically on every
  platform. markitdown is a **specification for it, not a dependency**: we
  reproduce its interface (`StreamInfo`, `accepts()`, converter priorities)
  and its representation decisions, but the code is our own. This is how
  the app behaves on a phone and, by default, on desktop too.
- **On desktop, a real markitdown sits alongside it** — a bundled Python
  install together with its interpreter, which the app invokes as a
  subprocess. It kicks in where the Dart converter is weaker or missing
  entirely (`.xls`, `.msg`, complex PDFs) — see
  [python-sidecar.md](python-sidecar.md).

The cost of this decision is stated plainly: **two implementations that can
diverge in their output**. What keeps that in check is a shared set of test
files with reference Markdown, the same for both layers; see "Working
conventions" in [../AGENTS.md](../AGENTS.md).

Separately: **"everything markitdown can do" and "everything offline" are
different sets.** The YouTube, Bing SERP, Wikipedia, and RSS converters are
inherently URL-based, image captioning goes through OpenAI, Azure Document
Intelligence is a cloud service, and markitdown's built-in audio
transcription (`SpeechRecognition`) defaults to Google's web API. None of
this is part of the product — not "not configured yet," but genuinely not
included. What replaces what is in
[format-coverage.md](format-coverage.md).

## 4. What to do in the first version (0.1)

The author has already written one Flutter app (Amicus — Android/iOS,
Supabase), meaning Dart, Riverpod, and building for mobile are familiar.
Two things are new here: **desktop as a platform** and **parsing binary
formats**. Accordingly, 0.1 is the full end-to-end path, but on a narrow
set of formats:

- One window: file-intake zone → Markdown preview → "Copy" button.
- File intake via dialog and drag & drop (desktop), via "Share" (Android).
- Type detection by extension + magic bytes.
- Converters: `txt`/`md`, `csv`/`tsv`, `json`, `xml`, `html`, `docx`.
  `docx` because without it the product doesn't answer the main request,
  and zip+xml also gives a framework for `xlsx`/`pptx`/`epub` along the way.
- Copying to the clipboard (`text/plain` + `text/markdown`), saving as
  `.md`.
- Builds for macOS and Android, with no network permissions.

The full set of formats is the project's goal, not the first version's;
how it's assembled stage by stage is in
[implementation-plan.md](implementation-plan.md), and what's decided for
each format is in [format-coverage.md](format-coverage.md).

## 5. Stack

| | what | why |
|---|---|---|
| UI | Flutter / Dart | one codebase for desktop and mobile; the author already writes in it |
| State | Riverpod | the same as in Amicus — experience carries over instead of being relearned |
| Zip/XML parsing | `archive`, `xml` | `docx`/`xlsx`/`pptx`/`epub` are zip files with XML inside |
| HTML → Markdown | `html` + `html2md` | the equivalent of markitdown's `beautifulsoup4` + `markdownify` |
| Clipboard | `super_clipboard` | can place several representations at once, unlike `Clipboard.setData` |
| File intake | `file_picker`, `desktop_drop`, `receive_sharing_intent` | dialog, drag & drop, the system "Share" |
| Heavy formats on desktop | real markitdown as a subprocess | no need to rewrite `pdfminer` in Dart |

Specific decisions and their revisions are tracked in
[client-architecture.md](client-architecture.md): this brief doesn't keep a
history.

**What's not in the stack:** any network client, analytics, crash
reporting. Crash reporting is also networking, and it sends file names
outward; if it's ever needed, that's a separate product decision, not a
technical detail.

## 6. Roadmap

**Stage 0 — Scaffolding.** A Flutter project for macOS and Android, CI with
`dart format`/`analyze`/`test`, an empty window that accepts a file and
shows its name.

**Stage 1 — Pipeline and text formats.** The converter registry, type
detection, `ConversionResult`, the preview screen, copying. Formats:
`txt`/`md`/`csv`/`tsv`/`json`/`xml`/`html`.

**Stage 2 — Office.** `docx`, then `xlsx` and `pptx` on a shared zip+xml
framework. This is also where the set of reference test files appears.

**Stage 3 — PDF.** A separate stage: text extraction is the heaviest part,
and the only one where a choice between license and amount of work has to
be made.

**Stage 4 — Python sidecar on desktop.** Packaging real markitdown, signing,
formats that aren't in the Dart core.

**Stage 5 — Images and audio.** Offline OCR and offline transcription. The
furthest-out stage, and the only one that drags ML models into the bundle.

**Stage 6 — Polish and release.** Keyboard shortcuts, batch conversion,
DMG/notarization, release.

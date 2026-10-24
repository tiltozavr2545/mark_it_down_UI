# Deferred features and open questions

Everything deliberately deferred beyond the plan
([implementation-plan.md](implementation-plan.md)), and questions that
don't have an answer yet. Finished work doesn't go here — the version
history is in [../CHANGELOG.md](../CHANGELOG.md).

---

## Open questions

### Large audio and video

Metadata only needs the beginning and end of a file, yet the pipeline
reads the whole file into memory: there's no longer a size limit, but a
multi-gigabyte video from a phone will be read into memory in full even
though parsing it could take milliseconds, and it might not even fit on
the phone. This is fixed by reading `head`/`tail` for media instead of the
whole file — a change to file intake (`StreamInfo`, `PickedFile`), not to
the converter.

### Name

The working title is "MarkItDown UI," and it won't do for publication:
MarkItDown is the name of Microsoft's project, the one the library
everything is built around lives under. Using that name would both
confuse people and invite a complaint.

A name of our own is needed, one that doesn't repeat someone else's but
still explains what the app does. There won't be a store listing (only
GitHub Releases, the author's decision), so renaming doesn't run into a
store-listing wall — but an Android app's `applicationId` would also
change, and with it an "update" becomes a fresh install. To be decided
before 1.0.

### Speech recognition: what's next

**Decided by the author in 0.8:** transcription exists — whisper.cpp, the
small model in the main bundle, on Windows and Android; all the "whys" are
in
[format-coverage.md](format-coverage.md#transcription-decisions-08). There
used to be a product question here, "is audio worth the app weighing ten
times as much" — the answer is "yes," the APK and the zip grew by
≈270 MB.

**What's still open:**

- ~~**Play.**~~ Resolved: we're not publishing to Google Play (the
  author's decision, 2026-10-14), and an APK from GitHub Releases has no
  200 MB limit — the model stays a Flutter asset, Play Asset Delivery
  isn't needed.
- **Double storage on Android.** The model lives both in the APK and in a
  copy on disk (≈530 MB). The copy can only be removed by reading straight
  from the APK via `AAssetManager` — meaning Java/JNI code.
- **Speed.** There are no measurements on a phone or on Windows yet —
  that's the first manual check to do. If it turns out to run much slower
  than real time on a phone: use base instead of small for Android (worse
  Russian quality), `audio_ctx` for short voice notes, beam search — the
  opposite, desktop only.
- **Manual language selection** — for recordings where auto-detection from
  the first 30 seconds gets it wrong (it already exists in
  `TranscriptionSettings.language`, only the UI setting is missing — for
  Stage 7, item 3).
- **Audio inside archives** — currently without recognition (see
  [format-coverage.md](format-coverage.md#transcription-whats-left)).

### How closely to stick to markitdown's output

We have two implementations (the Dart core and the sidecar), and they will
diverge. The question is: treat markitdown's output as the reference and
make Dart match it, or treat our own as the reference and just document
the differences. The first option is more expensive, the second more
honest. The second is what's chosen right now — divergences are recorded
in [format-coverage.md](format-coverage.md) — but if there get to be a lot
of them, the decision is worth revisiting.

### Sidecar performance on large files

**Decided by the author in [Stage 5, item 5](implementation-plan.md#stage-5--windows-05):**
in the app, the sidecar only goes first for `pdf`/`xls`/`msg`, and for PDF
only up to 50 pages; `docx`/`xlsx`/`pptx` go straight to Dart. How this
works is in
[conversion-pipeline.md](conversion-pipeline.md#the-sidecar--just-another-converter).

The reason was this (a Stage 4 measurement, Intel, macOS 12, cold
process; details in
[format-coverage.md](format-coverage.md#reconciliation-with-the-reference-stage-4)): a
300-page PDF — **111.6 s** on the sidecar versus **1.2 s** on Dart; an
xlsx with 50,000 rows — **54.7 s** and ~860 MB of RAM versus 4.4 s. While
the sidecar went first for everything, a large PDF could wait up to two
minutes (the ceiling being the 120 s timeout), and only then would it fall
back to Dart and return a result in a second.

**What's still open:**

- **Large `xls`/`msg`** — there's no fallback to Dart for these, so the
  threshold doesn't apply; a slow file runs into the 120 s timeout and
  gets rejected. Options are a timeout based on file size, or a "this may
  take minutes" indicator in the UI.
- **Tables in PDFs longer than 50 pages** get lost (Dart returns them as
  text, and says so in `warnings`). Only building our own table
  recognition into the Dart core could close this gap — see
  [format-coverage.md](format-coverage.md).
- **The threshold is based on Mac measurements**, not Windows ones: the
  Windows numbers come from the manual check in Stage 5, item 8; if they
  turn out to be very different, the threshold should be revisited.

### Size of the Windows sidecar

308 MB versus 242 on macOS. `python/DLLs/` is ≈70 MB — more than you'd
expect from standard `.pyd` files. It hasn't been looked into what's in
there (debug symbols? extra libraries?) or what can be trimmed without
breaking `build.sh`'s self-check. This doesn't block distribution; it's
worth digging into by Stage 7 (packaging, size in the README).

### Unfinished after Stage 4 (macOS sidecar) — secondary platform, not a priority

Not decisions, just unverified items: given the shift in priorities
(Windows and Android), these aren't being worked on without a separate
request; the list is kept so it isn't lost, not as a queue.

- **Developer ID, notarization, embedding into the Xcode build.** The
  commands are recorded in
  [operations.md](operations.md#signing-and-notarization-commands), only the
  ad-hoc signature has been verified. The Build Phase that places the
  sidecar into `Contents/Resources/sidecar` is described there too, but
  hasn't been written. Also worth checking whether
  `disable-library-validation` is still needed with a real certificate —
  the docs don't say, and the key weakens Hardened Runtime.
- **Lock files for other hosts.** Only `macos-x86_64` exists; for
  `macos-arm64` and `linux-*` the numpy/onnxruntime wheels are different,
  and the lock gets recreated on each host (`make sidecar-lock`). Windows
  isn't here, it's in [Stage 5](implementation-plan.md#stage-5--windows-05),
  item 4.
- **How the sidecar behaves under the sandbox of a live `.app`.** Tested
  with an ad-hoc signature outside the sandbox; how it behaves as a
  subprocess under App Sandbox (access to the container's temp folder,
  launching the interpreter from `Resources`) needs checking on the first
  `.app` build.

### Conversion history

Whether to store anything beyond paths. Right now the answer is no, and
that's more a property of the product than a limitation (see
[offline-and-privacy.md](offline-and-privacy.md)). But "I converted this
PDF yesterday, give me the same result" is a real request, and at some
point it will come up.

---

## Deferred

### Tables from PDF

`pdfplumber` can find tables in a PDF, PDFium on its own can't (the
engine decision from Stage 3, see
[format-coverage.md](format-coverage.md#stage-3-decisions)). This is a
task on the scale of its own stage, and until then, returning text is more
honest than a broken grid.

### macOS (build)

**Secondary platform, not a priority.** The plan's target platforms are
Windows (Stage 5) and Android; macOS stays a target, but second in line.

Since Stage 0: Xcode.app won't install on the author's machine, only
Command Line Tools 14.2 is available, and `flutter build
macos`/`flutter run -d macos` require the full Xcode. The code and
`flutter create --platforms=macos,android` for macOS haven't gone
anywhere, and the pipeline is written platform-independently.
Reinstalling Xcode on this machine has already been tried — it won't go
on. macOS (and iOS, see below) will be built later on a friend's Mac,
where Xcode does install — the build moves there, the product doesn't
lose the platform. What remains unresolved as a result — Developer ID,
notarization, embedding the sidecar into the Xcode build — is listed
above, under "Unfinished after Stage 4"; it's not being worked on without
a separate request.

### Linux

Flutter supports it, the Python sidecar builds for it (there's a branch
in `sidecar/common.sh`, but it hasn't been run). Not a priority: not a
single request for it, and there's nowhere to build it yet besides the CI
image. Windows used to sit here too as "nowhere to build it" — now that's
[Stage 5](implementation-plan.md#stage-5--windows-05): the build runs on
`windows-latest`, and verification happens on the author's Windows
machine.

### iOS

This also runs into the machine problem, more harshly than the rest. On
macOS 12.7.6, the most that will install is Xcode 14.2, and App Store
Connect rejects a binary built with that SDK (`ITMS-90111`): the host OS
version of the build machine gets baked in, not just the Xcode version.
So running it on the simulator and building it locally works, but
submitting it doesn't.

A workaround is known and already proven on Amicus — **Xcode Cloud**: it
builds on a stable Apple-provided image, independent of the local macOS.
This is the path to take if iOS is ever needed, and it doesn't require a
new machine — just a developer account and a configured workflow. A
second option is simpler: build the macOS and iOS targets on a friend's
computer with a working Xcode — the build moves there, and Xcode Cloud
isn't needed then.

Separately attached to iOS is the Share Extension (the main way to hand a
file to it) — a separate target with its own memory limit, inside which
conversion can't happen, see
[client-architecture.md](client-architecture.md#file-intake-four-inputs-one-entry-point).

### Mac App Store

A bundle with the interpreter isn't forbidden, but it requires a sandbox
and careful signing of the nested binaries — see
[python-sidecar.md](python-sidecar.md#about-the-app-store). For now,
distribution via DMG and GitHub Releases is enough.

### CLI

`core/` deliberately doesn't depend on Flutter, which means a console
utility can be built from it without changes: `md-it file.docx | pbcopy`.
To be done once there's a request for it; the groundwork is already in
place.

### Custom conversion rules

Output profiles: "for LLM" (minimal markup, no image placeholders), "for
Obsidian" (wiki-links, frontmatter), "as-is." Technically this is just the
`markdown_writer` parameter, so it's cheap — but there's nothing to
configure until the baseline output has been proven out.

### Plugins

markitdown has a plugin system (third-party converters tagged
`#markitdown-plugin`). Interesting, but in an app with no network there's
nowhere to install them from, and a plugin shipped in the bundle is just
another built-in converter.

### Watch folder

Drop a file in a folder — an `.md` shows up next to it. A natural
extension for desktop, and exactly what the CLI would come in handy for.

### Unprioritized ideas

- Preview with Markdown syntax highlighting (currently monospace, no
  highlighting).
- Diffing two documents after converting them to Markdown — a surprisingly
  handy way to compare two versions of a contract.
- Choosing a sheet/range in `xlsx` before conversion, instead of "all
  sheets, in full."
- Trimming the result by token count with a counter shown — if the main
  use case really is "paste into a chat with a model."
- A context-menu item in Explorer (Windows) and a Quick Action in Finder
  (macOS).

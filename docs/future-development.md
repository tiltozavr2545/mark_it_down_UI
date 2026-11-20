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

The packages include Whisper small and Silero VAD for offline
transcription. The model accounts for most of the download size. The
engine and decoder choices are documented in
[Format coverage](format-coverage.md#transcription-decisions-08).

**What's still open:**

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

The desktop app prefers the sidecar for `xls` and `msg`. Dart handles
PDF and the newer Office formats directly. See the
[conversion pipeline](conversion-pipeline.md#the-sidecar--just-another-converter).

The reason was this (a Stage 4 measurement, Intel, macOS 12, cold
process; details in
[format-coverage.md](format-coverage.md#reconciliation-with-the-reference-stage-4)): a
300-page PDF — **111.6 s** on the sidecar versus **1.2 s** on Dart; an
xlsx with 50,000 rows — **54.7 s** and ~860 MB of RAM versus 4.4 s. While
the sidecar went first for everything, a large PDF could wait up to two
minutes (the ceiling being the 120 s timeout), and only then would it fall
back to Dart and return a result in a second.

**What's still open:**

- **Large `xls`/`msg`** — the sidecar goes first for these with no page
  or size threshold. After a 120-second timeout the app tries Dart.
  Options include a timeout based on file size or a long-running
  conversion indicator.

### Size of the Windows sidecar

Stage 5 measured 308 MB on Windows and 242 MB on macOS. The Windows
`python/DLLs/` directory was about 70 MB. Measure the current bundle
before deciding which files can be trimmed while preserving the
sidecar's self-check.

### macOS release verification

The [CI workflow](operations.md#macos) builds Intel and Apple Silicon
DMGs alongside the Windows and Android packages.
Manual checks of Gatekeeper launch, native conversion and Markdown export
are still pending on the automated artifacts. See the
[macOS smoke checks](operations.md#macos-smoke-checks).

AAC transcription for M4A and MP4 needs a macOS platform decoder. The
current macOS pipeline extracts metadata for those files.

### Conversion history

Whether to store anything beyond paths. Right now the answer is no, and
that's more a property of the product than a limitation (see
[offline-and-privacy.md](offline-and-privacy.md)). But "I converted this
PDF yesterday, give me the same result" is a real request, and at some
point it will come up.

---

## Deferred

### Linux

Flutter supports it, the Python sidecar builds for it (there's a branch
in `sidecar/common.sh`, but it hasn't been run). Not a priority: not a
single request for it, and there's nowhere to build it yet besides the CI
image. Windows used to sit here too as "nowhere to build it" — now that's
[Stage 5](implementation-plan.md#stage-5--windows-05): the build runs on
`windows-2022`, and verification happens on the author's Windows
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
second option is to build the iOS target on a Mac with a supported
version of Xcode.

Separately attached to iOS is the Share Extension (the main way to hand a
file to it) — a separate target with its own memory limit, inside which
conversion can't happen, see
[client-architecture.md](client-architecture.md#file-intake).

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

# Offline and privacy

What "files don't leave the device" means in this project, how to verify
it, and what's missing from the app for that reason.

This document is deliberately short: it's not a declaration, it's a list
of verifiable build properties. Which converters didn't make it in because
of this is in [format-coverage.md](format-coverage.md).

---

## Statement

**The file is converted on the device, and its content is never sent
anywhere. The app only reaches out to the network in "link" mode — to
fetch what a link that the person pasted or shared themselves points to.**

Before 0.9 the statement was stricter: "no networking code, no network
permission." As of 0.9 (the author's decision from 2026-10-15: "anything
plain markitdown can do with an internet connection is in scope"), the app
has a "link" mode — a web page, a Wikipedia article, a YouTube video
(description and captions), a file at a direct link. That needs network
access by definition, and Android has a single network permission that
covers the whole app. So the guarantee moved from the OS level to the code
level — and it's checked in CI just as automatically:

- **All networking code lives in a single module, `core/lib/src/web/`.**
  `WebFetcher` is the only place with an `HttpClient`; its requests are a
  `GET` for the user's link and, for YouTube, a `POST` with the video ID to
  fetch the caption list. Neither the file path nor its bytes ever go into
  these requests: file converters never get a `WebFetcher` at all — it's
  only passed into the registry for pages downloaded via a link
  (`isolated_convert.dart`).
- **CI fails if sockets or an HTTP client show up outside this module**
  (the "network only in core/lib/src/web/" step in `ci.yml`), and if a
  networking package shows up in the dependencies (`http`, `dio`,
  `firebase_*`, `sentry_*`...) — such a package would mean network access
  bypassing the module.
- **Text recognition (OCR) and speech recognition are still on-device
  only**, with the models bundled in the app and the native libraries built
  without networking code (below). A link to audio gets downloaded, but
  recognition still happens locally the same way.

## How this is nailed down in the build

The target platforms are Windows and Android; macOS is secondary.

| platform | by what | how to verify |
|---|---|---|
| Android | `android.permission.INTERNET` is present as of 0.9 ("link" mode); no other network permissions (`ACCESS_NETWORK_STATE`, Wi-Fi) exist. `usesCleartextTraffic` is set so `http://` links also open | `aapt dump permissions app-release.apk` — the "APK permissions" step in `release.yml`; on the phone: "App info" → "Permissions" |
| macOS | `Release.entitlements` has `network.client` (outbound, as of 0.9), **not** `network.server`; sandbox is enabled | `codesign -d --entitlements - MarkItDown.app`; in CI — a grep against `Release.entitlements` |
| iOS | platform deferred | — |
| Windows | there's no OS-level guarantee and never was: the zip build doesn't have network permissions as a concept. It rests on the code: network only in `core/lib/src/web/`, no networking packages in `pub deps`, no networking libraries in `app/windows/` | in CI: grep against the code, `dart pub deps`, grep `app/windows/` for `ws2_32`/`winhttp`/`wininet`/`internetClient` |
| Linux | platform deferred | — |

Being honest about what's been lost compared to 0.8: on Android, the
absence of `INTERNET` used to mean that **not a single dependency** could
physically open a connection. Now it means a check of the code and the
dependency list. Dart source checks cannot detect behavior inside native
dependencies. The Tesseract and whisper.cpp build scripts check their
libraries for networking references. PDFium uses pinned,
SHA-256-checked upstream binaries.

About `DebugProfile.entitlements`: it has
`com.apple.security.network.server` — Flutter tooling needs it (hot
reload, VM service), and it doesn't make it into the release build. That's
why the check is against `Release.entitlements`, not against every
`*.entitlements` file indiscriminately.

The desktop Python bundle includes `requests` as a MarkItDown dependency.
The wrapper calls `MarkItDown.convert_local` with a filesystem path and
ships the document-conversion extras listed in
[Python sidecar](python-sidecar.md#what-exactly-gets-packaged).

OCR (Stage 6) — Tesseract with the models in the bundle, recognizing on
the device. The desktop build is built from source specifically for this
promise: the prebuilt options (vcpkg, the UB Mannheim installer) link
**libcurl** — Tesseract can download an image by URL itself.
`tesseract/build.sh` builds without curl, libarchive, and `Ws2_32`, and
fails if the built libraries reference `libcurl`/`ws2_32`/`winhttp`/`wininet`.
The Android build (Tesseract4Android) doesn't pull in any networking
libraries (`NEEDED` is only libc/libm/liblog/libz and its own
libjpeg/libpng). The models aren't downloaded — they're already in the
app.

Speech recognition (0.8) — whisper.cpp with the model in the bundle
(Whisper small, 264 MB, plus Silero VAD), on-device, the same on Windows
and Android. The model isn't downloaded — there's nothing to fetch it
with, so it's bundled in full. `whisper/build.sh` builds whisper.cpp
without `WHISPER_CURL` (downloading the model by URL) and without
`GGML_RPC` (a networked backend), and fails if the build references
`libcurl`/`ws2_32`/`winhttp`/`wininet`. AAC is decoded by the OS (Media
Foundation, MediaCodec) — locally, from the file; the temporary file used
for this is deleted in a `finally`.

On Windows, the sidecar is a child process with the app's privileges.
The wrapper keeps conversion on the local-file code path.

On macOS (a secondary platform) the sidecar is a subprocess of the app and
**inherits the parent's App Sandbox** — together with `network.client` as
of 0.9. Its wrapper uses the same local-file entry point as Windows. The
interpreter's own entitlements (`sidecar/sidecar.entitlements`) contain
only `cs.disable-library-validation` — about loading libraries, not about
networking — and have no network keys. CI checks this: the step fails if
`network.*` shows up in `sidecar/*.entitlements`, if `network.server` shows
up in `Release.entitlements`, or if the sandbox is disabled there. Caveat:
how the sidecar behaves under the sandbox of a live `.app` hasn't been
verified yet (no Xcode) — see
[future-development.md](future-development.md).

## What's not in the app

And won't appear without a separate product decision: each item below is
networking that isn't driven by a user's link but happens on its own, or
sends document content outward:

- **Analytics.** None at all, not even "anonymous."
- **Crash reporting.** Tempting, but a crash report contains a stack trace,
  and a stack trace contains file names. An app that sends
  `lease-agreement-final.docx` outward on a crash violates exactly the
  promise it exists to keep.
- **Update checking.** Updates are manual: a new version is downloaded from
  GitHub Releases (no app stores — the author's decision).
- **Image captioning via LLM and Azure Document Intelligence** — this is
  markitdown's main way of handling scans, and it's cloud-based.
- **Audio transcription via a web API** (markitdown's built-in path). Our
  own exists, on-device (see above).
- **The Bing converter** (a search-results page) — a fragile parse of
  someone else's output, against Bing's terms. YouTube and Wikipedia do
  exist, in "link" mode (0.9): only the link itself goes out.

## "Link" mode: what goes out over the network

- **A `GET` for the link** — the page or file the person chose; with
  redirects, same as in a browser. The `User-Agent` is an honest app name
  with a link to the repository, no cookies (except the YouTube consent
  cookie: "reject non-essential"), no history, no identifiers.
- **For YouTube, two more requests**: a `POST` to InnerTube
  (`/youtubei/v1/player`) with the video ID, to get the caption list, and a
  `GET` for the caption track itself. This isn't an official API: YouTube
  changes it, and when that happens the result is a description with no
  captions and a warning.
- **Nothing else.** What gets downloaded is converted on the device by the
  same pipeline as a file (a PDF link goes through PDFium, an audio link
  through whisper.cpp). The download limit is 1 GB, same as for an
  unpacked archive: otherwise an endless stream would eat up memory.

## What's stored on the device

- **Conversion content** is kept in memory while in use. Copy places it
  on the clipboard. **Save as .md** writes to the chosen file and
  **Save to folder** writes separate results to the selected folder.
  On Android, the batch picker requests local locations and grants
  access to the selected directory tree.
- **Temporary input created by the sidecar and audio decoder** is deleted
  after use. Android's share plugin can hand over files from its cache.
- **Model assets** copied out of the APK for OCR and transcription stay
  in application support for reuse. The theme and language follow the
  system.
- **"Recent files" history**, if it's ever added — only paths and names,
  with the option to turn it off and clear it. Content — never.

The clipboard is a deliberate hole in this picture, and it can't be
closed: on macOS/iOS, Universal Clipboard can see into it; on Windows,
clipboard history (Win+V) and, if enabled, cloud sync can; on Android, any
app with focus can. This is the price of what the product does in the
first place, and it's worth saying so plainly in the README and the
release notes, not glossing over it.

## What this costs

Half of markitdown's capabilities — scans, audio, images — are built on
the cloud, and without it they either don't exist or need their own
offline subsystem with models in the bundle (see "Open items" in
[format-coverage.md](format-coverage.md)). This is the project's main
trade-off. Link mode sends the address supplied by the user to fetch the
requested content. URLs can include query parameters that are passed to
the destination.

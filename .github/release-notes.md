The app turns a file into Markdown right on the device: open a file, get
the text, copy it to a chat or editor with one button. Or, given a link —
a page, a Wikipedia article, or a YouTube video with subtitles. Earlier
versions — in the
[CHANGELOG](https://github.com/tiltozavr2545/mark_it_down_UI/blob/main/CHANGELOG.md);
what each platform can do — in the
[README](https://github.com/tiltozavr2545/mark_it_down_UI#what-it-can-convert).

### Windows — `markitdown_ui-…-windows-x64.zip`

1. Download the zip and unpack it into any folder. Nothing needs to be
   installed, not even Python — it's already inside (the `sidecar`
   folder).
2. Run `markitdown_ui.exe`.
3. On first launch SmartScreen will show "Windows protected your PC":
   **"More info" → "Run anyway"**. The build isn't signed (there's no
   certificate yet) — that's the reason for the warning.

The first `xls`/`msg`/`pdf` conversion may take a few seconds: Windows
Defender scans the bundled Python.

Speech in audio (voice messages, voice-recorder recordings, MP3) is
transcribed right on the computer — the Whisper model is already inside
(≈265 MB of the archive's size). A long recording takes minutes; a
percentage is shown, and it can be stopped at any time.

### Android — `markitdown_ui-…-android-arm64.apk`

1. Download the APK to the phone and open it; allow installation from
   this source if Android asks.
2. Requires Android 6.0+ and an arm64 processor (practically any phone
   from recent years).
3. If the app was already installed from a build that isn't this release,
   uninstall it first — builds are signed with different keys and can't
   be installed over one another.

A file can be opened in the app with the "Choose file" button or via
"Share" from any other app; a link can be shared from YouTube or a
browser.

The APK weighs ≈300 MB — almost all of that is the speech-recognition
model. On the first audio file, it's copied from the APK to disk once
(needs another ≈265 MB of free space), which takes a few seconds.

### Files never leave the device

Files are converted on-device; OCR and speech recognition are too, with
the models shipped inside the app. The app reaches the internet only in
"Paste link" mode (or when a link is shared from YouTube or a browser) —
for the page or file that link points to. That's why the Android build
has the `INTERNET` permission; that all networking code lives in a single
module and never touches your files is checked by CI on every commit.
Details —
[offline-and-privacy.md](https://github.com/tiltozavr2545/mark_it_down_UI/blob/main/docs/offline-and-privacy.md).

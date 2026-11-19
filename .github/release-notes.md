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

The first `xls` or `msg` conversion may take a few seconds while Windows
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
3. If Android reports a signature mismatch, uninstall the previous
   build before installing the new one.

A file can be opened in the app with the "Choose file" button or via
"Share" from any other app; a link can be shared from YouTube or a
browser.

The APK weighs ≈300 MB — almost all of that is the speech-recognition
model. On the first audio file, it's copied from the APK to disk once
(needs another ≈265 MB of free space), which takes a few seconds.

### macOS — `markitdown_ui-…-macos-x64.dmg` or `markitdown_ui-…-macos-arm64.dmg`

1. Download `x64` for an Intel Mac or `arm64` for a Mac with an Apple M
   chip. Check the chip under **Apple menu → About This Mac**. Both builds
   target macOS 12 Monterey and later.
2. Open the DMG and drag **MarkItDown UI** into **Applications**.
3. Try to open it from **Applications**. If macOS blocks the first launch,
   go to **System Settings → Privacy & Security → Open Anyway** and
   confirm. On Monterey, look under **System Preferences → Security &
   Privacy → General**. [Apple's guide](https://support.apple.com/en-us/102445)

The DMGs use an ad-hoc signature and are distributed without Apple
notarization. PDF conversion, OCR, speech models and Python are included.
Speech transcription supports MP3, FLAC, Ogg and WAV on macOS. The app
extracts metadata from AAC media such as M4A and MP4.

### Files never leave the device

Files are converted on-device; OCR and speech recognition are too, with
the models shipped inside the app. The app reaches the internet only in
"Paste link" mode (or when a link is shared from YouTube or a browser) —
for the page or file that link points to. That's why the Android build
has the `INTERNET` permission; that all networking code lives in a single
module and never touches your files is checked by CI on every commit.
Details —
[offline-and-privacy.md](https://github.com/tiltozavr2545/mark_it_down_UI/blob/main/docs/offline-and-privacy.md).

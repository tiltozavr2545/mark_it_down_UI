# MarkItDown UI Flutter app

This package handles file intake, the conversion queue, Markdown
preview, copying and export. It runs the pipeline from `../core/` in a
worker isolate. The queue supports separate files and a merged document.

- [Install the app or set up development](../README.md)
- [Build for Windows and Android](../docs/operations.md#build)
- [Client architecture](../docs/client-architecture.md)

English and Russian UI strings are in `lib/l10n/`. After editing the ARB
files, run `flutter gen-l10n` from this directory.

Shared layout and output controls live in `lib/src/workspace.dart`. The
system light and dark themes are defined in `lib/src/app_theme.dart`.
Sofia Sans is bundled in `assets/fonts/` under the
[SIL Open Font License](assets/fonts/OFL.txt).

import 'dart:isolate';
import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';

/// Conversion runs in a separate isolate — parsing a large file is seconds
/// of solid CPU, and on the main isolate it would freeze the window along
/// with the progress indicator. See
/// `docs/client-architecture.md#conversion-in-an-isolate`. Only the bytes and
/// [StreamInfo] travel into the isolate — nothing platform-specific.
///
/// The sidecar is discovered already inside the isolate
/// ([SidecarConverter.discover]): that's reading a couple of files, and the
/// converter itself doesn't need to be sent between isolates. On
/// Android/iOS `discover` always returns `null` — there's no sidecar there
/// and never will be; on desktop, with no directory found, it's also
/// `null`, and the registry stays pure Dart core.
///
/// [ocr] is where the Tesseract models live (see `ocr_data.dart`): the path
/// string is sent to the isolate, and the OCR libraries are opened inside
/// it. Same with [transcription] (`speech_data.dart`); its progress and
/// cancellation go through [TranscriptionControl], whose address lives in
/// the settings.
Future<ConversionOutcome> isolatedConvert(
  Uint8List bytes,
  StreamInfo info, {
  OcrSettings? ocr,
  TranscriptionSettings? transcription,
}) {
  return Isolate.run(() {
    final sidecar = SidecarConverter.discover();
    final registry = ConverterRegistry.defaultRegistry(
      extra: [if (sidecar != null) sidecar],
      ocr: ocr,
      transcription: transcription,
      // Network access is only for pages downloaded by link (YouTube
      // subtitles); converters for files from disk don't touch it.
      web: info.url == null ? null : const WebFetcher(),
    );
    return registry.convert(bytes, info);
  });
}

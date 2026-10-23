import 'dart:isolate';
import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';

/// Конвертация идёт в отдельном изоляте — разбор крупного файла — секунды
/// сплошного CPU, и на главном изоляте он замораживает окно вместе с
/// индикатором прогресса. См.
/// `docs/client-architecture.md#конвертация-в-изоляте`. В изолят уезжают
/// только байты и [StreamInfo] — ничего платформенного.
///
/// Сайдкар ищется уже внутри изолята ([SidecarConverter.discover]): это
/// чтение пары файлов, а сам конвертер не нужно пересылать между изолятами.
/// На Android/iOS `discover` всегда возвращает `null` — там сайдкара нет и не
/// будет; на десктопе без найденного каталога тоже `null`, и реестр остаётся
/// чистым Dart-ядром.
///
/// [ocr] — где лежат модели Tesseract (см. `ocr_data.dart`): строка пути
/// пересылается в изолят, а библиотеки OCR открываются уже в нём. То же с
/// [transcription] (`speech_data.dart`); его прогресс и отмена — через
/// [TranscriptionControl], адрес которого лежит в настройках.
Future<ConversionOutcome> isolatedConvert(
  Uint8List bytes,
  StreamInfo info, {
  OcrSettings? ocr,
  TranscriptionSettings? transcription,
}) {
  return Isolate.run(() {
    // С OCR PDF-сканы должны дойти до Dart-ядра: сайдкар отдал бы по ним
    // пустоту как успех (см. SidecarConverter.scannedPdfToDart).
    final sidecar = SidecarConverter.discover(scannedPdfToDart: ocr != null);
    final registry = ConverterRegistry.defaultRegistry(
      extra: [if (sidecar != null) sidecar],
      ocr: ocr,
      transcription: transcription,
      // Сеть — только для страниц, скачанных по ссылке (субтитры YouTube);
      // конвертеры файлов с диска её не трогают.
      web: info.url == null ? null : const WebFetcher(),
    );
    return registry.convert(bytes, info);
  });
}

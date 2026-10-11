/// Конвейер конвертации файла в Markdown. Чистый Dart, без импорта
/// `flutter/` — см. `docs/client-architecture.md` в корне репозитория.
library;

export 'src/conversion/conversion_failure.dart';
export 'src/conversion/conversion_limits.dart';
export 'src/conversion/conversion_request.dart';
export 'src/conversion/conversion_result.dart';
export 'src/conversion/converter_registry.dart';
export 'src/conversion/document_converter.dart';
export 'src/conversion/ocr/tesseract_bindings.dart' show tesseractLibDirEnvVar;
export 'src/conversion/ocr/tesseract_ocr.dart' show OcrSettings, ocrAvailable;
export 'src/conversion/sidecar/sidecar_converter.dart';
export 'src/conversion/sidecar/sidecar_manifest.dart';
export 'src/stream_info.dart';
export 'src/type_detection/detected_type.dart';
export 'src/type_detection/type_detector.dart';

import 'dart:isolate';
import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';

/// Конвертация идёт в отдельном изоляте — разбор крупного файла — секунды
/// сплошного CPU, и на главном изоляте он замораживает окно вместе с
/// индикатором прогресса. См.
/// `docs/client-architecture.md#конвертация-в-изоляте`. В изолят уезжают
/// только байты и [StreamInfo] — ничего платформенного.
Future<ConversionOutcome> isolatedConvert(Uint8List bytes, StreamInfo info) {
  return Isolate.run(
    () => ConverterRegistry.defaultRegistry().convert(bytes, info),
  );
}

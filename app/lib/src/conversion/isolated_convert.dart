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
Future<ConversionOutcome> isolatedConvert(Uint8List bytes, StreamInfo info) {
  return Isolate.run(() {
    final sidecar = SidecarConverter.discover();
    final registry = ConverterRegistry.defaultRegistry(
      extra: [if (sidecar != null) sidecar],
    );
    return registry.convert(bytes, info);
  });
}

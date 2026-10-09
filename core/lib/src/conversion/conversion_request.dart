import 'dart:typed_data';

import '../stream_info.dart';
import 'conversion_limits.dart';
import 'converter_registry.dart';

/// Всё, что получает [DocumentConverter.convert]. `recurse` — не украшение:
/// `zip` и `epub` (Этап 2) обязаны прогнать вложенные файлы через тот же
/// реестр, не импортируя его напрямую, иначе цикл зависимостей. См.
/// `docs/conversion-pipeline.md#3-конвертация`.
class ConversionRequest {
  final Uint8List bytes;
  final StreamInfo info;
  final ConversionLimits limits;
  final Future<ConversionOutcome> Function(Uint8List bytes, StreamInfo info)
  recurse;

  const ConversionRequest({
    required this.bytes,
    required this.info,
    required this.limits,
    required this.recurse,
  });
}

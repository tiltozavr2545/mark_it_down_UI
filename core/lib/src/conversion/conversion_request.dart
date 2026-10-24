import 'dart:typed_data';

import '../stream_info.dart';
import 'conversion_limits.dart';
import 'converter_registry.dart';

/// Everything [DocumentConverter.convert] receives. `recurse` isn't
/// decoration: `zip` and `epub` (Stage 2) must run nested files through
/// the same registry without importing it directly, or there would be a
/// dependency cycle. See `docs/conversion-pipeline.md#3-конвертация`.
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

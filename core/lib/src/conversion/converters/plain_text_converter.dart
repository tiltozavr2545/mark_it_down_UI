import 'dart:typed_data';

import '../../stream_info.dart';
import '../../text_decoding.dart';
import '../../type_detection/detected_type.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';

/// Общий формат и настоящий catch-all — приоритет `10.0`, спрашивается
/// последним. Markdown для простого текста — это сам текст: без
/// экранирования и без переноса по ширине, см.
/// `docs/conversion-pipeline.md#как-markdown-собирается`.
class PlainTextConverter implements DocumentConverter {
  const PlainTextConverter();

  @override
  String get id => 'plain_text';

  @override
  double get priority => 10.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) =>
      info.detectedType.kind == FileKind.text ||
      info.detectedType.kind == FileKind.emptyFile;

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    if (request.info.detectedType.kind == FileKind.emptyFile) {
      return const ConversionResult(
        markdown: '',
        converterId: 'plain_text',
        elapsed: Duration.zero,
        warnings: [ConversionWarning('файл пуст')],
      );
    }

    final decoded = decodeTextBytes(request.bytes);
    final warnings = decoded.wasUtf8
        ? const <ConversionWarning>[]
        : const [ConversionWarning('кодировка определена как Windows-1251')];
    return ConversionResult(
      markdown: decoded.content,
      converterId: 'plain_text',
      elapsed: Duration.zero,
      warnings: warnings,
    );
  }
}

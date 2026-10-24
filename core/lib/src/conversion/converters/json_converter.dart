import 'dart:convert';
import 'dart:typed_data';

import '../../markdown_writer.dart' as md;
import '../../stream_info.dart';
import '../../text_decoding.dart';
import '../../type_detection/detected_type.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';

const _prettyEncoder = JsonEncoder.withIndent('  ');

/// `JSON` is emitted as a fenced code block rather than turned into a
/// markdown structure — this loses less information, and it is readable by
/// both a human and an LLM. The decision is recorded in
/// `docs/format-coverage.md`.
class JsonConverter implements DocumentConverter {
  const JsonConverter();

  @override
  String get id => 'json';

  @override
  double get priority => 0.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) =>
      info.detectedType.kind == FileKind.text && info.extension == 'json';

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final decoded = decodeTextBytes(request.bytes);

    Object? parsed;
    try {
      parsed = jsonDecode(decoded.content);
    } on FormatException {
      throw const ConversionCorruptedException('не удалось разобрать JSON');
    }

    return ConversionResult(
      markdown: md.codeBlock(_prettyEncoder.convert(parsed), language: 'json'),
      converterId: 'json',
      elapsed: Duration.zero,
    );
  }
}

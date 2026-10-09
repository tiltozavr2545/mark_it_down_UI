import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../../markdown_writer.dart' as md;
import '../../stream_info.dart';
import '../../text_decoding.dart';
import '../../type_detection/detected_type.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';

/// Как `json` — фенс-блок кода, не попытка построить markdown-структуру из
/// произвольного XML. См. `docs/format-coverage.md`.
class XmlConverter implements DocumentConverter {
  const XmlConverter();

  @override
  String get id => 'xml';

  @override
  double get priority => 0.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) =>
      info.detectedType.kind == FileKind.text && info.extension == 'xml';

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final decoded = decodeTextBytes(request.bytes);

    XmlDocument document;
    try {
      document = XmlDocument.parse(decoded.content);
    } on XmlException {
      throw const ConversionCorruptedException('не удалось разобрать XML');
    }

    return ConversionResult(
      markdown: md.codeBlock(
        document.toXmlString(pretty: true, indent: '  '),
        language: 'xml',
      ),
      converterId: 'xml',
      elapsed: Duration.zero,
    );
  }
}

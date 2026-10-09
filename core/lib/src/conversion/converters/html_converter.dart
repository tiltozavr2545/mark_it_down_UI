import 'dart:typed_data';

import 'package:html/parser.dart' as html_parser;
import 'package:html2md/html2md.dart' as html2md;

import '../../stream_info.dart';
import '../../text_decoding.dart';
import '../../type_detection/detected_type.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';

/// Общий формат, но не настоящий catch-all: приоритет между конкретными
/// форматами (`0.0`) и `plain text` (`10.0`), и `accepts()` проверяет
/// реальные html-сигналы — иначе он забрал бы себе любой текстовый файл
/// раньше `plain text`. См. `docs/conversion-pipeline.md#2-реестр-конвертеров`.
class HtmlConverter implements DocumentConverter {
  const HtmlConverter();

  @override
  String get id => 'html';

  @override
  double get priority => 9.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) {
    if (info.detectedType.kind != FileKind.text) return false;
    if (info.extension == 'html' || info.extension == 'htm') return true;
    return _looksLikeHtml(head);
  }

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final decoded = decodeTextBytes(request.bytes);

    String markdown;
    try {
      markdown = html2md.convert(decoded.content);
    } catch (_) {
      throw const ConversionCorruptedException('не удалось разобрать HTML');
    }

    final title = html_parser
        .parse(decoded.content)
        .querySelector('title')
        ?.text
        .trim();

    return ConversionResult(
      markdown: markdown,
      converterId: 'html',
      elapsed: Duration.zero,
      title: (title == null || title.isEmpty) ? null : title,
    );
  }
}

bool _looksLikeHtml(Uint8List head) {
  final sample = StringBuffer();
  for (final byte in head.take(2048)) {
    if (byte < 128) sample.writeCharCode(byte);
  }
  final text = sample.toString().toLowerCase();
  return text.contains('<html') ||
      text.contains('<!doctype html') ||
      text.contains('<body');
}

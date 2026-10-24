import 'dart:convert';
import 'dart:typed_data';

import '../../markdown_writer.dart' as md;
import '../../stream_info.dart';
import '../../text_decoding.dart';
import '../../type_detection/detected_type.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';

/// A Jupyter notebook is valid JSON, but with its own cell structure, so it
/// gets a separate converter rather than `json`: `code` → fenced block with
/// the kernel language + text outputs below it, `markdown` stays as-is
/// (already markup), `raw` stays as plain text unchanged.
class IpynbConverter implements DocumentConverter {
  const IpynbConverter();

  @override
  String get id => 'ipynb';

  @override
  double get priority => 0.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) =>
      info.detectedType.kind == FileKind.text && info.extension == 'ipynb';

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final decoded = decodeTextBytes(request.bytes);

    Object? parsed;
    try {
      parsed = jsonDecode(decoded.content);
    } on FormatException {
      throw const ConversionCorruptedException(
        'не удалось разобрать ipynb как JSON',
      );
    }

    if (parsed is! Map || parsed['cells'] is! List) {
      throw const ConversionCorruptedException('в ipynb нет списка cells');
    }

    final kernelspec = parsed['metadata'] is Map
        ? (parsed['metadata'] as Map)['kernelspec']
        : null;
    final language = kernelspec is Map
        ? (kernelspec['language'] as String?)
        : null;

    final blocks = <String>[];
    for (final cell in parsed['cells'] as List) {
      if (cell is! Map) continue;
      final block = _renderCell(cell, language ?? 'python');
      if (block != null && block.isNotEmpty) blocks.add(block);
    }

    return ConversionResult(
      markdown: blocks.join('\n\n'),
      converterId: 'ipynb',
      elapsed: Duration.zero,
    );
  }
}

String? _renderCell(Map cell, String language) {
  final source = _joinSource(cell['source']);
  switch (cell['cell_type']) {
    case 'markdown':
    case 'raw':
      return source;
    case 'code':
      final parts = [md.codeBlock(source, language: language)];
      for (final output in (cell['outputs'] as List? ?? const [])) {
        if (output is! Map) continue;
        final text = _outputText(output);
        if (text.isNotEmpty) parts.add(text);
      }
      return parts.join('\n\n');
    default:
      return source.isEmpty ? null : source;
  }
}

String _joinSource(Object? source) {
  if (source is List) return source.map((e) => e.toString()).join();
  if (source is String) return source;
  return '';
}

// `.trimRight()`: notebook output almost always ends with its own `\n`
// (that's how Jupyter writes line-buffered stdout) — without trimming this
// leaves an extra blank line before the next block, which already adds
// `\n\n` when joining.
String _outputText(Map output) {
  switch (output['output_type']) {
    case 'stream':
      return _joinSource(output['text']).trimRight();
    case 'execute_result':
    case 'display_data':
      final data = output['data'];
      if (data is! Map) return '';
      if (data['text/plain'] != null) {
        return _joinSource(data['text/plain']).trimRight();
      }
      final hasImage = data.keys.any((k) => k.toString().startsWith('image/'));
      return hasImage ? '![вывод](output)' : '';
    case 'error':
      return '${output['ename'] ?? ''}: ${output['evalue'] ?? ''}';
    default:
      return '';
  }
}

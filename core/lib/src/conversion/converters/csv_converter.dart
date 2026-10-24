import 'dart:typed_data';

import 'package:csv/csv.dart';

import '../../markdown_writer.dart' as md;
import '../../stream_info.dart';
import '../../text_decoding.dart';
import '../../type_detection/detected_type.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';

/// `csv` and `tsv` share one converter — the only difference is the
/// delimiter. Priority `0.0`: the extension unambiguously says this is a
/// table, not plain text.
class CsvConverter implements DocumentConverter {
  const CsvConverter();

  @override
  String get id => 'csv';

  @override
  double get priority => 0.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) =>
      info.detectedType.kind == FileKind.text &&
      (info.extension == 'csv' || info.extension == 'tsv');

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final decoded = decodeTextBytes(request.bytes);
    final delimiter = request.info.extension == 'tsv' ? '\t' : ',';

    List<List<dynamic>> rows;
    try {
      rows = CsvToListConverter(
        fieldDelimiter: delimiter,
        eol: '\n',
      ).convert(decoded.content);
    } on FormatException {
      throw const ConversionCorruptedException('не удалось разобрать CSV/TSV');
    }

    if (rows.isEmpty) {
      return const ConversionResult(
        markdown: '',
        converterId: 'csv',
        elapsed: Duration.zero,
        warnings: [ConversionWarning('файл пуст')],
      );
    }

    final headers = rows.first.map((cell) => cell.toString()).toList();
    final dataRows = rows
        .skip(1)
        .map((row) => row.map((cell) => cell.toString()).toList())
        .toList();

    return ConversionResult(
      markdown: md.table(headers, dataRows),
      converterId: 'csv',
      elapsed: Duration.zero,
    );
  }
}

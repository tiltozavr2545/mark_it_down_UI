import 'dart:typed_data';

import '../../stream_info.dart';
import '../../type_detection/detected_type.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';
import '../ole2/compound_file.dart';
import '../spreadsheet/sheet_markdown.dart';
import '../xls/biff_workbook.dart';

/// Excel 97–2003 (`.xls`, BIFF8) и Excel 5–95 (BIFF5/7): поток `Workbook`
/// или `Book` из OLE2-контейнера → листы тем же рендером, что у `xlsx`
/// ([renderSheet]). На десктопе первым идёт сайдкар (настоящий markitdown
/// через `xlrd`, решение автора, Этап 5), этот конвертер — запасной путь;
/// на Android — единственный.
class XlsConverter implements DocumentConverter {
  const XlsConverter();

  @override
  String get id => 'xls';

  @override
  double get priority => 0.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) =>
      info.detectedType.kind == FileKind.xls;

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final BiffWorkbook workbook;
    try {
      final file = CompoundFile.parse(request.bytes);
      final stream =
          file.child(file.root, 'Workbook') ?? file.child(file.root, 'Book');
      if (stream == null || stream.type != CfbEntryType.stream) {
        throw const ConversionCorruptedException(
          'в файле Excel нет потока книги',
        );
      }
      workbook = BiffWorkbook.parse(file.read(stream));
    } on XlsUnsupported catch (e) {
      throw ConversionCorruptedException(e.reason);
    } on FormatException {
      throw const ConversionCorruptedException(
        'не удалось разобрать книгу Excel',
      );
    } on RangeError {
      throw const ConversionCorruptedException(
        'не удалось разобрать книгу Excel',
      );
    }

    final warnings = [
      for (final name in workbook.unreadableSheets)
        ConversionWarning('лист "$name": не удалось прочитать'),
    ];
    final blocks = [
      for (final sheet in workbook.sheets)
        renderSheet(sheet.name, sheet.cells, sheet.merges, warnings),
    ];
    return ConversionResult(
      markdown: blocks.join('\n\n'),
      converterId: id,
      elapsed: Duration.zero,
      warnings: warnings,
    );
  }
}

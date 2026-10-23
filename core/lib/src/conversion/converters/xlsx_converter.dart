import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../../stream_info.dart';
import '../../type_detection/detected_type.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';
import '../ooxml/ooxml_package.dart';
import '../spreadsheet/sheet_markdown.dart';

/// `xl/workbook.xml` + `sharedStrings.xml` + листы → Markdown-таблицы, по
/// одной под заголовком с именем листа. Формулы отдаются кэшированным
/// значением `<v>`, а не текстом `<f>`. Объединённые ячейки Markdown не
/// выражает — такой лист целиком уходит HTML-таблицей, см.
/// `docs/format-coverage.md`.
class XlsxConverter implements DocumentConverter {
  const XlsxConverter();

  @override
  String get id => 'xlsx';

  @override
  double get priority => 0.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) =>
      info.detectedType.kind == FileKind.xlsx;

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final pkg = OoxmlPackage.read(request.bytes);
    final workbook = pkg.partXml('xl/workbook.xml');
    if (workbook == null) {
      throw const ConversionCorruptedException(
        'не удалось разобрать xl/workbook.xml',
      );
    }

    final sharedStrings = _parseSharedStrings(
      pkg.partXml('xl/sharedStrings.xml'),
    );
    final sheetRels = pkg.relationshipsFor('xl/workbook.xml');
    final dates = _DateStyles.parse(pkg.partXml('xl/styles.xml'), workbook);
    final warnings = <ConversionWarning>[];
    final blocks = <String>[];

    for (final sheet in workbook.findAllElements('sheet')) {
      final name = sheet.getAttribute('name') ?? 'Sheet';
      final path = sheetRels[sheet.getAttribute('r:id')];
      final sheetXml = path == null ? null : pkg.partXml(path);
      if (sheetXml == null) {
        // Молча выкинутый лист — потеря данных без следа; лучше сказать.
        warnings.add(ConversionWarning('лист "$name": не удалось прочитать'));
        continue;
      }
      blocks.add(_renderSheet(name, sheetXml, sharedStrings, dates, warnings));
    }

    return ConversionResult(
      markdown: blocks.join('\n\n'),
      converterId: 'xlsx',
      elapsed: Duration.zero,
      title: pkg.coreTitle(),
      warnings: warnings,
    );
  }
}

List<String> _parseSharedStrings(XmlDocument? doc) {
  if (doc == null) return const [];
  return doc
      .findAllElements('si')
      .map((si) => si.findAllElements('t').map((t) => t.innerText).join())
      .toList();
}

String _renderSheet(
  String name,
  XmlDocument sheetXml,
  List<String> sharedStrings,
  _DateStyles dates,
  List<ConversionWarning> warnings,
) {
  final grid = <int, Map<int, String>>{};
  final rows = sheetXml
      .findAllElements('sheetData')
      .expand((sheetData) => sheetData.findElements('row'));
  for (final row in rows) {
    for (final cell in row.findElements('c')) {
      final ref = cell.getAttribute('r');
      if (ref == null) continue;
      grid.putIfAbsent(_rowFromRef(ref) - 1, () => {})[_columnIndex(ref)] =
          _cellValue(cell, sharedStrings, dates);
    }
  }

  final merges = sheetXml
      .findAllElements('mergeCell')
      .map((m) => m.getAttribute('ref'))
      .whereType<String>()
      .map(_parseMergeRange)
      .toList();
  return renderSheet(name, grid, merges, warnings);
}

String _cellValue(
  XmlElement cell,
  List<String> sharedStrings,
  _DateStyles dates,
) {
  final type = cell.getAttribute('t');
  if (type == 'inlineStr') {
    return cell.findAllElements('t').map((t) => t.innerText).join();
  }

  final value = cell.getElement('v')?.innerText;
  if (value == null) return '';
  switch (type) {
    case 's':
      final index = int.tryParse(value);
      return (index == null || index >= sharedStrings.length)
          ? ''
          : sharedStrings[index];
    case 'b':
      return value == '1' ? 'TRUE' : 'FALSE';
    case null:
    case 'n':
      // Дата в xlsx — обычное число (дни от эпохи) со стилем «формат даты»;
      // без этой проверки `2024-03-01` выходит как `45352`.
      final styleIndex = int.tryParse(cell.getAttribute('s') ?? '');
      if (styleIndex != null && dates.isDateStyle(styleIndex)) {
        final serial = double.tryParse(value);
        if (serial != null) return dates.format(serial) ?? value;
      }
      return value;
    default:
      return value;
  }
}

/// Какие стили ячеек (`cellXfs` из `xl/styles.xml`) — даты, и от какой эпохи
/// считать серийные номера (`date1904` в `workbook.xml`).
class _DateStyles {
  final Set<int> _dateXfs;
  final bool date1904;

  _DateStyles._(this._dateXfs, this.date1904);

  factory _DateStyles.parse(XmlDocument? styles, XmlDocument workbook) {
    final date1904 =
        workbook
            .findAllElements('workbookPr')
            .firstOrNull
            ?.getAttribute('date1904') ==
        '1';
    if (styles == null) return _DateStyles._(const {}, date1904);

    final codes = <int, String>{
      for (final fmt in styles.findAllElements('numFmt'))
        if (int.tryParse(fmt.getAttribute('numFmtId') ?? '') case final id?)
          id: fmt.getAttribute('formatCode') ?? '',
    };
    final dateXfs = <int>{};
    final xfs = styles
        .findAllElements('cellXfs')
        .firstOrNull
        ?.findElements('xf')
        .toList();
    for (var i = 0; xfs != null && i < xfs.length; i++) {
      final id = int.tryParse(xfs[i].getAttribute('numFmtId') ?? '');
      if (id != null && isExcelDateFormat(id, codes[id])) dateXfs.add(i);
    }
    return _DateStyles._(dateXfs, date1904);
  }

  bool isDateStyle(int index) => _dateXfs.contains(index);

  String? format(double serial) => formatExcelDate(serial, date1904: date1904);
}

/// `A1`-стиль ссылки → индекс столбца с нуля.
int _columnIndex(String ref) {
  final letters = RegExp(r'^[A-Z]+').firstMatch(ref)!.group(0)!;
  var index = 0;
  for (final code in letters.codeUnits) {
    index = index * 26 + (code - 'A'.codeUnitAt(0) + 1);
  }
  return index - 1;
}

int _rowFromRef(String ref) =>
    int.parse(RegExp(r'[0-9]+$').firstMatch(ref)!.group(0)!);

/// `A1:B2` → `(startRow, startCol, rowSpan, colSpan)`, индексы с нуля — то,
/// что принимает `htmlTable`.
MergeRange _parseMergeRange(String ref) {
  final parts = ref.split(':');
  final start = parts.first;
  final end = parts.length > 1 ? parts[1] : parts.first;
  final startCol = _columnIndex(start);
  final startRow = _rowFromRef(start) - 1;
  final endCol = _columnIndex(end);
  final endRow = _rowFromRef(end) - 1;
  return (startRow, startCol, endRow - startRow + 1, endCol - startCol + 1);
}

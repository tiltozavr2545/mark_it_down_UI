import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../../markdown_writer.dart' as md;
import '../../stream_info.dart';
import '../../type_detection/detected_type.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';
import '../ooxml/ooxml_package.dart';

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
  var maxCol = -1;
  var maxRow = -1;

  final rows = sheetXml
      .findAllElements('sheetData')
      .expand((sheetData) => sheetData.findElements('row'));
  for (final row in rows) {
    for (final cell in row.findElements('c')) {
      final ref = cell.getAttribute('r');
      if (ref == null) continue;
      final colIndex = _columnIndex(ref);
      final rowIndex = _rowFromRef(ref) - 1;
      grid.putIfAbsent(rowIndex, () => {})[colIndex] = _cellValue(
        cell,
        sharedStrings,
        dates,
      );
      if (colIndex > maxCol) maxCol = colIndex;
      if (rowIndex > maxRow) maxRow = rowIndex;
    }
  }

  final heading = md.heading(2, name);
  if (maxCol < 0) {
    return '$heading\n\n*лист пуст*';
  }

  final headers = List.generate(maxCol + 1, _columnLetter);
  final body = List.generate(
    maxRow + 1,
    (r) => List.generate(maxCol + 1, (c) => grid[r]?[c] ?? ''),
  );

  final mergeRefs = sheetXml
      .findAllElements('mergeCell')
      .map((m) => m.getAttribute('ref'))
      .whereType<String>()
      .toList();
  if (mergeRefs.isNotEmpty) {
    warnings.add(
      ConversionWarning(
        'лист "$name": объединённые ячейки, таблица отдана как HTML',
      ),
    );
    final merges = mergeRefs.map(_parseMergeRange).toList();
    return '$heading\n\n${md.htmlTable(headers, body, merges)}';
  }

  // `md.table` заканчивается собственным `\n` после последней строки —
  // обрезаем, чтобы не плодить лишнюю пустую строку между листами при
  // склейке через `\n\n`.
  return '$heading\n\n${md.table(headers, body).trimRight()}';
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
      if (id != null && _isDateFormat(id, codes[id])) dateXfs.add(i);
    }
    return _DateStyles._(dateXfs, date1904);
  }

  bool isDateStyle(int index) => _dateXfs.contains(index);

  /// `yyyy-MM-dd` для целого числа дней, `HH:mm:ss` для доли суток,
  /// `yyyy-MM-dd HH:mm:ss` для остального; `null` — число не похоже на
  /// дату (отрицательное, не конечное), тогда остаётся как есть.
  String? format(double serial) {
    if (!serial.isFinite || serial < 0) return null;
    // Excel считает 1900 високосным: до 1 марта 1900 серийные номера
    // сдвинуты на день относительно «честной» эпохи 30.12.1899.
    final epoch = date1904
        ? DateTime.utc(1904)
        : serial < 60
        ? DateTime.utc(1899, 12, 31)
        : DateTime.utc(1899, 12, 30);
    final at = epoch.add(Duration(milliseconds: (serial * 86400000).round()));
    String two(int n) => n.toString().padLeft(2, '0');
    final date =
        '${at.year.toString().padLeft(4, '0')}-${two(at.month)}-${two(at.day)}';
    final time = '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
    if (serial == serial.floorToDouble()) return date;
    if (serial < 1) return time;
    return '$date $time';
  }
}

/// Встроенные форматы дат/времени Excel (14–22, 27–36, 45–47, 50–58) и
/// пользовательские коды, где вне кавычек и скобок встречаются `y`, `m`, `d`,
/// `h`, `s` (`[h]`, `[mm]`, `[ss]` — тоже время). `General` и числовые
/// форматы этих букв не содержат.
bool _isDateFormat(int id, String? code) {
  if ((id >= 14 && id <= 22) ||
      (id >= 27 && id <= 36) ||
      (id >= 45 && id <= 47) ||
      (id >= 50 && id <= 58)) {
    return true;
  }
  if (code == null) return false;
  final stripped = code
      .replaceAll(RegExp(r'"[^"]*"'), '')
      .replaceAll(RegExp(r'\\.'), '')
      .replaceAll(RegExp(r'\[(?![hms]+\])[^\]]*\]', caseSensitive: false), '');
  return RegExp(r'[ymdhs]', caseSensitive: false).hasMatch(stripped);
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

/// Индекс столбца с нуля → буквы (`0` → `A`, `26` → `AA`).
String _columnLetter(int index) {
  var n = index + 1;
  final letters = <String>[];
  while (n > 0) {
    final remainder = (n - 1) % 26;
    letters.add(String.fromCharCode('A'.codeUnitAt(0) + remainder));
    n = (n - 1) ~/ 26;
  }
  return letters.reversed.join();
}

/// `A1:B2` → `(startRow, startCol, rowSpan, colSpan)`, индексы с нуля — то,
/// что принимает [md.htmlTable].
(int, int, int, int) _parseMergeRange(String ref) {
  final parts = ref.split(':');
  final start = parts.first;
  final end = parts.length > 1 ? parts[1] : parts.first;
  final startCol = _columnIndex(start);
  final startRow = _rowFromRef(start) - 1;
  final endCol = _columnIndex(end);
  final endRow = _rowFromRef(end) - 1;
  return (startRow, startCol, endRow - startRow + 1, endCol - startCol + 1);
}

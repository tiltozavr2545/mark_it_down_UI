/// Shared between `xlsx` and `xls`: sheet → Markdown and Excel dates.
/// The two formats store the same thing (the cell grid, date serials,
/// number format codes) differently, but must render it identically —
/// otherwise the same sheet, saved in the 2003 and 2007 formats, would
/// read differently.
library;

import '../../markdown_writer.dart' as md;
import '../conversion_result.dart';

/// A merge range `(startRow, startCol, rowSpan, colSpan)`, zero-based
/// indices — what [md.htmlTable] accepts.
typedef MergeRange = (int, int, int, int);

/// The header is the column letters (A, B, C…), not the first row of
/// data: on a sheet, that row isn't necessarily a header. Markdown can't
/// express merged cells — such a sheet is rendered entirely as an HTML
/// table with a warning. [grid] is row → column → value, zero-based
/// indices.
String renderSheet(
  String name,
  Map<int, Map<int, String>> grid,
  List<MergeRange> merges,
  List<ConversionWarning> warnings,
) {
  var maxCol = -1;
  var maxRow = -1;
  for (final MapEntry(key: row, value: cells) in grid.entries) {
    for (final col in cells.keys) {
      if (col > maxCol) maxCol = col;
      if (row > maxRow) maxRow = row;
    }
  }

  final heading = md.heading(2, name);
  if (maxCol < 0) {
    return '$heading\n\n*лист пуст*';
  }

  final headers = List.generate(maxCol + 1, columnLetter);
  final body = List.generate(
    maxRow + 1,
    (r) => List.generate(maxCol + 1, (c) => grid[r]?[c] ?? ''),
  );

  if (merges.isNotEmpty) {
    warnings.add(
      ConversionWarning(
        'лист "$name": объединённые ячейки, таблица отдана как HTML',
      ),
    );
    return '$heading\n\n${md.htmlTable(headers, body, merges)}';
  }

  // `md.table` ends with its own `\n` after the last row — trim it so
  // we don't get an extra blank line between sheets when joining with
  // `\n\n`.
  return '$heading\n\n${md.table(headers, body).trimRight()}';
}

/// A zero-based column index → letters (`0` → `A`, `26` → `AA`).
String columnLetter(int index) {
  var n = index + 1;
  final letters = <String>[];
  while (n > 0) {
    final remainder = (n - 1) % 26;
    letters.add(String.fromCharCode('A'.codeUnitAt(0) + remainder));
    n = (n - 1) ~/ 26;
  }
  return letters.reversed.join();
}

/// Excel's built-in date/time formats (14–22, 27–36, 45–47, 50–58) and
/// custom codes where `y`, `m`, `d`, `h`, `s` occur outside quotes and
/// brackets (`[h]`, `[mm]`, `[ss]` are also time). `General` and numeric
/// formats don't contain these letters.
bool isExcelDateFormat(int id, String? code) {
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

/// `yyyy-MM-dd` for a whole number of days, `HH:mm:ss` for a fraction of
/// a day, `yyyy-MM-dd HH:mm:ss` for the rest; `null` — the number
/// doesn't look like a date (negative, not finite), in which case it's
/// left as-is. [date1904] is the workbook's epoch (`date1904` in
/// `workbook.xml`, `DATEMODE` in xls).
String? formatExcelDate(double serial, {required bool date1904}) {
  if (!serial.isFinite || serial < 0) return null;
  // Excel treats 1900 as a leap year: before March 1, 1900, serial
  // numbers are shifted by a day relative to the "honest" epoch of
  // 1899-12-30.
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

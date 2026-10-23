/// Общее для `xlsx` и `xls`: лист → Markdown и даты Excel. Два формата
/// хранят одно и то же (сетку ячеек, серийные даты, коды числовых форматов)
/// по-разному, а отдавать обязаны одинаково — иначе один и тот же лист,
/// сохранённый в 2003 и 2007 форматах, читался бы по-разному.
library;

import '../../markdown_writer.dart' as md;
import '../conversion_result.dart';

/// Диапазон объединения `(startRow, startCol, rowSpan, colSpan)`, индексы с
/// нуля — то, что принимает [md.htmlTable].
typedef MergeRange = (int, int, int, int);

/// Заголовок — буквы столбцов (A, B, C…), а не первая строка данных: на
/// листе она не обязана быть заголовком. Объединённые ячейки Markdown не
/// выражает — такой лист целиком уходит HTML-таблицей с предупреждением.
/// [grid] — строка → столбец → значение, индексы с нуля.
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

  // `md.table` заканчивается собственным `\n` после последней строки —
  // обрезаем, чтобы не плодить лишнюю пустую строку между листами при
  // склейке через `\n\n`.
  return '$heading\n\n${md.table(headers, body).trimRight()}';
}

/// Индекс столбца с нуля → буквы (`0` → `A`, `26` → `AA`).
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

/// Встроенные форматы дат/времени Excel (14–22, 27–36, 45–47, 50–58) и
/// пользовательские коды, где вне кавычек и скобок встречаются `y`, `m`, `d`,
/// `h`, `s` (`[h]`, `[mm]`, `[ss]` — тоже время). `General` и числовые
/// форматы этих букв не содержат.
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

/// `yyyy-MM-dd` для целого числа дней, `HH:mm:ss` для доли суток,
/// `yyyy-MM-dd HH:mm:ss` для остального; `null` — число не похоже на
/// дату (отрицательное, не конечное), тогда остаётся как есть.
/// [date1904] — эпоха книги (`date1904` в `workbook.xml`, `DATEMODE` в xls).
String? formatExcelDate(double serial, {required bool date1904}) {
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

/// Единая сборка Markdown-примитивов, которые реально нужны конвертерам.
/// Экранирование и построение таблиц живёт здесь и только здесь — см.
/// `docs/conversion-pipeline.md#как-markdown-собирается` и правило в
/// `AGENTS.md` про то, почему это не должно разойтись по конвертерам.
library;

/// Экранирует символы, которые в Markdown значат разметку, а не себя:
/// `\`, `*`, `_`, `` ` ``, `#`, `|`, `[`, `]`.
String escapeInline(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    if (_escaped.contains(char)) buffer.write('\\');
    buffer.write(char);
  }
  return buffer.toString();
}

const _escaped = {'\\', '*', '_', '`', '#', '|', '[', ']'};

/// Markdown-таблица из заголовка и строк. Ячейки экранируются через
/// [escapeInline], переносы строк внутри ячейки заменяются на `<br>` —
/// Markdown-таблица не умеет многострочные ячейки иначе. Строки короче
/// заголовка дополняются пустыми ячейками, длиннее — лишние хвостовые ячейки
/// склеиваются в последнюю: таблица должна остаться прямоугольной, а не
/// кидать исключение на «рваных» данных.
String table(List<String> headers, List<List<String>> rows) {
  if (headers.isEmpty) return '';

  final buffer = StringBuffer();
  buffer.writeln(_tableRow(headers.map(escapeInline).toList()));
  buffer.writeln(_tableRow(List.filled(headers.length, '---')));
  for (final row in rows) {
    buffer.writeln(_tableRow(_fitRow(row, headers.length).map(_cell).toList()));
  }
  return buffer.toString();
}

List<String> _fitRow(List<String> row, int width) {
  if (row.length == width) return row;
  if (row.length < width) {
    return [...row, ...List.filled(width - row.length, '')];
  }
  final head = row.sublist(0, width - 1);
  final tail = row.sublist(width - 1).join(' ');
  return [...head, tail];
}

String _cell(String value) => escapeInline(value.replaceAll('\n', '<br>'));

String _tableRow(List<String> cells) => '| ${cells.join(' | ')} |';

/// Заголовок уровня [level] (1–6).
String heading(int level, String text) => '${'#' * level} $text';

/// Полужирный текст. Экранирование — через [escapeInline], как у любого
/// инлайн-текста, прежде чем обернуть его в разметку.
String bold(String text) => '**${escapeInline(text)}**';

/// Курсив — см. [bold].
String italic(String text) => '*${escapeInline(text)}*';

/// Markdown-ссылка. [href] не экранируется — это URL, а не текст, который
/// может содержать значащие Markdown-символы.
String link(String text, String href) => '[${escapeInline(text)}]($href)';

/// Таблица как HTML-блок, а не Markdown-таблица, — для листов с
/// объединёнными ячейками: Markdown-таблица их не выражает, см.
/// `docs/conversion-pipeline.md#как-markdown-собирается`. [merges] — диапазоны
/// слияния в виде `(startRow, startCol, rowSpan, colSpan)`, индексы с нуля
/// **относительно [rows]** (данных), не включая строку заголовка — заголовок
/// сам никогда не участвует в слиянии. Ячейки, покрытые слиянием, но не
/// являющиеся его началом, не выводятся.
String htmlTable(
  List<String> headers,
  List<List<String>> rows,
  List<(int, int, int, int)> merges,
) {
  final allRows = [headers, ...rows];
  final covered = <int, Set<int>>{};
  final spanAt = <int, Map<int, (int, int)>>{};
  for (final (startRow, startCol, rowSpan, colSpan) in merges) {
    final r0 = startRow + 1; // +1: строка заголовка в allRows не из rows.
    spanAt.putIfAbsent(r0, () => {})[startCol] = (rowSpan, colSpan);
    for (var r = r0; r < r0 + rowSpan; r++) {
      for (var c = startCol; c < startCol + colSpan; c++) {
        if (r == r0 && c == startCol) continue;
        covered.putIfAbsent(r, () => {}).add(c);
      }
    }
  }

  final buffer = StringBuffer('<table>\n');
  for (var r = 0; r < allRows.length; r++) {
    final row = allRows[r];
    buffer.writeln('  <tr>');
    final tag = r == 0 ? 'th' : 'td';
    for (var c = 0; c < row.length; c++) {
      if (covered[r]?.contains(c) ?? false) continue;
      final span = spanAt[r]?[c];
      final attrs = span == null
          ? ''
          : [
              if (span.$1 > 1) ' rowspan="${span.$1}"',
              if (span.$2 > 1) ' colspan="${span.$2}"',
            ].join();
      buffer.writeln('    <$tag$attrs>${_htmlEscape(row[c])}</$tag>');
    }
    buffer.writeln('  </tr>');
  }
  buffer.write('</table>');
  return buffer.toString();
}

String _htmlEscape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// Фенс-блок кода. [language] попадает в info-строку фенса (````json`), если
/// задан. Контент не экранируется — внутри фенса всё значит себя.
String codeBlock(String content, {String? language}) {
  final fence = '```${language ?? ''}';
  final body = content.endsWith('\n') ? content : '$content\n';
  return '$fence\n$body```';
}

/// A single collection of the Markdown primitives converters actually
/// need. Escaping and table building live here, and only here — see
/// `docs/conversion-pipeline.md#как-markdown-собирается` and the rule in
/// `AGENTS.md` about why this must not spread across converters.
library;

/// Escapes characters that mean markup rather than themselves in
/// Markdown: `\`, `*`, `_`, `` ` ``, `#`, `|`, `[`, `]`.
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

/// A Markdown table from a header and rows. Cells are escaped via
/// [escapeInline]; line breaks inside a cell are replaced with `<br>` —
/// a Markdown table has no other way to handle multi-line cells. Rows
/// shorter than the header are padded with empty cells; rows longer than
/// it have their extra trailing cells merged into the last one: the
/// table must stay rectangular rather than throw on "jagged" data.
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

/// A heading at [level] (1-6).
String heading(int level, String text) => '${'#' * level} $text';

/// Bold text. Escaped via [escapeInline], like any inline text, before
/// being wrapped in markup.
String bold(String text) => '**${escapeInline(text)}**';

/// Italic — see [bold].
String italic(String text) => '*${escapeInline(text)}*';

/// A Markdown link. [href] isn't escaped — it's a URL, not text that
/// might contain meaningful Markdown characters.
String link(String text, String href) => '[${escapeInline(text)}]($href)';

/// A table as an HTML block rather than a Markdown table — for sheets
/// with merged cells: a Markdown table can't express those, see
/// `docs/conversion-pipeline.md#как-markdown-собирается`. [merges] is the
/// merge ranges as `(startRow, startCol, rowSpan, colSpan)`, zero-based
/// **relative to [rows]** (the data), not including the header row — the
/// header itself is never part of a merge. Cells covered by a merge but
/// not its starting cell aren't emitted.
String htmlTable(
  List<String> headers,
  List<List<String>> rows,
  List<(int, int, int, int)> merges,
) {
  final allRows = [headers, ...rows];
  final covered = <int, Set<int>>{};
  final spanAt = <int, Map<int, (int, int)>>{};
  for (final (startRow, startCol, rowSpan, colSpan) in merges) {
    final r0 = startRow + 1; // +1: the header row in allRows isn't from rows.
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

/// A fenced code block. [language] goes into the fence's info string
/// (````json`), if given. Content isn't escaped — inside a fence,
/// everything means itself.
String codeBlock(String content, {String? language}) {
  final fence = '```${language ?? ''}';
  final body = content.endsWith('\n') ? content : '$content\n';
  return '$fence\n$body```';
}

/// The normalization markitdown applies to any converter's output:
/// `\r\n` → `\n`, trailing whitespace on lines is stripped, three or more
/// consecutive line breaks collapse to two. Needed wherever a Dart
/// converter must match markitdown character-for-character (`msg`,
/// `rss`).
String normalizeLikeMarkitdown(String text) => text
    .split(RegExp(r'\r?\n'))
    .map((line) => line.trimRight())
    .join('\n')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n');

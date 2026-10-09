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

/// Фенс-блок кода. [language] попадает в info-строку фенса (````json`), если
/// задан. Контент не экранируется — внутри фенса всё значит себя.
String codeBlock(String content, {String? language}) {
  final fence = '```${language ?? ''}';
  final body = content.endsWith('\n') ? content : '$content\n';
  return '$fence\n$body```';
}

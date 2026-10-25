import 'dart:convert';
import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';
import 'package:test/test.dart';

/// Merging several converted files into one `.md` (0.10): the format is the
/// author's choice — a `# name` heading per file, `---` between files, the
/// files' own Markdown untouched.
void main() {
  ConversionResult result(
    String markdown, {
    List<String> warnings = const [],
    int ms = 0,
  }) => ConversionResult(
    markdown: markdown,
    converterId: 'plain_text',
    elapsed: Duration(milliseconds: ms),
    warnings: [for (final w in warnings) ConversionWarning(w)],
  );

  test('heading per file, separator between files, in the given order', () {
    final merged = mergeResults([
      MergePart('report.pdf', result('# Введение\n\nТекст.\n')),
      MergePart('contract.docx', result('Договор.')),
    ]);
    expect(
      merged.markdown,
      '# report.pdf\n\n# Введение\n\nТекст.\n\n---\n\n'
      '# contract.docx\n\nДоговор.\n',
    );
    expect(merged.converterId, 'merge');
  });

  test('a single file — just its heading and content, no separator', () {
    final merged = mergeResults([MergePart('a.txt', result('A'))]);
    expect(merged.markdown, '# a.txt\n\nA\n');
  });

  test('a file with no text keeps its heading', () {
    final merged = mergeResults([
      MergePart('scan.pdf', result('\n\n')),
      MergePart('b.txt', result('B')),
    ]);
    expect(merged.markdown, '# scan.pdf\n\n---\n\n# b.txt\n\nB\n');
  });

  test('blank lines around the content are trimmed, indentation kept', () {
    final merged = mergeResults([
      MergePart('code.md', result('\n\n    indented code\n\n\n')),
    ]);
    expect(merged.markdown, '# code.md\n\n    indented code\n');
  });

  test('markup characters in a filename are escaped', () {
    final merged = mergeResults([MergePart('*draft*_#2.md', result('x'))]);
    expect(
      merged.markdown,
      startsWith(
        r'# \*draft\*\_\#2.md'
        '\n',
      ),
    );
  });

  test('a page by link — the heading links to its address', () {
    final merged = mergeResults([
      MergePart('Статья', result('x'), url: 'https://example.com/a'),
    ]);
    expect(merged.markdown, startsWith('# [Статья](https://example.com/a)\n'));
  });

  test('warnings are prefixed with the file name, time is summed', () {
    final merged = mergeResults([
      MergePart('a.pdf', result('A', warnings: ['скан без текста'], ms: 5)),
      MergePart('b.xlsx', result('B', warnings: ['объединённые'], ms: 7)),
    ]);
    expect(merged.warnings.map((w) => w.message), [
      'a.pdf: скан без текста',
      'b.xlsx: объединённые',
    ]);
    expect(merged.elapsed, const Duration(milliseconds: 12));
  });

  test('real conversions of different formats merge as converted', () async {
    final registry = ConverterRegistry.defaultRegistry();
    Future<ConversionResult> convert(String text, String filename) async {
      final bytes = Uint8List.fromList(utf8.encode(text));
      final info = StreamInfo.fromHead(bytes, filename: filename);
      return (await registry.convert(bytes, info) as ConversionSuccess).result;
    }

    final csv = await convert('a,b\n1,2\n', 'data.csv');
    final txt = await convert('Привет', 'note.txt');
    final merged = mergeResults([
      MergePart('data.csv', csv),
      MergePart('note.txt', txt),
    ]);
    expect(
      merged.markdown,
      '# data.csv\n\n${csv.markdown.trim()}\n\n---\n\n'
      '# note.txt\n\n${txt.markdown.trim()}\n',
    );
  });
}

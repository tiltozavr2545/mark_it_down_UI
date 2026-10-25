import 'package:markitdown_core/src/conversion/pdf/pdf_tables.dart';
import 'package:test/test.dart';

/// The table heuristic on its own, without PDFium: characters are laid out
/// by hand the way `_extractChars` produces them (a 612pt Letter page,
/// `top` is the baseline).
void main() {
  const pageWidth = 612.0;
  var nextIndex = 0;

  /// One character per letter, [charWidth] wide each, starting at [x].
  List<PdfChar> text(
    String value,
    double x,
    double top, {
    double charWidth = 6,
  }) => [
    for (var i = 0; i < value.length; i++)
      PdfChar(
        index: nextIndex++,
        text: value[i],
        x0: x + i * charWidth,
        x1: x + (i + 1) * charWidth,
        top: top,
      ),
  ];

  setUp(() => nextIndex = 0);

  group('extractWords', () {
    test('a space holds a cell together, a column gap splits it', () {
      final words = extractWords([
        ...text('New York', 72, 100),
        ...text('8300000', 250, 100),
      ]);
      expect(words.map((w) => w.text), ['New York', '8300000']);
    });

    test('characters of one line are sorted left to right', () {
      final words = extractWords([
        ...text('right', 300, 100),
        ...text('left', 72, 100),
      ]);
      expect(words.map((w) => w.text), ['left', 'right']);
    });

    test('a space seen twice is written once', () {
      final words = extractWords([
        ...text('id', 72, 100),
        // PDFium's own space and a blank text object over the same spot.
        const PdfChar(index: 100, text: ' ', x0: 84, x1: 90, top: 100),
        const PdfChar(index: -1, text: ' ', x0: 84, x1: 150, top: 100),
        ...text('serial', 150, 100),
      ]);
      expect(words.map((w) => w.text), ['id serial']);
      expect(words.single.charIndices, isNot(contains(-1)));
    });

    test('a lone space is a word of its own, as in pdfplumber', () {
      final words = extractWords([
        ...text('a', 72, 100),
        const PdfChar(index: 50, text: ' ', x0: 300, x1: 303, top: 100),
      ]);
      expect(words.map((w) => w.text), ['a', ' ']);
    });
  });

  group('findTables', () {
    test('rows lining up into columns are a table, prose around is not', () {
      final words = extractWords([
        ...text('Cities of Europe', 72, 60),
        ...text('City', 72, 100),
        ...text('Population', 250, 100),
        ...text('Country', 430, 100),
        ...text('Berlin', 72, 124),
        ...text('3700000', 250, 124),
        ...text('Germany', 430, 124),
        ...text('Paris', 72, 148),
        ...text('2100000', 250, 148),
        ...text('France', 430, 148),
      ]);
      final tables = findTables(words, pageWidth);
      expect(tables, hasLength(1));
      expect(tables.single.rows, [
        ['City', 'Population', 'Country'],
        ['Berlin', '3700000', 'Germany'],
        ['Paris', '2100000', 'France'],
      ]);
      final title = words.first.charIndices.first;
      expect(tables.single.charIndices, isNot(contains(title)));
    });

    test('a page of prose has no tables', () {
      const line =
          'The quick brown fox jumps over the lazy dog and keeps on running';
      final words = extractWords([
        for (var row = 0; row < 5; row++) ...text(line, 72, 100.0 + row * 20),
      ]);
      expect(findTables(words, pageWidth), isEmpty);
    });

    test('a long justified line with trailing spaces counts as prose', () {
      // Words of a justified line: each keeps its trailing space, and with
      // them the row passes markitdown's 60-character "prose" threshold.
      final row = <PdfChar>[];
      var x = 72.0;
      // 55 characters with single spaces — a table row by length alone.
      const line = 'Type of index by default is B-tree, good for most cases';
      for (final word in line.split(' ')) {
        row.addAll(text('$word ', x, 100));
        x += (word.length + 1) * 6 + 5; // a stretched gap after the space
      }
      final words = extractWords([
        ...row,
        ...text('next', 72, 124),
        ...text('line', 250, 124),
      ]);
      expect(words.first.text, endsWith(' '));
      expect(findTables(words, pageWidth), isEmpty);
    });
  });
}

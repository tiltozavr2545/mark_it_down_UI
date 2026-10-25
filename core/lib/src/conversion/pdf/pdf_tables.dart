/// Tables on a PDF page found by how words line up into columns — a port
/// of `_extract_form_content_from_words` from markitdown 0.1.8
/// (`converters/_pdf_converter.py`), the same thing the sidecar does via
/// pdfplumber. Not ruling lines: markitdown doesn't look at them either,
/// and the point is for the Dart core and the sidecar to agree on which
/// rows are a table. The numeric thresholds are markitdown's, kept as-is
/// so the two stay comparable; only the output differs — cells go through
/// `markdown_writer.table` (escaping, no padding) like every other table
/// in the core.
library;

import 'dart:math' as math;

/// A single character from the page's content stream in pdfplumber's
/// coordinates: `top` is measured from the top of the page. [index] is
/// the character's index in PDFium's text page — it ties a table back to
/// the lines the rest of the converter works with.
class PdfChar {
  final int index;
  final String text;
  final double x0;
  final double x1;
  final double top;

  const PdfChar({
    required this.index,
    required this.text,
    required this.x0,
    required this.x1,
    required this.top,
  });
}

/// A word in pdfplumber's sense with `keep_blank_chars=True`: a run of
/// characters with no horizontal gap wider than the tolerance, so
/// "New York" in one cell is one word. [text] keeps a trailing space the
/// way pdfplumber does: markitdown measures a row's length with those
/// spaces in it, and "longer than 60 characters" is what tells a line of
/// prose from a table row.
class PdfWord {
  final String text;
  final double x0;
  final double x1;
  final double top;
  final List<int> charIndices;

  const PdfWord({
    required this.text,
    required this.x0,
    required this.x1,
    required this.top,
    required this.charIndices,
  });
}

/// A table found on a page: the first row is the header, as in
/// markitdown. [charIndices] are all the characters of its rows.
class PdfTable {
  final List<List<String>> rows;
  final Set<int> charIndices;

  const PdfTable({required this.rows, required this.charIndices});
}

/// pdfplumber's `extract_words(keep_blank_chars=True, x_tolerance=3,
/// y_tolerance=3)`: characters are clustered into lines by `top`, sorted
/// left to right, and a word breaks on a gap wider than 3pt, on a step
/// back, or on a jump in height.
///
/// Two differences, both because our spaces are rebuilt rather than read
/// (see `_extractChars`): a gap is measured from the right edge of the
/// word so far, not of its last character, and a space overlapping the
/// space before it is the same space seen twice (PDFium's text page and
/// a blank text object), so it's merged, not doubled — a doubled space
/// would also stretch the row past markitdown's 60-character "prose"
/// threshold. A word of nothing but a space is kept, as pdfplumber keeps
/// it: markitdown counts it as a column position like any other word.
List<PdfWord> extractWords(List<PdfChar> chars) {
  const xTolerance = 3.0;
  const yTolerance = 3.0;
  if (chars.isEmpty) return const [];

  // `List.sort` isn't stable: ties are broken by the original order, or
  // a word would depend on the sort's whims.
  final order = {for (var i = 0; i < chars.length; i++) chars[i]: i};
  int byOrder(PdfChar a, PdfChar b) => order[a]!.compareTo(order[b]!);

  final byTop = [...chars]
    ..sort((a, b) {
      final c = a.top.compareTo(b.top);
      return c != 0 ? c : byOrder(a, b);
    });
  final lines = <List<PdfChar>>[];
  double? lastTop;
  for (final char in byTop) {
    if (lastTop == null || char.top > lastTop + yTolerance) lines.add([]);
    lines.last.add(char);
    lastTop = char.top;
  }

  final words = <PdfWord>[];
  for (final line in lines) {
    line.sort((a, b) {
      final c = a.x0.compareTo(b.x0);
      return c != 0 ? c : byOrder(a, b);
    });
    final text = StringBuffer();
    final indices = <int>[];
    PdfChar? prev;
    late double x0, x1, top;
    void flush() {
      if (prev != null) {
        words.add(
          PdfWord(
            text: text.toString(),
            x0: x0,
            x1: x1,
            top: top,
            charIndices: [...indices],
          ),
        );
      }
      text.clear();
      indices.clear();
      prev = null;
    }

    for (final char in line) {
      final last = prev;
      if (last != null &&
          (char.x0 < last.x0 ||
              char.x0 > x1 + xTolerance ||
              (char.top - last.top).abs() > yTolerance)) {
        flush();
      }
      if (prev == null) {
        x0 = char.x0;
        x1 = char.x1;
        top = char.top;
      } else {
        x1 = math.max(x1, char.x1);
        top = math.min(top, char.top);
      }
      final doubledSpace =
          char.text == ' ' && last?.text == ' ' && char.x0 < last!.x1;
      if (!doubledSpace) text.write(char.text);
      if (char.index >= 0) indices.add(char.index);
      prev = char;
    }
    flush();
  }
  return words;
}

/// MasterFormat-style partial numbering (`.1`, `.10`) — a list item, not
/// a table row.
final _partialNumbering = RegExp(r'^\.\d+$');

class _Row {
  final List<PdfWord> words;
  final String text;
  final List<double> xGroups;
  final bool isParagraph;
  final bool hasPartialNumbering;
  bool isTableRow = false;

  _Row(
    this.words,
    this.text,
    this.xGroups,
    this.isParagraph,
    this.hasPartialNumbering,
  );
}

/// The tables on a page, or an empty list if the page doesn't look like a
/// form — then its text goes out as ordinary paragraphs. Every early
/// `return const []` below is one of markitdown's `return None`.
List<PdfTable> findTables(List<PdfWord> words, double pageWidth) {
  if (words.isEmpty) return const [];

  // Rows by `top` rounded to 5pt, as in markitdown (not by clustering).
  const yBucket = 5;
  final rowsByY = <int, List<PdfWord>>{};
  for (final word in words) {
    final key = (word.top / yBucket).round() * yBucket;
    (rowsByY[key] ??= []).add(word);
  }

  final rows = <_Row>[];
  for (final key in rowsByY.keys.toList()..sort()) {
    final rowWords = [...rowsByY[key]!]..sort((a, b) => a.x0.compareTo(b.x0));
    final lineWidth = rowWords.last.x1 - rowWords.first.x0;
    final text = rowWords.map((w) => w.text).join(' ');

    final xGroups = <double>[];
    for (final x in rowWords.map((w) => w.x0).toList()..sort()) {
      if (xGroups.isEmpty || x - xGroups.last > 50) xGroups.add(x);
    }

    rows.add(
      _Row(
        rowWords,
        text,
        xGroups,
        lineWidth > pageWidth * 0.55 && text.length > 60,
        _partialNumbering.hasMatch(rowWords.first.text.trim()),
      ),
    );
  }

  // The page's column structure comes from rows with 3+ columns.
  final tableXs = <double>[
    for (final row in rows)
      if (row.xGroups.length >= 3 && !row.isParagraph) ...row.xGroups,
  ]..sort();
  if (tableXs.isEmpty) return const [];

  final gaps = <double>[
    for (var i = 0; i < tableXs.length - 1; i++)
      if (tableXs[i + 1] - tableXs[i] > 5) tableXs[i + 1] - tableXs[i],
  ]..sort();
  // The 70th percentile of the gaps, clamped to [25, 50].
  final tolerance = gaps.length >= 3
      ? gaps[(gaps.length * 0.70).toInt()].clamp(25.0, 50.0)
      : 35.0;

  final columns = <double>[];
  for (final x in tableXs) {
    if (columns.isEmpty || x - columns.last > tolerance) columns.add(x);
  }
  if (columns.length <= 1) return const [];

  final contentWidth = columns.last - columns.first;
  // Very narrow columns or too many per inch — dense text, not a form.
  if (contentWidth / columns.length < 30) return const [];
  if (columns.length / (contentWidth / 72) > 10) return const [];
  final maxColumns = math.max(15, (20 * (pageWidth / 612)).toInt());
  if (columns.length > maxColumns) return const [];

  for (final row in rows) {
    if (row.isParagraph || row.hasPartialNumbering) continue;
    final aligned = <int>{};
    for (final word in row.words) {
      for (var c = 0; c < columns.length; c++) {
        if ((word.x0 - columns[c]).abs() < 40) {
          aligned.add(c);
          break;
        }
      }
    }
    row.isTableRow = aligned.length >= 2;
  }

  final regions = <(int, int)>[];
  for (var i = 0; i < rows.length;) {
    if (!rows[i].isTableRow) {
      i++;
      continue;
    }
    final start = i;
    while (i < rows.length && rows[i].isTableRow) {
      i++;
    }
    regions.add((start, i));
  }

  // Fewer than 20% table rows — not a form page.
  final tableRows = regions.fold(0, (sum, r) => sum + r.$2 - r.$1);
  if (tableRows / rows.length < 0.2) return const [];

  List<String> cells(_Row row) {
    final result = List.filled(columns.length, '');
    for (final word in row.words) {
      var column = columns.length - 1;
      for (var c = 0; c < columns.length - 1; c++) {
        if (word.x0 < columns[c + 1] - 20) {
          column = c;
          break;
        }
      }
      result[column] = result[column].isEmpty
          ? word.text
          : '${result[column]} ${word.text}';
    }
    return [for (final cell in result) cell.trim()];
  }

  return [
    for (final (start, end) in regions)
      PdfTable(
        rows: [for (var i = start; i < end; i++) cells(rows[i])],
        charIndices: {
          for (var i = start; i < end; i++)
            for (final word in rows[i].words) ...word.charIndices,
        },
      ),
  ];
}

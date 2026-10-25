import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'pdf_tables.dart';
import 'pdfium_bindings.dart';

/// A single line of text, in the shape PDFium splits the page into visual
/// lines (`\r\n` between them in `FPDFText_GetText`). `fontSize` and `top`
/// are the metrics of the line's first non-space character: enough to
/// tell a heading apart from regular text and to join lines of one
/// paragraph that were wrapped at the page width, without parsing the
/// letterform itself.
class PdfLine {
  final String text;
  final double fontSize;
  final double top;

  /// The line is a row of `PdfPage.tables[tableIndex]` — judged by its
  /// first non-space character; `null` for ordinary text.
  final int? tableIndex;

  const PdfLine({
    required this.text,
    required this.fontSize,
    required this.top,
    this.tableIndex,
  });

  bool get isBlank => text.isEmpty;
}

class PdfPage {
  final List<PdfLine> lines;

  /// Tables found by how words line up into columns, see `pdf_tables.dart`.
  final List<PdfTable> tables;

  /// Not a single character of text, but the page has an image — looks
  /// like a scan, see `docs/implementation-plan.md#этап-3-pdf-03`.
  final bool looksLikeScan;

  /// Text recognized by OCR on a scanned page; `null` — OCR wasn't run
  /// (no engine, page beyond the limit), an empty string — it ran but
  /// found no text.
  final String? ocrText;

  const PdfPage({
    required this.lines,
    required this.looksLikeScan,
    this.tables = const [],
    this.ocrText,
  });
}

/// Recognizes a rendered page: BGRx pixels (4 bytes per pixel),
/// dimensions, the row stride in bytes, and the render resolution.
/// Returns the text.
typedef PdfPageRecognizer =
    String Function(
      Pointer<Uint8> pixels,
      int width,
      int height,
      int stride,
      int dpi,
    );

/// The page render resolution for OCR: 300 dpi is what Tesseract is
/// trained on; lower loses small print, higher takes longer with no gain.
const _ocrDpi = 300;

/// The bitmap's long side is capped at this: an A0 drawing at 300 dpi is
/// 14,000 px and hundreds of megabytes of memory.
const _maxOcrSide = 5000;

class PdfExtractionResult {
  final List<PdfPage> pages;

  const PdfExtractionResult(this.pages);
}

/// PDFium failed to open the document — a password or unreadable bytes.
class PdfLoadException implements Exception {
  final String reason;

  const PdfLoadException(this.reason);

  @override
  String toString() => reason;
}

/// Parses the whole PDF into memory via PDFium. Synchronous and
/// CPU-heavy — the calling code is already inside `Isolate.run`, see
/// `docs/client-architecture.md#конвертация-в-изоляте`.
///
/// [recognize] — OCR for scanned pages, at most [maxOcrPages] of them in
/// order; without it, scanned pages are only flagged via
/// [PdfPage.looksLikeScan].
PdfExtractionResult extractPdf(
  Uint8List bytes, {
  PdfPageRecognizer? recognize,
  int maxOcrPages = 0,
}) {
  final pdfium = PdfiumBindings.instance();
  final fileBuffer = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  try {
    fileBuffer.asTypedList(bytes.length).setAll(0, bytes);
    final document = pdfium.loadMemDocument(
      fileBuffer.cast<Void>(),
      bytes.length,
    );
    if (document.address == 0) {
      throw PdfLoadException(_describeLoadError(pdfium.getLastError()));
    }
    try {
      final pageCount = pdfium.getPageCount(document);
      var ocrBudget = recognize == null ? 0 : maxOcrPages;
      final pages = <PdfPage>[];
      for (var i = 0; i < pageCount; i++) {
        final page = _extractPage(
          pdfium,
          document,
          i,
          ocrBudget > 0 ? recognize : null,
        );
        if (page.ocrText != null) ocrBudget--;
        pages.add(page);
      }
      return PdfExtractionResult(pages);
    } finally {
      pdfium.closeDocument(document);
    }
  } finally {
    calloc.free(fileBuffer);
  }
}

String _describeLoadError(int code) {
  const passwordOrSecurity = {4, 5}; // FPDF_ERR_PASSWORD, FPDF_ERR_SECURITY
  if (passwordOrSecurity.contains(code)) {
    return 'PDF защищён паролем';
  }
  return 'не удалось разобрать PDF';
}

PdfPage _extractPage(
  PdfiumBindings pdfium,
  Pointer<Void> document,
  int index,
  PdfPageRecognizer? recognize,
) {
  final page = pdfium.loadPage(document, index);
  if (page.address == 0) {
    return const PdfPage(lines: [], looksLikeScan: false);
  }

  PdfPage withoutText() {
    if (!_hasImageObject(pdfium, page)) {
      return const PdfPage(lines: [], looksLikeScan: false);
    }
    return PdfPage(
      lines: const [],
      looksLikeScan: true,
      ocrText: recognize == null
          ? null
          : _recognizePage(pdfium, page, recognize),
    );
  }

  try {
    final textPage = pdfium.textLoadPage(page);
    if (textPage.address == 0) return withoutText();
    try {
      final charCount = pdfium.textCountChars(textPage);
      if (charCount <= 0) return withoutText();
      final tables = findTables(
        extractWords(
          _extractChars(
            pdfium,
            page,
            textPage,
            charCount,
            pdfium.getPageHeight(page),
          ),
        ),
        pdfium.getPageWidth(page),
      );
      return PdfPage(
        lines: _extractLines(pdfium, textPage, charCount, tables),
        looksLikeScan: false,
        tables: tables,
      );
    } finally {
      pdfium.textClosePage(textPage);
    }
  } finally {
    pdfium.closePage(page);
  }
}

/// Renders the page as BGRx on a white background and runs OCR. The
/// bitmap is owned by PDFium and lives only for the duration of the
/// [recognize] call.
String _recognizePage(
  PdfiumBindings pdfium,
  Pointer<Void> page,
  PdfPageRecognizer recognize,
) {
  final widthPt = pdfium.getPageWidth(page);
  final heightPt = pdfium.getPageHeight(page);
  if (widthPt <= 0 || heightPt <= 0) return '';
  final longestPt = widthPt > heightPt ? widthPt : heightPt;
  final dpi = (longestPt / 72 * _ocrDpi > _maxOcrSide)
      ? (_maxOcrSide * 72 / longestPt).floor()
      : _ocrDpi;
  final width = (widthPt / 72 * dpi).round();
  final height = (heightPt / 72 * dpi).round();
  if (width <= 0 || height <= 0) return '';

  final bitmap = pdfium.bitmapCreate(width, height);
  if (bitmap.address == 0) return '';
  try {
    pdfium.bitmapFill(bitmap, width, height, 0xFFFFFFFF);
    pdfium.renderPageBitmap(bitmap, page, width, height);
    return recognize(
      pdfium.bitmapBuffer(bitmap),
      width,
      height,
      pdfium.bitmapStride(bitmap),
      dpi,
    );
  } finally {
    pdfium.bitmapDestroy(bitmap);
  }
}

/// A page with no text but at least one image — what `format-coverage.md`
/// calls "looks like a scan". An empty page with not a single object is
/// just an empty page, not a warning.
bool _hasImageObject(PdfiumBindings pdfium, Pointer<Void> page) {
  final count = pdfium.pageCountObjects(page);
  for (var i = 0; i < count; i++) {
    final object = pdfium.pageGetObject(page, i);
    if (object.address != 0 &&
        pdfium.pageObjGetType(object) == fpdfPageObjImage) {
      return true;
    }
  }
  return false;
}

/// The page's characters in pdfplumber's terms: `x0`/`x1` from the loose
/// box (the origin and the advance width, like pdfminer's), but `top` is
/// the baseline, not the top of a box. Boxes of different fonts on one
/// line start at different heights (2.5pt apart for Times and Courier on
/// a real Word PDF), and markitdown groups rows by `top` in 5pt buckets —
/// a cell in a code font would land in a row of its own. pdfminer's boxes
/// happen to line up there; the baseline lines up always.
///
/// Spaces need care, because they are what holds "New York" together as
/// one word: without them every word of a short line becomes its own
/// "column" and the line, a table row. pdfminer keeps every space glyph
/// of the content stream; PDFium drops them and puts in its own — one per
/// gap, zero-width, flagged "generated" (on a real Word PDF every single
/// space was) — and leaves objects made only of spaces out altogether
/// (see [_blankTextObjects]). So a generated space is rebuilt the way
/// pdfminer sees it: from where the previous character ends, as wide as
/// the font's own space. A real space keeps its glyph, but of a run of
/// spaces inside one text object PDFium keeps only the first (Word lines
/// up `id          serial` in a listing exactly so). The rest of the run
/// is stretched back in: up to the next character if it's in the same
/// object, otherwise up to where the object ends (its bounds take a
/// space's origin, so plus one space) — but never past the next
/// character.
List<PdfChar> _extractChars(
  PdfiumBindings pdfium,
  Pointer<Void> page,
  Pointer<Void> textPage,
  int charCount,
  double pageHeight,
) {
  final textBuffer = calloc<Uint16>(charCount + 1);
  final rect = calloc<FS_RECTF>();
  final originX = calloc<Double>();
  final originY = calloc<Double>();
  final spaces = _SpaceMeter(pdfium);
  try {
    final written = pdfium.textGetText(textPage, 0, charCount, textBuffer);
    final length = written > 0 ? written - 1 : 0;
    final codeUnits = textBuffer.asTypedList(length);
    final chars = <PdfChar>[];
    PdfChar? prev;
    var prevHeight = 0.0;
    // A real space just added: its object, to stretch it over a run.
    Pointer<Void>? spaceObject;
    for (var i = 0; i < length; i++) {
      final unit = codeUnits[i];
      if (unit == 0x0D || unit == 0x0A || unit == 0) continue;
      if (pdfium.textIsGenerated(textPage, i)) {
        final before = prev;
        if (unit == 0x20 && before != null && before.text != ' ') {
          final width =
              spaces.width(pdfium.textGetTextObject(textPage, before.index)) ??
              prevHeight * 0.25;
          final space = PdfChar(
            index: i,
            text: ' ',
            x0: before.x1,
            x1: before.x1 + width,
            top: before.top,
          );
          chars.add(space);
          prev = space;
        }
        continue;
      }
      if (!pdfium.textGetLooseCharBox(textPage, i, rect) ||
          !pdfium.textGetCharOrigin(textPage, i, originX, originY)) {
        continue;
      }
      final box = rect.ref;
      final char = PdfChar(
        index: i,
        text: String.fromCharCode(unit),
        x0: math.min(box.left, box.right),
        x1: math.max(box.left, box.right),
        top: pageHeight - originY.value,
      );
      final object = pdfium.textGetTextObject(textPage, i);
      final space = prev;
      final runObject = spaceObject;
      if (runObject != null &&
          space != null &&
          (char.top - space.top).abs() < 1) {
        final end = object.address == runObject.address
            ? char.x0
            : math.min(spaces.runEnd(runObject) ?? space.x1, char.x0);
        if (end > space.x1) {
          chars.last = PdfChar(
            index: space.index,
            text: ' ',
            x0: space.x0,
            x1: end,
            top: space.top,
          );
        }
      }
      spaceObject = unit == 0x20 ? object : null;
      chars.add(char);
      prev = char;
      prevHeight = (box.top - box.bottom).abs();
    }
    chars.addAll(_blankTextObjects(pdfium, page, textPage, spaces, pageHeight));
    return chars;
  } finally {
    calloc.free(textBuffer);
    calloc.free(rect);
    calloc.free(originX);
    calloc.free(originY);
    spaces.dispose();
  }
}

/// Text objects made of nothing but spaces — PDFium leaves them out of
/// the text page entirely, pdfminer keeps every glyph. Word draws a run
/// of spaces (code indentation, alignment in a listing) as an object of
/// its own; without it `id   serial   PRIMARY KEY` falls apart into
/// "columns" and a code listing turns into a table. Each such object
/// becomes one blank character over its width. Its bounds run from the
/// first space's origin to the last one's (a space has no outline), so
/// one more space is added on the right. Not linked to any line: the
/// index is `-1`.
List<PdfChar> _blankTextObjects(
  PdfiumBindings pdfium,
  Pointer<Void> page,
  Pointer<Void> textPage,
  _SpaceMeter spaces,
  double pageHeight,
) {
  const bufferUnits = 64;
  final buffer = calloc<Uint16>(bufferUnits);
  final left = calloc<Float>();
  final bottom = calloc<Float>();
  final right = calloc<Float>();
  final top = calloc<Float>();
  try {
    final chars = <PdfChar>[];
    final count = pdfium.pageCountObjects(page);
    for (var i = 0; i < count; i++) {
      final object = pdfium.pageGetObject(page, i);
      if (object.address == 0 ||
          pdfium.pageObjGetType(object) != fpdfPageObjText) {
        continue;
      }
      final bytes = pdfium.textObjGetText(
        object,
        textPage,
        buffer,
        bufferUnits * 2,
      );
      // Longer than the buffer — certainly not a run of spaces.
      if (bytes > bufferUnits * 2) continue;
      final units = bytes ~/ 2 - 1; // without the trailing NUL
      final text = units > 0
          ? String.fromCharCodes(buffer.asTypedList(units))
          : '';
      if (text.trim().isNotEmpty) continue;
      final width = spaces.width(object);
      if (width == null ||
          !pdfium.pageObjGetBounds(object, left, bottom, right, top)) {
        continue;
      }
      chars.add(
        PdfChar(
          index: -1,
          text: ' ',
          x0: left.value,
          x1: right.value + width,
          top: pageHeight - bottom.value,
        ),
      );
    }
    return chars;
  } finally {
    calloc.free(buffer);
    calloc.free(left);
    calloc.free(bottom);
    calloc.free(right);
    calloc.free(top);
  }
}

/// The width of a space on the page in a given text object: the font's
/// advance for U+0020 at the object's size, scaled by its matrix (which
/// already includes the CTM — on a Word PDF that's 0.75). Cached per
/// object: a line's generated spaces mostly share one. `null` — the font
/// has no space or the object is gone; the caller falls back to an
/// estimate.
class _SpaceMeter {
  _SpaceMeter(this._pdfium);

  final PdfiumBindings _pdfium;
  final _size = calloc<Float>();
  final _width = calloc<Float>();
  final _matrix = calloc<FS_MATRIX>();
  final _left = calloc<Float>();
  final _bottom = calloc<Float>();
  final _right = calloc<Float>();
  final _top = calloc<Float>();
  final _cache = <int, double?>{};

  double? width(Pointer<Void> object) {
    if (object.address == 0) return null;
    return _cache.putIfAbsent(object.address, () {
      final font = _pdfium.textObjGetFont(object);
      if (font.address == 0 ||
          !_pdfium.textObjGetFontSize(object, _size) ||
          !_pdfium.fontGetGlyphWidth(font, 0x20, _size.value, _width) ||
          !_pdfium.pageObjGetMatrix(object, _matrix)) {
        return null;
      }
      final m = _matrix.ref;
      final width = _width.value * math.sqrt(m.a * m.a + m.b * m.b);
      return width > 0 ? width : null;
    });
  }

  /// Where a text object's last space ends: its right bound (the last
  /// space's origin) plus one space.
  double? runEnd(Pointer<Void> object) {
    final space = width(object);
    if (space == null ||
        !_pdfium.pageObjGetBounds(object, _left, _bottom, _right, _top)) {
      return null;
    }
    return _right.value + space;
  }

  void dispose() {
    calloc.free(_size);
    calloc.free(_width);
    calloc.free(_matrix);
    calloc.free(_left);
    calloc.free(_bottom);
    calloc.free(_right);
    calloc.free(_top);
  }
}

List<PdfLine> _extractLines(
  PdfiumBindings pdfium,
  Pointer<Void> textPage,
  int charCount,
  List<PdfTable> tables,
) {
  final textBuffer = calloc<Uint16>(charCount + 1);
  try {
    final written = pdfium.textGetText(textPage, 0, charCount, textBuffer);
    final length = written > 0 ? written - 1 : 0; // without the trailing '\0'
    final codeUnits = textBuffer.asTypedList(length);

    final lines = <PdfLine>[];
    var lineStart = 0;

    void flush(int end) {
      final rep = _firstNonSpace(codeUnits, lineStart, end);
      if (rep == -1) {
        lines.add(const PdfLine(text: '', fontSize: 0, top: 0));
        return;
      }
      final tableIndex = tables.indexWhere((t) => t.charIndices.contains(rep));
      lines.add(
        PdfLine(
          text: String.fromCharCodes(codeUnits, lineStart, end).trim(),
          fontSize: pdfium.textGetFontSize(textPage, rep),
          top: _charTop(pdfium, textPage, rep),
          tableIndex: tableIndex == -1 ? null : tableIndex,
        ),
      );
    }

    var i = 0;
    while (i < length) {
      final unit = codeUnits[i];
      if (unit == 0x0D || unit == 0x0A) {
        flush(i);
        i += (unit == 0x0D && i + 1 < length && codeUnits[i + 1] == 0x0A)
            ? 2
            : 1;
        lineStart = i;
        continue;
      }
      i++;
    }
    flush(length);
    return lines;
  } finally {
    calloc.free(textBuffer);
  }
}

int _firstNonSpace(Uint16List codeUnits, int start, int end) {
  for (var i = start; i < end; i++) {
    final unit = codeUnits[i];
    if (unit != 0x20 && unit != 0x09) return i;
  }
  return -1;
}

double _charTop(PdfiumBindings pdfium, Pointer<Void> textPage, int index) {
  final left = calloc<Double>();
  final right = calloc<Double>();
  final bottom = calloc<Double>();
  final top = calloc<Double>();
  try {
    pdfium.textGetCharBox(textPage, index, left, right, bottom, top);
    return top.value;
  } finally {
    calloc.free(left);
    calloc.free(right);
    calloc.free(bottom);
    calloc.free(top);
  }
}

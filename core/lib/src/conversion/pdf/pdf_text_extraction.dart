import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

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

  const PdfLine({
    required this.text,
    required this.fontSize,
    required this.top,
  });

  bool get isBlank => text.isEmpty;
}

class PdfPage {
  final List<PdfLine> lines;

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

/// Just the page count, without parsing the text: PDFium reads the page
/// tree, not its content, so this stays cheap even on a large file.
/// `null` — if the document failed to open (password, garbage) or the
/// library itself failed to load: the caller decides what to do, instead
/// of catching an exception.
int? countPdfPages(Uint8List bytes) {
  final PdfiumBindings pdfium;
  try {
    pdfium = PdfiumBindings.instance();
  } on Object {
    return null;
  }
  final fileBuffer = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  try {
    fileBuffer.asTypedList(bytes.length).setAll(0, bytes);
    final document = pdfium.loadMemDocument(
      fileBuffer.cast<Void>(),
      bytes.length,
    );
    if (document.address == 0) return null;
    try {
      return pdfium.getPageCount(document);
    } finally {
      pdfium.closeDocument(document);
    }
  } finally {
    calloc.free(fileBuffer);
  }
}

/// Whether the PDF has a page without text but with an image (same test
/// as [PdfPage.looksLikeScan]) — without rendering or OCR. `null` — the
/// document failed to open or PDFium failed to load, the caller decides.
bool? pdfHasScanPages(Uint8List bytes) {
  final PdfiumBindings pdfium;
  try {
    pdfium = PdfiumBindings.instance();
  } on Object {
    return null;
  }
  final fileBuffer = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  try {
    fileBuffer.asTypedList(bytes.length).setAll(0, bytes);
    final document = pdfium.loadMemDocument(
      fileBuffer.cast<Void>(),
      bytes.length,
    );
    if (document.address == 0) return null;
    try {
      final pageCount = pdfium.getPageCount(document);
      for (var i = 0; i < pageCount; i++) {
        if (_extractPage(pdfium, document, i, null).looksLikeScan) return true;
      }
      return false;
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
      return PdfPage(
        lines: _extractLines(pdfium, textPage, charCount),
        looksLikeScan: false,
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

List<PdfLine> _extractLines(
  PdfiumBindings pdfium,
  Pointer<Void> textPage,
  int charCount,
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
      lines.add(
        PdfLine(
          text: String.fromCharCodes(codeUnits, lineStart, end).trim(),
          fontSize: pdfium.textGetFontSize(textPage, rep),
          top: _charTop(pdfium, textPage, rep),
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

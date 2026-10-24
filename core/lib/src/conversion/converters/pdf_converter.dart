import 'dart:ffi';
import 'dart:typed_data';

import '../../markdown_writer.dart' as md;
import '../../stream_info.dart';
import '../../type_detection/detected_type.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';
import '../ocr/tesseract_ocr.dart';
import '../pdf/pdf_text_extraction.dart';

/// Text extraction via PDFium (FFI, not a plugin — see
/// `docs/format-coverage.md#решения-этапа-3` for the engine choice).
/// We don't do tables — it's more honest to return text than a broken
/// grid (see the same section). Headings are detected by font size
/// relative to the document's typical text size; if a PDF has not a
/// single character of text, that's not an error: pages with no text
/// layer go into `warnings`, and the rest of the text is returned as-is
/// (a partial result is more useful than a failure).
///
/// With [ocr], scanned pages are rendered and recognized by Tesseract
/// (Stage 6) — no more than [OcrSettings.maxPdfPages] of them; the
/// recognized text takes the page's place, and `warnings` records which
/// pages and which engine.
class PdfConverter implements DocumentConverter {
  const PdfConverter({this.ocr});

  final OcrSettings? ocr;

  @override
  String get id => 'pdf';

  @override
  double get priority => 0.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) =>
      info.detectedType.kind == FileKind.pdf;

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final settings = ocr;
    // The engine opens on the first scanned page, not ahead of time:
    // loading the models takes half a second, and a PDF with a text layer
    // shouldn't have to pay for it.
    TesseractOcr? engine;
    var engineUnavailable = false;
    final confidences = <int>[];
    String recognize(Pointer<Uint8> pixels, int w, int h, int stride, int dpi) {
      if (engineUnavailable) return '';
      engine ??= TesseractOcr.open(settings!);
      final opened = engine;
      if (opened == null) {
        engineUnavailable = true;
        return '';
      }
      final result = opened.recognizePixels(pixels, w, h, 4, stride, dpi);
      if (result.text.trim().isNotEmpty) confidences.add(result.confidence);
      return result.text;
    }

    final PdfExtractionResult extraction;
    try {
      extraction = extractPdf(
        request.bytes,
        recognize: settings == null ? null : recognize,
        maxOcrPages: settings?.maxPdfPages ?? 0,
      );
    } on PdfLoadException catch (e) {
      throw ConversionCorruptedException(e.reason);
    } finally {
      engine?.dispose();
    }

    final bodySize = _bodyFontSize(extraction.pages);
    final markdown = _render(extraction.pages, bodySize);

    final pages = extraction.pages;
    bool recognized(PdfPage page) => page.ocrText?.trim().isNotEmpty ?? false;
    final ocrPages = [
      for (var i = 0; i < pages.length; i++)
        if (pages[i].looksLikeScan && recognized(pages[i])) i + 1,
    ];
    final scanPages = [
      for (var i = 0; i < pages.length; i++)
        if (pages[i].looksLikeScan && !recognized(pages[i])) i + 1,
    ];
    final skippedByLimit =
        settings != null &&
        !engineUnavailable &&
        pages.where((p) => p.looksLikeScan && p.ocrText == null).isNotEmpty;

    final warnings = <ConversionWarning>[
      if (ocrPages.isNotEmpty) ConversionWarning(_ocrWarning(ocrPages, engine)),
      if (confidences.isNotEmpty &&
          confidences.reduce((a, b) => a + b) / confidences.length <
              lowOcrConfidence)
        const ConversionWarning(
          'уверенность распознавания низкая — проверьте текст сканов',
        ),
      if (scanPages.isNotEmpty) ConversionWarning(_scanWarning(scanPages)),
      if (skippedByLimit)
        ConversionWarning(
          'OCR выполнен только для первых ${settings.maxPdfPages} '
          'страниц-сканов',
        ),
      if (engineUnavailable && scanPages.isNotEmpty)
        const ConversionWarning(
          'распознавание текста недоступно: нет движка OCR или языковых '
          'моделей',
        ),
      if (markdown.isEmpty && scanPages.isEmpty && ocrPages.isEmpty)
        const ConversionWarning('в PDF не найдено текста'),
    ];

    return ConversionResult(
      markdown: markdown,
      converterId: 'pdf',
      elapsed: Duration.zero,
      warnings: warnings,
    );
  }
}

/// The document's typical body font size — the most frequent size among
/// non-blank lines, weighted by text length (otherwise a short heading in
/// a large font could outweigh the paragraphs). `null` if the document has
/// no text at all — then headings aren't highlighted, and all the text
/// goes out as plain text, as described in the plan.
double? _bodyFontSize(List<PdfPage> pages) {
  final weightBySize = <double, double>{};
  for (final page in pages) {
    for (final line in page.lines) {
      if (line.isBlank) continue;
      final bucket = (line.fontSize * 2).round() / 2;
      weightBySize[bucket] = (weightBySize[bucket] ?? 0) + line.text.length;
    }
  }
  if (weightBySize.isEmpty) return null;
  return weightBySize.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
}

/// A heading is a line noticeably larger than the typical text and shorter
/// than a "sentence the length of a paragraph". Ordinary text is glued into
/// paragraphs: adjacent lines with no vertical gap are a width-based wrap
/// within one paragraph, not a new paragraph — the same "text doesn't wrap
/// by width" rule as in `markdown_writer`, just applied on input rather
/// than on output.
String _render(List<PdfPage> pages, double? bodySize) {
  final buffer = StringBuffer();
  var wroteAnything = false;
  var pendingParagraphBreak = true;
  double? prevTop;
  double? prevFontSize;

  void startParagraph() {
    if (wroteAnything) buffer.write('\n\n');
    wroteAnything = true;
  }

  for (final page in pages) {
    prevTop = null;
    prevFontSize = null;

    final ocrText = page.ocrText;
    if (ocrText != null) {
      for (final paragraph in ocrParagraphs(ocrText)) {
        startParagraph();
        buffer.write(md.escapeInline(paragraph));
      }
      pendingParagraphBreak = true;
      continue;
    }

    for (final line in page.lines) {
      if (line.isBlank) {
        pendingParagraphBreak = true;
        continue;
      }

      final text = md.escapeInline(line.text);
      final isHeading =
          bodySize != null &&
          line.fontSize > bodySize * 1.15 &&
          line.text.length <= 120;

      if (isHeading) {
        final level = line.fontSize >= bodySize * 1.5
            ? 1
            : line.fontSize >= bodySize * 1.3
            ? 2
            : 3;
        startParagraph();
        buffer.write(md.heading(level, text));
        pendingParagraphBreak = true;
        prevTop = null;
        prevFontSize = null;
        continue;
      }

      // `top` is the top of the bbox of the line's first character, not the
      // baseline: a line starting with a letter that has no ascender
      // (`c`, `e`) has its top 1-2pt lower than one starting with `T` or
      // `l`, even at the same real line spacing. Threshold 2.0 — with
      // margin over this noise and well clear of a paragraph break (on the
      // fixtures, noise is ~1.5pt, a break is ~3x the font size).
      final isContinuation =
          !pendingParagraphBreak &&
          prevTop != null &&
          prevFontSize != null &&
          (prevTop - line.top).abs() <= prevFontSize * 2.0;

      if (isContinuation) {
        buffer.write(' ');
        buffer.write(text);
      } else {
        startParagraph();
        buffer.write(text);
      }
      pendingParagraphBreak = false;
      prevTop = line.top;
      prevFontSize = line.fontSize;
    }
    pendingParagraphBreak = true; // a page boundary is always a new paragraph
  }
  return buffer.toString();
}

String _ocrWarning(List<int> pages, TesseractOcr? engine) {
  final (word, ranges) = _pagesPhrase(pages);
  final verb = word == 'страница' ? 'распознана' : 'распознаны';
  return '$word $ranges $verb OCR (${engine?.engine ?? 'Tesseract'}) — '
      'возможны ошибки распознавания';
}

String _scanWarning(List<int> pages) {
  final (word, ranges) = _pagesPhrase(pages);
  final verb = word == 'страница' ? 'выглядит' : 'выглядят';
  final noun = word == 'страница' ? 'изображение' : 'изображения';
  return '$word $ranges $verb как $noun, текста на '
      '${word == 'страница' ? 'ней' : 'них'} нет';
}

/// `[2, 3, 5]` → (`страницы`, `2–3, 5`); a single page is `страница` (the
/// actual Russian word returned, matched to the output phrase's grammatical
/// number).
(String, String) _pagesPhrase(List<int> pages) {
  final ranges = <String>[];
  var start = pages.first;
  var prev = pages.first;
  for (final page in pages.skip(1)) {
    if (page == prev + 1) {
      prev = page;
      continue;
    }
    ranges.add(start == prev ? '$start' : '$start–$prev');
    start = page;
    prev = page;
  }
  ranges.add(start == prev ? '$start' : '$start–$prev');

  final word = ranges.length == 1 && !ranges.first.contains('–')
      ? 'страница'
      : 'страницы';
  return (word, ranges.join(', '));
}

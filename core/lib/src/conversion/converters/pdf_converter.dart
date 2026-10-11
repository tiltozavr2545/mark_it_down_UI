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

/// Извлечение текста через PDFium (FFI, не плагин — см.
/// `docs/format-coverage.md#решения-этапа-3` про выбор движка).
/// Таблицы не делаем — честнее отдать текст, чем сломанную сетку (см. там
/// же). Заголовки — по размеру шрифта относительно типового размера текста
/// в документе; если в PDF нет ни одного символа текста, это не ошибка:
/// страницы без текстового слоя уходят в `warnings`, остальной текст
/// отдаётся как есть (частичный результат полезнее отказа).
///
/// С [ocr] страницы-сканы рендерятся и распознаются Tesseract (Этап 6) —
/// не больше [OcrSettings.maxPdfPages] штук; распознанный текст встаёт на
/// место страницы, а в `warnings` пишется, какие страницы и каким движком.
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
    // Движок открывается при первой странице-скане, а не заранее: загрузка
    // моделей — полсекунды, и PDF с текстовым слоем платить её не должен.
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

/// Типовой размер шрифта текста документа — самый частый размер среди
/// непустых строк, взвешенный длиной текста (иначе короткий заголовок с
/// крупным шрифтом мог бы перевесить абзацы). `null`, если в документе нет
/// текста вовсе — тогда заголовки не выделяются, весь текст идёт плоским
/// текстом, как и описано в плане.
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

/// Заголовок — строка заметно крупнее типового текста и короче «предложения
/// длиной в абзац». Обычный текст склеивается в абзацы: соседние строки без
/// разрыва по вертикали — это перенос по ширине внутри одного абзаца, а не
/// новый абзац, и склейка здесь — то же правило «текст не переносится по
/// ширине», что в `markdown_writer`, только на входе, а не на выходе.
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

      // `top` — верх bbox первого символа строки, не базовая линия: у
      // строки, начинающейся с буквы без выносного элемента («c», «e»),
      // верх ниже, чем у «T» или «l», на 1–2pt при одном и том же реальном
      // межстрочном интервале. Порог 2.0 — с запасом над этим шумом и
      // далеко от разрыва абзаца (на фикстурах шум ≈1.5pt, разрыв ≈3×
      // кегль).
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
    pendingParagraphBreak = true; // граница страницы — всегда новый абзац
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

/// `[2, 3, 5]` → (`страницы`, `2–3, 5`); одна страница — `страница`.
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

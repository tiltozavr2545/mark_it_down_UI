import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'pdfium_bindings.dart';

/// Одна строка текста, в том виде, в каком PDFium разбивает страницу по
/// визуальным строкам (`\r\n` между ними в `FPDFText_GetText`). `fontSize` и
/// `top` — метрики первого непробельного символа строки: достаточно, чтобы
/// отличить заголовок от обычного текста и склеить перенесённые по ширине
/// строки одного абзаца, не разбирая форму буквы целиком.
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

  /// Ни одного символа текста, но на странице есть изображение — похоже на
  /// скан, см. `docs/implementation-plan.md#этап-3-pdf-03`.
  final bool looksLikeScan;

  const PdfPage({required this.lines, required this.looksLikeScan});
}

class PdfExtractionResult {
  final List<PdfPage> pages;

  const PdfExtractionResult(this.pages);
}

/// PDFium не смог открыть документ — пароль или нечитаемые байты.
class PdfLoadException implements Exception {
  final String reason;

  const PdfLoadException(this.reason);

  @override
  String toString() => reason;
}

/// Разбирает PDF целиком в память через PDFium. Синхронная и CPU-тяжёлая —
/// вызывающий код уже внутри `Isolate.run`, см.
/// `docs/client-architecture.md#конвертация-в-изоляте`.
PdfExtractionResult extractPdf(Uint8List bytes) {
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
      return PdfExtractionResult([
        for (var i = 0; i < pageCount; i++) _extractPage(pdfium, document, i),
      ]);
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

PdfPage _extractPage(PdfiumBindings pdfium, Pointer<Void> document, int index) {
  final page = pdfium.loadPage(document, index);
  if (page.address == 0) {
    return const PdfPage(lines: [], looksLikeScan: false);
  }
  try {
    final textPage = pdfium.textLoadPage(page);
    if (textPage.address == 0) {
      return PdfPage(
        lines: const [],
        looksLikeScan: _hasImageObject(pdfium, page),
      );
    }
    try {
      final charCount = pdfium.textCountChars(textPage);
      if (charCount <= 0) {
        return PdfPage(
          lines: const [],
          looksLikeScan: _hasImageObject(pdfium, page),
        );
      }
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

/// Страница без текста, но с хотя бы одной картинкой, — то, что в
/// `format-coverage.md` называется «похоже на скан». Пустая страница без
/// единого объекта — просто пустая страница, не предупреждение.
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
    final length = written > 0 ? written - 1 : 0; // без замыкающего '\0'
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

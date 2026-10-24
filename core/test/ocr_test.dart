import 'dart:io';
import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// OCR with real Tesseract (Stage 6). The expected result isn't
/// byte-exact Markdown but key phrases: OCR output depends on the engine
/// version and build (on CI Linux it's the distro package, on Windows and
/// Mac it's `tesseract/build.sh`), and what's checked here is the
/// "image/scan → text" path, not the exact digits of a specific version.
/// Fixtures come from `sidecar/samples/make_samples.py --only ocr`.
///
/// Needs the libraries (`MARKITDOWN_TESSERACT_DIR` or system ones on
/// Linux) and the `tesseract/tessdata/` models (`tesseract/fetch.sh`).
/// Without them the tests are skipped — like `sidecar_integration_test.dart`
/// without the sidecar; `make test` sets the variables itself if `make
/// tesseract` has already been built.
void main() {
  final root = Directory.current.parent.path;
  final tessdata = p.join(root, 'tesseract', 'tessdata');
  final fixtures = p.join(Directory.current.path, 'test', 'fixtures');
  final settings = OcrSettings(tessdataDir: tessdata);
  final registry = ConverterRegistry.defaultRegistry(ocr: settings);

  final available = ocrAvailable(settings);
  final skip = available
      ? false
      : 'нет Tesseract или моделей (MARKITDOWN_TESSERACT_DIR, '
            'tesseract/fetch.sh)';

  Future<ConversionResult> convert(String relative) async {
    final bytes = Uint8List.fromList(
      File(p.join(fixtures, relative)).readAsBytesSync(),
    );
    final info = StreamInfo.fromHead(bytes, filename: p.basename(relative));
    final outcome = await registry.convert(bytes, info);
    expect(outcome, isA<ConversionSuccess>());
    return (outcome as ConversionSuccess).result;
  }

  void expectInvoiceText(String markdown) {
    expect(markdown, contains('Счёт № 42 от 14 июля 2024 года'));
    expect(markdown, contains('ООО «Ромашка», ИНН 7701234567'));
    expect(markdown, contains('Invoice total: 12 500 RUB'));
  }

  test('image with text — section with recognized text', () async {
    final result = await convert('ocr/invoice.png');
    expect(result.markdown, contains('## Текст на изображении'));
    expectInvoiceText(result.markdown);
    expect(
      result.warnings.map((w) => w.message),
      contains(contains('текст распознан OCR (Tesseract')),
    );
  }, skip: skip);

  test('a "sideways" shot is rotated per EXIF Orientation', () async {
    final result = await convert('ocr/invoice_rotated.jpg');
    expectInvoiceText(result.markdown);
  }, skip: skip);

  // The Leptonica in our builds doesn't read these formats: Dart decodes
  // the frame. GIF and WebP have a transparent background, like a
  // sticker: without a backing fill the text would vanish into "black"
  // transparency.
  for (final name in ['invoice.gif', 'invoice.webp', 'invoice.tiff']) {
    test('$name — text via the Dart decoder', () async {
      final result = await convert('ocr/$name');
      expect(result.markdown, contains('## Текст на изображении'));
      expectInvoiceText(result.markdown);
    }, skip: skip);
  }

  test('PDF with no text layer — page text from OCR', () async {
    final result = await convert('ocr/invoice_scan.pdf');
    expectInvoiceText(result.markdown);
    expect(
      result.warnings.map((w) => w.message),
      contains(contains('страница 1 распознана OCR')),
    );
  }, skip: skip);

  test('image with no text — an honest "text not found"', () async {
    final result = await convert('image/screenshot.png');
    expect(result.markdown, isNot(contains('## Текст на изображении')));
    expect(
      result.warnings.map((w) => w.message),
      contains('текст на изображении не найден'),
    );
  }, skip: skip);

  test('scanned PDF over the page limit — a limit warning', () async {
    final limited = ConverterRegistry.defaultRegistry(
      ocr: OcrSettings(tessdataDir: tessdata, maxPdfPages: 1),
    );
    final bytes = Uint8List.fromList(
      File(p.join(fixtures, 'pdf', 'scanned.pdf')).readAsBytesSync(),
    );
    final outcome = await limited.convert(
      bytes,
      StreamInfo.fromHead(bytes, filename: 'scanned.pdf'),
    );
    final warnings = (outcome as ConversionSuccess).result.warnings.map(
      (w) => w.message,
    );
    expect(warnings, contains(contains('только для первых 1')));
  }, skip: skip);

  test('no models — metadata and a clear warning, not a failure', () async {
    final noModels = ConverterRegistry.defaultRegistry(
      ocr: const OcrSettings(tessdataDir: '/нет/такого/каталога'),
    );
    final bytes = Uint8List.fromList(
      File(p.join(fixtures, 'ocr', 'invoice.png')).readAsBytesSync(),
    );
    final outcome = await noModels.convert(
      bytes,
      StreamInfo.fromHead(bytes, filename: 'invoice.png'),
    );
    final result = (outcome as ConversionSuccess).result;
    expect(result.markdown, contains('- **Формат:** PNG'));
    expect(
      result.warnings.map((w) => w.message),
      contains(contains('распознавание текста недоступно')),
    );
  });
}

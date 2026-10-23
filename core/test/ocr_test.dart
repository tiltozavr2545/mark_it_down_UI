import 'dart:io';
import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// OCR на настоящем Tesseract (Этап 6). Эталон — не побайтный Markdown, а
/// ключевые фразы: вывод OCR зависит от версии движка и сборки (на CI Linux
/// — пакет дистрибутива, на Windows и Mac — `tesseract/build.sh`), а
/// проверяется здесь путь «картинка/скан → текст», а не цифры конкретной
/// версии. Фикстуры — `sidecar/samples/make_samples.py --only ocr`.
///
/// Нужны библиотеки (`MARKITDOWN_TESSERACT_DIR` или системные на Linux) и
/// модели `tesseract/tessdata/` (`tesseract/fetch.sh`). Без них тесты
/// пропускаются — как `sidecar_integration_test.dart` без сайдкара; `make
/// test` выставляет переменные сам, если `make tesseract` уже собран.
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

  test('картинка с текстом — раздел с распознанным текстом', () async {
    final result = await convert('ocr/invoice.png');
    expect(result.markdown, contains('## Текст на изображении'));
    expectInvoiceText(result.markdown);
    expect(
      result.warnings.map((w) => w.message),
      contains(contains('текст распознан OCR (Tesseract')),
    );
  }, skip: skip);

  test('снимок «боком» поворачивается по EXIF Orientation', () async {
    final result = await convert('ocr/invoice_rotated.jpg');
    expectInvoiceText(result.markdown);
  }, skip: skip);

  // Leptonica наших сборок этих форматов не читает: кадр декодирует Dart.
  // GIF и WebP — с прозрачным фоном, как стикер: без подложки текст
  // пропал бы на «чёрной» прозрачности.
  for (final name in ['invoice.gif', 'invoice.webp', 'invoice.tiff']) {
    test('$name — текст через декодер Dart', () async {
      final result = await convert('ocr/$name');
      expect(result.markdown, contains('## Текст на изображении'));
      expectInvoiceText(result.markdown);
    }, skip: skip);
  }

  test('PDF без текстового слоя — текст страницы из OCR', () async {
    final result = await convert('ocr/invoice_scan.pdf');
    expectInvoiceText(result.markdown);
    expect(
      result.warnings.map((w) => w.message),
      contains(contains('страница 1 распознана OCR')),
    );
  }, skip: skip);

  test('картинка без текста — честное «текст не найден»', () async {
    final result = await convert('image/screenshot.png');
    expect(result.markdown, isNot(contains('## Текст на изображении')));
    expect(
      result.warnings.map((w) => w.message),
      contains('текст на изображении не найден'),
    );
  }, skip: skip);

  test('PDF-скан сверх лимита страниц — предупреждение о лимите', () async {
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

  test(
    'нет моделей — метаданные и понятное предупреждение, не отказ',
    () async {
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
    },
  );
}

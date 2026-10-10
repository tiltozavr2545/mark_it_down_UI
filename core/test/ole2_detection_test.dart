import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';
import 'package:test/test.dart';

import 'support/cfb_builder.dart';

void main() {
  group('OLE2: различение по именам потоков каталога CFB', () {
    test('Workbook → xls', () {
      final bytes = buildCfb(['Workbook', '\u0005SummaryInformation']);
      expect(detectType(bytes).kind, FileKind.xls);
    });

    test('Book (BIFF5) → xls', () {
      expect(detectType(buildCfb(['Book'])).kind, FileKind.xls);
    });

    test('__properties_version1.0 → msg', () {
      final bytes = buildCfb(['__properties_version1.0']);
      expect(detectType(bytes).kind, FileKind.msg);
    });

    test('__substg1.0_* → msg', () {
      final bytes = buildCfb(['__substg1.0_0037001F', '__substg1.0_1000001F']);
      expect(detectType(bytes).kind, FileKind.msg);
    });

    test('WordDocument → doc: распознаётся, но это отдельный вид', () {
      final result = detectType(buildCfb(['WordDocument', '1Table']));
      expect(result.kind, FileKind.doc);
      expect(result.label, contains('.doc'));
    });

    test('PowerPoint Document → ppt', () {
      final bytes = buildCfb(['PowerPoint Document']);
      expect(detectType(bytes).kind, FileKind.ppt);
    });

    test('расширение врёт: msg под именем .xls остаётся msg', () {
      final bytes = buildCfb(['__properties_version1.0']);
      expect(detectType(bytes, extension: 'xls').kind, FileKind.msg);
    });

    test('каталог в нескольких секторах (цепочка по FAT)', () {
      // 12 записей при 4 на сектор = 3 сектора каталога; нужный поток — в
      // последнем.
      final names = [for (var i = 0; i < 11; i++) 'Stream$i', 'Workbook'];
      expect(detectType(buildCfb(names)).kind, FileKind.xls);
    });

    test('сектор 4096 байт (CFB версии 4)', () {
      final bytes = buildCfb(['Workbook'], sectorShift: 12);
      expect(detectType(bytes).kind, FileKind.xls);
    });

    test('неизвестные потоки — прежнее поведение: контейнер + подсказка', () {
      final bytes = buildCfb(['Something']);
      final result = detectType(bytes, extension: 'xls');
      expect(result.kind, FileKind.ole2Compound);
      expect(result.label, contains('похоже на .xls'));
    });

    test('обрезанный файл: каталог недоступен → подсказка по расширению', () {
      final full = buildCfb(['Workbook']);
      final truncated = Uint8List.sublistView(full, 0, 600);
      final result = detectType(truncated, extension: 'xls');
      expect(result.kind, FileKind.ole2Compound);
    });

    test('цепочка каталога зациклена — не зависаем', () {
      final names = [for (var i = 0; i < 8; i++) 'Stream$i'];
      final bytes = buildCfb(names, loopDirectory: true);
      expect(detectType(bytes).kind, FileKind.ole2Compound);
    });

    test('мусор после сигнатуры не роняет детектор', () {
      final bytes = Uint8List(1024)
        ..setAll(0, [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        ..fillRange(8, 1024, 0xFF);
      expect(detectType(bytes).kind, FileKind.ole2Compound);
    });
  });

  group('xls/msg/doc через реестр без сайдкара', () {
    final registry = ConverterRegistry.defaultRegistry();

    for (final (name, streams, label) in [
      ('xls', ['Workbook'], '.xls'),
      ('msg', ['__properties_version1.0'], '.msg'),
      ('doc', ['WordDocument'], '.doc'),
    ]) {
      test('$name — честное «не поддерживается» с названием формата', () async {
        final bytes = buildCfb(streams);
        final info = StreamInfo.fromHead(bytes, filename: 'file.$name');
        final outcome = await registry.convert(bytes, info);
        expect(outcome, isA<ConversionError>());
        final failure = (outcome as ConversionError).failure;
        expect(failure, isA<UnsupportedFormatFailure>());
        expect(
          (failure as UnsupportedFormatFailure).detectedTypeLabel,
          contains(label),
        );
      });
    }
  });
}

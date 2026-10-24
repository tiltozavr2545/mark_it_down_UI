import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';
import 'package:test/test.dart';

import 'support/cfb_builder.dart';

void main() {
  group('OLE2: distinguishing by CFB directory stream names', () {
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

    test('WordDocument → doc: recognized, but a separate kind', () {
      final result = detectType(buildCfb(['WordDocument', '1Table']));
      expect(result.kind, FileKind.doc);
      expect(result.label, contains('.doc'));
    });

    test('PowerPoint Document → ppt', () {
      final bytes = buildCfb(['PowerPoint Document']);
      expect(detectType(bytes).kind, FileKind.ppt);
    });

    test('extension lies: msg named .xls stays msg', () {
      final bytes = buildCfb(['__properties_version1.0']);
      expect(detectType(bytes, extension: 'xls').kind, FileKind.msg);
    });

    test('directory spanning several sectors (FAT chain)', () {
      // 12 entries at 4 per sector = 3 directory sectors; the needed
      // stream is in the last one.
      final names = [for (var i = 0; i < 11; i++) 'Stream$i', 'Workbook'];
      expect(detectType(buildCfb(names)).kind, FileKind.xls);
    });

    test('4096-byte sector (CFB version 4)', () {
      final bytes = buildCfb(['Workbook'], sectorShift: 12);
      expect(detectType(bytes).kind, FileKind.xls);
    });

    test('unknown streams — old behavior: container + hint', () {
      final bytes = buildCfb(['Something']);
      final result = detectType(bytes, extension: 'xls');
      expect(result.kind, FileKind.ole2Compound);
      expect(result.label, contains('похоже на .xls'));
    });

    test('truncated file: directory unavailable → extension hint', () {
      final full = buildCfb(['Workbook']);
      final truncated = Uint8List.sublistView(full, 0, 600);
      final result = detectType(truncated, extension: 'xls');
      expect(result.kind, FileKind.ole2Compound);
    });

    test('directory chain loops — we don\'t hang', () {
      final names = [for (var i = 0; i < 8; i++) 'Stream$i'];
      final bytes = buildCfb(names, loopDirectory: true);
      expect(detectType(bytes).kind, FileKind.ole2Compound);
    });

    test('garbage after the signature doesn\'t crash the detector', () {
      final bytes = Uint8List(1024)
        ..setAll(0, [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        ..fillRange(8, 1024, 0xFF);
      expect(detectType(bytes).kind, FileKind.ole2Compound);
    });
  });

  group('xls/msg/doc through the registry without the sidecar', () {
    final registry = ConverterRegistry.defaultRegistry();

    test('doc — an honest "not supported" with the format name', () async {
      final bytes = buildCfb(['WordDocument']);
      final info = StreamInfo.fromHead(bytes, filename: 'file.doc');
      final outcome = await registry.convert(bytes, info);
      expect(outcome, isA<ConversionError>());
      final failure = (outcome as ConversionError).failure;
      expect(failure, isA<UnsupportedFormatFailure>());
      expect(
        (failure as UnsupportedFormatFailure).detectedTypeLabel,
        contains('.doc'),
      );
    });

    // Since 0.9, xls and msg have Dart parsing.
    test(
      'xls with an empty workbook stream — "corrupted", not "not supported"',
      () async {
        final bytes = buildCfb(['Workbook']);
        final info = StreamInfo.fromHead(bytes, filename: 'file.xls');
        final outcome = await registry.convert(bytes, info);
        final failure = (outcome as ConversionError).failure;
        expect((failure as CorruptedFileFailure).converterId, 'xls');
      },
    );

    test(
      'msg with no properties — empty email template, like markitdown',
      () async {
        final bytes = buildCfb(['__properties_version1.0']);
        final info = StreamInfo.fromHead(bytes, filename: 'file.msg');
        final outcome = await registry.convert(bytes, info);
        expect(
          (outcome as ConversionSuccess).result.markdown,
          '# Email Message\n\n## Content',
        );
      },
    );
  });
}

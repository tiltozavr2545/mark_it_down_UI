import 'dart:io';
import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Интеграция с НАСТОЯЩИМ сайдкаром (Python + markitdown), а не с фейковым
/// shell-скриптом из `sidecar_converter_test.dart`. Пропускается, если
/// `MARKITDOWN_SIDECAR_DIR` не задан: в CI сайдкара нет, и `make verify`
/// его не собирает. Вручную:
///
///   make sidecar
///   cd core && MARKITDOWN_SIDECAR_DIR=$PWD/../sidecar/dist/macos-x86_64 \
///     MARKITDOWN_PDFIUM_PATH=$PWD/../pdfium/native/host/libpdfium.dylib \
///     dart test test/sidecar_integration_test.dart
///
/// Для `xls`/`msg` эталон (`*.expected.md`) — вывод самого сайдкара: Dart-
/// конвертеров для них нет. Для остальных форматов расхождения с Dart-ядром
/// разбирает `make compare-sidecar`, а здесь проверяется только, что сайдкар
/// отработал и это именно он — по характерным для markitdown признакам.
void main() {
  final sidecarDir =
      Platform.environment[SidecarConverter.sidecarDirEnvVar] ?? '';
  final skipReason = sidecarDir.isEmpty
      ? '${SidecarConverter.sidecarDirEnvVar} не задан: настоящего сайдкара '
            'нет (make sidecar; в CI его нет намеренно)'
      : null;

  final fixturesDir = p.join(Directory.current.path, 'test', 'fixtures');

  group('настоящий сайдкар', skip: skipReason, () {
    late SidecarConverter sidecar;
    late ConverterRegistry registry;

    setUpAll(() {
      final found = SidecarConverter.fromDirectory(sidecarDir);
      expect(
        found,
        isNotNull,
        reason:
            'в $sidecarDir нет рабочего сайдкара (manifest.json, run.py, '
            'python/bin/python3)',
      );
      sidecar = found!;
      registry = ConverterRegistry.defaultRegistry(extra: [sidecar]);
    });

    Uint8List read(String relative) => Uint8List.fromList(
      File(p.join(fixturesDir, relative)).readAsBytesSync(),
    );

    Future<ConversionResult> convert(
      String relative, {
      String? filename,
      bool withLocalPath = false,
    }) async {
      final bytes = read(relative);
      final info = StreamInfo.fromHead(
        bytes,
        filename: filename ?? p.basename(relative),
        localPath: withLocalPath ? p.join(fixturesDir, relative) : null,
      );
      final outcome = await registry.convert(bytes, info);
      expect(outcome, isA<ConversionSuccess>(), reason: '$outcome');
      return (outcome as ConversionSuccess).result;
    }

    test('манифест: сайдкар берёт все шесть форматов', () {
      expect(
        sidecar.formats,
        containsAll(['pdf', 'docx', 'xlsx', 'xls', 'pptx', 'msg']),
      );
    });

    // xls и msg: Dart-конвертеров нет, поэтому эталон — вывод сайдкара, а
    // главное — что детекция ядра сама отправляет их туда. Имя файла
    // нарочно без расширения: тип должен определиться по содержимому
    // (каталог OLE2), а не по подсказке.
    for (final entry in {
      'xls/simple.xls': FileKind.xls,
      'msg/simple.msg': FileKind.msg,
    }.entries) {
      final source = entry.key;
      final expected = source.replaceAll(RegExp(r'\.\w+$'), '.expected.md');

      test('$source: детекция по содержимому и вывод сайдкара', () async {
        final bytes = read(source);
        final info = StreamInfo.fromHead(bytes, filename: 'attachment');
        expect(info.detectedType.kind, entry.value);

        final result = await convert(source, filename: 'attachment');
        expect(result.converterId, 'sidecar');
        expect(
          result.markdown,
          File(p.join(fixturesDir, expected)).readAsStringSync(),
        );
        // По этой строке видно, что сработал сайдкар, а не Dart-ядро.
        expect(
          result.warnings.first.message,
          startsWith('converterId: sidecar'),
        );
      });

      test(
        '$source: путь на диске и байты в памяти дают одно и то же',
        () async {
          final byPath = await convert(source, withLocalPath: true);
          final byBytes = await convert(source);
          expect(byPath.markdown, byBytes.markdown);
        },
      );
    }

    // Остальные форматы: сайдкар (приоритет −1.0) должен перехватывать их у
    // Dart-конвертеров. Признак markitdown, которого у Dart-ядра нет.
    final markers = {
      'docx/simple.docx': ['* Первый пункт', '[[1]](#footnote-1)'],
      'xlsx/simple.xlsx': ['## Данные', '| Город | Население |'],
      'pptx/simple.pptx': ['<!-- Slide number: 1 -->', '### Notes:'],
      'pdf/simple.pdf': [
        'Document Title',
        'The first paragraph has two lines that\n',
      ],
      'pdf/table.pdf': ['| City   | Population | Country |'],
    };
    for (final entry in markers.entries) {
      test('${entry.key}: отвечает сайдкар', () async {
        final result = await convert(entry.key);
        expect(result.converterId, 'sidecar');
        for (final marker in entry.value) {
          expect(result.markdown, contains(marker));
        }
      });
    }

    test('pptx/no_sppr.pptx: python-pptx отказал → откат на Dart', () async {
      final result = await convert('pptx/no_sppr.pptx');
      expect(result.converterId, 'pptx');
      expect(
        result.warnings.first.message,
        startsWith('сайдкар не смог обработать файл'),
      );
      expect(result.markdown, contains('## Первый слайд'));
    });

    test('битый xls: отказ сайдкара — окончательный (запасного нет)', () async {
      // Сигнатура OLE2 и каталог от .xls, но дальше мусор: markitdown не
      // откроет, Dart-конвертера нет.
      final bytes = read('xls/simple.xls');
      final broken = Uint8List.fromList([
        ...bytes.sublist(0, 1024),
        ...List.filled(512, 0x41),
      ]);
      final info = StreamInfo.fromHead(broken, filename: 'broken.xls');
      final outcome = await registry.convert(broken, info);
      expect(outcome, isA<ConversionError>());
    });
  });
}

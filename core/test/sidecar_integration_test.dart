import 'dart:io';
import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Integration with the REAL sidecar (Python + markitdown), not with the
/// fake shell script from `sidecar_converter_test.dart`. Skipped if
/// `MARKITDOWN_SIDECAR_DIR` is not set: there is no sidecar in CI, and
/// `make verify` does not build it. Manually:
///
///   make sidecar
///   cd core && MARKITDOWN_SIDECAR_DIR=$PWD/../sidecar/dist/macos-x86_64 \
///     MARKITDOWN_PDFIUM_PATH=$PWD/../pdfium/native/host/libpdfium.dylib \
///     dart test test/sidecar_integration_test.dart
///
/// For `xls`/`msg` the expected file (`*.expected.md`) is the sidecar's
/// own output (Dart `xls` parsing has its own expected file —
/// `simple_dart.expected.md`; Dart `msg` matches it character for
/// character). For the other formats, divergences from the Dart core are
/// handled by `make compare-sidecar`, and here we only check that the
/// sidecar actually ran and that it was indeed the sidecar — by markers
/// characteristic of markitdown.
void main() {
  final sidecarDir =
      Platform.environment[SidecarConverter.sidecarDirEnvVar] ?? '';
  final skipReason = sidecarDir.isEmpty
      ? '${SidecarConverter.sidecarDirEnvVar} не задан: настоящего сайдкара '
            'нет (make sidecar; в CI его нет намеренно)'
      : null;

  final fixturesDir = p.join(Directory.current.path, 'test', 'fixtures');

  group('real sidecar', skip: skipReason, () {
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

    test('manifest: the sidecar takes all six formats', () {
      expect(
        sidecar.formats,
        containsAll(['pdf', 'docx', 'xlsx', 'xls', 'pptx', 'msg']),
      );
    });

    // xls and msg: in the app the sidecar takes them first, the expected
    // file is its output, and the main point is that the core's own
    // detection sends them there. The filename deliberately has no
    // extension: the type must be determined by content (the OLE2
    // directory), not by a hint.
    for (final entry in {
      'xls/simple.xls': FileKind.xls,
      'msg/simple.msg': FileKind.msg,
    }.entries) {
      final source = entry.key;
      final expected = source.replaceAll(RegExp(r'\.\w+$'), '.expected.md');

      test('$source: content-based detection and sidecar output', () async {
        final bytes = read(source);
        final info = StreamInfo.fromHead(bytes, filename: 'attachment');
        expect(info.detectedType.kind, entry.value);

        final result = await convert(source, filename: 'attachment');
        expect(result.converterId, 'sidecar');
        expect(
          result.markdown,
          File(p.join(fixturesDir, expected)).readAsStringSync(),
        );
        // This line shows that the sidecar ran, not the Dart core.
        expect(
          result.warnings.first.message,
          startsWith('converterId: sidecar'),
        );
      });

      test(
        '$source: a path on disk and in-memory bytes give the same result',
        () async {
          final byPath = await convert(source, withLocalPath: true);
          final byBytes = await convert(source);
          expect(byPath.markdown, byBytes.markdown);
        },
      );
    }

    // The other formats: the sidecar (priority -1.0) must intercept them
    // from the Dart converters. A markitdown marker that the Dart core
    // doesn't have.
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
      test('${entry.key}: the sidecar answers', () async {
        final result = await convert(entry.key);
        expect(result.converterId, 'sidecar');
        for (final marker in entry.value) {
          expect(result.markdown, contains(marker));
        }
      });
    }

    test('pptx/no_sppr.pptx: python-pptx failed → falls back to Dart', () async {
      final result = await convert('pptx/no_sppr.pptx');
      expect(result.converterId, 'pptx');
      expect(
        result.warnings.first.message,
        startsWith('сайдкар не смог обработать файл'),
      );
      expect(result.markdown, contains('## Первый слайд'));
    });

    test('corrupted xls: both the sidecar and Dart parsing fail', () async {
      // The OLE2 signature and directory are from .xls, but what follows
      // is garbage: neither markitdown nor the fallback Dart parsing (0.9)
      // will open it.
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

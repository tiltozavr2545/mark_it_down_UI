import 'dart:io';
import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Truncated and corrupted `xls`/`msg`. Unlike images and audio, a
/// failure here is acceptable (a workbook without a row table can't be
/// shown), but only from its own converter and in finite time: the CFB
/// directory is a tree, and sector chains and BIFF records come from the
/// file and can loop or point past the end. The test catches hangs and a
/// failure attributed to the wrong converter.
void main() {
  final fixturesDir = p.join(Directory.current.path, 'test', 'fixtures');
  final registry = ConverterRegistry.defaultRegistry();
  final files = [
    for (final dir in ['xls', 'msg'])
      ...Directory(
        p.join(fixturesDir, dir),
      ).listSync().whereType<File>().where((f) => !f.path.endsWith('.md')),
  ];

  Future<void> expectOwnOutcome(
    Uint8List bytes,
    String name,
    String why,
  ) async {
    final info = StreamInfo.fromHead(bytes, filename: name);
    final kind = info.detectedType.kind;
    if (kind != FileKind.xls && kind != FileKind.msg) return;
    final outcome = await registry.convert(bytes, info);
    if (outcome case ConversionError(:final failure)) {
      expect(failure, isA<CorruptedFileFailure>(), reason: why);
      expect(
        (failure as CorruptedFileFailure).converterId,
        kind.name,
        reason: why,
      );
    }
  }

  for (final file in files) {
    final name = p.basename(file.path);
    final full = Uint8List.fromList(file.readAsBytesSync());

    test('$name, truncated — its own result or its own failure', () async {
      for (var length = 512; length < full.length; length += 61) {
        await expectOwnOutcome(
          Uint8List.sublistView(full, 0, length),
          name,
          'длина $length',
        );
      }
    });

    test('$name with corrupted bytes — no hanging', () async {
      for (var phase = 0; phase < 13; phase++) {
        final bytes = Uint8List.fromList(full);
        // The CFB header (first 76 bytes) stays intact, so the corruption
        // reaches the directory, FAT and streams instead of stopping at
        // the signature.
        for (var i = 76 + phase; i < bytes.length; i += 13) {
          bytes[i] ^= 0x5A;
        }
        await expectOwnOutcome(bytes, name, 'фаза $phase');
      }
    });
  }
}

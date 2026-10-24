import 'dart:io';
import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Truncated and corrupted images and audio. If the signature is
/// recognized, there must be no failure (see `ImageConverter`,
/// `AudioConverter`): the format is always there, the rest is whatever
/// could be read. Catches out-of-bounds access in header parsing, EXIF,
/// ID3, MP4 boxes, and Ogg pages, which doesn't show up on whole
/// fixtures.
void main() {
  final fixturesDir = p.join(Directory.current.path, 'test', 'fixtures');
  final registry = ConverterRegistry.defaultRegistry();
  final media = [
    for (final dir in ['image', 'audio'])
      ...Directory(
        p.join(fixturesDir, dir),
      ).listSync().whereType<File>().where((f) => !f.path.endsWith('.md')),
  ];

  for (final file in media) {
    final name = p.basename(file.path);
    final full = Uint8List.fromList(file.readAsBytesSync());

    test('$name, truncated at any length — a result, not a failure', () async {
      final kind = StreamInfo.fromHead(full).detectedType.kind;
      for (final length in _truncationPoints(full.length)) {
        final bytes = Uint8List.sublistView(full, 0, length);
        final info = StreamInfo.fromHead(bytes, filename: name);
        // A start that's too short may not reach the signature — that's
        // already a different type, and its fate isn't decided here.
        if (info.detectedType.kind != kind) continue;
        final outcome = await registry.convert(bytes, info);
        expect(outcome, isA<ConversionSuccess>(), reason: 'длина $length');
      }
    });

    test('$name with corrupted bytes — a result, not a failure', () async {
      final kind = StreamInfo.fromHead(full).detectedType.kind;
      // Deterministic "corruption": every 7th byte after the first 16
      // (where the signatures are) is inverted.
      for (var phase = 0; phase < 7; phase++) {
        final bytes = Uint8List.fromList(full);
        for (var i = 16 + phase; i < bytes.length; i += 7) {
          bytes[i] ^= 0xFF;
        }
        final info = StreamInfo.fromHead(bytes, filename: name);
        if (info.detectedType.kind != kind) continue;
        final outcome = await registry.convert(bytes, info);
        expect(outcome, isA<ConversionSuccess>(), reason: 'фаза $phase');
      }
    });
  }
}

/// Every length in the first 2 KB (all the headers are there), then
/// around a thousand points evenly spaced: audio fixtures run tens of KB,
/// and each length is a full parsing pass.
Iterable<int> _truncationPoints(int length) sync* {
  final dense = length < 2048 ? length : 2048;
  for (var i = 1; i < dense; i++) {
    yield i;
  }
  if (length <= 2048) return;
  final step = ((length - 2048) / 1000).ceil();
  for (var i = 2048; i < length; i += step) {
    yield i;
  }
}

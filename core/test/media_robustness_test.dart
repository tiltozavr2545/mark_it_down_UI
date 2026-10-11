import 'dart:io';
import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Обрезанные и испорченные картинки и аудио. Сигнатура опознана — значит
/// отказа быть не должно (см. `ImageConverter`, `AudioConverter`): формат
/// есть всегда, остальное — что удалось прочитать. Ловит выход за границы в
/// разборе заголовков, EXIF, ID3, коробок MP4 и страниц Ogg, который на
/// целых фикстурах не проявляется.
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

    test('$name, обрезанный на любой длине — результат, а не отказ', () async {
      final kind = StreamInfo.fromHead(full).detectedType.kind;
      for (final length in _truncationPoints(full.length)) {
        final bytes = Uint8List.sublistView(full, 0, length);
        final info = StreamInfo.fromHead(bytes, filename: name);
        // Слишком короткое начало может не дотянуть до сигнатуры — это уже
        // другой тип, и судьба его не здесь.
        if (info.detectedType.kind != kind) continue;
        final outcome = await registry.convert(bytes, info);
        expect(outcome, isA<ConversionSuccess>(), reason: 'длина $length');
      }
    });

    test('$name с испорченными байтами — результат, а не отказ', () async {
      final kind = StreamInfo.fromHead(full).detectedType.kind;
      // Детерминированная «порча»: каждый 7-й байт после первых 16 (там
      // сигнатуры) инвертирован.
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

/// Каждая длина в первых 2 КБ (там все заголовки), дальше — около тысячи
/// точек равномерно: аудиофикстуры по десятки КБ, а каждая длина — полный
/// прогон разбора.
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

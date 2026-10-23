import 'dart:io';
import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Обрезанные и испорченные `xls`/`msg`. В отличие от картинок и аудио,
/// отказ здесь допустим (книгу без таблицы строк не показать), но только
/// своим конвертером и за конечное время: каталог CFB — дерево, цепочки
/// секторов и записи BIFF приходят из файла и могут замыкаться или
/// указывать за конец. Тест ловит зависание и чужой отказ.
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

    test('$name, обрезанный — свой результат или свой отказ', () async {
      for (var length = 512; length < full.length; length += 61) {
        await expectOwnOutcome(
          Uint8List.sublistView(full, 0, length),
          name,
          'длина $length',
        );
      }
    });

    test('$name с испорченными байтами — без зависания', () async {
      for (var phase = 0; phase < 13; phase++) {
        final bytes = Uint8List.fromList(full);
        // Заголовок CFB (первые 76 байт) цел, чтобы порча доходила до
        // каталога, FAT и потоков, а не обрывалась на сигнатуре.
        for (var i = 76 + phase; i < bytes.length; i += 13) {
          bytes[i] ^= 0x5A;
        }
        await expectOwnOutcome(bytes, name, 'фаза $phase');
      }
    });
  }
}

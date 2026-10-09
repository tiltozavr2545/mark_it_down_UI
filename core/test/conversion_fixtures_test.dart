import 'dart:io';
import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Пара «исходник + ожидаемый markdown» — см. `AGENTS.md#конвенции-работы` и
/// `docs/format-coverage.md#эталонные-файлы`. Список явный, а не обход
/// директории: источник без расширения (`no_extension_sample`) делает
/// автоматическое сопоставление по имени неоднозначным.
class _Fixture {
  final String source;
  final String expected;
  final String? filenameOverride;

  const _Fixture(this.source, this.expected, {this.filenameOverride});
}

const _fixtures = [
  _Fixture('plain_text/hello_utf8.txt', 'plain_text/hello_utf8.expected.md'),
  _Fixture('plain_text/windows1251.txt', 'plain_text/windows1251.expected.md'),
  _Fixture('plain_text/empty.txt', 'plain_text/empty.expected.md'),
  _Fixture(
    'plain_text/no_extension_sample',
    'plain_text/no_extension_sample.expected.md',
    filenameOverride: 'no_extension_sample',
  ),
  _Fixture('csv/simple.csv', 'csv/simple.expected.md'),
  _Fixture('csv/simple.tsv', 'csv/simple_tsv.expected.md'),
  _Fixture('csv/ragged.csv', 'csv/ragged.expected.md'),
  _Fixture('json/simple.json', 'json/simple.expected.md'),
  _Fixture('json/empty.json', 'json/empty.expected.md'),
  _Fixture('xml/simple.xml', 'xml/simple.expected.md'),
  _Fixture('html/article.html', 'html/article.expected.md'),
];

void main() {
  // `dart test` (как и `make verify`) запускается из корня пакета, поэтому
  // путь строится от текущей директории, а не от `Platform.script` — у него
  // под тест-раннером путь указывает на скомпилированный kernel во временной
  // папке, а не на исходники.
  final fixturesDir = p.join(Directory.current.path, 'test', 'fixtures');
  final registry = ConverterRegistry.defaultRegistry();

  for (final fixture in _fixtures) {
    test('фикстура ${fixture.source}', () async {
      final sourcePath = p.join(fixturesDir, fixture.source);
      final expectedPath = p.join(fixturesDir, fixture.expected);
      final bytes = Uint8List.fromList(File(sourcePath).readAsBytesSync());
      final expected = File(expectedPath).readAsStringSync();

      final filename = fixture.filenameOverride ?? p.basename(fixture.source);
      final info = StreamInfo.fromHead(bytes, filename: filename);

      final outcome = await registry.convert(bytes, info);

      expect(outcome, isA<ConversionSuccess>());
      final markdown = (outcome as ConversionSuccess).result.markdown;
      expect(markdown, expected);
    });
  }

  group('ошибки конвертации', () {
    test('неподдерживаемый формат — нет совпавшего конвертера', () async {
      // PDF распознаётся по магическим байтам (FileKind.pdf), но конвертера
      // для него в реестре пока нет — появится на Этапе 3.
      final bytes = Uint8List.fromList('%PDF-1.4\n...'.codeUnits);
      final info = StreamInfo.fromHead(bytes, filename: 'file.pdf');

      final outcome = await registry.convert(bytes, info);

      expect(outcome, isA<ConversionError>());
      expect(
        (outcome as ConversionError).failure,
        isA<UnsupportedFormatFailure>(),
      );
    });

    test('битый файл — распознанный формат, сломанное содержимое', () async {
      final bytes = Uint8List.fromList('{not valid json'.codeUnits);
      final info = StreamInfo.fromHead(bytes, filename: 'broken.json');

      final outcome = await registry.convert(bytes, info);

      expect(outcome, isA<ConversionError>());
      final failure = (outcome as ConversionError).failure;
      expect(failure, isA<CorruptedFileFailure>());
      expect((failure as CorruptedFileFailure).converterId, 'json');
    });

    test('превышен лимит размера', () async {
      final bytes = Uint8List.fromList('hello'.codeUnits);
      final info = StreamInfo.fromHead(
        bytes,
        filename: 'huge.txt',
        lengthBytes: 100 * 1024 * 1024,
      );

      final outcome = await registry.convert(
        bytes,
        info,
        limits: const ConversionLimits(maxInMemoryBytes: 50 * 1024 * 1024),
      );

      expect(outcome, isA<ConversionError>());
      expect((outcome as ConversionError).failure, isA<LimitExceededFailure>());
    });
  });
}

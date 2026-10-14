import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
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

  /// Если задано — после сравнения markdown проверяется, что среди
  /// [ConversionResult.warnings] есть хотя бы одно, содержащее эту
  /// подстроку (например, предупреждение про объединённые ячейки `xlsx`).
  final String? expectedWarningContains;

  const _Fixture(
    this.source,
    this.expected, {
    this.filenameOverride,
    this.expectedWarningContains,
  });
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
  // Этап 2 — Office.
  _Fixture('docx/simple.docx', 'docx/simple.expected.md'),
  _Fixture(
    'docx/evil_nested.docx',
    'docx/evil_nested.expected.md',
  ), // вложенные списки + таблица в таблице
  _Fixture(
    'docx/nested_numbered.docx',
    'docx/nested_numbered.expected.md',
  ), // отступ вложенных пунктов = ширина маркера нумерованного родителя
  _Fixture('xlsx/simple.xlsx', 'xlsx/simple.expected.md'),
  _Fixture(
    'xlsx/merged_cells.xlsx',
    'xlsx/merged_cells.expected.md',
    expectedWarningContains: 'объединённые ячейки',
  ),
  _Fixture(
    'xlsx/types_and_gaps.xlsx',
    'xlsx/types_and_gaps.expected.md',
  ), // даты, булевы, пропуски; пакет от openpyxl с абсолютными Target в rels
  _Fixture('pptx/simple.pptx', 'pptx/simple.expected.md'), // от python-pptx
  _Fixture(
    'pptx/no_sppr.pptx',
    'pptx/no_sppr.expected.md',
  ), // фигуры без <p:spPr>: невалидно для python-pptx, Dart терпит
  _Fixture('epub/simple.epub', 'epub/simple.expected.md'),
  _Fixture('zip/simple.zip', 'zip/simple.expected.md'),
  _Fixture('zip/nested.zip', 'zip/nested.expected.md'), // zip в zip
  _Fixture('ipynb/simple.ipynb', 'ipynb/simple.expected.md'),
  // Этап 3 — PDF.
  _Fixture('pdf/simple.pdf', 'pdf/simple.expected.md'),
  // ИЗВЕСТНОЕ ОТСТАВАНИЕ: таблицу PDFium-конвертер не распознаёт, ячейки
  // строки склеиваются в одну (а строки таблицы — в абзац), тогда как
  // pdfplumber в сайдкаре отдаёт настоящую Markdown-таблицу. Ожидаемый вывод
  // фиксирует текущее поведение; при появлении таблиц в PDF — обновить.
  _Fixture('pdf/table.pdf', 'pdf/table.expected.md'),
  _Fixture(
    'pdf/scanned.pdf',
    'pdf/scanned.expected.md',
    expectedWarningContains: 'выглядят как изображения',
  ), // страницы 2–3 — картинка без текста, похоже на скан
  _Fixture(
    'pdf/blank.pdf',
    'pdf/blank.expected.md',
    expectedWarningContains: 'не найдено текста',
  ), // страница есть, текста и объектов на ней нет вовсе
  // Этап 6 — изображения: метаданные без OCR.
  _Fixture(
    'image/photo.jpg',
    'image/photo.expected.md',
    expectedWarningContains: 'геометка',
  ), // EXIF «с камеры»: GPS, UTF-8-кириллица, символы разметки в описании
  _Fixture('image/photo.heic', 'image/photo_heic.expected.md'), // sips
  _Fixture('image/screenshot.png', 'image/screenshot.expected.md'), // без EXIF
  _Fixture('image/sticker.webp', 'image/sticker.expected.md'), // EXIF в RIFF
  _Fixture('image/scan.tiff', 'image/scan.expected.md'), // XP*-теги Windows
  _Fixture('image/animation.gif', 'image/animation.expected.md'),
  _Fixture('image/icon.bmp', 'image/icon.expected.md'),
  _Fixture(
    'image/evil_loop.jpg',
    'image/evil_loop.expected.md',
    expectedWarningContains: 'EXIF повреждены',
  ), // IFD указывает сам на себя, смещение за пределы блока, 65535 записей
  // Этап 6 — аудио: метаданные без транскрипции.
  _Fixture(
    'audio/song.mp3',
    'audio/song.expected.md',
    expectedWarningContains: 'речь не распознаётся',
  ), // ID3v2.3 UTF-16, жанр «(17)», COMM iTunNORM, текст песни, Xing VBR
  _Fixture(
    'audio/legacy.mp3',
    'audio/legacy.expected.md',
  ), // «Latin-1», который на деле Windows-1251, + ID3v1; Motörhead — Latin-1
  _Fixture('audio/voice.ogg', 'audio/voice.expected.md'), // Opus
  _Fixture('audio/music.ogg', 'audio/music.expected.md'), // Vorbis
  _Fixture('audio/track.flac', 'audio/track.expected.md'),
  _Fixture('audio/recording.wav', 'audio/recording.expected.md'), // LIST/INFO
  _Fixture('audio/memo.m4a', 'audio/memo.expected.md'), // afconvert + теги
  _Fixture(
    'audio/clip.mp4',
    'audio/clip.expected.md',
  ), // синтетика: только moov с видеодорожкой
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
      final result = (outcome as ConversionSuccess).result;
      expect(result.markdown, expected);

      final expectedWarning = fixture.expectedWarningContains;
      if (expectedWarning != null) {
        expect(
          result.warnings.any((w) => w.message.contains(expectedWarning)),
          isTrue,
          reason: 'ожидали warning, содержащий "$expectedWarning"',
        );
      }
    });
  }

  group('ошибки конвертации', () {
    test('неподдерживаемый формат — нет совпавшего конвертера', () async {
      // Ни одна сигнатура не совпадает, и доля управляющих байт достаточно
      // высока, чтобы не быть принятым за текст (`_looksBinary`) — файл
      // уходит в FileKind.unknown, как `.sketch` в примере из
      // docs/conversion-pipeline.md#ошибки.
      final bytes = Uint8List.fromList(List.generate(64, (i) => i % 32));
      final info = StreamInfo.fromHead(bytes, filename: 'file.sketch');

      final outcome = await registry.convert(bytes, info);

      expect(outcome, isA<ConversionError>());
      expect(
        (outcome as ConversionError).failure,
        isA<UnsupportedFormatFailure>(),
      );
    });

    test('битый PDF — распознанный формат, нечитаемые байты', () async {
      // `%PDF-` узнаётся по магическим байтам, но дальше не PDF вовсе —
      // PDFium не откроет документ.
      final bytes = Uint8List.fromList('%PDF-1.4\nне PDF дальше'.codeUnits);
      final info = StreamInfo.fromHead(bytes, filename: 'broken.pdf');

      final outcome = await registry.convert(bytes, info);

      expect(outcome, isA<ConversionError>());
      final failure = (outcome as ConversionError).failure;
      expect(failure, isA<CorruptedFileFailure>());
      expect((failure as CorruptedFileFailure).converterId, 'pdf');
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

    test('предела на размер файла нет', () async {
      final bytes = Uint8List.fromList('hello'.codeUnits);
      final info = StreamInfo.fromHead(
        bytes,
        filename: 'huge.txt',
        lengthBytes: 5 * 1024 * 1024 * 1024,
      );

      final outcome = await registry.convert(bytes, info);

      expect(outcome, isA<ConversionSuccess>());
    });

    test('превышен суммарный распакованный объём архива — хард-фейл', () async {
      final bytes = _buildZip({'a.txt': 'A' * 600, 'b.txt': 'B' * 600});
      final info = StreamInfo.fromHead(bytes, filename: 'big.zip');

      final outcome = await registry.convert(
        bytes,
        info,
        limits: const ConversionLimits(maxExtractedBytes: 1000),
      );

      expect(outcome, isA<ConversionError>());
      expect((outcome as ConversionError).failure, isA<LimitExceededFailure>());
    });

    test(
      'превышен лимит числа файлов в архиве — хард-фейл, не warning',
      () async {
        final bytes = _buildZip({'a.txt': 'A', 'b.txt': 'B', 'c.txt': 'C'});
        final info = StreamInfo.fromHead(bytes, filename: 'many.zip');

        final outcome = await registry.convert(
          bytes,
          info,
          limits: const ConversionLimits(maxFilesInArchive: 2),
        );

        expect(outcome, isA<ConversionError>());
        expect(
          (outcome as ConversionError).failure,
          isA<LimitExceededFailure>(),
        );
      },
    );

    test(
      'превышен лимит глубины рекурсии в zip-в-zip — хард-фейл всего архива',
      () async {
        // zip/nested.zip: nested.zip → inner.zip → deep.txt — три уровня
        // (0, 1, 2). При maxRecursionDepth: 1 третий уровень превышает
        // предел, и это должно провалить всю конвертацию, а не осесть
        // warning-ом на вложенном файле.
        final sourcePath = p.join(fixturesDir, 'zip', 'nested.zip');
        final bytes = Uint8List.fromList(File(sourcePath).readAsBytesSync());
        final info = StreamInfo.fromHead(bytes, filename: 'nested.zip');

        final outcome = await registry.convert(
          bytes,
          info,
          limits: const ConversionLimits(maxRecursionDepth: 1),
        );

        expect(outcome, isA<ConversionError>());
        expect(
          (outcome as ConversionError).failure,
          isA<LimitExceededFailure>(),
        );
      },
    );
  });
}

Uint8List _buildZip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final data = Uint8List.fromList(entry.value.codeUnits);
    archive.addFile(ArchiveFile(entry.key, data.length, data));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

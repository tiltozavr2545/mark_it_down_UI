import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:markitdown_core/markitdown_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A "source + expected markdown" pair — see `AGENTS.md#конвенции-работы`
/// and `docs/format-coverage.md#эталонные-файлы`. The list is explicit
/// rather than a directory walk: a source with no extension
/// (`no_extension_sample`) makes automatic matching by name ambiguous.
class _Fixture {
  final String source;
  final String expected;
  final String? filenameOverride;

  /// If set — after comparing the markdown, checks that among
  /// [ConversionResult.warnings] there is at least one containing this
  /// substring (e.g. the warning about merged cells in `xlsx`).
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
  // Stage 2 — Office.
  _Fixture('docx/simple.docx', 'docx/simple.expected.md'),
  _Fixture(
    'docx/evil_nested.docx',
    'docx/evil_nested.expected.md',
  ), // nested lists + a table inside a table
  _Fixture(
    'docx/nested_numbered.docx',
    'docx/nested_numbered.expected.md',
  ), // nested item indent = marker width of the numbered parent
  _Fixture('xlsx/simple.xlsx', 'xlsx/simple.expected.md'),
  _Fixture(
    'xlsx/merged_cells.xlsx',
    'xlsx/merged_cells.expected.md',
    expectedWarningContains: 'объединённые ячейки',
  ),
  _Fixture(
    'xlsx/types_and_gaps.xlsx',
    'xlsx/types_and_gaps.expected.md',
  ), // dates, booleans, gaps; a package from openpyxl with absolute Target in rels
  _Fixture('pptx/simple.pptx', 'pptx/simple.expected.md'), // from python-pptx
  _Fixture(
    'pptx/no_sppr.pptx',
    'pptx/no_sppr.expected.md',
  ), // shapes without <p:spPr>: invalid for python-pptx, Dart tolerates it
  _Fixture('epub/simple.epub', 'epub/simple.expected.md'),
  _Fixture('zip/simple.zip', 'zip/simple.expected.md'),
  _Fixture('zip/nested.zip', 'zip/nested.expected.md'), // zip in zip
  _Fixture('ipynb/simple.ipynb', 'ipynb/simple.expected.md'),
  // Excel 97–2003 and Outlook: Dart OLE2 parsing (0.9). The expected
  // simple.xls for Dart is its own (header is column letters, like xlsx);
  // simple.msg is shared with the sidecar: the output matches markitdown
  // character for character.
  _Fixture('xls/simple.xls', 'xls/simple_dart.expected.md'),
  _Fixture(
    'xls/evil.xls',
    'xls/evil.expected.md',
    expectedWarningContains: 'объединённые ячейки',
  ), // SST via CONTINUE split mid-character, dates, RK, an empty sheet
  _Fixture('xls/biff5.xls', 'xls/biff5.expected.md'), // Excel 95, cp1251
  _Fixture('msg/simple.msg', 'msg/simple.expected.md'),
  _Fixture('msg/ansi.msg', 'msg/ansi.expected.md'), // 001E, cp1251, not mini
  _Fixture(
    'msg/html_only.msg',
    'msg/html_only.expected.md',
    expectedWarningContains: 'HTML-версии',
  ),
  // Feeds (0.9): a port of markitdown's RssConverter; entry bodies use html2md.
  _Fixture('rss/news.rss', 'rss/news.expected.md'), // CDATA, xml:base
  _Fixture(
    'rss/updates.atom',
    'rss/updates.expected.md',
  ), // indented text, html, xhtml, binary content
  _Fixture(
    'rss/feed_no_extension',
    'rss/news.expected.md',
    filenameOverride: 'feed_no_extension',
  ), // the <rss> root is recognized with no extension
  // Stage 3 — PDF.
  _Fixture('pdf/simple.pdf', 'pdf/simple.expected.md'),
  // KNOWN GAP: the PDFium converter does not recognize tables; row cells
  // get glued into one (and table rows into a paragraph), whereas
  // pdfplumber in the sidecar produces a real Markdown table. The expected
  // output locks in the current behavior; update it if PDF tables appear.
  _Fixture('pdf/table.pdf', 'pdf/table.expected.md'),
  _Fixture(
    'pdf/scanned.pdf',
    'pdf/scanned.expected.md',
    expectedWarningContains: 'выглядят как изображения',
  ), // pages 2–3 are an image with no text, looks like a scan
  _Fixture(
    'pdf/blank.pdf',
    'pdf/blank.expected.md',
    expectedWarningContains: 'не найдено текста',
  ), // the page exists, but has no text or objects at all
  // Stage 6 — images: metadata without OCR.
  _Fixture(
    'image/photo.jpg',
    'image/photo.expected.md',
    expectedWarningContains: 'геометка',
  ), // "from a camera" EXIF: GPS, UTF-8 Cyrillic, markup characters in the description
  _Fixture('image/photo.heic', 'image/photo_heic.expected.md'), // sips
  _Fixture('image/screenshot.png', 'image/screenshot.expected.md'), // no EXIF
  _Fixture('image/sticker.webp', 'image/sticker.expected.md'), // EXIF in RIFF
  _Fixture('image/scan.tiff', 'image/scan.expected.md'), // Windows XP* tags
  _Fixture('image/animation.gif', 'image/animation.expected.md'),
  _Fixture('image/icon.bmp', 'image/icon.expected.md'),
  _Fixture(
    'image/evil_loop.jpg',
    'image/evil_loop.expected.md',
    expectedWarningContains: 'EXIF повреждены',
  ), // the IFD points at itself, an offset past the block, 65535 entries
  // Stage 6 — audio: metadata without transcription.
  _Fixture(
    'audio/song.mp3',
    'audio/song.expected.md',
    expectedWarningContains: 'речь не распознаётся',
  ), // ID3v2.3 UTF-16, genre "(17)", COMM iTunNORM, lyrics, Xing VBR
  _Fixture(
    'audio/legacy.mp3',
    'audio/legacy.expected.md',
  ), // "Latin-1" that is actually Windows-1251, + ID3v1; Motörhead — Latin-1
  _Fixture('audio/voice.ogg', 'audio/voice.expected.md'), // Opus
  _Fixture('audio/music.ogg', 'audio/music.expected.md'), // Vorbis
  _Fixture('audio/track.flac', 'audio/track.expected.md'),
  _Fixture('audio/recording.wav', 'audio/recording.expected.md'), // LIST/INFO
  _Fixture('audio/memo.m4a', 'audio/memo.expected.md'), // afconvert + tags
  _Fixture(
    'audio/clip.mp4',
    'audio/clip.expected.md',
  ), // synthetic: only a moov with a video track
];

void main() {
  // `dart test` (like `make verify`) runs from the package root, so the
  // path is built from the current directory rather than from
  // `Platform.script` — under the test runner that points at a compiled
  // kernel in a temp folder, not at the sources.
  final fixturesDir = p.join(Directory.current.path, 'test', 'fixtures');
  final registry = ConverterRegistry.defaultRegistry();

  for (final fixture in _fixtures) {
    test('fixture ${fixture.source}', () async {
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

  group('conversion errors', () {
    test('unsupported format — no matching converter', () async {
      // No signature matches, and the share of control bytes is high
      // enough not to be mistaken for text (`_looksBinary`) — the file
      // goes to FileKind.unknown, like `.sketch` in the example from
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

    test('corrupted PDF — recognized format, unreadable bytes', () async {
      // `%PDF-` is recognized by magic bytes, but what follows isn't PDF
      // at all — PDFium won't open the document.
      final bytes = Uint8List.fromList('%PDF-1.4\nне PDF дальше'.codeUnits);
      final info = StreamInfo.fromHead(bytes, filename: 'broken.pdf');

      final outcome = await registry.convert(bytes, info);

      expect(outcome, isA<ConversionError>());
      final failure = (outcome as ConversionError).failure;
      expect(failure, isA<CorruptedFileFailure>());
      expect((failure as CorruptedFileFailure).converterId, 'pdf');
    });

    test('corrupted file — recognized format, broken content', () async {
      final bytes = Uint8List.fromList('{not valid json'.codeUnits);
      final info = StreamInfo.fromHead(bytes, filename: 'broken.json');

      final outcome = await registry.convert(bytes, info);

      expect(outcome, isA<ConversionError>());
      final failure = (outcome as ConversionError).failure;
      expect(failure, isA<CorruptedFileFailure>());
      expect((failure as CorruptedFileFailure).converterId, 'json');
    });

    test('there is no limit on file size', () async {
      final bytes = Uint8List.fromList('hello'.codeUnits);
      final info = StreamInfo.fromHead(
        bytes,
        filename: 'huge.txt',
        lengthBytes: 5 * 1024 * 1024 * 1024,
      );

      final outcome = await registry.convert(bytes, info);

      expect(outcome, isA<ConversionSuccess>());
    });

    test('total unpacked archive size exceeded — hard fail', () async {
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
      'file count limit in archive exceeded — hard fail, not a warning',
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
      'recursion depth limit exceeded in zip-in-zip — hard fail for the whole archive',
      () async {
        // zip/nested.zip: nested.zip → inner.zip → deep.txt — three levels
        // (0, 1, 2). With maxRecursionDepth: 1 the third level exceeds the
        // limit, and that must fail the whole conversion rather than
        // settle as a warning on the nested file.
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
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:markitdown_core/markitdown_core.dart';
import 'package:test/test.dart';

Uint8List _buildZip(Map<String, String> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  final encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded!);
}

void main() {
  group('детекция по сигнатуре', () {
    test('PDF', () {
      final bytes = Uint8List.fromList(utf8.encode('%PDF-1.7\nостальное'));
      expect(detectType(bytes).kind, FileKind.pdf);
    });

    test('OLE2 без подсказки по расширению — только контейнер', () {
      final bytes = Uint8List.fromList([
        0xD0,
        0xCF,
        0x11,
        0xE0,
        0xA1,
        0xB1,
        0x1A,
        0xE1,
        ...List.filled(10, 0),
      ]);
      final result = detectType(bytes);
      expect(result.kind, FileKind.ole2Compound);
      expect(result.label, isNot(contains('похоже на')));
    });

    test('OLE2 с расширением .xls — расширение как подсказка', () {
      final bytes = Uint8List.fromList([
        0xD0,
        0xCF,
        0x11,
        0xE0,
        0xA1,
        0xB1,
        0x1A,
        0xE1,
        ...List.filled(10, 0),
      ]);
      final result = detectType(bytes, extension: 'xls');
      expect(result.kind, FileKind.ole2Compound);
      expect(result.label, contains('.xls'));
    });

    test('PNG', () {
      final bytes = Uint8List.fromList([
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0,
        0,
        0,
      ]);
      expect(detectType(bytes).kind, FileKind.png);
    });

    test('JPEG', () {
      final bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0]);
      expect(detectType(bytes).kind, FileKind.jpeg);
    });

    test('TIFF в обоих порядках байтов', () {
      final little = Uint8List.fromList([0x49, 0x49, 0x2A, 0, 8, 0, 0, 0]);
      final big = Uint8List.fromList([0x4D, 0x4D, 0, 0x2A, 0, 0, 0, 8]);
      expect(detectType(little).kind, FileKind.tiff);
      expect(detectType(big).kind, FileKind.tiff);
    });

    test('HEIC по марке в ftyp', () {
      final bytes = Uint8List.fromList([0, 0, 0, 24, ...'ftypheic'.codeUnits]);
      expect(detectType(bytes).kind, FileKind.heic);
    });

    test('MP3 по ID3v2 и по кадру MPEG без тега', () {
      final id3 = Uint8List.fromList([...'ID3'.codeUnits, 3, 0, 0, 0, 0, 0, 0]);
      final frame = Uint8List.fromList([0xFF, 0xFB, 0x90, 0x64, 0, 0]);
      expect(detectType(id3).kind, FileKind.mp3);
      expect(detectType(frame).kind, FileKind.mp3);
    });

    test('текст, начинающийся с «ID3», — не MP3', () {
      final bytes = Uint8List.fromList('ID3 tags explained'.codeUnits);
      expect(detectType(bytes).kind, FileKind.text);
    });

    test('AAC ADTS с тем же синхрословом — не MP3', () {
      final bytes = Uint8List.fromList([0xFF, 0xF1, 0x50, 0x80, 0, 0]);
      expect(detectType(bytes).kind, isNot(FileKind.mp3));
    });

    test('FLAC за тегом ID3v2 — FLAC, а не MP3', () {
      final bytes = Uint8List.fromList([
        ...'ID3'.codeUnits,
        4,
        0,
        0,
        0,
        0,
        0,
        2,
        0,
        0,
        ...'fLaC'.codeUnits,
      ]);
      expect(detectType(bytes).kind, FileKind.flac);
    });

    test('WAV и Ogg', () {
      final wav = Uint8List.fromList([
        ...'RIFF'.codeUnits,
        0,
        0,
        0,
        0,
        ...'WAVE'.codeUnits,
      ]);
      final ogg = Uint8List.fromList([...'OggS'.codeUnits, 0, 2]);
      expect(detectType(wav).kind, FileKind.wav);
      expect(detectType(ogg).kind, FileKind.ogg);
    });

    test('MP4 и M4A с той же коробкой ftyp — не изображение', () {
      for (final brand in ['isom', 'mp42', 'M4A ', 'qt  ']) {
        final bytes = Uint8List.fromList([
          0,
          0,
          0,
          24,
          ...'ftyp$brand'.codeUnits,
          ...List.filled(8, 0),
        ]);
        expect(
          detectType(bytes).kind,
          isNot(FileKind.heic),
          reason: 'марка $brand',
        );
      }
    });
  });

  group('zip-семья', () {
    test('docx по word/document.xml', () {
      final bytes = _buildZip({
        '[Content_Types].xml': '<Types/>',
        'word/document.xml': '<document/>',
      });
      expect(detectType(bytes).kind, FileKind.docx);
    });

    test('xlsx по xl/workbook.xml', () {
      final bytes = _buildZip({
        '[Content_Types].xml': '<Types/>',
        'xl/workbook.xml': '<workbook/>',
      });
      expect(detectType(bytes).kind, FileKind.xlsx);
    });

    test('pptx по ppt/presentation.xml', () {
      final bytes = _buildZip({
        '[Content_Types].xml': '<Types/>',
        'ppt/presentation.xml': '<presentation/>',
      });
      expect(detectType(bytes).kind, FileKind.pptx);
    });

    test('epub по mimetype первым файлом', () {
      final bytes = _buildZip({
        'mimetype': 'application/epub+zip',
        'content.opf': '<package/>',
      });
      expect(detectType(bytes).kind, FileKind.epub);
    });

    test('apk по AndroidManifest.xml', () {
      final bytes = _buildZip({'AndroidManifest.xml': 'binary-xml'});
      expect(detectType(bytes).kind, FileKind.androidApk);
    });

    test('обычный zip без OOXML-примет', () {
      final bytes = _buildZip({'readme.txt': 'привет'});
      expect(detectType(bytes).kind, FileKind.zipArchive);
    });

    test('.docx под именем .pdf — содержимое важнее расширения', () {
      final bytes = _buildZip({
        '[Content_Types].xml': '<Types/>',
        'word/document.xml': '<document/>',
      });
      // Расширение из имени файла — заведомо лживое, как бывает после
      // пересылки в мессенджере.
      final result = detectType(bytes, extension: 'pdf');
      expect(result.kind, FileKind.docx);
    });

    test('повреждённый zip не кидает исключение', () {
      final bytes = Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 1, 2, 3]);
      final result = detectType(bytes);
      expect(result.kind, FileKind.zipArchive);
      expect(result.label, contains('повреждён'));
    });
  });

  group('текст', () {
    test('UTF-8 текст с подсказкой по расширению', () {
      final bytes = Uint8List.fromList(utf8.encode('a,b,c\n1,2,3'));
      final result = detectType(bytes, extension: 'csv');
      expect(result.kind, FileKind.text);
      expect(result.label, contains('.csv'));
    });

    test('текст без BOM, не UTF-8 — предполагаем Windows-1251', () {
      // Байт 0xC0 в одиночку — невалидный старт UTF-8-последовательности.
      final bytes = Uint8List.fromList([0x41, 0x42, 0xC0, 0x20, 0x43]);
      final result = detectType(bytes, extension: 'txt');
      expect(result.kind, FileKind.text);
      expect(result.label, contains('Windows-1251'));
    });

    test('файл без расширения — определяем по содержимому', () {
      final bytes = Uint8List.fromList(utf8.encode('просто текст'));
      final result = detectType(bytes, extension: null);
      expect(result.kind, FileKind.text);
    });
  });

  group('краевые случаи', () {
    test('файл нулевой длины', () {
      final result = detectType(Uint8List(0));
      expect(result.kind, FileKind.emptyFile);
    });

    test('случайные бинарные байты — неизвестный формат', () {
      final bytes = Uint8List.fromList(
        List.generate(64, (i) => (i * 37 + 11) % 256)
          ..[0] = 0x01
          ..[1] = 0x02
          ..[2] = 0x03,
      );
      final result = detectType(bytes);
      expect(result.kind, FileKind.unknown);
    });
  });

  group('StreamInfo', () {
    test('извлекает расширение из имени файла', () {
      final info = StreamInfo.fromHead(
        Uint8List.fromList(utf8.encode('text')),
        filename: 'document.MD',
      );
      expect(info.extension, 'md');
    });

    test('файл без точки в имени — расширения нет', () {
      final info = StreamInfo.fromHead(
        Uint8List.fromList(utf8.encode('text')),
        filename: 'document',
      );
      expect(info.extension, isNull);
    });

    test('lengthBytes берётся из явного значения, не из head', () {
      final info = StreamInfo.fromHead(
        Uint8List.fromList(utf8.encode('%PDF-1.7')),
        filename: 'report.pdf',
        lengthBytes: 188416,
      );
      expect(info.lengthBytes, 188416);
      expect(info.detectedType.kind, FileKind.pdf);
    });
  });
}

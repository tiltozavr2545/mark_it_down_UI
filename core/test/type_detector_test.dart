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
  return Uint8List.fromList(encoded);
}

void main() {
  group('detection by signature', () {
    test('PDF', () {
      final bytes = Uint8List.fromList(utf8.encode('%PDF-1.7\nостальное'));
      expect(detectType(bytes).kind, FileKind.pdf);
    });

    test('OLE2 with no extension hint — container only', () {
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

    test('OLE2 with a .xls extension — extension as a hint', () {
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

    test('TIFF in both byte orders', () {
      final little = Uint8List.fromList([0x49, 0x49, 0x2A, 0, 8, 0, 0, 0]);
      final big = Uint8List.fromList([0x4D, 0x4D, 0, 0x2A, 0, 0, 0, 8]);
      expect(detectType(little).kind, FileKind.tiff);
      expect(detectType(big).kind, FileKind.tiff);
    });

    test('HEIC by the brand in ftyp', () {
      final bytes = Uint8List.fromList([0, 0, 0, 24, ...'ftypheic'.codeUnits]);
      expect(detectType(bytes).kind, FileKind.heic);
    });

    test('MP3 by ID3v2 and by an MPEG frame with no tag', () {
      final id3 = Uint8List.fromList([...'ID3'.codeUnits, 3, 0, 0, 0, 0, 0, 0]);
      final frame = Uint8List.fromList([0xFF, 0xFB, 0x90, 0x64, 0, 0]);
      expect(detectType(id3).kind, FileKind.mp3);
      expect(detectType(frame).kind, FileKind.mp3);
    });

    test('text starting with "ID3" is not MP3', () {
      final bytes = Uint8List.fromList('ID3 tags explained'.codeUnits);
      expect(detectType(bytes).kind, FileKind.text);
    });

    test('AAC ADTS with the same sync word is not MP3', () {
      final bytes = Uint8List.fromList([0xFF, 0xF1, 0x50, 0x80, 0, 0]);
      expect(detectType(bytes).kind, isNot(FileKind.mp3));
    });

    test('FLAC behind an ID3v2 tag — FLAC, not MP3', () {
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

    test('WAV and Ogg', () {
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

    test('MP4 and M4A with the same ftyp box — not an image', () {
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

  group('zip family', () {
    test('docx by word/document.xml', () {
      final bytes = _buildZip({
        '[Content_Types].xml': '<Types/>',
        'word/document.xml': '<document/>',
      });
      expect(detectType(bytes).kind, FileKind.docx);
    });

    test('xlsx by xl/workbook.xml', () {
      final bytes = _buildZip({
        '[Content_Types].xml': '<Types/>',
        'xl/workbook.xml': '<workbook/>',
      });
      expect(detectType(bytes).kind, FileKind.xlsx);
    });

    test('pptx by ppt/presentation.xml', () {
      final bytes = _buildZip({
        '[Content_Types].xml': '<Types/>',
        'ppt/presentation.xml': '<presentation/>',
      });
      expect(detectType(bytes).kind, FileKind.pptx);
    });

    test('epub by mimetype as the first file', () {
      final bytes = _buildZip({
        'mimetype': 'application/epub+zip',
        'content.opf': '<package/>',
      });
      expect(detectType(bytes).kind, FileKind.epub);
    });

    test('apk by AndroidManifest.xml', () {
      final bytes = _buildZip({'AndroidManifest.xml': 'binary-xml'});
      expect(detectType(bytes).kind, FileKind.androidApk);
    });

    test('plain zip with no OOXML markers', () {
      final bytes = _buildZip({'readme.txt': 'привет'});
      expect(detectType(bytes).kind, FileKind.zipArchive);
    });

    test('.docx named .pdf — content matters more than the extension', () {
      final bytes = _buildZip({
        '[Content_Types].xml': '<Types/>',
        'word/document.xml': '<document/>',
      });
      // The extension from the filename is known to lie, as happens after
      // being forwarded in a messenger app.
      final result = detectType(bytes, extension: 'pdf');
      expect(result.kind, FileKind.docx);
    });

    test('a corrupted zip does not throw an exception', () {
      final bytes = Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 1, 2, 3]);
      final result = detectType(bytes);
      expect(result.kind, FileKind.zipArchive);
      expect(result.label, contains('повреждён'));
    });
  });

  group('text', () {
    test('UTF-8 text with an extension hint', () {
      final bytes = Uint8List.fromList(utf8.encode('a,b,c\n1,2,3'));
      final result = detectType(bytes, extension: 'csv');
      expect(result.kind, FileKind.text);
      expect(result.label, contains('.csv'));
    });

    test('text with no BOM, not UTF-8 — assume Windows-1251', () {
      // A lone 0xC0 byte is an invalid start of a UTF-8 sequence.
      final bytes = Uint8List.fromList([0x41, 0x42, 0xC0, 0x20, 0x43]);
      final result = detectType(bytes, extension: 'txt');
      expect(result.kind, FileKind.text);
      expect(result.label, contains('Windows-1251'));
    });

    test('file with no extension — determined by content', () {
      final bytes = Uint8List.fromList(utf8.encode('просто текст'));
      final result = detectType(bytes, extension: null);
      expect(result.kind, FileKind.text);
    });
  });

  group('edge cases', () {
    test('zero-length file', () {
      final result = detectType(Uint8List(0));
      expect(result.kind, FileKind.emptyFile);
    });

    test('random binary bytes — unknown format', () {
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
    test('extracts the extension from the filename', () {
      final info = StreamInfo.fromHead(
        Uint8List.fromList(utf8.encode('text')),
        filename: 'document.MD',
      );
      expect(info.extension, 'md');
    });

    test('file with no dot in the name — no extension', () {
      final info = StreamInfo.fromHead(
        Uint8List.fromList(utf8.encode('text')),
        filename: 'document',
      );
      expect(info.extension, isNull);
    });

    test('lengthBytes comes from the explicit value, not from head', () {
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

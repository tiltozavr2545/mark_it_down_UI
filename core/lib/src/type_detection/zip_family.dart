import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'detected_type.dart';

/// `PK\x03\x04` сам по себе не говорит ничего: `docx`, `xlsx`, `pptx`,
/// `epub`, `apk` и обычный zip — всё это zip. Различаются по содержимому:
/// `[Content_Types].xml` (OOXML, дальше по имени части), `mimetype` первым
/// файлом (EPUB), `AndroidManifest.xml` (APK), иначе — обычный архив.
///
/// Только имена записей читаются заранее (центральная директория); архив не
/// распаковывается целиком — это и держит проверку дешёвой.
DetectedType refineZipFamily(Uint8List bytes) {
  final archive = decodeZip(bytes);
  if (archive == null) {
    return const DetectedType(
      FileKind.zipArchive,
      'zip-архив (не удалось прочитать как zip — возможно, повреждён)',
    );
  }

  final names = archive.files.map((f) => f.name).toSet();

  final mimetypeEntry = archive.findFile('mimetype');
  if (mimetypeEntry != null) {
    final content = _tryReadAsString(mimetypeEntry);
    if (content?.trim() == 'application/epub+zip') {
      return const DetectedType(FileKind.epub, 'EPUB');
    }
  }

  if (names.contains('[Content_Types].xml')) {
    if (names.contains('word/document.xml')) {
      return const DetectedType(FileKind.docx, 'OOXML Word (.docx)');
    }
    if (names.contains('xl/workbook.xml')) {
      return const DetectedType(FileKind.xlsx, 'OOXML Excel (.xlsx)');
    }
    if (names.contains('ppt/presentation.xml')) {
      return const DetectedType(FileKind.pptx, 'OOXML PowerPoint (.pptx)');
    }
    return const DetectedType(FileKind.zipArchive, 'OOXML-пакет');
  }

  if (names.contains('AndroidManifest.xml')) {
    return const DetectedType(FileKind.androidApk, 'Android APK');
  }

  return const DetectedType(FileKind.zipArchive, 'zip-архив');
}

String? _tryReadAsString(ArchiveFile file) {
  try {
    return utf8.decode(file.content, allowMalformed: true);
  } catch (_) {
    return null;
  }
}

/// Каталог zip или `null`, если файл как zip не читается. `archive` 4 на
/// битом файле не бросает, а отдаёт пустой архив, — пустым он может быть
/// честно только у файла, который и начинается с конца каталога
/// (`PK\x05\x06`, архив без записей).
Archive? decodeZip(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes, verify: false);
  } catch (_) {
    return null;
  }
  final emptyZip =
      bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4B &&
      bytes[2] == 0x05 &&
      bytes[3] == 0x06;
  if (archive.isEmpty && !emptyZip) return null;
  return archive;
}

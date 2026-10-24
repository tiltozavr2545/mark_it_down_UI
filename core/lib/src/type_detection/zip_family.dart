import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'detected_type.dart';

/// `PK\x03\x04` by itself says nothing: `docx`, `xlsx`, `pptx`, `epub`,
/// `apk` and a plain zip are all zip. They are distinguished by content:
/// `[Content_Types].xml` (OOXML, then by the part's name), `mimetype` as
/// the first file (EPUB), `AndroidManifest.xml` (APK), otherwise a plain
/// archive.
///
/// Only the entry names are read upfront (the central directory); the
/// archive is not unpacked in full — that is what keeps the check cheap.
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

/// The zip's catalog, or `null` if the file does not read as a zip. On a
/// broken file `archive` doesn't throw but returns an empty archive — it
/// can genuinely be empty only for a file that itself starts with the end
/// of the catalog (`PK\x05\x06`, an archive with no entries).
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

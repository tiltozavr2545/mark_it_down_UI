import 'dart:typed_data';

import 'detected_type.dart';
import 'ole2_directory.dart';

bool _startsWith(Uint8List bytes, List<int> signature) {
  if (bytes.length < signature.length) return false;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return false;
  }
  return true;
}

const _pdfSignature = [0x25, 0x50, 0x44, 0x46, 0x2D]; // %PDF-
const _ole2Signature = [
  0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, // OLE2 compound file
];
const _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
const _jpegSignature = [0xFF, 0xD8, 0xFF];
const _gifSignature = [0x47, 0x49, 0x46, 0x38]; // GIF8
const _bmpSignature = [0x42, 0x4D]; // BM

/// Три варианта сигнатуры zip: обычный, пустой архив, архив из нескольких
/// дисков. Для распознавания формата различие между ними не важно — дальше
/// за дело берётся [refineZipFamily].
const _zipSignatures = [
  [0x50, 0x4B, 0x03, 0x04],
  [0x50, 0x4B, 0x05, 0x06],
  [0x50, 0x4B, 0x07, 0x08],
];

bool isPdf(Uint8List head) => _startsWith(head, _pdfSignature);

bool isOle2Compound(Uint8List head) => _startsWith(head, _ole2Signature);

bool isZipSignature(Uint8List head) =>
    _zipSignatures.any((signature) => _startsWith(head, signature));

bool _isWebp(Uint8List head) {
  if (head.length < 12) return false;
  return head[0] == 0x52 &&
      head[1] == 0x49 &&
      head[2] == 0x46 &&
      head[3] == 0x46 && // RIFF
      head[8] == 0x57 &&
      head[9] == 0x45 &&
      head[10] == 0x42 &&
      head[11] == 0x50; // WEBP
}

/// Сигнатуры картинок — дёшево отличить от прочих бинарных форматов, даже
/// если конвертер для них появится только на этапе 5.
DetectedType? detectImageSignature(Uint8List head) {
  if (_startsWith(head, _pngSignature)) {
    return const DetectedType(FileKind.png, 'PNG');
  }
  if (_startsWith(head, _jpegSignature)) {
    return const DetectedType(FileKind.jpeg, 'JPEG');
  }
  if (_startsWith(head, _gifSignature)) {
    return const DetectedType(FileKind.gif, 'GIF');
  }
  if (_isWebp(head)) {
    return const DetectedType(FileKind.webp, 'WebP');
  }
  if (_startsWith(head, _bmpSignature)) {
    return const DetectedType(FileKind.bmp, 'BMP');
  }
  return null;
}

/// OLE2-контейнер сам по себе не говорит, `.doc`, `.xls`, `.msg` или `.ppt`
/// перед нами — все они делят одну сигнатуру. Различаются по именам потоков
/// в каталоге CFB ([readOle2EntryNames]): `Workbook`/`Book` — Excel,
/// `__properties_version1.0` и `__substg1.0_*` — Outlook `.msg`,
/// `WordDocument` — Word, `PowerPoint Document` — PowerPoint. Расширение —
/// только запасная подсказка, когда каталог прочитать не удалось (обрезанный
/// файл, нестандартный контейнер): оно может и врать.
DetectedType describeOle2(Uint8List head, String? extension) {
  final names = readOle2EntryNames(head);
  if (names != null) {
    if (names.any(
      (n) =>
          n == '__properties_version1.0' ||
          n.startsWith('__substg1.0_') ||
          n.startsWith('__recip_version1.0_') ||
          n.startsWith('__attach_version1.0_'),
    )) {
      return const DetectedType(FileKind.msg, 'Outlook-сообщение (.msg)');
    }
    if (names.contains('Workbook') || names.contains('Book')) {
      return const DetectedType(FileKind.xls, 'Excel 97–2003 (.xls)');
    }
    if (names.contains('WordDocument')) {
      return const DetectedType(FileKind.doc, 'Word 97–2003 (.doc)');
    }
    if (names.contains('PowerPoint Document')) {
      return const DetectedType(FileKind.ppt, 'PowerPoint 97–2003 (.ppt)');
    }
  }

  const knownExtensions = {'doc', 'xls', 'msg', 'ppt'};
  if (extension != null && knownExtensions.contains(extension)) {
    return DetectedType(
      FileKind.ole2Compound,
      'OLE2-контейнер, похоже на .$extension (по расширению)',
    );
  }
  return const DetectedType(
    FileKind.ole2Compound,
    'OLE2-контейнер (.doc / .xls / .msg)',
  );
}

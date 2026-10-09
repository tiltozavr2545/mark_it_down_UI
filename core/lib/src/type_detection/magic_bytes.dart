import 'dart:typed_data';

import 'detected_type.dart';

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

/// OLE2-контейнер сам по себе не говорит, `.doc`, `.xls` или `.msg` перед
/// нами — все три делят одну сигнатуру. Расширение здесь легитимная
/// подсказка (байты неоднозначны), но не более того: он может и врать.
DetectedType describeOle2(String? extension) {
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

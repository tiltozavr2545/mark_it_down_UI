import 'dart:convert';
import 'dart:typed_data';

import 'detected_type.dart';
import 'magic_bytes.dart';
import 'zip_family.dart';

const _textExtensions = {
  'txt',
  'md',
  'csv',
  'tsv',
  'json',
  'xml',
  'html',
  'htm',
  'rss',
  'atom',
};

/// Order — from cheap to expensive, the first confident answer wins:
/// magic bytes → refinement within the zip family → extension as a hint
/// → encoding for text files. The extension alone cannot be trusted — it
/// lies regularly (a file with no extension, a `.docx` named `.pdf`).
///
/// [head] — the bytes of the file already read (for small files, the
/// whole file; for large ones the start is enough; the decision of how
/// much to read stays with the caller).
DetectedType detectType(Uint8List head, {String? extension}) {
  if (head.isEmpty) {
    return const DetectedType(FileKind.emptyFile, 'Пустой файл');
  }

  if (isPdf(head)) {
    return const DetectedType(FileKind.pdf, 'PDF');
  }

  if (isOle2Compound(head)) {
    return describeOle2(head, extension);
  }

  if (isZipSignature(head)) {
    return refineZipFamily(head);
  }

  final image = detectImageSignature(head);
  if (image != null) return image;

  final media = detectMediaSignature(head, extension);
  if (media != null) return media;

  return _describeText(head, extension);
}

DetectedType _describeText(Uint8List head, String? extension) {
  if (_looksBinary(head)) {
    return const DetectedType(FileKind.unknown, 'Неизвестный формат');
  }

  final label = extension != null && _textExtensions.contains(extension)
      ? 'Текст (.$extension)'
      : 'Текст';

  try {
    utf8.decode(head, allowMalformed: false);
    return DetectedType(FileKind.text, label);
  } catch (_) {
    // No BOM and doesn't parse as UTF-8 — almost certainly Windows-1251,
    // which is routine for Russian-language exports, not a sign of a
    // corrupt file.
    return DetectedType(
      FileKind.text,
      '$label, не UTF-8 (вероятно Windows-1251)',
    );
  }
}

/// The share of control bytes (other than `\t`, `\n`, `\r`) among the
/// first bytes — a rough but cheap check for "does this even look like
/// text".
bool _looksBinary(Uint8List head) {
  final sample = head.length > 1024 ? head.sublist(0, 1024) : head;
  var controlBytes = 0;
  for (final byte in sample) {
    final isAllowedControl = byte == 0x09 || byte == 0x0A || byte == 0x0D;
    if (!isAllowedControl && byte < 0x20) controlBytes++;
  }
  return controlBytes / sample.length > 0.1;
}

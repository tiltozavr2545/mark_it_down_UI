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
};

/// Порядок — от дешёвого к дорогому, первый уверенный ответ побеждает:
/// магические байты → уточнение внутри zip-семьи → расширение как подсказка
/// → кодировка для текстовых. Расширению самому по себе верить нельзя — оно
/// врёт регулярно (файл без расширения, `.docx` под именем `.pdf`).
///
/// [head] — уже прочитанные байты файла (для маленьких файлов — файл
/// целиком, для больших достаточно начала; решение, сколько читать, остаётся
/// на вызывающей стороне).
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
    // Без BOM и не разбирается как UTF-8 — почти наверняка Windows-1251,
    // это обычное дело на русскоязычных выгрузках, а не признак битого файла.
    return DetectedType(
      FileKind.text,
      '$label, не UTF-8 (вероятно Windows-1251)',
    );
  }
}

/// Доля управляющих байтов (кроме `\t`, `\n`, `\r`) среди первых байтов —
/// грубая, но дешёвая проверка «это вообще похоже на текст».
bool _looksBinary(Uint8List head) {
  final sample = head.length > 1024 ? head.sublist(0, 1024) : head;
  var controlBytes = 0;
  for (final byte in sample) {
    final isAllowedControl = byte == 0x09 || byte == 0x0A || byte == 0x0D;
    if (!isAllowedControl && byte < 0x20) controlBytes++;
  }
  return controlBytes / sample.length > 0.1;
}

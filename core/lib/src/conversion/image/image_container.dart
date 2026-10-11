import 'dart:typed_data';

import '../../type_detection/detected_type.dart';

/// Сегмент JPEG между маркерами: [start] и [length] — полезная нагрузка, без
/// маркера и двух байт длины.
class JpegSegment {
  final int marker;
  final int start;
  final int length;

  const JpegSegment(this.marker, this.start, this.length);
}

/// Сегменты JPEG до начала сжатых данных (`SOS`) — там живут и `APP1` с
/// EXIF, и `SOFn` с размером. Обрезанный или нестандартный поток просто
/// заканчивает перебор: дальше маркеров нет, и ошибкой это не считается.
Iterable<JpegSegment> jpegSegments(Uint8List bytes) sync* {
  var offset = 2; // за SOI
  while (offset + 4 <= bytes.length) {
    if (bytes[offset] != 0xFF) return;
    final marker = bytes[offset + 1];
    // Заполняющие 0xFF перед маркером допустимы стандартом.
    if (marker == 0xFF) {
      offset++;
      continue;
    }
    // Маркеры без длины: TEM и RSTn.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      offset += 2;
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA) return; // EOI, SOS
    final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
    final end = offset + 2 + length;
    if (length < 2 || end > bytes.length) return;
    yield JpegSegment(marker, offset + 4, length - 2);
    offset = end;
  }
}

/// Блок EXIF — то есть TIFF-структура с `II*\0`/`MM\0*` в начале — внутри
/// контейнера картинки. `null`, если в файле его нет (скриншоты, картинки из
/// мессенджеров, где метаданные вычищены) или формат его не носит
/// (`GIF`, `BMP`).
Uint8List? findExifBlock(Uint8List bytes, FileKind kind) => switch (kind) {
  FileKind.jpeg => _jpegExif(bytes),
  FileKind.png => _pngExif(bytes),
  FileKind.webp => _webpExif(bytes),
  FileKind.tiff => bytes,
  FileKind.heic => _scanForExif(bytes),
  _ => null,
};

const _exifPrefix = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]; // Exif\0\0

bool _matchesAt(Uint8List bytes, int offset, List<int> pattern) {
  if (offset < 0 || offset + pattern.length > bytes.length) return false;
  for (var i = 0; i < pattern.length; i++) {
    if (bytes[offset + i] != pattern[i]) return false;
  }
  return true;
}

bool _isTiffHeaderAt(Uint8List bytes, int offset) =>
    _matchesAt(bytes, offset, const [0x49, 0x49, 0x2A, 0x00]) ||
    _matchesAt(bytes, offset, const [0x4D, 0x4D, 0x00, 0x2A]);

Uint8List _view(Uint8List bytes, int start, int length) =>
    Uint8List.sublistView(bytes, start, start + length);

/// `APP1`, начинающийся с `Exif\0\0`. Тот же маркер носит и XMP
/// (`http://ns.adobe.com/xap/1.0/`) — его пропускаем.
Uint8List? _jpegExif(Uint8List bytes) {
  for (final segment in jpegSegments(bytes)) {
    if (segment.marker == 0xE1 &&
        segment.length > _exifPrefix.length &&
        _matchesAt(bytes, segment.start, _exifPrefix)) {
      return _view(
        bytes,
        segment.start + _exifPrefix.length,
        segment.length - _exifPrefix.length,
      );
    }
  }
  return null;
}

/// Чанк `eXIf` (PNG 1.5+). Обычно стоит до `IDAT`, но стандарт разрешает и
/// после — поэтому идём по всем чанкам, а не до первого `IDAT`.
Uint8List? _pngExif(Uint8List bytes) {
  var offset = 8; // за сигнатурой
  while (offset + 8 <= bytes.length) {
    final length = ByteData.sublistView(bytes).getUint32(offset);
    final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
    final dataStart = offset + 8;
    if (dataStart + length > bytes.length) return null;
    if (type == 'eXIf') return _view(bytes, dataStart, length);
    if (type == 'IEND') return null;
    offset = dataStart + length + 4; // + CRC
  }
  return null;
}

/// Чанк `EXIF` в RIFF-контейнере WebP. Часть писателей кладёт перед TIFF
/// ещё и `Exif\0\0`, как в JPEG, — оба варианта встречаются.
Uint8List? _webpExif(Uint8List bytes) {
  var offset = 12; // за RIFF....WEBP
  while (offset + 8 <= bytes.length) {
    final type = String.fromCharCodes(bytes, offset, offset + 4);
    final length = ByteData.sublistView(
      bytes,
    ).getUint32(offset + 4, Endian.little);
    final dataStart = offset + 8;
    if (dataStart + length > bytes.length) return null;
    if (type == 'EXIF') {
      final skip =
          length > _exifPrefix.length &&
              _matchesAt(bytes, dataStart, _exifPrefix)
          ? _exifPrefix.length
          : 0;
      return _view(bytes, dataStart + skip, length - skip);
    }
    offset = dataStart + length + (length & 1); // чанки выровнены на 2
  }
  return null;
}

/// HEIC хранит EXIF отдельным элементом, найти который по-честному — это
/// разобрать `meta` → `iinf` + `iloc`. Вместо этого ищем сам элемент по
/// содержимому: он начинается с `Exif\0\0` и сразу за ним — заголовок TIFF.
/// Десять байт подряд такой формы в сжатых данных случайно не возникают, а
/// разбор коробок ради одного указателя дороже и хрупче.
Uint8List? _scanForExif(Uint8List bytes) {
  for (var i = 0; i + 10 <= bytes.length; i++) {
    if (bytes[i] == 0x45 &&
        _matchesAt(bytes, i, _exifPrefix) &&
        _isTiffHeaderAt(bytes, i + _exifPrefix.length)) {
      final start = i + _exifPrefix.length;
      return _view(bytes, start, bytes.length - start);
    }
  }
  return null;
}

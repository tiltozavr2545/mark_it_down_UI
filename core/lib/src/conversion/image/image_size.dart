import 'dart:typed_data';

import '../../type_detection/detected_type.dart';
import 'image_container.dart';

/// Ширина и высота изображения в пикселях.
class ImageSize {
  final int width;
  final int height;

  const ImageSize(this.width, this.height);

  @override
  String toString() => '$width × $height';
}

/// Размер по заголовку файла, без декодирования пикселей — картинку на
/// 50 МБ не нужно разжимать, чтобы сказать «4032 × 3024». `null`, если
/// заголовок обрезан, нестандартный или у формата его негде взять
/// (`TIFF` — размер приходит из EXIF, см. `ImageConverter`).
ImageSize? readImageSize(Uint8List bytes, FileKind kind) {
  try {
    final size = switch (kind) {
      FileKind.png => _png(bytes),
      FileKind.gif => _gif(bytes),
      FileKind.bmp => _bmp(bytes),
      FileKind.jpeg => _jpeg(bytes),
      FileKind.webp => _webp(bytes),
      FileKind.heic => _heif(bytes),
      _ => null,
    };
    if (size == null || size.width <= 0 || size.height <= 0) return null;
    return size;
  } on RangeError {
    // Обрезанный файл: заголовок обещал больше байтов, чем есть.
    return null;
  }
}

ByteData _view(Uint8List bytes) => ByteData.sublistView(bytes, 0, bytes.length);

/// `IHDR` — всегда первый чанк сразу за сигнатурой: ширина и высота, big
/// endian, по смещениям 16 и 20.
ImageSize? _png(Uint8List bytes) {
  if (String.fromCharCodes(bytes.sublist(12, 16)) != 'IHDR') return null;
  final view = _view(bytes);
  return ImageSize(view.getUint32(16), view.getUint32(20));
}

/// Logical Screen Descriptor сразу за `GIF87a`/`GIF89a`, little endian.
ImageSize? _gif(Uint8List bytes) {
  final view = _view(bytes);
  return ImageSize(
    view.getUint16(6, Endian.little),
    view.getUint16(8, Endian.little),
  );
}

/// `BITMAPINFOHEADER` и его потомки: ширина и высота — int32 по смещениям
/// 18 и 22; отрицательная высота значит «строки сверху вниз», а не размер.
/// Старый `BITMAPCOREHEADER` (размер заголовка 12) — uint16.
ImageSize? _bmp(Uint8List bytes) {
  final view = _view(bytes);
  final headerSize = view.getUint32(14, Endian.little);
  if (headerSize == 12) {
    return ImageSize(
      view.getUint16(18, Endian.little),
      view.getUint16(20, Endian.little),
    );
  }
  return ImageSize(
    view.getInt32(18, Endian.little),
    view.getInt32(22, Endian.little).abs(),
  );
}

/// Первый `SOFn` — в нём точность, высота и ширина.
ImageSize? _jpeg(Uint8List bytes) {
  for (final segment in jpegSegments(bytes)) {
    final marker = segment.marker;
    final isSof =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 && // DHT
        marker != 0xC8 && // JPG (зарезервирован)
        marker != 0xCC; // DAC
    if (isSof && segment.length >= 5) {
      final view = _view(bytes);
      return ImageSize(
        view.getUint16(segment.start + 3),
        view.getUint16(segment.start + 1),
      );
    }
  }
  return null;
}

/// `RIFF....WEBP` и первый чанк: `VP8 ` (с потерями), `VP8L` (без потерь)
/// или `VP8X` (расширенный — с EXIF, альфой, анимацией).
ImageSize? _webp(Uint8List bytes) {
  final view = _view(bytes);
  final chunk = String.fromCharCodes(bytes.sublist(12, 16));
  switch (chunk) {
    case 'VP8 ':
      // Кадр-ключ: 3 байта тега кадра, 3 байта стартового кода, затем
      // ширина и высота по 14 бит.
      return ImageSize(
        view.getUint16(26, Endian.little) & 0x3FFF,
        view.getUint16(28, Endian.little) & 0x3FFF,
      );
    case 'VP8L':
      // Байт сигнатуры 0x2F, затем ширина-1 и высота-1 по 14 бит подряд.
      final bits = view.getUint32(21, Endian.little);
      return ImageSize((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
    case 'VP8X':
      // Ширина-1 и высота-1 — по 24 бита после флагов и резерва.
      int uint24(int at) =>
          bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16);
      return ImageSize(uint24(24) + 1, uint24(27) + 1);
  }
  return null;
}

/// HEIF: размеры элементов лежат свойствами `ispe` внутри коробки `meta`.
/// У снимка с iPhone их несколько — плитки 512 × 512, миниатюра и сама
/// сетка; честно сопоставить их с основным элементом — это разбор
/// `pitm`/`iprp`/`ipma`. Берём наибольший: основное изображение больше и
/// своих плиток, и миниатюры.
ImageSize? _heif(Uint8List bytes) {
  final view = _view(bytes);
  var offset = 0;
  while (offset + 8 <= bytes.length) {
    final size = view.getUint32(offset);
    final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
    // 0 — «до конца файла», 1 — 64-битный размер дальше; `meta` стоит до
    // `mdat`, так что до таких коробок дело обычно не доходит.
    if (size < 8) return null;
    if (type == 'meta') {
      final end = offset + size > bytes.length ? bytes.length : offset + size;
      ImageSize? largest;
      for (var i = offset + 8; i + 16 <= end; i++) {
        if (bytes[i] != 0x69 ||
            String.fromCharCodes(bytes, i, i + 4) != 'ispe') {
          continue;
        }
        // За именем: версия и флаги (4 байта), ширина, высота.
        final candidate = ImageSize(
          view.getUint32(i + 8),
          view.getUint32(i + 12),
        );
        if (largest == null ||
            candidate.width * candidate.height >
                largest.width * largest.height) {
          largest = candidate;
        }
      }
      return largest;
    }
    offset += size;
  }
  return null;
}

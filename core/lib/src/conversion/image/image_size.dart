import 'dart:typed_data';

import '../../type_detection/detected_type.dart';
import 'image_container.dart';

/// An image's width and height in pixels.
class ImageSize {
  final int width;
  final int height;

  const ImageSize(this.width, this.height);

  @override
  String toString() => '$width × $height';
}

/// Size from the file header, without decoding the pixels — a hundreds-
/// of-MB image shouldn't need unpacking just to say "4032 × 3024". `null`
/// if the header is truncated, non-standard, or the format has nowhere
/// to take it from (`TIFF` — the size comes from EXIF, see
/// `ImageConverter`).
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
    // A truncated file: the header promised more bytes than there are.
    return null;
  }
}

ByteData _view(Uint8List bytes) => ByteData.sublistView(bytes, 0, bytes.length);

/// `IHDR` is always the first chunk right after the signature: width and
/// height, big endian, at offsets 16 and 20.
ImageSize? _png(Uint8List bytes) {
  if (String.fromCharCodes(bytes.sublist(12, 16)) != 'IHDR') return null;
  final view = _view(bytes);
  return ImageSize(view.getUint32(16), view.getUint32(20));
}

/// The Logical Screen Descriptor right after `GIF87a`/`GIF89a`, little
/// endian.
ImageSize? _gif(Uint8List bytes) {
  final view = _view(bytes);
  return ImageSize(
    view.getUint16(6, Endian.little),
    view.getUint16(8, Endian.little),
  );
}

/// `BITMAPINFOHEADER` and its descendants: width and height — int32 at
/// offsets 18 and 22; a negative height means "rows top to bottom", not
/// the size itself. The old `BITMAPCOREHEADER` (header size 12) uses
/// uint16.
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

/// The first `SOFn` — holds the precision, height and width.
ImageSize? _jpeg(Uint8List bytes) {
  for (final segment in jpegSegments(bytes)) {
    final marker = segment.marker;
    final isSof =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 && // DHT
        marker != 0xC8 && // JPG (reserved)
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

/// `RIFF....WEBP` and the first chunk: `VP8 ` (lossy), `VP8L` (lossless)
/// or `VP8X` (extended — with EXIF, alpha, animation).
ImageSize? _webp(Uint8List bytes) {
  final view = _view(bytes);
  final chunk = String.fromCharCodes(bytes.sublist(12, 16));
  switch (chunk) {
    case 'VP8 ':
      // A key frame: 3 bytes of frame tag, 3 bytes of start code, then
      // width and height, 14 bits each.
      return ImageSize(
        view.getUint16(26, Endian.little) & 0x3FFF,
        view.getUint16(28, Endian.little) & 0x3FFF,
      );
    case 'VP8L':
      // A signature byte 0x2F, then width-1 and height-1, 14 bits each
      // in sequence.
      final bits = view.getUint32(21, Endian.little);
      return ImageSize((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
    case 'VP8X':
      // Width-1 and height-1 — 24 bits each after the flags and reserved
      // bytes.
      int uint24(int at) =>
          bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16);
      return ImageSize(uint24(24) + 1, uint24(27) + 1);
  }
  return null;
}

/// HEIF: item sizes sit as `ispe` properties inside the `meta` box. An
/// iPhone photo has several of them — 512 × 512 tiles, a thumbnail, and
/// the grid itself; properly matching them to the primary item means
/// parsing `pitm`/`iprp`/`ipma`. We take the largest: the primary image is
/// bigger than both its own tiles and the thumbnail.
ImageSize? _heif(Uint8List bytes) {
  final view = _view(bytes);
  var offset = 0;
  while (offset + 8 <= bytes.length) {
    final size = view.getUint32(offset);
    final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
    // 0 means "to the end of the file", 1 means a 64-bit size follows;
    // `meta` sits before `mdat`, so such boxes usually aren't an issue.
    if (size < 8) return null;
    if (type == 'meta') {
      final end = offset + size > bytes.length ? bytes.length : offset + size;
      ImageSize? largest;
      for (var i = offset + 8; i + 16 <= end; i++) {
        if (bytes[i] != 0x69 ||
            String.fromCharCodes(bytes, i, i + 4) != 'ispe') {
          continue;
        }
        // After the name: version and flags (4 bytes), width, height.
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

import 'dart:typed_data';

import '../../type_detection/detected_type.dart';

/// A JPEG segment between markers: [start] and [length] are the payload,
/// without the marker and the two length bytes.
class JpegSegment {
  final int marker;
  final int start;
  final int length;

  const JpegSegment(this.marker, this.start, this.length);
}

/// JPEG segments up to the start of the compressed data (`SOS`) — that's
/// where both the `APP1` with EXIF and the `SOFn` with the size live. A
/// truncated or non-standard stream simply ends the iteration: there are
/// no more markers past that point, and it isn't treated as an error.
Iterable<JpegSegment> jpegSegments(Uint8List bytes) sync* {
  var offset = 2; // past SOI
  while (offset + 4 <= bytes.length) {
    if (bytes[offset] != 0xFF) return;
    final marker = bytes[offset + 1];
    // Fill bytes of 0xFF before a marker are allowed by the standard.
    if (marker == 0xFF) {
      offset++;
      continue;
    }
    // Markers without a length: TEM and RSTn.
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

/// The EXIF block — i.e. a TIFF structure with `II*\0`/`MM\0*` at the
/// start — inside the image container. `null` if the file has none
/// (screenshots, images from messengers that strip metadata) or the
/// format doesn't carry it (`GIF`, `BMP`).
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

/// `APP1` starting with `Exif\0\0`. The same marker also carries XMP
/// (`http://ns.adobe.com/xap/1.0/`) — we skip that one.
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

/// The `eXIf` chunk (PNG 1.5+). It's usually before `IDAT`, but the
/// standard also allows after — so we go through all chunks, not just
/// up to the first `IDAT`.
Uint8List? _pngExif(Uint8List bytes) {
  var offset = 8; // past the signature
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

/// The `EXIF` chunk in a WebP RIFF container. Some writers also put
/// `Exif\0\0` before the TIFF, like in JPEG — both variants occur.
Uint8List? _webpExif(Uint8List bytes) {
  var offset = 12; // past RIFF....WEBP
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
    offset = dataStart + length + (length & 1); // chunks are 2-byte aligned
  }
  return null;
}

/// HEIC stores EXIF as a separate item, and finding it properly means
/// parsing `meta` → `iinf` + `iloc`. Instead, we search for the item by
/// its content: it starts with `Exif\0\0` and right after it is the TIFF
/// header. Ten consecutive bytes of that exact shape don't occur by
/// chance in compressed data, and parsing boxes just for one pointer is
/// more expensive and fragile.
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

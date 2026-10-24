import 'dart:convert';
import 'dart:typed_data';

import '../../text_decoding.dart';

/// One IFD entry: the TIFF type and the raw value bytes in the file's
/// byte order. Interpretation is on demand, via getters: a file has dozens
/// of tags, and only a handful of them are ever needed.
class ExifEntry {
  final int type;
  final int count;
  final Uint8List raw;
  final Endian endian;

  const ExifEntry(this.type, this.count, this.raw, this.endian);

  ByteData get _data => ByteData.sublistView(raw);

  /// A string from `ASCII` (type 2) or `UNDEFINED`/`BYTE`. The standard
  /// promises ASCII, but phones and Windows write UTF-8 there, and older
  /// programs write Windows-1251; hence decoding via [decodeTextBytes],
  /// like ordinary text. An empty string or one made of only spaces
  /// becomes `null`.
  String? get text {
    var end = raw.indexOf(0);
    if (end < 0) end = raw.length;
    final value = decodeTextBytes(
      Uint8List.sublistView(raw, 0, end),
    ).content.trim();
    return value.isEmpty ? null : value;
  }

  /// Integer `BYTE`/`SHORT`/`LONG` values and their signed variants.
  List<int> get ints {
    final int Function(int at)? read = switch (type) {
      1 || 7 => (at) => raw[at],
      6 => (at) => _data.getInt8(at),
      3 => (at) => _data.getUint16(at, endian),
      8 => (at) => _data.getInt16(at, endian),
      4 => (at) => _data.getUint32(at, endian),
      9 => (at) => _data.getInt32(at, endian),
      _ => null,
    };
    if (read == null) return const [];
    final size = _typeSizes[type]!;
    return [
      for (var i = 0; i < count && (i + 1) * size <= raw.length; i++)
        read(i * size),
    ];
  }

  /// `RATIONAL`/`SRATIONAL` as numerator/denominator pairs — an exposure
  /// time of `1/250` is needed as a fraction, not as `0.004`.
  List<(int, int)> get rationals {
    if (type != 5 && type != 10) return const [];
    final result = <(int, int)>[];
    for (var i = 0; i < count && (i + 1) * 8 <= raw.length; i++) {
      final at = i * 8;
      result.add(
        type == 5
            ? (_data.getUint32(at, endian), _data.getUint32(at + 4, endian))
            : (_data.getInt32(at, endian), _data.getInt32(at + 4, endian)),
      );
    }
    return result;
  }

  /// A null-terminated UTF-16LE string — this is how Windows ("Properties" →
  /// "Details") stores `XPTitle`, `XPComment`, `XPAuthor`, `XPKeywords`.
  String? get utf16LeText {
    final units = <int>[];
    for (var i = 0; i + 1 < raw.length; i += 2) {
      final unit = raw[i] | (raw[i + 1] << 8);
      if (unit == 0) break;
      units.add(unit);
    }
    final value = String.fromCharCodes(units).trim();
    return value.isEmpty ? null : value;
  }

  /// `UserComment`: the first 8 bytes are the encoding (`ASCII`, `UNICODE`,
  /// `JIS`, or all zeros meaning "unspecified"), followed by the text.
  /// `UNICODE` is UTF-16 in the file's byte order; `JIS` is only seen from
  /// Japanese cameras and is read as-is.
  String? get userComment {
    if (raw.length <= 8) return null;
    final code = ascii.decode(raw.sublist(0, 8), allowInvalid: true);
    final body = Uint8List.sublistView(raw, 8);
    if (code.startsWith('UNICODE')) {
      final units = <int>[];
      final data = ByteData.sublistView(body);
      for (var i = 0; i + 1 < body.length; i += 2) {
        final unit = data.getUint16(i, endian);
        if (unit == 0) break;
        units.add(unit);
      }
      final value = String.fromCharCodes(units).trim();
      return value.isEmpty ? null : value;
    }
    return ExifEntry(2, body.length, body, endian).text;
  }
}

/// The three IFDs the photo's metadata is drawn from: the main one
/// (`IFD0`), `Exif` (capture parameters), and `GPS`. Keyed by tag number.
class ExifData {
  final Map<int, ExifEntry> image;
  final Map<int, ExifEntry> exif;
  final Map<int, ExifEntry> gps;

  /// Something in the structure pointed outside the block or was
  /// implausible — whatever could be read was read.
  final bool damaged;

  const ExifData({
    required this.image,
    required this.exif,
    required this.gps,
    required this.damaged,
  });
}

const _typeSizes = {
  1: 1, // BYTE
  2: 1, // ASCII
  3: 2, // SHORT
  4: 4, // LONG
  5: 8, // RATIONAL
  6: 1, // SBYTE
  7: 1, // UNDEFINED
  8: 2, // SSHORT
  9: 4, // SLONG
  10: 8, // SRATIONAL
  11: 4, // FLOAT
  12: 8, // DOUBLE
};

const _exifIfdPointer = 0x8769;
const _gpsIfdPointer = 0x8825;

/// Real-world files never have more entries than this in a single IFD;
/// more means the counter is corrupt, and reading on would just be
/// looping over garbage.
const _maxEntriesPerIfd = 1000;

/// No tag being read needs values longer than this (the longest is a
/// comment); a `MakerNote` of hundreds of KB is skipped instead of copied.
const _maxValueBytes = 64 * 1024;

/// Parses the TIFF structure of an EXIF block ([tiff] starts with `II*\0`
/// or `MM\0*`). Returns `null` if it isn't TIFF at all. A hand-rolled
/// parser rather than the `exif` package: that one walks the IFD chain
/// with no loop protection, and a file where an IFD points at itself is
/// exactly the malicious fixture this needs to withstand.
/// See `docs/format-coverage.md#решения-этапа-6`.
ExifData? readExif(Uint8List tiff) {
  if (tiff.length < 8) return null;
  final Endian endian;
  if (tiff[0] == 0x49 && tiff[1] == 0x49) {
    endian = Endian.little;
  } else if (tiff[0] == 0x4D && tiff[1] == 0x4D) {
    endian = Endian.big;
  } else {
    return null;
  }
  final data = ByteData.sublistView(tiff);
  if (data.getUint16(2, endian) != 42) return null;

  final reader = _IfdReader(tiff, data, endian);
  final image = reader.read(data.getUint32(4, endian));

  // Вложенные IFD — по указателям из основного. Посещённые смещения
  // помнятся в [_IfdReader]: указатель на уже прочитанный IFD — петля.
  Map<int, ExifEntry> nested(int pointerTag) {
    final pointer = image[pointerTag]?.ints;
    if (pointer == null || pointer.isEmpty) return {};
    return reader.read(pointer.first);
  }

  final exif = nested(_exifIfdPointer);
  final gps = nested(_gpsIfdPointer);
  return ExifData(image: image, exif: exif, gps: gps, damaged: reader.damaged);
}

class _IfdReader {
  final Uint8List bytes;
  final ByteData data;
  final Endian endian;
  final _visited = <int>{};
  bool damaged = false;

  _IfdReader(this.bytes, this.data, this.endian);

  Map<int, ExifEntry> read(int offset) {
    final entries = <int, ExifEntry>{};
    if (!_visited.add(offset)) {
      damaged = true;
      return entries;
    }
    if (offset < 8 || offset + 2 > bytes.length) {
      damaged = true;
      return entries;
    }
    final count = data.getUint16(offset, endian);
    if (count > _maxEntriesPerIfd || offset + 2 + count * 12 > bytes.length) {
      damaged = true;
      return entries;
    }
    for (var i = 0; i < count; i++) {
      final at = offset + 2 + i * 12;
      final tag = data.getUint16(at, endian);
      final type = data.getUint16(at + 2, endian);
      final valueCount = data.getUint32(at + 4, endian);
      final size = _typeSizes[type];
      // Неизвестный тип — не повреждение: стандарт велит такие пропускать.
      if (size == null) continue;
      final length = size * valueCount;
      if (length > _maxValueBytes) continue;
      final valueOffset = length <= 4 ? at + 8 : data.getUint32(at + 8, endian);
      if (valueOffset + length > bytes.length) {
        damaged = true;
        continue;
      }
      entries[tag] = ExifEntry(
        type,
        valueCount,
        Uint8List.sublistView(bytes, valueOffset, valueOffset + length),
        endian,
      );
    }
    return entries;
  }
}

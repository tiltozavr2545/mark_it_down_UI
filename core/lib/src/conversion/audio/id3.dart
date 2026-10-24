import 'dart:convert';
import 'dart:typed_data';

import '../../text_decoding.dart';
import '../../type_detection/magic_bytes.dart';
import 'audio_info.dart';

/// ID3v2 frames that get translated into [AudioTags]. ID3v2.2 writes the
/// same frames with three-letter names — see [_v22Names].
const _textFrames = {
  'TIT2': 'title',
  'TPE1': 'artist',
  'TPE2': 'albumartist',
  'TALB': 'album',
  'TYER': 'year',
  'TDRC': 'year',
  'TCON': 'genre',
  'TRCK': 'track',
  'TCOM': 'composer',
};

const _v22Names = {
  'TT2': 'TIT2',
  'TP1': 'TPE1',
  'TP2': 'TPE2',
  'TAL': 'TALB',
  'TYE': 'TYER',
  'TCO': 'TCON',
  'TRK': 'TRCK',
  'TCM': 'TCOM',
  'COM': 'COMM',
  'ULT': 'USLT',
  'TLE': 'TLEN',
};

/// Reads the ID3v2 tag at the start of the file into [info]. Returns the
/// tag's length — the MPEG frames start right after it; `0` if there's
/// no tag. Corrupt frames are skipped rather than aborting the parse: a
/// partial result is more useful than a failure.
int readId3v2(Uint8List bytes, AudioInfo info) {
  final length = id3v2Length(bytes);
  if (length == null) return 0;
  final major = bytes[3];
  final flags = bytes[5];
  if (length > bytes.length) info.damaged = true;

  var body = Uint8List.sublistView(bytes, 10, length.clamp(10, bytes.length));
  // Unsynchronisation of the whole tag (v2.2/v2.3): a 0x00 is inserted
  // after every 0xFF so old players don't mistake the tag for an MPEG
  // frame.
  if (major < 4 && flags & 0x80 != 0) body = _deunsync(body);

  var offset = 0;
  if (flags & 0x40 != 0 && major >= 3 && body.length >= 4) {
    final view = ByteData.sublistView(body);
    // Extended header: in v2.3 the size excludes these 4 bytes
    // themselves, in v2.4 it includes them and is synchsafe.
    offset = major == 3 ? 4 + view.getUint32(0) : _synchsafe(body, 0);
  }

  final headerSize = major == 2 ? 6 : 10;
  final idSize = major == 2 ? 3 : 4;
  while (offset + headerSize <= body.length) {
    if (body[offset] == 0) break; // padding
    var id = String.fromCharCodes(body, offset, offset + idSize);
    if (!RegExp(r'^[A-Z0-9]+$').hasMatch(id)) {
      info.damaged = true;
      break;
    }
    final size = switch (major) {
      2 =>
        (body[offset + 3] << 16) | (body[offset + 4] << 8) | body[offset + 5],
      3 => ByteData.sublistView(body).getUint32(offset + 4),
      _ => _synchsafe(body, offset + 4),
    };
    final start = offset + headerSize;
    if (size <= 0 || start + size > body.length) {
      info.damaged = true;
      break;
    }
    var data = Uint8List.sublistView(body, start, start + size);
    offset = start + size;

    if (major == 2) id = _v22Names[id] ?? id;
    if (major >= 3) {
      final formatFlags = body[start - 1];
      final skip = major == 3
          ? formatFlags & 0xC0 !=
                0 // compression, encryption
          : formatFlags & 0x0C != 0;
      if (skip) continue;
      if (major == 3 && formatFlags & 0x20 != 0) {
        // grouping — a group identifier byte before the data
        if (data.isEmpty) continue;
        data = Uint8List.sublistView(data, 1);
      }
      if (major == 4) {
        if (formatFlags & 0x40 != 0) {
          if (data.isEmpty) continue;
          data = Uint8List.sublistView(data, 1); // grouping
        }
        if (formatFlags & 0x02 != 0) data = _deunsync(data);
        if (formatFlags & 0x01 != 0) {
          if (data.length < 4) continue;
          data = Uint8List.sublistView(data, 4); // pre-compression length
        }
      }
    }
    _applyFrame(id, data, info);
  }
  return length;
}

void _applyFrame(String id, Uint8List data, AudioInfo info) {
  if (data.isEmpty) return;
  final field = _textFrames[id];
  if (field != null) {
    final text = _decodeText(data[0], Uint8List.sublistView(data, 1));
    // v2.4 separates multiple values with a null byte.
    final value = text.split('\u0000').where((v) => v.isNotEmpty).join(', ');
    info.tags.set(field, field == 'genre' ? normalizeGenre(value) : value);
    return;
  }
  switch (id) {
    case 'COMM':
      final (description, text) = _describedText(data);
      // iTunes stores internal data in comments (`iTunNORM`, `iTunSMPB`).
      if (!description.startsWith('iTun')) info.tags.set('comment', text);
    case 'USLT':
      info.tags.set('lyrics', _describedText(data).$2);
    case 'TLEN':
      final ms = int.tryParse(
        _decodeText(data[0], Uint8List.sublistView(data, 1)).trim(),
      );
      if (ms != null && ms > 0) {
        info.duration ??= Duration(milliseconds: ms);
      }
  }
}

/// `COMM`/`USLT`: encoding, language (3 bytes), description up to the
/// terminator, text.
(String, String) _describedText(Uint8List data) {
  if (data.length < 4) return ('', '');
  final encoding = data[0];
  final rest = Uint8List.sublistView(data, 4);
  final wide = encoding == 1 || encoding == 2;
  var end = 0;
  if (wide) {
    while (end + 1 < rest.length && (rest[end] != 0 || rest[end + 1] != 0)) {
      end += 2;
    }
  } else {
    while (end < rest.length && rest[end] != 0) {
      end++;
    }
  }
  final textStart = (end + (wide ? 2 : 1)).clamp(0, rest.length);
  return (
    _decodeText(encoding, Uint8List.sublistView(rest, 0, end)),
    _decodeText(encoding, Uint8List.sublistView(rest, textStart)),
  );
}

/// ID3v2 encodings: 0 — "ISO-8859-1" (in practice often Windows-1251, see
/// [decodeLegacyText]), 1 — UTF-16 with a BOM, 2 — UTF-16BE, 3 — UTF-8.
String _decodeText(int encoding, Uint8List bytes) {
  var text = switch (encoding) {
    1 => _utf16(bytes, bigEndianByDefault: false),
    2 => _utf16(bytes, bigEndianByDefault: true),
    3 => utf8.decode(bytes, allowMalformed: true),
    _ => decodeLegacyText(bytes),
  };
  while (text.endsWith('\u0000')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

String _utf16(Uint8List bytes, {required bool bigEndianByDefault}) {
  var bigEndian = bigEndianByDefault;
  var start = 0;
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      bigEndian = false;
      start = 2;
    } else if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      bigEndian = true;
      start = 2;
    }
  }
  final units = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    final unit = bigEndian
        ? (bytes[i] << 8) | bytes[i + 1]
        : bytes[i] | (bytes[i + 1] << 8);
    // A BOM at the start of each value in a v2.4 list — not a character.
    if (unit == 0xFEFF) continue;
    units.add(unit);
  }
  return String.fromCharCodes(units);
}

int _synchsafe(Uint8List bytes, int at) =>
    (bytes[at] << 21) |
    (bytes[at + 1] << 14) |
    (bytes[at + 2] << 7) |
    bytes[at + 3];

Uint8List _deunsync(Uint8List bytes) {
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < bytes.length; i++) {
    out.addByte(bytes[i]);
    if (bytes[i] == 0xFF && i + 1 < bytes.length && bytes[i + 1] == 0x00) {
      i++;
    }
  }
  return out.toBytes();
}

/// ID3v1 — the file's last 128 bytes, `TAG` + fixed-length fields padded
/// with nulls or spaces. Returns `true` if the tag is present — in which
/// case these 128 bytes aren't audio and don't count toward the
/// duration.
bool readId3v1(Uint8List bytes, AudioInfo info) {
  if (bytes.length < 128) return false;
  final at = bytes.length - 128;
  if (bytes[at] != 0x54 || bytes[at + 1] != 0x41 || bytes[at + 2] != 0x47) {
    return false;
  }
  String? field(int offset, int length) {
    final raw = Uint8List.sublistView(bytes, at + offset, at + offset + length);
    var end = raw.indexOf(0);
    if (end < 0) end = raw.length;
    final value = decodeLegacyText(Uint8List.sublistView(raw, 0, end)).trim();
    return value.isEmpty ? null : value;
  }

  info.tags
    ..set('title', field(3, 30))
    ..set('artist', field(33, 30))
    ..set('album', field(63, 30))
    ..set('year', field(93, 4));
  // ID3v1.1: a zero in the comment's 29th byte means the 30th holds the
  // track number.
  final hasTrack = bytes[at + 125] == 0 && bytes[at + 126] != 0;
  info.tags.set('comment', field(97, hasTrack ? 28 : 30));
  if (hasTrack) info.tags.set('track', '${bytes[at + 126]}');
  final genre = bytes[at + 127];
  if (genre < id3Genres.length) info.tags.set('genre', id3Genres[genre]);
  return true;
}

import 'dart:convert';
import 'dart:typed_data';

import 'audio_info.dart';

/// Ключи Vorbis comment → поля [AudioTags]. Ключи регистронезависимы, а
/// имена гуляют между программами (`DATE`/`YEAR`, `COMMENT`/`DESCRIPTION`).
const _vorbisFields = {
  'TITLE': 'title',
  'ARTIST': 'artist',
  'ALBUMARTIST': 'albumartist',
  'ALBUM ARTIST': 'albumartist',
  'ALBUM': 'album',
  'DATE': 'year',
  'YEAR': 'year',
  'GENRE': 'genre',
  'TRACKNUMBER': 'track',
  'COMPOSER': 'composer',
  'COMMENT': 'comment',
  'DESCRIPTION': 'comment',
  'LYRICS': 'lyrics',
  'UNSYNCEDLYRICS': 'lyrics',
};

/// Записей больше этого в живых файлах не бывает; больше — битый счётчик.
const _maxComments = 10000;

/// Vorbis comment (FLAC, Ogg Vorbis, Opus): little endian, длина
/// производителя, производитель, число записей, записи `КЛЮЧ=значение` в
/// UTF-8. Несколько значений одного ключа склеиваются через запятую;
/// `TRACKNUMBER` + `TRACKTOTAL` → `3/12`.
void readVorbisComment(Uint8List data, AudioInfo info) {
  final view = ByteData.sublistView(data);
  if (data.length < 8) {
    info.damaged = true;
    return;
  }
  final vendorLength = view.getUint32(0, Endian.little);
  var offset = 4 + vendorLength;
  if (offset + 4 > data.length) {
    info.damaged = true;
    return;
  }
  final count = view.getUint32(offset, Endian.little);
  offset += 4;
  if (count > _maxComments) {
    info.damaged = true;
    return;
  }

  final values = <String, List<String>>{};
  for (var i = 0; i < count; i++) {
    if (offset + 4 > data.length) {
      info.damaged = true;
      break;
    }
    final length = view.getUint32(offset, Endian.little);
    offset += 4;
    if (offset + length > data.length) {
      info.damaged = true;
      break;
    }
    final entry = utf8.decode(
      Uint8List.sublistView(data, offset, offset + length),
      allowMalformed: true,
    );
    offset += length;
    final eq = entry.indexOf('=');
    if (eq <= 0) continue;
    final key = entry.substring(0, eq).toUpperCase();
    values.putIfAbsent(key, () => []).add(entry.substring(eq + 1));
  }

  for (final MapEntry(:key, :value) in values.entries) {
    final field = _vorbisFields[key];
    if (field == null) continue;
    final joined = value.where((v) => v.trim().isNotEmpty).join(', ');
    info.tags.set(field, field == 'genre' ? normalizeGenre(joined) : joined);
  }
  final total = (values['TRACKTOTAL'] ?? values['TOTALTRACKS'])?.first;
  final track = info.tags.track;
  if (track != null && total != null && !track.contains('/')) {
    info.tags.track = '$track/$total';
  }
}

/// FLAC: `fLaC` (возможно, после ID3v2 — [start]) и блоки метаданных.
/// `STREAMINFO` — частота, каналы, общее число сэмплов (отсюда точная
/// длительность); `VORBIS_COMMENT` — теги.
void readFlac(Uint8List bytes, int start, AudioInfo info) {
  var offset = start + 4;
  info.codec = 'FLAC';
  while (offset + 4 <= bytes.length) {
    final header = bytes[offset];
    final isLast = header & 0x80 != 0;
    final type = header & 0x7F;
    final length =
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    final dataStart = offset + 4;
    if (dataStart + length > bytes.length) {
      info.damaged = true;
      return;
    }
    final data = Uint8List.sublistView(bytes, dataStart, dataStart + length);
    if (type == 0 && length >= 18) {
      final sampleRate = (data[10] << 12) | (data[11] << 4) | (data[12] >> 4);
      final totalSamples =
          ((data[13] & 0x0F) << 32) |
          (data[14] << 24) |
          (data[15] << 16) |
          (data[16] << 8) |
          data[17];
      info
        ..hasAudio = true
        ..channels = ((data[12] >> 1) & 0x07) + 1;
      if (sampleRate > 0) {
        info.sampleRate = sampleRate;
        if (totalSamples > 0) {
          info.duration = Duration(
            microseconds: totalSamples * 1000000 ~/ sampleRate,
          );
        }
      }
    } else if (type == 4) {
      readVorbisComment(data, info);
    }
    if (isLast) break;
    offset = dataStart + length;
  }
}

/// Сколько байт пакетов собирать из страниц Ogg. Пакет комментариев может
/// нести обложку (`METADATA_BLOCK_PICTURE`) — дальше нее читать незачем.
const _maxPacketBytes = 8 * 1024 * 1024;

/// Ogg: страницы `OggS`, из сегментов которых склеиваются пакеты первого
/// логического потока. Первый пакет — заголовок кодека (Vorbis или Opus),
/// второй — Vorbis comment. Длительность — по granule position последней
/// страницы того же потока: в сэмплах, у Opus — всегда в 48 кГц и с
/// поправкой на pre-skip.
void readOgg(Uint8List bytes, AudioInfo info) {
  final view = ByteData.sublistView(bytes);
  final packets = <Uint8List>[];
  final current = BytesBuilder(copy: false);
  int? serial;
  var offset = 0;
  while (packets.length < 2 && offset + 27 <= bytes.length) {
    if (String.fromCharCodes(bytes, offset, offset + 4) != 'OggS') {
      info.damaged = true;
      break;
    }
    final pageSerial = view.getUint32(offset + 14, Endian.little);
    final segments = bytes[offset + 26];
    final tableEnd = offset + 27 + segments;
    if (tableEnd > bytes.length) {
      info.damaged = true;
      break;
    }
    var dataOffset = tableEnd;
    serial ??= pageSerial;
    for (var i = 0; i < segments; i++) {
      final lace = bytes[offset + 27 + i];
      if (dataOffset + lace > bytes.length) {
        info.damaged = true;
        return _finishOgg(bytes, packets, serial, info);
      }
      if (pageSerial == serial && current.length < _maxPacketBytes) {
        current.add(
          Uint8List.sublistView(bytes, dataOffset, dataOffset + lace),
        );
      }
      dataOffset += lace;
      if (lace < 255 && pageSerial == serial) {
        packets.add(current.takeBytes());
        if (packets.length == 2) break;
      }
    }
    offset = dataOffset;
  }
  _finishOgg(bytes, packets, serial, info);
}

void _finishOgg(
  Uint8List bytes,
  List<Uint8List> packets,
  int? serial,
  AudioInfo info,
) {
  if (packets.isEmpty || serial == null) return;
  final head = packets.first;
  final headView = ByteData.sublistView(head);
  int? granuleRate;
  var preSkip = 0;
  if (_startsWith(head, '\u0001vorbis') && head.length >= 28) {
    info
      ..codec = 'Vorbis'
      ..channels = head[11]
      ..sampleRate = headView.getUint32(12, Endian.little);
    final nominal = headView.getInt32(20, Endian.little);
    if (nominal > 0) info.bitrateKbps = (nominal / 1000).round();
    granuleRate = info.sampleRate;
  } else if (_startsWith(head, 'OpusHead') && head.length >= 19) {
    preSkip = headView.getUint16(10, Endian.little);
    final inputRate = headView.getUint32(12, Endian.little);
    info
      ..codec = 'Opus'
      ..channels = head[9]
      ..sampleRate = inputRate > 0 ? inputRate : 48000;
    granuleRate = 48000;
  } else {
    return; // Ogg FLAC, Speex, Theora — не разбираем
  }
  info.hasAudio = true;

  if (packets.length > 1) {
    final tags = packets[1];
    if (_startsWith(tags, '\u0003vorbis')) {
      readVorbisComment(Uint8List.sublistView(tags, 7), info);
    } else if (_startsWith(tags, 'OpusTags')) {
      readVorbisComment(Uint8List.sublistView(tags, 8), info);
    }
  }

  final granule = _lastGranule(bytes, serial);
  if (granuleRate != null && granuleRate > 0 && granule != null) {
    final samples = granule - preSkip;
    if (samples > 0) {
      info.duration = Duration(microseconds: samples * 1000000 ~/ granuleRate);
    }
  }
}

/// Granule position последней страницы потока [serial]: ищем `OggS` с
/// конца файла.
int? _lastGranule(Uint8List bytes, int serial) {
  final view = ByteData.sublistView(bytes);
  for (var i = bytes.length - 27; i >= 0; i--) {
    if (bytes[i] != 0x4F ||
        bytes[i + 1] != 0x67 ||
        bytes[i + 2] != 0x67 ||
        bytes[i + 3] != 0x53) {
      continue;
    }
    if (view.getUint32(i + 14, Endian.little) != serial) continue;
    final granule = view.getInt64(i + 6, Endian.little);
    if (granule >= 0) return granule;
  }
  return null;
}

bool _startsWith(Uint8List bytes, String prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix.codeUnitAt(i)) return false;
  }
  return true;
}

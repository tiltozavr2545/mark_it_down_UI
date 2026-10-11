import 'dart:convert';
import 'dart:typed_data';

import '../../text_decoding.dart';
import 'audio_info.dart';

/// Поля `LIST/INFO` в WAV → поля [AudioTags]. Строки — в кодировке системы
/// записавшего, отсюда [decodeLegacyText].
const _infoFields = {
  'INAM': 'title',
  'IART': 'artist',
  'IPRD': 'album',
  'ICRD': 'year',
  'IGNR': 'genre',
  'ICMT': 'comment',
  'ITRK': 'track',
  'IPRT': 'track',
};

const _wavCodecs = {
  1: 'PCM',
  3: 'PCM (float)',
  6: 'A-law',
  7: 'µ-law',
  0x11: 'IMA ADPCM',
  0x55: 'MP3',
};

/// WAV: RIFF-чанки `fmt ` (формат, каналы, частота, байт в секунду) и
/// `data` (её размер / байт в секунду = длительность). Диктофоны, пишущие
/// поток, оставляют в размере `data` 0 или `0xFFFFFFFF` — тогда берётся
/// реальный остаток файла.
void readWav(Uint8List bytes, AudioInfo info) {
  final view = ByteData.sublistView(bytes);
  int? byteRate;
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes, offset, offset + 4);
    final declared = view.getUint32(offset + 4, Endian.little);
    final dataStart = offset + 8;
    final available = bytes.length - dataStart;
    final length = declared > available ? available : declared;
    if (declared > available && id != 'data') info.damaged = true;

    if (id == 'fmt ' && length >= 16) {
      final format = view.getUint16(dataStart, Endian.little);
      final bits = view.getUint16(dataStart + 14, Endian.little);
      byteRate = view.getUint32(dataStart + 8, Endian.little);
      info
        ..hasAudio = true
        ..channels = view.getUint16(dataStart + 2, Endian.little)
        ..sampleRate = view.getUint32(dataStart + 4, Endian.little)
        ..codec = format == 1 && bits > 0
            ? 'PCM, $bits бит'
            : (_wavCodecs[format] ?? 'формат 0x${format.toRadixString(16)}');
      if (byteRate > 0) info.bitrateKbps = (byteRate * 8 / 1000).round();
    } else if (id == 'data') {
      final rate = byteRate;
      if (rate != null && rate > 0) {
        final size = declared == 0 || declared == 0xFFFFFFFF
            ? available
            : length;
        info.duration = Duration(microseconds: size * 1000000 ~/ rate);
      }
    } else if (id == 'LIST' &&
        length >= 4 &&
        String.fromCharCodes(bytes, dataStart, dataStart + 4) == 'INFO') {
      _readInfo(
        Uint8List.sublistView(bytes, dataStart + 4, dataStart + length),
        info,
      );
    }
    offset = dataStart + length + (length & 1);
  }
}

void _readInfo(Uint8List data, AudioInfo info) {
  final view = ByteData.sublistView(data);
  var offset = 0;
  while (offset + 8 <= data.length) {
    final id = String.fromCharCodes(data, offset, offset + 4);
    final length = view.getUint32(offset + 4, Endian.little);
    final start = offset + 8;
    if (start + length > data.length) {
      info.damaged = true;
      return;
    }
    final field = _infoFields[id];
    if (field != null) {
      var raw = Uint8List.sublistView(data, start, start + length);
      final end = raw.indexOf(0);
      if (end >= 0) raw = Uint8List.sublistView(raw, 0, end);
      final value = decodeLegacyText(raw);
      info.tags.set(field, field == 'genre' ? normalizeGenre(value) : value);
    }
    offset = start + length + (length & 1);
  }
}

// --- ISO BMFF (MP4, M4A, MOV, 3GP) ------------------------------------------

/// Коробка ISO BMFF: тип и границы полезной нагрузки.
class _Box {
  final String type;
  final int start;
  final int end;

  const _Box(this.type, this.start, this.end);
}

/// Дочерние коробки в `[start, end)`. Размер 1 — 64-битный размер следом,
/// 0 — «до конца родителя». Коробка, вылезающая за родителя, обрезается по
/// нему и помечает файл битым — но не роняет разбор.
List<_Box> _children(Uint8List bytes, int start, int end, AudioInfo info) {
  final view = ByteData.sublistView(bytes);
  final boxes = <_Box>[];
  var offset = start;
  while (offset + 8 <= end) {
    var size = view.getUint32(offset);
    final type = latin1.decode(bytes.sublist(offset + 4, offset + 8));
    var header = 8;
    if (size == 1) {
      if (offset + 16 > end) break;
      size = view.getUint64(offset + 8);
      header = 16;
    } else if (size == 0) {
      size = end - offset;
    }
    if (size < header) {
      info.damaged = true;
      break;
    }
    var boxEnd = offset + size;
    if (boxEnd > end) {
      info.damaged = true;
      boxEnd = end;
    }
    boxes.add(_Box(type, offset + header, boxEnd));
    offset = boxEnd;
  }
  return boxes;
}

_Box? _child(List<_Box> boxes, String type) {
  for (final box in boxes) {
    if (box.type == type) return box;
  }
  return null;
}

/// Ключи `ilst` (теги iTunes) → поля [AudioTags]. `©` — байт 0xA9.
const _ilstFields = {
  '©nam': 'title',
  '©ART': 'artist',
  'aART': 'albumartist',
  '©alb': 'album',
  '©day': 'year',
  '©gen': 'genre',
  '©wrt': 'composer',
  '©cmt': 'comment',
  '©lyr': 'lyrics',
};

const _audioCodecs = {
  'mp4a': 'AAC',
  'alac': 'ALAC',
  'Opus': 'Opus',
  'fLaC': 'FLAC',
  'ac-3': 'AC-3',
  'ec-3': 'E-AC-3',
  'samr': 'AMR',
  'sawb': 'AMR-WB',
  '.mp3': 'MP3',
};

/// MP4/M4A/MOV/3GP: `moov/mvhd` — длительность, `moov/trak` — дорожки
/// (`hdlr`: `soun` — звук, `vide` — видео; размер видео из `tkhd`, кодек и
/// частота звука из `stsd`), `moov/udta/meta/ilst` — теги iTunes.
void readMp4(Uint8List bytes, AudioInfo info) {
  final view = ByteData.sublistView(bytes);
  final moov = _child(_children(bytes, 0, bytes.length, info), 'moov');
  if (moov == null) {
    info.damaged = true;
    return;
  }
  final boxes = _children(bytes, moov.start, moov.end, info);

  final mvhd = _child(boxes, 'mvhd');
  if (mvhd != null && mvhd.end - mvhd.start >= 32) {
    final v1 = bytes[mvhd.start] == 1;
    final timescale = view.getUint32(mvhd.start + (v1 ? 20 : 12));
    final duration = v1
        ? view.getUint64(mvhd.start + 24)
        : view.getUint32(mvhd.start + 16);
    if (timescale > 0 && duration > 0 && duration != 0xFFFFFFFF) {
      info.duration = Duration(microseconds: duration * 1000000 ~/ timescale);
    }
  }

  for (final trak in boxes.where((b) => b.type == 'trak')) {
    _readTrack(bytes, trak, info);
  }

  final udta = _child(boxes, 'udta');
  if (udta != null) {
    final meta = _child(_children(bytes, udta.start, udta.end, info), 'meta');
    if (meta != null) _readMeta(bytes, meta, info);
  }
}

void _readTrack(Uint8List bytes, _Box trak, AudioInfo info) {
  final view = ByteData.sublistView(bytes);
  final trakBoxes = _children(bytes, trak.start, trak.end, info);
  final mdia = _child(trakBoxes, 'mdia');
  if (mdia == null) return;
  final mdiaBoxes = _children(bytes, mdia.start, mdia.end, info);
  final hdlr = _child(mdiaBoxes, 'hdlr');
  if (hdlr == null || hdlr.end - hdlr.start < 12) return;
  final handler = latin1.decode(bytes.sublist(hdlr.start + 8, hdlr.start + 12));

  if (handler == 'vide') {
    info.hasVideo = true;
    final tkhd = _child(trakBoxes, 'tkhd');
    if (tkhd != null && info.videoWidth == null) {
      final at = tkhd.start + (bytes[tkhd.start] == 1 ? 88 : 76);
      if (at + 8 <= tkhd.end) {
        final width = view.getUint32(at) >> 16;
        final height = view.getUint32(at + 4) >> 16;
        if (width > 0 && height > 0) {
          info
            ..videoWidth = width
            ..videoHeight = height;
        }
      }
    }
  } else if (handler == 'soun' && !info.hasAudio) {
    info.hasAudio = true;
    // mdia/minf/stbl/stsd → первая запись: 8 байт заголовка коробки, затем
    // 6 резерв + 2 индекс + 8 резерв, каналы, бит, 4 резерв, частота 16.16.
    final minf = _child(mdiaBoxes, 'minf');
    final stbl = minf == null
        ? null
        : _child(_children(bytes, minf.start, minf.end, info), 'stbl');
    final stsd = stbl == null
        ? null
        : _child(_children(bytes, stbl.start, stbl.end, info), 'stsd');
    if (stsd == null || stsd.start + 8 + 36 > stsd.end) return;
    final entry = stsd.start + 8; // версия/флаги + число записей
    final format = latin1.decode(bytes.sublist(entry + 4, entry + 8));
    info
      ..codec = _audioCodecs[format] ?? format.trim()
      ..channels = view.getUint16(entry + 8 + 16)
      ..sampleRate = view.getUint32(entry + 8 + 24) >> 16;
  }
}

void _readMeta(Uint8List bytes, _Box meta, AudioInfo info) {
  // `meta` в MP4 — full box (4 байта версии и флагов), в QuickTime — нет.
  // Отличаем по содержимому: за full box сразу идут нули.
  final view = ByteData.sublistView(bytes);
  final start = meta.start + 4 <= meta.end && view.getUint32(meta.start) == 0
      ? meta.start + 4
      : meta.start;
  final ilst = _child(_children(bytes, start, meta.end, info), 'ilst');
  if (ilst == null) return;
  for (final item in _children(bytes, ilst.start, ilst.end, info)) {
    final data = _child(_children(bytes, item.start, item.end, info), 'data');
    if (data == null || data.end - data.start < 8) continue;
    final type = view.getUint32(data.start) & 0xFFFFFF;
    final value = Uint8List.sublistView(bytes, data.start + 8, data.end);
    switch (item.type) {
      case 'trkn' when value.length >= 6:
        final track = (value[2] << 8) | value[3];
        final total = (value[4] << 8) | value[5];
        if (track > 0) {
          info.tags.set('track', total > 0 ? '$track/$total' : '$track');
        }
      default:
        final field = _ilstFields[item.type];
        if (field == null || type != 1) continue; // 1 — UTF-8
        final text = utf8.decode(value, allowMalformed: true);
        info.tags.set(field, field == 'genre' ? normalizeGenre(text) : text);
    }
  }
}

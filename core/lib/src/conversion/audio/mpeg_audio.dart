import 'dart:typed_data';

import '../../type_detection/magic_bytes.dart';
import 'audio_info.dart';

/// Bitrates, kbit/s, by index 1–14 (0 — "free", 15 — reserved).
const _bitratesV1L1 = [
  0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, //
];
const _bitratesV1L2 = [
  0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, //
];
const _bitratesV1L3 = [
  0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, //
];
const _bitratesV2L1 = [
  0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, //
];
const _bitratesV2L23 = [
  0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, //
];

/// An MPEG audio frame header, parsed into its fields.
class _Frame {
  final int version; // 1, 2, 25 (MPEG 2.5)
  final int layer; // 1, 2, 3
  final int bitrateKbps;
  final int sampleRate;
  final bool mono;
  final int length;

  const _Frame(
    this.version,
    this.layer,
    this.bitrateKbps,
    this.sampleRate,
    this.mono,
    this.length,
  );

  int get samplesPerFrame => switch (layer) {
    1 => 384,
    2 => 1152,
    _ => version == 1 ? 1152 : 576,
  };

  static _Frame? at(Uint8List bytes, int offset) {
    if (!isMpegAudioFrame(bytes, offset)) return null;
    final b1 = bytes[offset + 1];
    final b2 = bytes[offset + 2];
    final b3 = bytes[offset + 3];
    final version = switch ((b1 >> 3) & 3) {
      0 => 25,
      2 => 2,
      _ => 1,
    };
    final layer = 4 - ((b1 >> 1) & 3);
    final table = version == 1
        ? [_bitratesV1L1, _bitratesV1L2, _bitratesV1L3][layer - 1]
        : (layer == 1 ? _bitratesV2L1 : _bitratesV2L23);
    final bitrate = table[b2 >> 4];
    // A "free" bitrate: the frame length can't be computed from the
    // header.
    if (bitrate == 0) return null;
    final baseRate = [44100, 48000, 32000][(b2 >> 2) & 3];
    final sampleRate = switch (version) {
      1 => baseRate,
      2 => baseRate ~/ 2,
      _ => baseRate ~/ 4,
    };
    final padding = (b2 >> 1) & 1;
    final length = layer == 1
        ? (12 * bitrate * 1000 ~/ sampleRate + padding) * 4
        : (layer == 3 && version != 1 ? 72 : 144) *
                  bitrate *
                  1000 ~/
                  sampleRate +
              padding;
    return _Frame(version, layer, bitrate, sampleRate, b3 >> 6 == 3, length);
  }
}

/// How many bytes after the ID3v2 tag to scan looking for the first
/// frame: there can be junk between the tag and the audio (unfinished
/// padding, a second tag).
const _searchWindow = 64 * 1024;

/// Duration, bitrate and audio parameters from MPEG frames. [audioStart]
/// is the end of ID3v2, [audioEnd] is the start of ID3v1 (or the end of
/// the file).
///
/// The first frame is the first position where the header is valid
/// **and** the next frame also starts with a valid header: a lone
/// `0xFFE…` shows up in junk data often, two in a row at the right
/// distance apart — doesn't. Duration comes from the Xing/Info or VBRI
/// header (written by any VBR encoder), otherwise from the size assuming
/// a constant bitrate.
void readMpegAudio(
  Uint8List bytes,
  int audioStart,
  int audioEnd,
  AudioInfo info,
) {
  final limit = (audioStart + _searchWindow).clamp(0, audioEnd);
  for (var offset = audioStart; offset + 4 <= limit; offset++) {
    if (bytes[offset] != 0xFF) continue;
    final frame = _Frame.at(bytes, offset);
    if (frame == null) continue;
    final next = offset + frame.length;
    if (next + 4 <= audioEnd && _Frame.at(bytes, next) == null) continue;
    _describe(bytes, offset, audioEnd, frame, info);
    return;
  }
}

void _describe(
  Uint8List bytes,
  int offset,
  int audioEnd,
  _Frame frame,
  AudioInfo info,
) {
  info
    ..hasAudio = true
    ..codec =
        'MPEG ${frame.version == 25 ? '2.5' : frame.version} '
        'Layer ${['I', 'II', 'III'][frame.layer - 1]}'
    ..sampleRate = frame.sampleRate
    ..channels = frame.mono ? 1 : 2;

  final audioBytes = audioEnd - offset;
  final (frames, variable) = _frameCount(bytes, offset, frame);
  if (frames != null && frames > 0) {
    final seconds = frames * frame.samplesPerFrame / frame.sampleRate;
    info.duration = Duration(milliseconds: (seconds * 1000).round());
    // `Info` is the same header, but for a CBR file: the bitrate is the
    // genuine one from the frame.
    info
      ..variableBitrate = variable
      ..bitrateKbps = variable
          ? (audioBytes * 8 / seconds / 1000).round()
          : frame.bitrateKbps;
    return;
  }
  info
    ..bitrateKbps = frame.bitrateKbps
    ..duration = Duration(
      milliseconds: (audioBytes * 8 / frame.bitrateKbps).round(),
    );
}

/// The frame count from the Xing/Info header (in the first frame, after
/// the side info) or VBRI (exactly 32 bytes after the frame header), and
/// a VBR flag.
(int?, bool) _frameCount(Uint8List bytes, int offset, _Frame frame) {
  final view = ByteData.sublistView(bytes);
  final sideInfo = frame.version == 1
      ? (frame.mono ? 17 : 32)
      : (frame.mono ? 9 : 17);
  final xing = offset + 4 + sideInfo;
  if (xing + 12 <= bytes.length) {
    final tag = String.fromCharCodes(bytes, xing, xing + 4);
    if (tag == 'Xing' || tag == 'Info') {
      final flags = view.getUint32(xing + 4);
      return (flags & 1 != 0 ? view.getUint32(xing + 8) : null, tag == 'Xing');
    }
  }
  final vbri = offset + 4 + 32;
  if (vbri + 18 <= bytes.length &&
      String.fromCharCodes(bytes, vbri, vbri + 4) == 'VBRI') {
    return (view.getUint32(vbri + 14), true);
  }
  return (null, false);
}

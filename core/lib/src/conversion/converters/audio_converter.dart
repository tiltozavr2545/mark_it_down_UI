import 'dart:typed_data';

import '../../markdown_writer.dart' as md;
import '../../stream_info.dart';
import '../../type_detection/detected_type.dart';
import '../audio/audio_info.dart';
import '../audio/containers.dart';
import '../audio/id3.dart';
import '../audio/mpeg_audio.dart';
import '../audio/xiph.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';

const _mediaKinds = {
  FileKind.mp3,
  FileKind.flac,
  FileKind.ogg,
  FileKind.wav,
  FileKind.mp4,
};

/// Аудио (и видео в MP4/MOV/3GP) → список метаданных: формат, длительность,
/// параметры звука, теги, текст песни. Речь не распознаётся — офлайн-
/// транскрипция отложена (`docs/future-development.md`). Отказа, как и у
/// картинок, не бывает: сигнатура опознана, формат сказать можно всегда.
/// См. `docs/format-coverage.md#решения-этапа-6`.
class AudioConverter implements DocumentConverter {
  const AudioConverter();

  @override
  String get id => 'audio';

  @override
  double get priority => 0.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) =>
      _mediaKinds.contains(info.detectedType.kind);

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final bytes = request.bytes;
    final kind = request.info.detectedType.kind;
    final info = AudioInfo();
    try {
      _read(bytes, kind, info);
    } on RangeError {
      // Разборы проверяют границы сами; где не проверили — не повод терять
      // уже прочитанное.
      info.damaged = true;
    }

    final warnings = <ConversionWarning>[
      if (info.damaged)
        const ConversionWarning(
          'структура файла повреждена — показано то, что удалось прочитать',
        ),
      if (info.hasAudio || !info.hasVideo)
        const ConversionWarning(
          'речь не распознаётся — в результате только метаданные',
        ),
    ];

    final tags = info.tags;
    final fields = <(String, String?)>[
      ('Формат', _format(request.info.detectedType, info)),
      ('Длительность', _duration(info.duration)),
      if (info.hasVideo)
        (
          'Видео',
          info.videoWidth == null
              ? 'есть'
              : '${info.videoWidth} × ${info.videoHeight}',
        ),
      ('Звук', _sound(info)),
      ('Название', tags.title),
      ('Исполнитель', tags.artist),
      (
        'Исполнитель альбома',
        tags.albumArtist == tags.artist ? null : tags.albumArtist,
      ),
      ('Альбом', tags.album),
      ('Дата', tags.year),
      ('Жанр', tags.genre),
      ('Трек', tags.track),
      ('Композитор', tags.composer),
      ('Комментарий', tags.comment),
    ];
    final blocks = [
      [
        for (final (label, value) in fields)
          if (value != null)
            '- ${md.bold('$label:')} ${md.escapeInline(_oneLine(value))}',
      ].join('\n'),
      if (tags.lyrics != null) ...[
        md.heading(2, 'Текст песни'),
        _paragraphs(tags.lyrics!),
      ],
    ];
    return ConversionResult(
      markdown: blocks.join('\n\n'),
      converterId: id,
      elapsed: Duration.zero,
      title: tags.title,
      warnings: warnings,
    );
  }
}

void _read(Uint8List bytes, FileKind kind, AudioInfo info) {
  switch (kind) {
    case FileKind.mp3:
      final start = readId3v2(bytes, info);
      final end = readId3v1(bytes, info) ? bytes.length - 128 : bytes.length;
      readMpegAudio(bytes, start, end, info);
    case FileKind.flac:
      final start = readId3v2(bytes, info);
      readFlac(bytes, start, info);
    case FileKind.ogg:
      readOgg(bytes, info);
    case FileKind.wav:
      readWav(bytes, info);
    case FileKind.mp4:
      readMp4(bytes, info);
    default:
      break;
  }
}

/// `MP4` с одной звуковой дорожкой — это аудио, даже если марка `isom`: так
/// пишут диктофоны и мессенджеры. Уточняем, чтобы не звать его «видео».
String _format(DetectedType type, AudioInfo info) {
  if (type.kind != FileKind.mp4) return type.label;
  if (info.hasVideo) return '${type.label} (видео)';
  if (info.hasAudio && !type.label.startsWith('M4A')) {
    return '${type.label} (аудио)';
  }
  return type.label;
}

/// `3:07`, `1:02:03`; доли секунды отбрасываются.
String? _duration(Duration? duration) {
  if (duration == null || duration <= Duration.zero) return null;
  final hours = duration.inHours;
  final minutes = duration.inMinutes % 60;
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds'
      : '$minutes:$seconds';
}

/// `MPEG 1 Layer III, 44,1 кГц, стерео, 192 кбит/с`.
String? _sound(AudioInfo info) {
  final parts = <String>[
    if (info.codec != null) info.codec!,
    if (info.sampleRate case final rate? when rate > 0) '${_khz(rate)} кГц',
    if (info.channels case final channels? when channels > 0)
      switch (channels) {
        1 => 'моно',
        2 => 'стерео',
        _ => '$channels канала',
      },
    if (info.bitrateKbps case final kbps? when kbps > 0)
      '${info.variableBitrate ? '~' : ''}$kbps кбит/с',
  ];
  return parts.isEmpty ? null : parts.join(', ');
}

/// `44100` → `44,1`, `22050` → `22,05`, `48000` → `48`.
String _khz(int hertz) {
  var text = (hertz / 1000).toStringAsFixed(3);
  text = text.replaceFirst(RegExp(r'\.?0+$'), '');
  return text.replaceAll('.', ',');
}

String _oneLine(String value) =>
    value.replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ').trim();

/// Текст песни: строки куплета остаются строками (жёсткий перенос — два
/// пробела в конце), куплеты разделены пустой строкой.
String _paragraphs(String text) => text
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .split(RegExp(r'\n\s*\n'))
    .map(
      (stanza) => stanza
          .split('\n')
          .map((line) => md.escapeInline(line.trim()))
          .where((line) => line.isNotEmpty)
          .join('  \n'),
    )
    .where((stanza) => stanza.isNotEmpty)
    .join('\n\n');

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
import '../speech/whisper_transcriber.dart';

const _mediaKinds = {
  FileKind.mp3,
  FileKind.flac,
  FileKind.ogg,
  FileKind.wav,
  FileKind.mp4,
};

/// Audio (and video in MP4/MOV/3GP) → a list of metadata: format,
/// duration, sound parameters, tags, lyrics, and with [transcription] —
/// also a speech transcript (whisper.cpp, offline). As with images, there
/// is no hard failure: once the signature is recognized, the format can
/// always be stated, and anything that didn't work out with recognition
/// goes into `warnings`. See
/// `docs/format-coverage.md#решения-этапа-6` and
/// `docs/format-coverage.md#решения-транскрипции-08`.
class AudioConverter implements DocumentConverter {
  const AudioConverter({this.transcription});

  /// Where the Whisper model and libraries are; `null` means metadata
  /// only (that's how fixtures are run: their output must not depend on
  /// the engine available on the machine).
  final TranscriptionSettings? transcription;

  @override
  String get id => 'audio';

  @override
  double get priority => 0.0;

  /// Whether this converter handles files of this kind — and therefore
  /// whether it transcribes speech in them. The app uses this to decide
  /// which ones need progress and a "Stop" control.
  static bool handles(FileKind kind) => _mediaKinds.contains(kind);

  @override
  bool accepts(StreamInfo info, Uint8List head) =>
      handles(info.detectedType.kind);

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final bytes = request.bytes;
    final kind = request.info.detectedType.kind;
    final info = AudioInfo();
    try {
      _read(bytes, kind, info);
    } on RangeError {
      // Parsers check bounds themselves; where they didn't, that's no
      // reason to lose what's already been read.
      info.damaged = true;
    }

    final warnings = <ConversionWarning>[
      if (info.damaged)
        const ConversionWarning(
          'структура файла повреждена — показано то, что удалось прочитать',
        ),
    ];
    // There's nothing to transcribe in video with no audio track; if no
    // tracks were found at all (a corrupted header), we still try — the
    // decoder will tell us itself.
    final speech = info.hasAudio || !info.hasVideo
        ? _transcribe(request, kind, info.duration, warnings)
        : null;

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
    if (speech?.language case final language?) {
      fields.add(('Язык речи', _languageName(language)));
    }
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
      if (speech != null && speech.segments.isNotEmpty) ...[
        md.heading(2, 'Расшифровка'),
        ..._transcriptParagraphs(speech.segments),
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

  /// The transcript, or `null`; anything that went wrong goes into
  /// [warnings], not an exception: the metadata is already there.
  Transcript? _transcribe(
    ConversionRequest request,
    FileKind kind,
    Duration? duration,
    List<ConversionWarning> warnings,
  ) {
    final settings = transcription;
    if (settings == null) {
      warnings.add(
        const ConversionWarning(
          'речь не распознаётся — в результате только метаданные',
        ),
      );
      return null;
    }
    final outcome = transcribeAudio(
      request.bytes,
      settings,
      mp4: kind == FileKind.mp4,
      extension: _extensions[kind] ?? 'bin',
      localPath: request.info.localPath,
      duration: duration,
    );
    final transcript = outcome.transcript;
    if (transcript == null) {
      warnings.add(
        ConversionWarning(switch (outcome.failure!) {
          TranscriptionFailure.unavailable =>
            'распознавание речи недоступно: нет движка или модели',
          TranscriptionFailure.unsupportedAudio =>
            'звук в этом формате распознать не удалось: кодек не '
                'поддерживается на этом устройстве',
          TranscriptionFailure.undecodable =>
            'звук не удалось декодировать для распознавания речи',
          TranscriptionFailure.noAudio => 'в файле нет звука для распознавания',
          TranscriptionFailure.failed => 'распознавание речи не удалось',
        }),
      );
      return null;
    }

    if (transcript.segments.isEmpty) {
      warnings.add(
        ConversionWarning(
          transcript.cancelled
              ? 'распознавание остановлено до первой фразы'
              : 'речь не найдена',
        ),
      );
      return transcript;
    }
    warnings.add(
      ConversionWarning(
        'речь распознана офлайн (${transcript.engine}) — возможны ошибки, '
        'имена и термины стоит проверить',
      ),
    );
    if (transcript.cancelled) {
      warnings.add(
        ConversionWarning(
          'распознавание остановлено на '
          '${_duration(transcript.processed) ?? '0:00'} — расшифровка неполная',
        ),
      );
    }
    return transcript;
  }
}

/// File extension for the platform decoder — by signature, not by name.
const _extensions = {
  FileKind.mp3: 'mp3',
  FileKind.flac: 'flac',
  FileKind.ogg: 'ogg',
  FileKind.wav: 'wav',
  FileKind.mp4: 'm4a',
};

/// Whisper segments (a phrase or two each) → paragraphs with a start
/// timestamp. A new paragraph starts after a pause of two seconds or more,
/// or when the current one has gone past ~600 characters and ended at a
/// sentence boundary (don't break a phrase mid-way; with no punctuation —
/// no longer than 1200): a wall of text for an hour-long recording is
/// unreadable, while a paragraph per phrase is noise for whoever pastes
/// this into a prompt.
List<String> _transcriptParagraphs(List<TranscriptSegment> segments) {
  const pause = Duration(seconds: 2);
  const maxLength = 600;
  final sentenceEnd = RegExp(r'[.!?…]["»”)]?$');
  final paragraphs = <String>[];
  Duration? start;
  Duration? lastEnd;
  final text = StringBuffer();
  void flush() {
    if (text.isEmpty) return;
    paragraphs.add(
      '${md.bold(_timestamp(start!))} ${md.escapeInline(text.toString())}',
    );
    text.clear();
  }

  for (final segment in segments) {
    final gap = lastEnd == null ? Duration.zero : segment.start - lastEnd;
    final long =
        text.length >= maxLength && sentenceEnd.hasMatch(text.toString()) ||
        text.length >= maxLength * 2;
    if (text.isNotEmpty && (gap >= pause || long)) flush();
    if (text.isEmpty) {
      start = segment.start;
    } else {
      text.write(' ');
    }
    text.write(_oneLine(segment.text));
    lastEnd = segment.end;
  }
  flush();
  return paragraphs;
}

/// `0:05`, `12:34`, `1:02:03` — like duration, but works for zero too.
String _timestamp(Duration time) =>
    _duration(time) ?? '0:${(time.inSeconds % 60).toString().padLeft(2, '0')}';

/// Whisper language code → Russian display name. An unknown one falls
/// back to the code: better `ka` than nothing.
String _languageName(String code) => switch (code) {
  'ru' => 'русский',
  'en' => 'английский',
  'it' => 'итальянский',
  'uk' => 'украинский',
  'be' => 'белорусский',
  'de' => 'немецкий',
  'fr' => 'французский',
  'es' => 'испанский',
  'pt' => 'португальский',
  'pl' => 'польский',
  'kk' => 'казахский',
  'tr' => 'турецкий',
  'zh' => 'китайский',
  'ja' => 'японский',
  _ => code,
};

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

/// `MP4` with a single audio track is audio, even with the `isom` brand:
/// that's how voice recorders and messengers write it. We clarify this so
/// as not to call it "video".
String _format(DetectedType type, AudioInfo info) {
  if (type.kind != FileKind.mp4) return type.label;
  if (info.hasVideo) return '${type.label} (видео)';
  if (info.hasAudio && !type.label.startsWith('M4A')) {
    return '${type.label} (аудио)';
  }
  return type.label;
}

/// `3:07`, `1:02:03`; fractions of a second are dropped.
String? _duration(Duration? duration) {
  if (duration == null || duration <= Duration.zero) return null;
  final hours = duration.inHours;
  final minutes = duration.inMinutes % 60;
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds'
      : '$minutes:$seconds';
}

/// `MPEG 1 Layer III, 44,1 кГц, стерео, 192 кбит/с` (example of the
/// Russian-language output format).
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

/// `44100` → `44.1`, `22050` → `22.05`, `48000` → `48` (comma is the
/// decimal separator used in the Russian-language output).
String _khz(int hertz) {
  var text = (hertz / 1000).toStringAsFixed(3);
  text = text.replaceFirst(RegExp(r'\.?0+$'), '');
  return text.replaceAll('.', ',');
}

String _oneLine(String value) =>
    value.replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ').trim();

/// Lyrics: the lines of a verse stay lines (a hard break — two trailing
/// spaces), verses are separated by a blank line.
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

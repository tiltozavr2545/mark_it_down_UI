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

/// Аудио (и видео в MP4/MOV/3GP) → список метаданных: формат, длительность,
/// параметры звука, теги, текст песни, а с [transcription] — и расшифровка
/// речи (whisper.cpp, офлайн). Отказа, как и у картинок, не бывает:
/// сигнатура опознана, формат сказать можно всегда, а всё, что не вышло с
/// распознаванием, — в `warnings`. См.
/// `docs/format-coverage.md#решения-этапа-6` и
/// `docs/format-coverage.md#решения-транскрипции-08`.
class AudioConverter implements DocumentConverter {
  const AudioConverter({this.transcription});

  /// Где модель и библиотеки Whisper; `null` — только метаданные (так
  /// гоняются фикстуры: их вывод не должен зависеть от движка на машине).
  final TranscriptionSettings? transcription;

  @override
  String get id => 'audio';

  @override
  double get priority => 0.0;

  /// Берёт ли конвертер файлы этого вида — а значит, и распознаёт ли в
  /// них речь. Приложение по нему решает, кому нужны прогресс и
  /// «Остановить».
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
      // Разборы проверяют границы сами; где не проверили — не повод терять
      // уже прочитанное.
      info.damaged = true;
    }

    final warnings = <ConversionWarning>[
      if (info.damaged)
        const ConversionWarning(
          'структура файла повреждена — показано то, что удалось прочитать',
        ),
    ];
    // Видео без звуковой дорожки распознавать нечего; если дорожек не
    // нашли вовсе (битый заголовок) — пробуем: декодер скажет сам.
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

  /// Расшифровка или `null`; всё, что пошло не так, — в [warnings], не
  /// исключением: метаданные уже есть.
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

/// Расширение файла для декодера платформы — по сигнатуре, не по имени.
const _extensions = {
  FileKind.mp3: 'mp3',
  FileKind.flac: 'flac',
  FileKind.ogg: 'ogg',
  FileKind.wav: 'wav',
  FileKind.mp4: 'm4a',
};

/// Сегменты Whisper (по фразе-две) → абзацы с отметкой времени начала.
/// Новый абзац — после паузы от двух секунд или когда текущий перевалил за
/// ~600 знаков и кончился на конце предложения (не рвать фразу посередине;
/// без знаков препинания — не длиннее 1200): стена текста на час записи
/// нечитаема, а абзац на каждую фразу — шум для того, кто вставит это в
/// промпт.
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

/// `0:05`, `12:34`, `1:02:03` — как длительность, но и для нуля.
String _timestamp(Duration time) =>
    _duration(time) ?? '0:${(time.inSeconds % 60).toString().padLeft(2, '0')}';

/// Код языка Whisper → по-русски. Неизвестный — кодом: лучше `ka`, чем
/// ничего.
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

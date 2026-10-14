import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'whisper_bindings.dart';

/// Частота, которую ждёт Whisper (`MDW_SAMPLE_RATE`).
const _sampleRate = 16000;

/// Настройки распознавания речи, которые приложение передаёт в изолят
/// конвертации: только строки и числа — библиотеки открываются уже внутри
/// изолята, как у OCR ([OcrSettings]).
class TranscriptionSettings {
  /// Модель Whisper (`ggml-small-q8_0.bin`). На Windows — ассет рядом с
  /// `.exe`, на Android — копия ассета в каталоге приложения (whisper.cpp
  /// читает модель с диска, а не из APK), см.
  /// `app/lib/src/conversion/speech_data.dart`.
  final String modelPath;

  /// Silero VAD или `null` — распознавать без вырезания тишины.
  final String? vadModelPath;

  /// Каталог библиотек; `null` — место по умолчанию для платформы (см.
  /// [loadWhisperLibrary]).
  final String? libraryDir;

  /// Куда писать звук во временный файл, когда декодеру платформы (AAC)
  /// нужен путь, а файла на диске нет. `null` — системный временный каталог.
  final String? tempDir;

  /// Код языка (`ru`, `en`, `it`) или `auto` — определить по первым 30
  /// секундам. Один язык на весь файл: так устроен Whisper.
  final String language;

  /// Сколько звука распознавать. Расшифровка идёт медленнее реального
  /// времени на телефоне, а 16 кГц float — 3,8 МБ в минуту памяти;
  /// остальное — в `warnings`, как страницы PDF сверх
  /// [OcrSettings.maxPdfPages].
  final Duration maxDuration;

  /// Адрес `mdw_control` ([TranscriptionControl.address]) — прогресс и
  /// отмена из главного изолята; 0 — без них.
  final int controlAddress;

  const TranscriptionSettings({
    required this.modelPath,
    this.vadModelPath,
    this.libraryDir,
    this.tempDir,
    this.language = 'auto',
    this.maxDuration = const Duration(hours: 3),
    this.controlAddress = 0,
  });

  TranscriptionSettings withControl(TranscriptionControl control) =>
      TranscriptionSettings(
        modelPath: modelPath,
        vadModelPath: vadModelPath,
        libraryDir: libraryDir,
        tempDir: tempDir,
        language: language,
        maxDuration: maxDuration,
        controlAddress: control.address,
      );
}

/// Прогресс и отмена распознавания — память, общая с изолятом конвертации.
/// Создаётся на главном изоляте до конвертации, освобождается [dispose]
/// только после её конца: нативный код пишет сюда до последнего окна.
class TranscriptionControl {
  final Pointer<MdwControl> _control = calloc<MdwControl>();

  int get address => _control.address;

  /// 0–100: доля обработанного звука; 0 — распознавание ещё не началось.
  int get progress => _control.ref.progress;

  bool get cancelled => _control.ref.cancel != 0;

  /// Остановить распознавание: дольше одного 30-секундного окна не ждёт,
  /// уже распознанное остаётся в результате.
  void cancel() => _control.ref.cancel = 1;

  void dispose() => calloc.free(_control);
}

/// Есть ли рабочее распознавание с этими настройками: библиотеки грузятся,
/// CPU-бэкенд нашёлся, модель на месте. Модель не загружается — это
/// секунды; конвертерам проверять заранее не нужно.
bool transcriptionAvailable(TranscriptionSettings settings) =>
    WhisperEngine.open(settings) != null &&
    File(settings.modelPath).existsSync();

class TranscriptSegment {
  final Duration start;
  final Duration end;
  final String text;

  const TranscriptSegment(this.start, this.end, this.text);
}

enum TranscriptionFailure {
  /// Нет библиотек, CPU-бэкенда или модели.
  unavailable,

  /// Ни один декодер не взял звук (кодек, которого нет у платформы).
  unsupportedAudio,

  /// Формат опознан, но звук не декодировался.
  undecodable,

  /// В файле нет звуковой дорожки.
  noAudio,

  /// whisper.cpp вернул ошибку.
  failed,
}

class Transcript {
  final List<TranscriptSegment> segments;

  /// Определённый (или заданный) язык: `ru`, `en`, `it`…; `null` — неизвестен.
  final String? language;

  /// Сколько звука распознавалось — меньше длительности файла, если
  /// упёрлись в [TranscriptionSettings.maxDuration] или остановили.
  final Duration processed;

  final bool truncated;
  final bool cancelled;

  /// `whisper.cpp 1.9.5` — пишется в `warnings`, как движок OCR.
  final String engine;

  const Transcript({
    required this.segments,
    required this.language,
    required this.processed,
    required this.truncated,
    required this.cancelled,
    required this.engine,
  });
}

/// Результат: либо [transcript], либо [failure].
class TranscriptionOutcome {
  final Transcript? transcript;
  final TranscriptionFailure? failure;

  const TranscriptionOutcome.success(Transcript this.transcript)
    : failure = null;

  const TranscriptionOutcome.failure(TranscriptionFailure this.failure)
    : transcript = null;
}

/// Декодированный звук: 16 кГц моно float в нативной памяти — передаётся в
/// whisper.cpp без копии в Dart. [dispose] обязателен.
class DecodedAudio {
  DecodedAudio._(this._bindings, this.samples, this.length);

  final WhisperBindings _bindings;
  final Pointer<Float> samples;
  final int length;

  Duration get duration =>
      Duration(microseconds: length * 1000000 ~/ _sampleRate);

  void dispose() => _bindings.freeSamples(samples);
}

/// Открытые библиотеки и выбранный CPU-бэкенд. Один на изолят: открыть
/// библиотеку повторно дёшево, но варианты бэкенда грузятся один раз.
class WhisperEngine {
  WhisperEngine._(this._bindings);

  final WhisperBindings _bindings;

  static WhisperEngine? _cached;
  static bool _loadFailed = false;

  /// `null` — библиотек нет или ни один вариант CPU-бэкенда не загрузился.
  static WhisperEngine? open(TranscriptionSettings settings) {
    if (_cached != null) return _cached;
    if (_loadFailed) return null;
    final library = loadWhisperLibrary(settings.libraryDir);
    if (library == null) {
      _loadFailed = true;
      return null;
    }
    final WhisperBindings bindings;
    try {
      bindings = WhisperBindings(library.library);
    } on ArgumentError {
      _loadFailed = true; // не та сборка: нет нужного символа
      return null;
    }
    final dir = library.backendDir?.toNativeUtf8() ?? nullptr;
    try {
      if (bindings.init(dir) == 0) {
        _loadFailed = true;
        return null;
      }
    } finally {
      if (dir != nullptr) calloc.free(dir);
    }
    return _cached = WhisperEngine._(bindings);
  }

  /// `whisper.cpp 1.9.5`.
  String get engine => 'whisper.cpp ${_bindings.version().toDartString()}';

  /// Звук в памяти → 16 кГц моно: WAV, MP3, FLAC, Ogg Vorbis/Opus.
  /// Возвращает [DecodedAudio] или код `MdwStatus`.
  (DecodedAudio?, int) decodeMemory(Uint8List bytes, int maxSamples) {
    final data = calloc<Uint8>(math.max(bytes.length, 1));
    final out = calloc<Pointer<Float>>();
    final count = calloc<Int64>();
    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      final status = _bindings.decodeMemory(
        data,
        bytes.length,
        maxSamples,
        out,
        count,
      );
      return status == MdwStatus.ok
          ? (DecodedAudio._(_bindings, out.value, count.value), status)
          : (null, status);
    } finally {
      calloc
        ..free(data)
        ..free(out)
        ..free(count);
    }
  }

  /// Файл → 16 кГц моно декодером платформы (AAC и всё, что умеет ОС).
  (DecodedAudio?, int) decodeFile(String path, int maxSamples) {
    final nativePath = path.toNativeUtf8();
    final out = calloc<Pointer<Float>>();
    final count = calloc<Int64>();
    try {
      final status = _bindings.decodeFile(nativePath, maxSamples, out, count);
      return status == MdwStatus.ok
          ? (DecodedAudio._(_bindings, out.value, count.value), status)
          : (null, status);
    } finally {
      calloc
        ..free(nativePath)
        ..free(out)
        ..free(count);
    }
  }

  /// Распознаёт [audio]. `null` — модель не открылась.
  Transcript? transcribe(
    DecodedAudio audio,
    TranscriptionSettings settings, {
    required bool truncated,
  }) {
    final modelPath = settings.modelPath.toNativeUtf8();
    final model = _bindings.openModel(modelPath);
    calloc.free(modelPath);
    if (model == nullptr) return null;

    final language = settings.language.toNativeUtf8();
    final vad =
        settings.vadModelPath != null &&
            File(settings.vadModelPath!).existsSync()
        ? settings.vadModelPath!.toNativeUtf8()
        : nullptr;
    final control = settings.controlAddress != 0
        ? Pointer<MdwControl>.fromAddress(settings.controlAddress)
        : nullptr;
    try {
      final status = _bindings.transcribe(
        model,
        audio.samples,
        audio.length,
        language,
        vad,
        _threads(),
        control,
      );
      if (status != MdwStatus.ok && status != MdwStatus.cancelled) {
        return null;
      }
      final cancelled = status == MdwStatus.cancelled;
      final segments = <TranscriptSegment>[];
      final count = _bindings.segmentCount(model);
      for (var i = 0; i < count; i++) {
        final text = _bindings.segmentText(model, i).toDartString().trim();
        if (text.isEmpty) continue;
        segments.add(
          TranscriptSegment(
            Duration(milliseconds: _bindings.segmentStartMs(model, i)),
            Duration(milliseconds: _bindings.segmentEndMs(model, i)),
            text,
          ),
        );
      }
      // Без сегментов язык не определялся: whisper отдаёт свой «по
      // умолчанию» — английский, и музыка без слов стала бы «английской».
      final detected = _bindings.language(model).toDartString();
      return Transcript(
        segments: segments,
        language: detected.isEmpty || segments.isEmpty ? null : detected,
        processed: cancelled && segments.isNotEmpty
            ? segments.last.end
            : audio.duration,
        truncated: truncated,
        cancelled: cancelled,
        engine: engine,
      );
    } finally {
      calloc.free(language);
      if (vad != nullptr) calloc.free(vad);
      _bindings.closeModel(model);
    }
  }
}

/// Потоков на распознавание. Whisper упирается в физические ядра, а не в
/// логические; на телефоне «больших» ядер обычно 4, и маленькие только
/// тормозят общий шаг.
int _threads() {
  final cores = Platform.numberOfProcessors;
  final limit = Platform.isAndroid ? 4 : 8;
  return cores.clamp(1, limit);
}

/// Целиком: декодирование и распознавание. [mp4] — контейнер ISO BMFF
/// (M4A, MP4, MOV, 3GP): его звук почти всегда AAC, и сразу идёт декодеру
/// платформы. [extension] — настоящее расширение по сигнатуре (`m4a`,
/// `mp3`…): Media Foundation выбирает обработчик по расширению файла, и
/// голосовое без расширения или под чужим не открыл бы. [localPath] — файл
/// на диске с теми же байтами, если есть и расширение верное: иначе для
/// декодера платформы пишется временный файл (и удаляется в `finally`).
TranscriptionOutcome transcribeAudio(
  Uint8List bytes,
  TranscriptionSettings settings, {
  required bool mp4,
  required String extension,
  String? localPath,
}) {
  final engine = WhisperEngine.open(settings);
  if (engine == null || !File(settings.modelPath).existsSync()) {
    return const TranscriptionOutcome.failure(TranscriptionFailure.unavailable);
  }
  final maxSamples = settings.maxDuration.inMilliseconds * _sampleRate ~/ 1000;

  var (audio, status) = mp4
      ? (null, MdwStatus.unsupported)
      : engine.decodeMemory(bytes, maxSamples);
  if (audio == null &&
      (status == MdwStatus.unsupported || status == MdwStatus.decode)) {
    final fromFile = _withFile(
      bytes,
      extension,
      mp4 ? _isoBmffExtensions : {extension},
      localPath,
      settings.tempDir,
      (path) => engine.decodeFile(path, maxSamples),
    );
    // Код переносимого декодера («битый поток») информативнее, чем
    // «платформа не умеет», — его и оставляем, если и файл не помог.
    if (fromFile.$1 != null || status == MdwStatus.unsupported) {
      (audio, status) = fromFile;
    }
  }
  if (audio == null) {
    return TranscriptionOutcome.failure(switch (status) {
      MdwStatus.noAudio => TranscriptionFailure.noAudio,
      MdwStatus.decode => TranscriptionFailure.undecodable,
      _ => TranscriptionFailure.unsupportedAudio,
    });
  }

  try {
    if (audio.length == 0) {
      return const TranscriptionOutcome.failure(TranscriptionFailure.noAudio);
    }
    // Щелчок, а не речь: whisper.cpp на звуке короче ~0,1 с отвечает
    // ошибкой — пользователю честнее «речь не найдена».
    if (audio.length < _sampleRate ~/ 2) {
      return TranscriptionOutcome.success(
        Transcript(
          segments: const [],
          language: null,
          processed: audio.duration,
          truncated: false,
          cancelled: false,
          engine: engine.engine,
        ),
      );
    }
    final transcript = engine.transcribe(
      audio,
      settings,
      truncated: audio.length >= maxSamples,
    );
    return transcript == null
        ? const TranscriptionOutcome.failure(TranscriptionFailure.failed)
        : TranscriptionOutcome.success(transcript);
  } finally {
    audio.dispose();
  }
}

/// Расширения контейнера ISO BMFF, под которыми Media Foundation открывает
/// файл как MPEG-4: видео с телефона не копируем во временный ради одного
/// лишь «правильного» `.m4a`.
const _isoBmffExtensions = {'m4a', 'mp4', 'm4v', 'm4b', 'mov', '3gp', '3g2'};

/// [action] над путём к файлу с [bytes]: [localPath], если он есть, того
/// же размера и с одним из расширений [accepted], иначе временный файл с
/// расширением [extension], который удаляется в `finally` — путь по ошибке
/// — главный способ оставить голосовое пользователя в `/tmp`.
(DecodedAudio?, int) _withFile(
  Uint8List bytes,
  String extension,
  Set<String> accepted,
  String? localPath,
  String? tempDir,
  (DecodedAudio?, int) Function(String path) action,
) {
  final localExtension = localPath?.split('.').last.toLowerCase();
  if (localPath != null && accepted.contains(localExtension)) {
    final local = File(localPath);
    if (local.existsSync() && local.lengthSync() == bytes.length) {
      return action(localPath);
    }
  }
  Directory? dir;
  try {
    final parent = tempDir != null ? Directory(tempDir) : Directory.systemTemp;
    dir = parent.createTempSync('markitdown_audio_');
    final file = File('${dir.path}${Platform.pathSeparator}audio.$extension')
      ..writeAsBytesSync(bytes, flush: true);
    return action(file.path);
  } on FileSystemException {
    return (null, MdwStatus.io);
  } finally {
    try {
      dir?.deleteSync(recursive: true);
    } on FileSystemException {
      // Не удалось удалить — не повод терять результат; каталог временный.
    }
  }
}

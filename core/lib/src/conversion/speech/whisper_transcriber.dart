import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'whisper_bindings.dart';

/// The sample rate Whisper expects (`MDW_SAMPLE_RATE`).
const _sampleRate = 16000;

/// Speech recognition settings that the app passes into the conversion
/// isolate: only strings and numbers — the libraries are opened inside the
/// isolate itself, same as OCR ([OcrSettings]).
class TranscriptionSettings {
  /// The Whisper model (`ggml-small-q8_0.bin`). On Windows — an asset next
  /// to the `.exe`; on Android — a copy of the asset in the app's directory
  /// (whisper.cpp reads the model from disk, not from the APK), see
  /// `app/lib/src/conversion/speech_data.dart`.
  final String modelPath;

  /// Silero VAD, or `null` — transcribe without cutting out silence.
  final String? vadModelPath;

  /// The libraries directory; `null` — the platform's default location (see
  /// [loadWhisperLibrary]).
  final String? libraryDir;

  /// Where to write audio to a temp file when the platform decoder (AAC)
  /// needs a path but there's no file on disk. `null` — the system temp
  /// directory.
  final String? tempDir;

  /// The language code (`ru`, `en`, `it`) or `auto` — detect from the first
  /// 30 seconds of speech. One language for the whole file: that's how
  /// Whisper works.
  final String language;

  /// The `mdw_control` address ([TranscriptionControl.address]) — progress
  /// and cancellation from the main isolate; 0 — none.
  final int controlAddress;

  const TranscriptionSettings({
    required this.modelPath,
    this.vadModelPath,
    this.libraryDir,
    this.tempDir,
    this.language = 'auto',
    this.controlAddress = 0,
  });

  TranscriptionSettings withControl(TranscriptionControl control) =>
      TranscriptionSettings(
        modelPath: modelPath,
        vadModelPath: vadModelPath,
        libraryDir: libraryDir,
        tempDir: tempDir,
        language: language,
        controlAddress: control.address,
      );
}

/// Progress and cancellation for transcription — memory shared with the
/// conversion isolate. Created on the main isolate before conversion,
/// freed by [dispose] only after it ends: native code writes here up to
/// the very last window.
class TranscriptionControl {
  final Pointer<MdwControl> _control = calloc<MdwControl>();

  int get address => _control.address;

  /// 0-100: the fraction of audio processed; 0 — transcription hasn't
  /// started yet.
  int get progress => _control.ref.progress;

  bool get cancelled => _control.ref.cancel != 0;

  /// Stop transcription: it doesn't wait longer than a single 30-second
  /// window (or preparing a 10-minute chunk — VAD and the mel spectrogram);
  /// whatever was already transcribed stays in the result.
  void cancel() => _control.ref.cancel = 1;

  void dispose() => calloc.free(_control);
}

/// Whether working transcription is available with these settings: the
/// libraries load, a CPU backend was found, the model is in place. The
/// model itself isn't loaded — that takes seconds; converters don't need to
/// check in advance.
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
  /// No libraries, CPU backend, or model.
  unavailable,

  /// No decoder could take the audio (a codec the platform doesn't have).
  unsupportedAudio,

  /// The format was recognized, but the audio didn't decode.
  undecodable,

  /// The file has no audio track.
  noAudio,

  /// whisper.cpp returned an error.
  failed,
}

class Transcript {
  final List<TranscriptSegment> segments;

  /// The detected (or given) language: `ru`, `en`, `it`…; `null` — unknown.
  final String? language;

  /// How much audio was transcribed — less than the file's duration if it
  /// was stopped.
  final Duration processed;

  final bool cancelled;

  /// `whisper.cpp 1.9.5` — written to `warnings`, like the OCR engine.
  final String engine;

  const Transcript({
    required this.segments,
    required this.language,
    required this.processed,
    required this.cancelled,
    required this.engine,
  });
}

/// The result: either [transcript] or [failure].
class TranscriptionOutcome {
  final Transcript? transcript;
  final TranscriptionFailure? failure;

  const TranscriptionOutcome.success(Transcript this.transcript)
    : failure = null;

  const TranscriptionOutcome.failure(TranscriptionFailure this.failure)
    : transcript = null;
}

/// Decoded audio: 16 kHz mono float in native memory. Not needed for
/// transcription — it decodes on its own, in chunks; this is for testing
/// the decoders as a whole. [dispose] is mandatory.
class DecodedAudio {
  DecodedAudio._(this._bindings, this.samples, this.length);

  final WhisperBindings _bindings;
  final Pointer<Float> samples;
  final int length;

  Duration get duration =>
      Duration(microseconds: length * 1000000 ~/ _sampleRate);

  void dispose() => _bindings.freeSamples(samples);
}

/// The opened libraries and the chosen CPU backend. One per isolate:
/// reopening the library is cheap, but backend variants are loaded once.
class WhisperEngine {
  WhisperEngine._(this._bindings);

  final WhisperBindings _bindings;

  static WhisperEngine? _cached;
  static bool _loadFailed = false;

  /// `null` — no libraries, or no CPU backend variant loaded.
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
      _loadFailed = true; // wrong build: the needed symbol is missing
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

  /// Stopped before the first phrase: an empty transcript with a marker.
  Transcript _stopped(Duration processed) => Transcript(
    segments: const [],
    language: null,
    processed: processed,
    cancelled: true,
    engine: engine,
  );

  /// In-memory audio → 16 kHz mono: WAV, MP3, FLAC, Ogg Vorbis/Opus.
  /// Returns [DecodedAudio] or an `MdwStatus` code.
  (DecodedAudio?, int) decodeMemory(Uint8List bytes, int maxSamples) {
    // malloc, not calloc: a buffer the size of the file gets fully
    // overwritten right away, zeroing it is a wasted pass over hundreds of
    // MB. Handing over the Uint8List itself (`.address`) is only possible
    // with a leaf call, which holds the GC for the whole isolate group,
    // including the UI, for the entire decode.
    final data = malloc<Uint8>(math.max(bytes.length, 1));
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
      malloc.free(data);
      calloc
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
}

/// Распознавание одного файла: сеанс `mdw_session` и параметры в нативной
/// памяти. Первым пробует один декодер, при неудаче — другой, в том же
/// сеансе: модель грузится при первом куске звука, и неудачная попытка её
/// не грузит. [close] обязателен.
class _Run {
  _Run(this._engine, TranscriptionSettings settings, Duration? duration)
    : _session = _newSession(_engine._bindings, settings.modelPath),
      _language = settings.language.toNativeUtf8(),
      _vad =
          settings.vadModelPath != null &&
              File(settings.vadModelPath!).existsSync()
          ? settings.vadModelPath!.toNativeUtf8()
          : nullptr,
      _control = settings.controlAddress != 0
          ? Pointer<MdwControl>.fromAddress(settings.controlAddress)
          : nullptr,
      _expected = duration == null
          ? 0
          : duration.inMicroseconds * _sampleRate ~/ 1000000;

  /// `nullptr` — нет памяти. Путь сеанс копирует себе.
  static Pointer<Void> _newSession(WhisperBindings bindings, String path) {
    final nativePath = path.toNativeUtf8();
    try {
      return bindings.newSession(nativePath);
    } finally {
      malloc.free(nativePath);
    }
  }

  final WhisperEngine _engine;
  final Pointer<Void> _session;
  final Pointer<Utf8> _language;
  final Pointer<Utf8> _vad;
  final Pointer<MdwControl> _control;
  final int _expected;

  WhisperBindings get _bindings => _engine._bindings;

  /// Переносимыми декодерами: WAV, MP3, FLAC, Ogg Vorbis/Opus.
  int memory(Uint8List bytes) {
    if (_session == nullptr) return MdwStatus.noMemory;
    // malloc, не calloc: буфер размером с файл тут же целиком
    // перезаписывается, обнулять его — лишний проход по сотням МБ. Отдать
    // сам Uint8List (`.address`) можно только листовым вызовом, а он
    // держит GC всей группы изолятов, включая UI, на всё распознавание.
    final data = malloc<Uint8>(math.max(bytes.length, 1));
    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      return _bindings.transcribeMemory(
        _session,
        data,
        bytes.length,
        _expected,
        _language,
        _vad,
        _threads(),
        _control,
      );
    } finally {
      malloc.free(data);
    }
  }

  /// Декодером платформы (AAC и всё, что умеет ОС).
  int file(String path) {
    if (_session == nullptr) return MdwStatus.noMemory;
    final nativePath = path.toNativeUtf8();
    try {
      return _bindings.transcribeFile(
        _session,
        nativePath,
        _expected,
        _language,
        _vad,
        _threads(),
        _control,
      );
    } finally {
      malloc.free(nativePath);
    }
  }

  /// Результат последнего успешного или остановленного вызова.
  Transcript transcript({required bool cancelled}) {
    final segments = <TranscriptSegment>[];
    final count = _bindings.segmentCount(_session);
    for (var i = 0; i < count; i++) {
      final text = _lossyUtf8(_bindings.segmentText(_session, i)).trim();
      if (text.isEmpty) continue;
      segments.add(
        TranscriptSegment(
          Duration(milliseconds: _bindings.segmentStartMs(_session, i)),
          Duration(milliseconds: _bindings.segmentEndMs(_session, i)),
          text,
        ),
      );
    }
    // Пустой — речи не нашлось: язык без неё не определялся.
    final detected = _bindings.language(_session).toDartString();
    return Transcript(
      segments: segments,
      language: detected.isEmpty || segments.isEmpty ? null : detected,
      processed: cancelled && segments.isNotEmpty
          ? segments.last.end
          : Duration(milliseconds: _bindings.processedMs(_session)),
      cancelled: cancelled,
      engine: _engine.engine,
    );
  }

  void close() {
    if (_session != nullptr) _bindings.freeSession(_session);
    malloc.free(_language);
    if (_vad != nullptr) malloc.free(_vad);
  }
}

/// Нажата ли «Остановить» — флаг в общей памяти `mdw_control`.
bool _cancelled(TranscriptionSettings settings) =>
    settings.controlAddress != 0 &&
    Pointer<MdwControl>.fromAddress(settings.controlAddress).ref.cancel != 0;

/// Текст сегмента: whisper.cpp режет его по токенам BPE, и граница
/// сегмента может пройти посреди многобайтной буквы (кириллица, CJK).
/// `toDartString()` на этом бросает `FormatException` — и минуты
/// распознавания пропали бы из-за одного символа; битый станет `�`.
String _lossyUtf8(Pointer<Utf8> text) => utf8.decode(
  text.cast<Uint8>().asTypedList(text.length),
  allowMalformed: true,
);

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
/// [duration] — длительность из метаданных, для процента; `null` —
/// неизвестна, процента не будет.
///
/// Предела длительности нет: звук распознаётся кусками по мере
/// декодирования, и память не растёт с длиной записи (`mdw.h`).
TranscriptionOutcome transcribeAudio(
  Uint8List bytes,
  TranscriptionSettings settings, {
  required bool mp4,
  required String extension,
  String? localPath,
  Duration? duration,
}) {
  final engine = WhisperEngine.open(settings);
  if (engine == null || !File(settings.modelPath).existsSync()) {
    return const TranscriptionOutcome.failure(TranscriptionFailure.unavailable);
  }
  if (_cancelled(settings)) {
    return TranscriptionOutcome.success(engine._stopped(Duration.zero));
  }

  final run = _Run(engine, settings, duration);
  try {
    var status = mp4 ? MdwStatus.unsupported : run.memory(bytes);
    if (status == MdwStatus.unsupported || status == MdwStatus.decode) {
      final fromFile = _withFile(
        bytes,
        extension,
        mp4 ? _isoBmffExtensions : {extension},
        localPath,
        settings.tempDir,
        run.file,
      );
      // Код переносимого декодера («битый поток») информативнее, чем
      // «платформа не умеет», — его и оставляем, если и файл не помог.
      if (!_noSound.contains(fromFile) || status == MdwStatus.unsupported) {
        status = fromFile;
      }
    }
    return switch (status) {
      MdwStatus.ok || MdwStatus.cancelled => TranscriptionOutcome.success(
        run.transcript(cancelled: status == MdwStatus.cancelled),
      ),
      MdwStatus.noAudio => const TranscriptionOutcome.failure(
        TranscriptionFailure.noAudio,
      ),
      MdwStatus.decode => const TranscriptionOutcome.failure(
        TranscriptionFailure.undecodable,
      ),
      MdwStatus.unsupported ||
      MdwStatus.io => const TranscriptionOutcome.failure(
        TranscriptionFailure.unsupportedAudio,
      ),
      _ => const TranscriptionOutcome.failure(TranscriptionFailure.failed),
    };
  } finally {
    run.close();
  }
}

/// Декодер не дал ни одного отсчёта — распознавание не начиналось.
const _noSound = {
  MdwStatus.unsupported,
  MdwStatus.decode,
  MdwStatus.noAudio,
  MdwStatus.io,
};

/// Расширения контейнера ISO BMFF, под которыми Media Foundation открывает
/// файл как MPEG-4: видео с телефона не копируем во временный ради одного
/// лишь «правильного» `.m4a`.
const _isoBmffExtensions = {'m4a', 'mp4', 'm4v', 'm4b', 'mov', '3gp', '3g2'};

/// [action] над путём к файлу с [bytes]: [localPath], если он есть, того
/// же размера и с одним из расширений [accepted], иначе временный файл с
/// расширением [extension], который удаляется в `finally` — путь по ошибке
/// — главный способ оставить голосовое пользователя в `/tmp`.
int _withFile(
  Uint8List bytes,
  String extension,
  Set<String> accepted,
  String? localPath,
  String? tempDir,
  int Function(String path) action,
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
    return MdwStatus.io;
  } finally {
    try {
      dir?.deleteSync(recursive: true);
    } on FileSystemException {
      // Не удалось удалить — не повод терять результат; каталог временный.
    }
  }
}

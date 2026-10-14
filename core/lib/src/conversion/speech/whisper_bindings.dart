/// FFI-биндинги на `markitdown_whisper` — нашу C-прослойку над whisper.cpp
/// (`whisper/shim/mdw.h`). Не на `whisper.h` напрямую: `whisper_full_params`
/// — структура на сотню полей, меняющаяся от версии к версии, и повторять её
/// раскладку в Dart значит молча читать мусор после обновления. Почему
/// whisper.cpp и откуда библиотеки — `docs/format-coverage.md#решения-транскрипции-08`.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Переменная окружения с каталогом, где лежат `markitdown_whisper`,
/// `whisper`, `ggml*` и варианты `ggml-cpu-*`. Нужна для `dart test` и для
/// любой машины, где библиотеки не на стандартном месте платформы.
const whisperLibDirEnvVar = 'MARKITDOWN_WHISPER_DIR';

/// Коды возврата `mdw_*` (`mdw.h`).
abstract final class MdwStatus {
  static const ok = 0;
  static const unsupported = 1;
  static const decode = 2;
  static const noAudio = 3;
  static const noMemory = 4;
  static const cancelled = 5;
  static const transcribe = 6;
  static const io = 7;
  static const model = 8;
}

/// `mdw_control`: общая память изолята конвертации и главного изолята —
/// главный пишет [cancel], нативный код пишет [progress].
final class MdwControl extends Struct {
  @Int32()
  external int cancel;

  @Int32()
  external int progress;
}

/// Открытая библиотека и каталог, где искать варианты CPU-бэкенда (`null`
/// — по голым именам, так на Android).
class WhisperLibrary {
  final DynamicLibrary library;
  final String? backendDir;

  const WhisperLibrary(this.library, this.backendDir);
}

/// Находит и открывает библиотеки. `null`, если их нет: распознавание речи
/// — необязательная часть конвейера, его отсутствие не ошибка конвертации.
///
/// 1. [libraryDir] или [whisperLibDirEnvVar] — явный каталог.
/// 2. Android: голые имена — `.so` лежат в `jniLibs/arm64-v8a/` и находятся
///    сами (сборка `whisper/build.sh --android`).
/// 3. Windows и Linux: рядом с исполняемым файлом (`install(...)` в
///    `app/windows/CMakeLists.txt`).
WhisperLibrary? loadWhisperLibrary([String? libraryDir]) {
  try {
    final dir = libraryDir ?? Platform.environment[whisperLibDirEnvVar];
    if (dir != null && dir.isNotEmpty) return _openFromDirectory(dir);
    if (Platform.isAndroid) {
      // Зависимости (libwhisper.so, libggml*.so) линкер Android подтянет
      // сам из того же APK.
      return WhisperLibrary(
        DynamicLibrary.open('libmarkitdown_whisper.so'),
        null,
      );
    }
    if (Platform.isWindows || Platform.isLinux) {
      return _openFromDirectory(File(Platform.resolvedExecutable).parent.path);
    }
  } on ArgumentError {
    return null; // DynamicLibrary.open: файла нет или не грузится
  }
  return null;
}

WhisperLibrary? _openFromDirectory(String dir) {
  String path(String name) => '$dir${Platform.pathSeparator}$name';
  if (Platform.isWindows) {
    // Зависимости — первыми и по порядку: LoadLibrary ищет импорты DLL
    // рядом с .exe процесса (у `dart test` это dart.exe), а уже
    // загруженный модуль с тем же именем находит всегда.
    for (final name in ['ggml-base.dll', 'ggml.dll', 'whisper.dll']) {
      if (!File(path(name)).existsSync()) return null;
      DynamicLibrary.open(path(name));
    }
    final shim = path('markitdown_whisper.dll');
    if (!File(shim).existsSync()) return null;
    return WhisperLibrary(DynamicLibrary.open(shim), dir);
  }
  // macOS/Linux: соседей находит rpath (@loader_path / $ORIGIN).
  final name = Platform.isMacOS
      ? 'libmarkitdown_whisper.dylib'
      : 'libmarkitdown_whisper.so';
  if (!File(path(name)).existsSync()) return null;
  return WhisperLibrary(DynamicLibrary.open(path(name)), dir);
}

typedef _VersionNative = Pointer<Utf8> Function();
typedef _InitNative = Int32 Function(Pointer<Utf8> dir);
typedef _InitDart = int Function(Pointer<Utf8> dir);
typedef _DecodeMemoryNative =
    Int32 Function(
      Pointer<Uint8> data,
      Int64 size,
      Int64 maxSamples,
      Pointer<Pointer<Float>> out,
      Pointer<Int64> count,
    );
typedef _DecodeMemoryDart =
    int Function(
      Pointer<Uint8> data,
      int size,
      int maxSamples,
      Pointer<Pointer<Float>> out,
      Pointer<Int64> count,
    );
typedef _DecodeFileNative =
    Int32 Function(
      Pointer<Utf8> path,
      Int64 maxSamples,
      Pointer<Pointer<Float>> out,
      Pointer<Int64> count,
    );
typedef _DecodeFileDart =
    int Function(
      Pointer<Utf8> path,
      int maxSamples,
      Pointer<Pointer<Float>> out,
      Pointer<Int64> count,
    );
typedef _FreeSamplesNative = Void Function(Pointer<Float> samples);
typedef _FreeSamplesDart = void Function(Pointer<Float> samples);
typedef _SessionNewNative = Pointer<Void> Function(Pointer<Utf8> modelPath);
typedef _SessionFreeNative = Void Function(Pointer<Void> session);
typedef _SessionFreeDart = void Function(Pointer<Void> session);
typedef _TranscribeMemoryNative =
    Int32 Function(
      Pointer<Void> session,
      Pointer<Uint8> data,
      Int64 size,
      Int64 expectedSamples,
      Pointer<Utf8> language,
      Pointer<Utf8> vadModelPath,
      Int32 threads,
      Pointer<MdwControl> control,
    );
typedef _TranscribeMemoryDart =
    int Function(
      Pointer<Void> session,
      Pointer<Uint8> data,
      int size,
      int expectedSamples,
      Pointer<Utf8> language,
      Pointer<Utf8> vadModelPath,
      int threads,
      Pointer<MdwControl> control,
    );
typedef _TranscribeFileNative =
    Int32 Function(
      Pointer<Void> session,
      Pointer<Utf8> path,
      Int64 expectedSamples,
      Pointer<Utf8> language,
      Pointer<Utf8> vadModelPath,
      Int32 threads,
      Pointer<MdwControl> control,
    );
typedef _TranscribeFileDart =
    int Function(
      Pointer<Void> session,
      Pointer<Utf8> path,
      int expectedSamples,
      Pointer<Utf8> language,
      Pointer<Utf8> vadModelPath,
      int threads,
      Pointer<MdwControl> control,
    );
typedef _SegmentCountNative = Int32 Function(Pointer<Void> model);
typedef _SegmentCountDart = int Function(Pointer<Void> model);
typedef _SegmentTextNative =
    Pointer<Utf8> Function(Pointer<Void> model, Int32 index);
typedef _SegmentTextDart =
    Pointer<Utf8> Function(Pointer<Void> model, int index);
typedef _SegmentTimeNative = Int64 Function(Pointer<Void> model, Int32 index);
typedef _SegmentTimeDart = int Function(Pointer<Void> model, int index);
typedef _LanguageNative = Pointer<Utf8> Function(Pointer<Void> model);
typedef _ProcessedNative = Int64 Function(Pointer<Void> session);
typedef _ProcessedDart = int Function(Pointer<Void> session);

/// Функции `mdw.h`. Отсутствие любой — `ArgumentError` из `lookup`: не та
/// сборка библиотеки.
class WhisperBindings {
  WhisperBindings(DynamicLibrary lib)
    : version = lib.lookupFunction<_VersionNative, _VersionNative>(
        'mdw_version',
      ),
      init = lib.lookupFunction<_InitNative, _InitDart>('mdw_init'),
      decodeMemory = lib.lookupFunction<_DecodeMemoryNative, _DecodeMemoryDart>(
        'mdw_decode_memory',
      ),
      decodeFile = lib.lookupFunction<_DecodeFileNative, _DecodeFileDart>(
        'mdw_decode_file',
      ),
      freeSamples = lib.lookupFunction<_FreeSamplesNative, _FreeSamplesDart>(
        'mdw_free_samples',
      ),
      newSession = lib.lookupFunction<_SessionNewNative, _SessionNewNative>(
        'mdw_session_new',
      ),
      freeSession = lib.lookupFunction<_SessionFreeNative, _SessionFreeDart>(
        'mdw_session_free',
      ),
      transcribeMemory = lib
          .lookupFunction<_TranscribeMemoryNative, _TranscribeMemoryDart>(
            'mdw_transcribe_memory',
          ),
      transcribeFile = lib
          .lookupFunction<_TranscribeFileNative, _TranscribeFileDart>(
            'mdw_transcribe_file',
          ),
      segmentCount = lib.lookupFunction<_SegmentCountNative, _SegmentCountDart>(
        'mdw_segment_count',
      ),
      segmentText = lib.lookupFunction<_SegmentTextNative, _SegmentTextDart>(
        'mdw_segment_text',
      ),
      segmentStartMs = lib.lookupFunction<_SegmentTimeNative, _SegmentTimeDart>(
        'mdw_segment_start_ms',
      ),
      segmentEndMs = lib.lookupFunction<_SegmentTimeNative, _SegmentTimeDart>(
        'mdw_segment_end_ms',
      ),
      language = lib.lookupFunction<_LanguageNative, _LanguageNative>(
        'mdw_language',
      ),
      processedMs = lib.lookupFunction<_ProcessedNative, _ProcessedDart>(
        'mdw_processed_ms',
      );

  // Типы полей — развёрнутые, а не typedef-ы выше: те приватные, а
  // привязки читаются из соседнего файла.
  final Pointer<Utf8> Function() version;
  final int Function(Pointer<Utf8> dir) init;
  final int Function(
    Pointer<Uint8> data,
    int size,
    int maxSamples,
    Pointer<Pointer<Float>> out,
    Pointer<Int64> count,
  )
  decodeMemory;
  final int Function(
    Pointer<Utf8> path,
    int maxSamples,
    Pointer<Pointer<Float>> out,
    Pointer<Int64> count,
  )
  decodeFile;
  final void Function(Pointer<Float> samples) freeSamples;
  final Pointer<Void> Function(Pointer<Utf8> modelPath) newSession;
  final void Function(Pointer<Void> session) freeSession;
  final int Function(
    Pointer<Void> session,
    Pointer<Uint8> data,
    int size,
    int expectedSamples,
    Pointer<Utf8> language,
    Pointer<Utf8> vadModelPath,
    int threads,
    Pointer<MdwControl> control,
  )
  transcribeMemory;
  final int Function(
    Pointer<Void> session,
    Pointer<Utf8> path,
    int expectedSamples,
    Pointer<Utf8> language,
    Pointer<Utf8> vadModelPath,
    int threads,
    Pointer<MdwControl> control,
  )
  transcribeFile;
  final int Function(Pointer<Void> model) segmentCount;
  final Pointer<Utf8> Function(Pointer<Void> model, int index) segmentText;
  final int Function(Pointer<Void> model, int index) segmentStartMs;
  final int Function(Pointer<Void> model, int index) segmentEndMs;
  final Pointer<Utf8> Function(Pointer<Void> model) language;
  final int Function(Pointer<Void> session) processedMs;
}

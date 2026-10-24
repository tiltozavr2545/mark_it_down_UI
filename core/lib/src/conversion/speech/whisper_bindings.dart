/// FFI bindings onto `markitdown_whisper` — our C shim over whisper.cpp
/// (`whisper/shim/mdw.h`). Not onto `whisper.h` directly: `whisper_full_params`
/// is a struct with about a hundred fields that changes from version to
/// version, and repeating its layout in Dart would mean silently reading
/// garbage after an update. For why whisper.cpp and where the libraries
/// come from, see `docs/format-coverage.md#решения-транскрипции-08`.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Environment variable with the directory holding `markitdown_whisper`,
/// `whisper`, `ggml*` and the `ggml-cpu-*` variants. Needed for
/// `dart test` and for any machine where the libraries aren't in the
/// platform's standard location.
const whisperLibDirEnvVar = 'MARKITDOWN_WHISPER_DIR';

/// `mdw_*` return codes (`mdw.h`).
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

/// `mdw_control`: memory shared between the conversion isolate and the
/// main isolate — the main isolate writes [cancel], the native code
/// writes [progress].
final class MdwControl extends Struct {
  @Int32()
  external int cancel;

  @Int32()
  external int progress;
}

/// The opened library and the directory to look for CPU-backend variants
/// in (`null` — by bare names, as on Android).
class WhisperLibrary {
  final DynamicLibrary library;
  final String? backendDir;

  const WhisperLibrary(this.library, this.backendDir);
}

/// Finds and opens the libraries. `null` if they're missing: speech
/// recognition is an optional part of the pipeline, its absence isn't a
/// conversion error.
///
/// 1. [libraryDir] or [whisperLibDirEnvVar] — an explicit directory.
/// 2. Android: bare names — the `.so` files live in `jniLibs/arm64-v8a/`
///    and are found on their own (built by `whisper/build.sh --android`).
/// 3. Windows and Linux: next to the executable (`install(...)` in
///    `app/windows/CMakeLists.txt`).
WhisperLibrary? loadWhisperLibrary([String? libraryDir]) {
  try {
    final dir = libraryDir ?? Platform.environment[whisperLibDirEnvVar];
    if (dir != null && dir.isNotEmpty) return _openFromDirectory(dir);
    if (Platform.isAndroid) {
      // Dependencies (libwhisper.so, libggml*.so) are pulled in by the
      // Android linker on its own from the same APK.
      return WhisperLibrary(
        DynamicLibrary.open('libmarkitdown_whisper.so'),
        null,
      );
    }
    if (Platform.isWindows || Platform.isLinux) {
      return _openFromDirectory(File(Platform.resolvedExecutable).parent.path);
    }
  } on ArgumentError {
    return null; // DynamicLibrary.open: file missing or fails to load
  }
  return null;
}

WhisperLibrary? _openFromDirectory(String dir) {
  String path(String name) => '$dir${Platform.pathSeparator}$name';
  if (Platform.isWindows) {
    // Dependencies first and in order: LoadLibrary looks for DLL imports
    // next to the process's .exe (for `dart test` that's dart.exe), but
    // it always finds an already-loaded module with the same name.
    for (final name in ['ggml-base.dll', 'ggml.dll', 'whisper.dll']) {
      if (!File(path(name)).existsSync()) return null;
      DynamicLibrary.open(path(name));
    }
    final shim = path('markitdown_whisper.dll');
    if (!File(shim).existsSync()) return null;
    return WhisperLibrary(DynamicLibrary.open(shim), dir);
  }
  // macOS/Linux: neighboring libraries are found via rpath
  // (@loader_path / $ORIGIN).
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

/// The functions from `mdw.h`. If any is missing — an `ArgumentError`
/// from `lookup`: wrong library build.
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

  // Field types are spelled out rather than using the typedefs above:
  // those are private, and the bindings are read from a neighboring file.
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

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:markitdown_core/markitdown_core.dart';
import 'package:markitdown_core/src/conversion/speech/whisper_bindings.dart';
import 'package:markitdown_core/src/conversion/speech/whisper_transcriber.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Speech recognition on real whisper.cpp. The baseline is keywords, not
/// byte-for-byte Markdown like OCR: the text depends on the engine version,
/// the model, and even the processor's instruction set (CPU backend variants
/// compute with different precision). The `speech/` fixtures are synthesized
/// speech (`say` on macOS: Milena, Samantha, Alice), see
/// `docs/format-coverage.md`.
///
/// Requires the libraries (`MARKITDOWN_WHISPER_DIR`, `whisper/build.sh`) and,
/// for recognition, the models (`whisper/models/`, `whisper/fetch.sh`).
/// Without them the tests are skipped; decoders are checked even without
/// models.
void main() {
  final root = Directory.current.parent.path;
  final models = p.join(root, 'whisper', 'models');
  final fixtures = p.join(Directory.current.path, 'test', 'fixtures');
  final settings = TranscriptionSettings(
    modelPath: p.join(models, 'ggml-small-q8_0.bin'),
    vadModelPath: p.join(models, 'ggml-silero-v6.2.0.bin'),
  );
  final registry = ConverterRegistry.defaultRegistry(transcription: settings);

  final engine = WhisperEngine.open(settings);
  final noLibrary = engine == null
      ? 'нет библиотек whisper (MARKITDOWN_WHISPER_DIR, whisper/build.sh)'
      : false;
  final noModel = engine == null
      ? noLibrary
      : transcriptionAvailable(settings)
      ? false
      : 'нет модели (whisper/fetch.sh)';

  Uint8List read(String relative) =>
      Uint8List.fromList(File(p.join(fixtures, relative)).readAsBytesSync());

  Future<ConversionResult> convert(
    String relative, {
    ConverterRegistry? using,
  }) async {
    final bytes = read(relative);
    final info = StreamInfo.fromHead(bytes, filename: p.basename(relative));
    final outcome = await (using ?? registry).convert(bytes, info);
    expect(outcome, isA<ConversionSuccess>());
    return (outcome as ConversionSuccess).result;
  }

  Iterable<String> messages(ConversionResult result) =>
      result.warnings.map((w) => w.message);

  // One word out of several may come out differently on another processor:
  // ggml picks a CPU-code variant for the runner, and "riconoscimento" once
  // became "riconosimento". So one inexact phrase is allowed, while the
  // language is checked strictly.
  void expectMostOf(String markdown, List<String> phrases) {
    final text = markdown.toLowerCase();
    final missing = phrases.where((p) => !text.contains(p)).toList();
    expect(
      missing.length,
      lessThanOrEqualTo(1),
      reason: 'нет фраз $missing в:\n$markdown',
    );
  }

  group('recognition', () {
    test('Russian — transcription, language and engine in warnings', () async {
      final result = await convert('speech/ru.wav');
      expect(result.markdown, contains('## Расшифровка'));
      expect(result.markdown, contains('**0:00** '));
      expectMostOf(result.markdown, [
        'распознавания речи',
        'встреча',
        'понедельник',
        'утра',
      ]);
      expect(result.markdown, contains('- **Язык речи:** русский'));
      expect(messages(result), contains(contains('whisper.cpp')));
    }, skip: noModel);

    test('English', () async {
      final result = await convert('speech/en.wav');
      expectMostOf(result.markdown, [
        'speech recognition',
        'meeting',
        'monday',
        'morning',
      ]);
      expect(result.markdown, contains('- **Язык речи:** английский'));
    }, skip: noModel);

    test('Italian', () async {
      final result = await convert('speech/it.wav');
      expectMostOf(result.markdown, [
        'prova',
        'riconoscimento',
        'riunione',
        'lunedì',
      ]);
      expect(result.markdown, contains('- **Язык речи:** итальянский'));
    }, skip: noModel);

    // English and Italian are primary for the author, on par with Russian.
    // 50 seconds, four voices (Samantha, Daniel, Alex / Alice, Luca), fast
    // speech at the end: several consecutive 30-second windows, language
    // detected automatically. The 0.8 measurement on these recordings is
    // WER 0% (English) and 1.6% (Italian: "ha" → "a", "caldaia" → "caldàia").
    test('English, 50 seconds, four voices', () async {
      final result = await convert('speech/en_long.flac');
      expect(result.markdown, contains('- **Язык речи:** английский'));
      expectMostOf(result.markdown, [
        'thank the whole team',
        'office will be closed on friday',
        'three main risks',
        'responsible for the final testing',
        'payments and penalties',
      ]);
    }, skip: noModel);

    test('Italian, 50 seconds, four voices', () async {
      final result = await convert('speech/it_long.flac');
      expect(result.markdown, contains('- **Язык речи:** итальянский'));
      expectMostOf(result.markdown, [
        'ringraziare la squadra',
        'chiuso venerdì pomeriggio',
        'tre rischi principali',
        'collaudo finale',
        'pagamenti e sulle penali',
      ]);
    }, skip: noModel);

    test('FLAC — same path through miniaudio', () async {
      final result = await convert('speech/en.flac');
      expectMostOf(result.markdown, [
        'speech recognition',
        'meeting',
        'monday',
      ]);
    }, skip: noModel);

    test('M4A (AAC) — platform decoder', () async {
      final result = await convert('speech/ru.m4a');
      if (result.markdown.contains('## Расшифровка')) {
        expectMostOf(result.markdown, ['распознавания речи', 'понедельник']);
        return;
      }
      // No AAC decoder: test host is macOS/Linux, Windows "N", or Windows
      // Server without Media Foundation (the windows-2022 CI runner has it).
      // Metadata is present, recognition isn't — and that's reported; the
      // AAC path itself isn't verified here, so the test is marked skipped
      // rather than green.
      expect(result.markdown, contains('- **Формат:**'));
      expect(messages(result), contains(contains('кодек не поддерживается')));
      markTestSkipped(
        'нет декодера AAC у платформы — проверено предупреждение',
      );
    }, skip: noModel);

    test('cancel before start — result without text, not an error', () async {
      final control = TranscriptionControl()..cancel();
      try {
        final cancelled = ConverterRegistry.defaultRegistry(
          transcription: settings.withControl(control),
        );
        final result = await convert('speech/ru.wav', using: cancelled);
        expect(result.markdown, isNot(contains('## Расшифровка')));
        expect(result.markdown, isNot(contains('Язык речи')));
        expect(messages(result), contains(contains('остановлено')));
      } finally {
        control.dispose();
      }
    }, skip: noModel);

    // Dart checks the flag before the shim itself, so its early exit is
    // tested directly: cancelling before the call means nothing is decoded
    // and no model is loaded.
    test('cancel before mdw_transcribe_memory — immediately "cancelled"', () {
      final bindings = WhisperBindings(loadWhisperLibrary()!.library);
      final bytes = read('speech/ru.wav');
      final data = malloc<Uint8>(bytes.length);
      data.asTypedList(bytes.length).setAll(0, bytes);
      final modelPath = settings.modelPath.toNativeUtf8();
      final session = bindings.newSession(modelPath);
      final language = 'auto'.toNativeUtf8();
      final control = TranscriptionControl()..cancel();
      try {
        final status = bindings.transcribeMemory(
          session,
          data,
          bytes.length,
          0,
          language,
          nullptr,
          1,
          Pointer<MdwControl>.fromAddress(control.address),
        );
        expect(status, MdwStatus.cancelled);
        expect(bindings.segmentCount(session), 0);
        expect(bindings.processedMs(session), 0, reason: 'не декодировалось');
      } finally {
        control.dispose();
        bindings.freeSession(session);
        malloc
          ..free(data)
          ..free(modelPath)
          ..free(language);
      }
    }, skip: noModel);

    // A chunk is 10 minutes: speech, 10.5 minutes of silence, speech again.
    // The chunk boundary falls in the silence, the second phrase is in the
    // second chunk with a time offset, the language comes from the first
    // chunk. Only speech is recognized (VAD), so the test runs in seconds,
    // not minutes.
    test('long recording — in chunks: time and language carry through', () async {
      final (speech, _) = engine!.decodeMemory(read('speech/ru.wav'), 1 << 30);
      final words = Float32List.fromList(
        speech!.samples.asTypedList(speech.length),
      );
      speech.dispose();
      const gap = 16000 * 630;
      final all = Float32List(words.length * 2 + gap)
        ..setAll(0, words)
        ..setAll(words.length + gap, words);
      final bytes = _wav16(all);

      final control = TranscriptionControl();
      try {
        final long = ConverterRegistry.defaultRegistry(
          transcription: settings.withControl(control),
        );
        final info = StreamInfo.fromHead(bytes, filename: 'long.wav');
        final outcome = await long.convert(bytes, info);
        final result = (outcome as ConversionSuccess).result;
        final paragraphs = result.markdown
            .split('\n\n')
            .where((block) => block.startsWith('**'))
            .toList();
        expect(paragraphs, hasLength(2), reason: result.markdown);
        expect(paragraphs[0], startsWith('**0:00** '));
        expect(paragraphs[1], matches(RegExp(r'^\*\*10:3\d\*\* ')));
        for (final paragraph in paragraphs) {
          expectMostOf(paragraph, [
            'распознавания речи',
            'встреча',
            'понедельник',
            'утра',
          ]);
        }
        expect(result.markdown, contains('- **Язык речи:** русский'));
        expect(messages(result), isNot(contains(contains('остановлено'))));
        expect(control.progress, 100);
      } finally {
        control.dispose();
      }
    }, skip: noModel);

    // Chunk boundary in the middle of speech: silence until 9:40, then the
    // phrase six times in a row until 10:16 — there's no silence in the last
    // 15 seconds of the chunk, and it's cut in the pause between phrases.
    // The remainder of the chunk carries over into the next one: lose or
    // corrupt it and a phrase would be missing.
    test('chunk boundary within speech — no phrase lost', () async {
      final (speech, _) = engine!.decodeMemory(read('speech/ru.wav'), 1 << 30);
      final words = Float32List.fromList(
        speech!.samples.asTypedList(speech.length),
      );
      speech.dispose();
      const silence = 16000 * 580;
      final all = Float32List(silence + words.length * 6);
      for (var i = 0; i < 6; i++) {
        all.setAll(silence + words.length * i, words);
      }
      final bytes = _wav16(all);
      final info = StreamInfo.fromHead(bytes, filename: 'boundary.wav');
      final outcome = await registry.convert(bytes, info);
      final markdown = (outcome as ConversionSuccess).result.markdown;
      final count = 'понедельник'.allMatches(markdown.toLowerCase()).length;
      expect(count, greaterThanOrEqualTo(5), reason: markdown);
      expect(markdown, contains('- **Язык речи:** русский'));
    }, skip: noModel);
  });

  // The directory is set explicitly (make test, CI) — meaning the libraries
  // should be there: silently skipping all tests would look like success
  // in CI.
  test(
    'libraries load from MARKITDOWN_WHISPER_DIR',
    () {
      expect(engine, isNotNull, reason: 'не загрузилась markitdown_whisper');
    },
    skip: Platform.environment[whisperLibDirEnvVar] == null,
  );

  test('no model — metadata and warning, not a failure', () async {
    final missing = ConverterRegistry.defaultRegistry(
      transcription: const TranscriptionSettings(modelPath: '/нет/модели.bin'),
    );
    final result = await convert('speech/ru.wav', using: missing);
    expect(result.markdown, contains('- **Формат:**'));
    expect(messages(result), contains(contains('недоступно')));
  });

  test('music without words — "speech not found", no language', () async {
    final result = await convert('audio/music.ogg');
    expect(result.markdown, isNot(contains('## Расшифровка')));
    expect(result.markdown, isNot(contains('Язык речи')));
    expect(messages(result), contains('речь не найдена'));
  }, skip: noModel);

  group('decoders', () {
    // Duration from metadata (AudioConverter) versus decoded.
    const durations = {
      'audio/voice.ogg': 3.0, // Ogg Opus — own Ogg parsing + libopus
      'audio/music.ogg': null, // Ogg Vorbis — stb_vorbis
      'audio/song.mp3': null,
      'audio/track.flac': null,
      'audio/recording.wav': null,
      'speech/ru.wav': 6.6, // 22,050 Hz — through the resampler
    };
    for (final MapEntry(key: name, value: seconds) in durations.entries) {
      test('$name → 16 kHz mono', () {
        final (audio, status) = engine!.decodeMemory(read(name), 1 << 30);
        expect(status, 0, reason: 'код mdw: $status');
        try {
          expect(audio!.length, greaterThan(0));
          if (seconds != null) {
            expect(audio.duration.inMilliseconds / 1000, closeTo(seconds, 0.3));
          }
        } finally {
          audio?.dispose();
        }
      }, skip: noLibrary);
    }

    // The native decoder runs in the app's process: a corrupt file must not
    // crash it. An error code or a partial result are both fine.
    test('truncated files — return code, not a crash', () {
      final names = [...durations.keys, 'speech/en.flac'];
      for (final name in names) {
        final full = read(name);
        for (final length in {0, 1, 4, 27, 44, 100, full.length ~/ 2}) {
          if (length > full.length) continue;
          final (audio, _) = engine!.decodeMemory(
            Uint8List.sublistView(full, 0, length),
            1 << 30,
          );
          audio?.dispose();
        }
      }
    }, skip: noLibrary);

    // AAC — platform decoder only (Media Foundation, MediaCodec). The test
    // targets the decoder directly: if the M4A transcription is empty, this
    // shows whether the audio is short, silent, or noisy.
    test(
      'speech/ru.m4a → platform decoder: duration and not silence',
      () {
        final dir = Directory.systemTemp.createTempSync('mdw_m4a_');
        try {
          final file = File(p.join(dir.path, 'ru.m4a'))
            ..writeAsBytesSync(read('speech/ru.m4a'));
          final (audio, status) = engine!.decodeFile(file.path, 1 << 30);
          if (status == MdwStatus.unsupported) {
            markTestSkipped('нет декодера AAC у платформы');
            return;
          }
          expect(status, MdwStatus.ok, reason: 'код mdw: $status');
          try {
            final samples = audio!.samples.asTypedList(audio.length);
            var energy = 0.0;
            var peak = 0.0;
            for (final x in samples) {
              energy += x * x;
              if (x.abs() > peak) peak = x.abs();
            }
            final rms = math.sqrt(energy / samples.length);
            final reason =
                'длительность ${audio.duration}, rms $rms, пик $peak';
            expect(
              audio.duration.inMilliseconds / 1000,
              closeTo(6.6, 0.4),
              reason: reason,
            );
            expect(rms, inInclusiveRange(0.01, 0.5), reason: reason);
            expect(peak, lessThanOrEqualTo(1.5), reason: reason);
          } finally {
            audio?.dispose();
          }
        } finally {
          dir.deleteSync(recursive: true);
        }
      },
      skip: noLibrary,
    );

    test('sample limit is respected', () {
      final (audio, status) = engine!.decodeMemory(
        read('speech/ru.wav'),
        16000,
      );
      expect(status, 0);
      expect(audio!.length, 16000);
      audio.dispose();
    }, skip: noLibrary);
  });
}

/// 16 kHz mono float → WAV 16-bit: a long recording for the chunking test
/// without a 20 MB fixture.
Uint8List _wav16(Float32List samples) {
  final data = ByteData(44 + samples.length * 2);
  void ascii(int at, String text) {
    for (var i = 0; i < text.length; i++) {
      data.setUint8(at + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + samples.length * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little) // PCM
    ..setUint16(22, 1, Endian.little) // mono
    ..setUint32(24, 16000, Endian.little)
    ..setUint32(28, 32000, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    final value = (samples[i].clamp(-1.0, 1.0) * 32767).round();
    data.setInt16(44 + i * 2, value, Endian.little);
  }
  return data.buffer.asUint8List();
}

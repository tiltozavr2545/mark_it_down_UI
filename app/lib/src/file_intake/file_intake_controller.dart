import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markitdown_core/markitdown_core.dart';

import '../conversion/isolated_convert.dart';
import '../conversion/ocr_data.dart';
import '../conversion/speech_data.dart';
import 'picked_file.dart';

enum FileIntakePhase { idle, converting, ready, failed }

/// Файлы, речь в которых распознаётся (`AudioConverter`). Распознавание —
/// минуты, а не секунды, поэтому у них прогресс и кнопка «Остановить».
const _speechKinds = {
  FileKind.mp3,
  FileKind.flac,
  FileKind.ogg,
  FileKind.wav,
  FileKind.mp4,
};

class FileIntakeState {
  final FileIntakePhase phase;
  final StreamInfo? info;
  final ConversionResult? result;
  final ConversionFailure? failure;

  /// Идёт распознавание речи: показывать [speechProgress] и «Остановить».
  final bool transcribing;

  /// 0–100; 0 — звук ещё декодируется или модель загружается.
  final int speechProgress;

  /// «Остановить» нажата — ждём конца текущего 30-секундного окна.
  final bool stopping;

  const FileIntakeState._(
    this.phase, {
    this.info,
    this.result,
    this.failure,
    this.transcribing = false,
    this.speechProgress = 0,
    this.stopping = false,
  });

  const FileIntakeState.idle() : this._(FileIntakePhase.idle);

  const FileIntakeState.converting(
    StreamInfo info, {
    bool transcribing = false,
    int speechProgress = 0,
    bool stopping = false,
  }) : this._(
         FileIntakePhase.converting,
         info: info,
         transcribing: transcribing,
         speechProgress: speechProgress,
         stopping: stopping,
       );

  const FileIntakeState.ready(StreamInfo info, ConversionResult result)
    : this._(FileIntakePhase.ready, info: info, result: result);

  const FileIntakeState.failed(StreamInfo info, ConversionFailure failure)
    : this._(FileIntakePhase.failed, info: info, failure: failure);
}

/// Единая точка приёма файла — см. [PickedFile]. Конвертация запускается
/// автоматически сразу после приёма, без отдельной кнопки — см. план Этапа 1.
class FileIntakeController extends Notifier<FileIntakeState> {
  TranscriptionControl? _control;

  @override
  FileIntakeState build() => const FileIntakeState.idle();

  Future<void> accept(PickedFile file) async {
    final info = StreamInfo.fromHead(
      file.bytes,
      filename: file.filename,
      mimeType: file.mimeType,
      localPath: file.localPath,
    );
    state = FileIntakeState.converting(info);

    TranscriptionSettings? speech;
    TranscriptionControl? control;
    Timer? poll;
    if (_speechKinds.contains(info.detectedType.kind)) {
      speech = await transcriptionSettings();
      if (speech != null) {
        control = _control = TranscriptionControl();
        speech = speech.withControl(control);
        state = FileIntakeState.converting(info, transcribing: true);
        // Прогресс пишет нативный код в общую память — опрашиваем, а не
        // ждём сообщений: изолят занят в whisper_full и не ответит.
        poll = Timer.periodic(const Duration(milliseconds: 500), (_) {
          if (state.phase != FileIntakePhase.converting) return;
          state = FileIntakeState.converting(
            info,
            transcribing: true,
            speechProgress: control!.progress,
            stopping: control.cancelled,
          );
        });
      }
    }

    final ConversionOutcome outcome;
    try {
      outcome = await isolatedConvert(
        file.bytes,
        info,
        ocr: await ocrSettings(),
        transcription: speech,
      );
    } finally {
      poll?.cancel();
      // Освобождать только после конца изолята: нативный код пишет в
      // control до последнего окна.
      _control = null;
      control?.dispose();
    }

    switch (outcome) {
      case ConversionSuccess(result: final result):
        state = FileIntakeState.ready(info, result);
      case ConversionError(failure: final failure):
        state = FileIntakeState.failed(info, failure);
    }
  }

  /// Остановить распознавание речи: уже распознанное придёт результатом с
  /// предупреждением, что расшифровка неполная.
  void stopTranscription() {
    final control = _control;
    if (control == null || state.phase != FileIntakePhase.converting) return;
    control.cancel();
    state = FileIntakeState.converting(
      state.info!,
      transcribing: true,
      speechProgress: control.progress,
      stopping: true,
    );
  }

  void clear() => state = const FileIntakeState.idle();
}

final fileIntakeControllerProvider =
    NotifierProvider<FileIntakeController, FileIntakeState>(
      FileIntakeController.new,
    );

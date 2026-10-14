import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markitdown_core/markitdown_core.dart';

import '../conversion/isolated_convert.dart';
import '../conversion/ocr_data.dart';
import '../conversion/speech_data.dart';
import 'picked_file.dart';

enum FileIntakePhase { idle, converting, ready, failed }

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

  /// Номер последнего принятого файла. Пока идёт конвертация, приём не
  /// закрыт (drop, «Поделиться»), и новый файл заменяет текущий: результат
  /// и `finally` старого вызова не должны трогать состояние нового.
  int _generation = 0;

  @override
  FileIntakeState build() => const FileIntakeState.idle();

  Future<void> accept(PickedFile file) async {
    final generation = _supersede();
    bool current() => generation == _generation;
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
    // Речь распознаёт AudioConverter, и это минуты, а не секунды, — поэтому
    // у его файлов прогресс и кнопка «Остановить».
    if (AudioConverter.handles(info.detectedType.kind)) {
      speech = await transcriptionSettings();
      if (!current()) return; // пока ждали модель, пришёл другой файл
      if (speech != null) {
        control = _control = TranscriptionControl();
        speech = speech.withControl(control);
        state = FileIntakeState.converting(info, transcribing: true);
        // Прогресс пишет нативный код в общую память — опрашиваем, а не
        // ждём сообщений: изолят занят в whisper_full и не ответит.
        poll = Timer.periodic(const Duration(milliseconds: 500), (_) {
          final progress = control!.progress;
          final stopping = control.cancelled;
          // Процент двигается шагами по 5 — без сравнения карточка
          // перестраивалась бы дважды в секунду впустую.
          if (!current() ||
              progress == state.speechProgress && stopping == state.stopping) {
            return;
          }
          state = FileIntakeState.converting(
            info,
            transcribing: true,
            speechProgress: progress,
            stopping: stopping,
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
      if (identical(_control, control)) _control = null;
      control?.dispose();
    }

    if (!current()) return;
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

  void clear() {
    _supersede();
    state = const FileIntakeState.idle();
  }

  /// Текущая конвертация больше не нужна: её распознавание останавливается
  /// (иначе минуты занимало бы процессор впустую), результат отбрасывается.
  int _supersede() {
    _control?.cancel();
    _control = null;
    return ++_generation;
  }
}

final fileIntakeControllerProvider =
    NotifierProvider<FileIntakeController, FileIntakeState>(
      FileIntakeController.new,
    );

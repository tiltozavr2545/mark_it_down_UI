import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markitdown_core/markitdown_core.dart';

import '../conversion/isolated_convert.dart';
import '../conversion/ocr_data.dart';
import 'picked_file.dart';

enum FileIntakePhase { idle, converting, ready, failed }

class FileIntakeState {
  final FileIntakePhase phase;
  final StreamInfo? info;
  final ConversionResult? result;
  final ConversionFailure? failure;

  const FileIntakeState._(this.phase, {this.info, this.result, this.failure});

  const FileIntakeState.idle() : this._(FileIntakePhase.idle);

  const FileIntakeState.converting(StreamInfo info)
    : this._(FileIntakePhase.converting, info: info);

  const FileIntakeState.ready(StreamInfo info, ConversionResult result)
    : this._(FileIntakePhase.ready, info: info, result: result);

  const FileIntakeState.failed(StreamInfo info, ConversionFailure failure)
    : this._(FileIntakePhase.failed, info: info, failure: failure);
}

/// Единая точка приёма файла — см. [PickedFile]. Конвертация запускается
/// автоматически сразу после приёма, без отдельной кнопки — см. план Этапа 1.
class FileIntakeController extends Notifier<FileIntakeState> {
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

    final outcome = await isolatedConvert(
      file.bytes,
      info,
      ocr: await ocrSettings(),
    );

    switch (outcome) {
      case ConversionSuccess(result: final result):
        state = FileIntakeState.ready(info, result);
      case ConversionError(failure: final failure):
        state = FileIntakeState.failed(info, failure);
    }
  }

  void clear() => state = const FileIntakeState.idle();
}

final fileIntakeControllerProvider =
    NotifierProvider<FileIntakeController, FileIntakeState>(
      FileIntakeController.new,
    );

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markitdown_core/markitdown_core.dart';

import 'picked_file.dart';

class FileIntakeState {
  final StreamInfo? info;

  const FileIntakeState({this.info});
}

/// Единая точка приёма файла — см. [PickedFile]. На этапе 0 распознаёт тип
/// и показывает его; конвертация появится на этапе 1.
class FileIntakeController extends Notifier<FileIntakeState> {
  @override
  FileIntakeState build() => const FileIntakeState();

  void accept(PickedFile file) {
    state = FileIntakeState(
      info: StreamInfo.fromHead(
        file.bytes,
        filename: file.filename,
        mimeType: file.mimeType,
      ),
    );
  }

  void clear() => state = const FileIntakeState();
}

final fileIntakeControllerProvider =
    NotifierProvider<FileIntakeController, FileIntakeState>(
      FileIntakeController.new,
    );

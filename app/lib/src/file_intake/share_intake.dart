import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'picked_file.dart';

/// Системное «Поделиться» на Android — третий из четырёх входов. Плагин
/// умеет и iOS, но Share Extension там — отдельный процесс и отдельная
/// задача (см. `docs/client-architecture.md`), поэтому здесь вызывающая
/// сторона включает это только под `Platform.isAndroid`.
///
/// Файлы уже лежат во временном кеше плагина — [SharedMediaFile.path] ведёт
/// на диск, поэтому [PickedFile.bytes] здесь читается через `File.readAsBytes`.
/// Текст и URL (а не файл) этим входом не принимаются — это не то, что
/// конвертирует продукт, см. `docs/project-brief.md`.
class ShareIntake {
  Future<List<PickedFile>> initialFiles() async {
    final media = await ReceiveSharingIntent.instance.getInitialMedia();
    final files = await _toPickedFiles(media);
    await ReceiveSharingIntent.instance.reset();
    return files;
  }

  Stream<List<PickedFile>> fileStream() {
    return ReceiveSharingIntent.instance.getMediaStream().asyncMap(
      _toPickedFiles,
    );
  }

  Future<List<PickedFile>> _toPickedFiles(List<SharedMediaFile> media) async {
    final result = <PickedFile>[];
    for (final shared in media) {
      if (shared.type == SharedMediaType.text ||
          shared.type == SharedMediaType.url) {
        continue;
      }
      final bytes = await File(shared.path).readAsBytes();
      result.add(
        PickedFile(
          bytes: bytes,
          filename: p.basename(shared.path),
          mimeType: shared.mimeType,
          localPath: shared.path,
        ),
      );
    }
    return result;
  }
}

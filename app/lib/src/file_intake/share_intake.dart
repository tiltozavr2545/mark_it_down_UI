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
/// Текст и URL (ссылкой делятся YouTube и браузер) приходят как
/// [SharedInput.link] — для режима «ссылка»; текст без ссылки отбрасывается
/// уже там.
class ShareIntake {
  Future<SharedInput> initial() async {
    final media = await ReceiveSharingIntent.instance.getInitialMedia();
    final input = await _toInput(media);
    await ReceiveSharingIntent.instance.reset();
    return input;
  }

  Stream<SharedInput> stream() {
    return ReceiveSharingIntent.instance.getMediaStream().asyncMap(_toInput);
  }

  Future<SharedInput> _toInput(List<SharedMediaFile> media) async {
    final result = <PickedFile>[];
    String? link;
    for (final shared in media) {
      if (shared.type == SharedMediaType.text ||
          shared.type == SharedMediaType.url) {
        // У текста плагин кладёт сам текст в `path`.
        link ??= shared.path;
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
    return SharedInput(result, link);
  }
}

/// Чем поделились: файлы или текст со ссылкой.
class SharedInput {
  final List<PickedFile> files;
  final String? link;

  const SharedInput(this.files, this.link);
}

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'picked_file.dart';

/// The system "Share" on Android — the third of four intake sources. The
/// plugin supports iOS too, but the Share Extension there is a separate
/// process and a separate task (see `docs/client-architecture.md`), so here
/// the caller enables this only under `Platform.isAndroid`.
///
/// Files already sit in the plugin's temporary cache — [SharedMediaFile.path]
/// points to disk, so [PickedFile.bytes] here is read via
/// `File.readAsBytes`. Text and URLs (YouTube and the browser share as a
/// link) arrive as [SharedInput.link] — for "link" mode; text with no link
/// is already discarded there.
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
        // For text, the plugin puts the text itself into `path`.
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

/// What was shared: files, or text with a link.
class SharedInput {
  final List<PickedFile> files;
  final String? link;

  const SharedInput(this.files, this.link);
}

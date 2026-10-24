import 'dart:typed_data';

/// The common shape all four file sources (file dialog, drag&drop, "Share",
/// clipboard) can produce before reaching the single intake point —
/// [FileIntakeController.accept]. The sources differ only in how these bytes
/// were obtained; branching beyond this point is forbidden, see
/// `docs/client-architecture.md#file-intake-four-inputs-one-entry-point`.
class PickedFile {
  final String? filename;
  final String? mimeType;
  final Uint8List bytes;

  /// Path to the file on disk, if the source knows it (file dialog,
  /// drag&drop, "Share"). Needed by the desktop sidecar so it doesn't have
  /// to write a copy to a temp file; the clipboard has no paths.
  final String? localPath;

  /// The address the file was downloaded from ("link" mode): converters use
  /// it to recognize YouTube and Wikipedia and to resolve relative links.
  final String? url;

  const PickedFile({
    required this.bytes,
    this.filename,
    this.mimeType,
    this.localPath,
    this.url,
  });
}

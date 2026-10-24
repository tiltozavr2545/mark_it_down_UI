import 'dart:typed_data';

import 'type_detection/detected_type.dart';
import 'type_detection/type_detector.dart';

/// What's known about a file before it's parsed: name, size, and what
/// could be told from the content. The fields deliberately mirror
/// markitdown's — see
/// `docs/conversion-pipeline.md#1-распознавание-типа`.
class StreamInfo {
  /// The filename from the source — can be anything, including empty.
  final String? filename;

  /// The extension from [filename], lowercase, without the dot. `null`
  /// if there's no extension — a common case for files from messengers.
  final String? extension;

  /// The MIME type from the OS (drag&drop/share) — often
  /// `application/octet-stream` on Android, can't be trusted.
  final String? mimeType;

  /// The file's full size in bytes.
  final int lengthBytes;

  /// The result of detection by magic bytes.
  final DetectedType detectedType;

  /// The file's path on disk, if it's sitting there (a picker dialog,
  /// drag&drop). Needed by the sidecar, which takes a path argument
  /// rather than bytes; if `null` (clipboard, a nested archive file),
  /// the converter writes a temp file itself. The Dart-core converters
  /// never read it.
  final String? localPath;

  /// The address the file was downloaded from ("paste a link" mode) —
  /// like markitdown's `stream_info.url`: relative links in HTML and
  /// feeds are resolved against it. `null` for files from disk.
  final String? url;

  const StreamInfo({
    required this.filename,
    required this.extension,
    required this.mimeType,
    required this.lengthBytes,
    required this.detectedType,
    this.localPath,
    this.url,
  });

  /// [head] is the first bytes of the file, enough for detection (for
  /// small files, the whole file can be passed). [lengthBytes] is the
  /// file's full size, which can be larger than `head.length`.
  factory StreamInfo.fromHead(
    Uint8List head, {
    String? filename,
    String? mimeType,
    int? lengthBytes,
    String? localPath,
    String? url,
  }) {
    final extension = _extensionOf(filename);
    return StreamInfo(
      filename: filename,
      extension: extension,
      mimeType: mimeType,
      lengthBytes: lengthBytes ?? head.length,
      detectedType: detectType(head, extension: extension),
      localPath: localPath,
      url: url,
    );
  }

  @override
  String toString() =>
      'StreamInfo(filename: $filename, lengthBytes: $lengthBytes, '
      'detectedType: $detectedType)';
}

String? _extensionOf(String? filename) {
  if (filename == null) return null;
  final dot = filename.lastIndexOf('.');
  if (dot <= 0 || dot == filename.length - 1) return null;
  return filename.substring(dot + 1).toLowerCase();
}

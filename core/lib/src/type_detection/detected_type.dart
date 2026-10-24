/// The detected kind of file. `kind` is the stable machine identifier (the
/// converter choice from the registry will rely on it in the future),
/// `label` is the human-readable description for the file intake screen.
enum FileKind {
  docx,
  xlsx,
  pptx,
  epub,
  androidApk,
  zipArchive,
  pdf,
  xls,
  msg,

  /// Legacy `.doc` / `.ppt` (OLE2) — recognized, but there is no converter
  /// either in the Dart core or in markitdown: an honest "not supported"
  /// with the format name instead of a generic "OLE2 container".
  doc,
  ppt,
  ole2Compound,
  png,
  jpeg,
  gif,
  bmp,
  webp,
  tiff,

  /// HEIC/HEIF and AVIF — the ISO BMFF container (`ftyp`) that the iPhone
  /// shoots in. Distinguished only by the brand in `ftyp`.
  heic,

  /// Audio: MP3 (with or without ID3), FLAC, Ogg (Vorbis/Opus), WAV.
  mp3,
  flac,
  ogg,
  wav,

  /// Non-HEIF ISO BMFF: M4A, MP4, MOV, 3GP — audio or video, distinguished
  /// by the tracks inside rather than by signature; [DetectedType.label]
  /// refines it by the `ftyp` brand.
  mp4,
  text,
  emptyFile,
  unknown,
}

class DetectedType {
  final FileKind kind;
  final String label;

  const DetectedType(this.kind, this.label);

  @override
  String toString() => label;

  @override
  bool operator ==(Object other) =>
      other is DetectedType && other.kind == kind && other.label == label;

  @override
  int get hashCode => Object.hash(kind, label);
}

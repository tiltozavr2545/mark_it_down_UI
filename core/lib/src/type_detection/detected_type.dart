/// Распознанный вид файла. `kind` — стабильный машинный идентификатор (на
/// нём в будущем будет держаться выбор конвертера из реестра), `label` —
/// человекочитаемое описание для экрана приёма файла.
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

  /// Старый `.doc` / `.ppt` (OLE2) — распознаётся, но конвертера нет ни в
  /// Dart-ядре, ни в markitdown: честное «не поддерживается» с названием
  /// формата вместо общего «OLE2-контейнер».
  doc,
  ppt,
  ole2Compound,
  png,
  jpeg,
  gif,
  bmp,
  webp,
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

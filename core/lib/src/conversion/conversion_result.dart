/// A non-fatal remark about the conversion — a list, not an exception,
/// because a partial result is more useful than a failure. See
/// `docs/conversion-pipeline.md#3-конвертация`.
class ConversionWarning {
  final String message;

  const ConversionWarning(this.message);

  @override
  String toString() => message;
}

/// The result of successfully converting one file.
class ConversionResult {
  final String markdown;

  /// From the document's metadata, if present (not filled in by any
  /// converter at Stage 1 — will appear for docx/xlsx/pptx at Stage 2).
  final String? title;

  final List<ConversionWarning> warnings;
  final String converterId;
  final Duration elapsed;

  const ConversionResult({
    required this.markdown,
    required this.converterId,
    required this.elapsed,
    this.title,
    this.warnings = const [],
  });

  /// Converters do not measure their own time — [ConverterRegistry] does
  /// that around the `convert()` call, and plugs it in here.
  ConversionResult withElapsed(Duration elapsed) => ConversionResult(
    markdown: markdown,
    converterId: converterId,
    elapsed: elapsed,
    title: title,
    warnings: warnings,
  );

  /// Replaces the [warnings] list — the registry appends a note about the
  /// fallback path (see `ConversionDeclinedException`).
  ConversionResult withWarnings(List<ConversionWarning> warnings) =>
      ConversionResult(
        markdown: markdown,
        converterId: converterId,
        elapsed: elapsed,
        title: title,
        warnings: warnings,
      );
}

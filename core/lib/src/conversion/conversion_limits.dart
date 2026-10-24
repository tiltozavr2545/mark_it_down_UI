/// Limits that the pipeline must check before doing something expensive
/// or dangerous — not protection against an attack, but protection
/// against the app silently eating up memory. See
/// `docs/client-architecture.md#большие-файлы`.
///
/// There is no limit on the size of the file itself: whatever the person
/// chose gets converted, no matter how much it weighs. All three fields
/// are about archives (`zip` inside `zip`), where the volume is unknown
/// upfront and the header cannot be trusted.
class ConversionLimits {
  /// The limit on the total unpacked size of all the archive's nested
  /// files — the only protection against a zip bomb. The top-level source
  /// file itself does not count toward this sum.
  final int maxExtractedBytes;

  /// The maximum recursion depth for nested archives (zip in zip, etc.).
  final int maxRecursionDepth;

  /// The maximum total number of files recursion is willing to go through.
  final int maxFilesInArchive;

  const ConversionLimits({
    this.maxExtractedBytes = 1024 * 1024 * 1024,
    this.maxRecursionDepth = 8,
    this.maxFilesInArchive = 2000,
  });

  static const defaults = ConversionLimits();
}

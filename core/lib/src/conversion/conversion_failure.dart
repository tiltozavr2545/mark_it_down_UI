/// A failure is a result too, and it must be understandable. Three cases,
/// exactly per `docs/conversion-pipeline.md#ошибки`; the raw exception
/// text is never shown to the user — it stays inside the converter/logs,
/// only what has already been phrased in human terms ends up here.
sealed class ConversionFailure {
  const ConversionFailure();
}

/// The format isn't supported by any converter in the registry.
class UnsupportedFormatFailure extends ConversionFailure {
  /// Human-readable label of the detected type (`DetectedType.label`), to
  /// show "what format this is".
  final String detectedTypeLabel;

  const UnsupportedFormatFailure(this.detectedTypeLabel);
}

/// The converter recognized the format, but the file is corrupted.
class CorruptedFileFailure extends ConversionFailure {
  final String converterId;

  /// A short, already human-readable description of where the corruption
  /// is — not a stack trace and not exception text.
  final String reason;

  const CorruptedFileFailure({required this.converterId, required this.reason});
}

/// One of the [ConversionLimits] has been exceeded.
class LimitExceededFailure extends ConversionFailure {
  /// Which limit exactly was exceeded, human-readably ("the number of
  /// files in the archive exceeds the limit of 2000").
  final String description;

  const LimitExceededFailure(this.description);
}

/// "Link" mode: the page or file could not be downloaded (no network, the
/// server returned an error, the link isn't http). Does not concern files
/// from disk.
class NetworkFailure extends ConversionFailure {
  /// What happened, human-readably ("no connection to the server…").
  final String description;

  const NetworkFailure(this.description);
}

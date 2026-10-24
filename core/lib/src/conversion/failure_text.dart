import 'conversion_failure.dart';

/// A short human-readable description of a failure — for `warnings` on a
/// nested file inside a `zip`/`epub`, where the failure itself isn't
/// fatal for the whole archive. Used instead of having every
/// container-converter invent its own text for the cases from
/// `docs/conversion-pipeline.md#ошибки`.
String describeFailure(ConversionFailure failure) => switch (failure) {
  UnsupportedFormatFailure(detectedTypeLabel: final label) =>
    'формат не поддерживается ($label)',
  CorruptedFileFailure(reason: final reason) => reason,
  LimitExceededFailure(description: final description) => description,
  NetworkFailure(description: final description) => description,
};

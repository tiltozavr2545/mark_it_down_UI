import 'conversion_failure.dart';

/// Короткое человекочитаемое описание отказа — для `warnings` на вложенном
/// файле внутри `zip`/`epub`, где сам отказ не фатален для всего архива.
/// Используется вместо того, чтобы каждый конвертер-контейнер придумывал
/// свой текст по трём случаям из `docs/conversion-pipeline.md#ошибки`.
String describeFailure(ConversionFailure failure) => switch (failure) {
  UnsupportedFormatFailure(detectedTypeLabel: final label) =>
    'формат не поддерживается ($label)',
  CorruptedFileFailure(reason: final reason) => reason,
  LimitExceededFailure(description: final description) => description,
};

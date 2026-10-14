/// Отказ — тоже результат, и он обязан быть понятным. Три случая, ровно по
/// `docs/conversion-pipeline.md#ошибки`; сырой текст исключения пользователю
/// никогда не показывается — он остаётся внутри конвертера/логов, сюда
/// попадает только то, что уже сформулировано по-человечески.
sealed class ConversionFailure {
  const ConversionFailure();
}

/// Формат не поддерживается ни одним конвертером в реестре.
class UnsupportedFormatFailure extends ConversionFailure {
  /// Человекочитаемая метка распознанного типа (`DetectedType.label`), чтобы
  /// показать «какой это формат».
  final String detectedTypeLabel;

  const UnsupportedFormatFailure(this.detectedTypeLabel);
}

/// Конвертер опознал формат, но файл повреждён.
class CorruptedFileFailure extends ConversionFailure {
  final String converterId;

  /// Короткое, уже человекочитаемое описание места повреждения — не стек и
  /// не текст исключения.
  final String reason;

  const CorruptedFileFailure({required this.converterId, required this.reason});
}

/// Превышен один из [ConversionLimits].
class LimitExceededFailure extends ConversionFailure {
  /// Какой именно лимит превышен, человекочитаемо («число файлов в архиве
  /// превышает предел 2000»).
  final String description;

  const LimitExceededFailure(this.description);
}

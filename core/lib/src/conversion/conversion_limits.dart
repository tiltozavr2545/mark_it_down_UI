/// Пределы, которые конвейер обязан проверять перед тем, как сделать что-то
/// дорогое или опасное — не защита от атаки, а защита от того, что
/// приложение молча съест память. См.
/// `docs/client-architecture.md#большие-файлы`.
///
/// На Этапе 1 реально проверяется только [maxInMemoryBytes] — остальные два
/// поля задел под `recurse` в `zip`/`epub` (Этап 2): форма контракта
/// фиксируется сразу, чтобы не переезжать типом позже.
class ConversionLimits {
  /// Выше этого размера файл в память целиком не читается — честный отказ
  /// вместо попытки распарсить что-то весом в сотни МБ.
  final int maxInMemoryBytes;

  /// Максимальная глубина рекурсии вложенных архивов (zip в zip и т.п.).
  final int maxRecursionDepth;

  /// Максимальное суммарное число файлов, которые рекурсия готова пройти.
  final int maxFilesInArchive;

  const ConversionLimits({
    this.maxInMemoryBytes = 50 * 1024 * 1024,
    this.maxRecursionDepth = 8,
    this.maxFilesInArchive = 2000,
  });

  static const defaults = ConversionLimits();
}

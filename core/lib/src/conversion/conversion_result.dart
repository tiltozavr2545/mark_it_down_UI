/// Нефатальное замечание о конвертации — список, а не исключение, потому что
/// частичный результат полезнее отказа. См.
/// `docs/conversion-pipeline.md#3-конвертация`.
class ConversionWarning {
  final String message;

  const ConversionWarning(this.message);

  @override
  String toString() => message;
}

/// Результат успешной конвертации одного файла.
class ConversionResult {
  final String markdown;

  /// Из метаданных документа, если есть (на Этапе 1 не заполняется ни одним
  /// конвертером — появится у docx/xlsx/pptx на Этапе 2).
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

  /// Конвертеры не измеряют собственное время — это делает
  /// [ConverterRegistry] вокруг вызова `convert()`, и подставляет его сюда.
  ConversionResult withElapsed(Duration elapsed) => ConversionResult(
    markdown: markdown,
    converterId: converterId,
    elapsed: elapsed,
    title: title,
    warnings: warnings,
  );

  /// Заменяет список [warnings] — реестр дописывает пометку о запасном пути
  /// (см. `ConversionDeclinedException`).
  ConversionResult withWarnings(List<ConversionWarning> warnings) =>
      ConversionResult(
        markdown: markdown,
        converterId: converterId,
        elapsed: elapsed,
        title: title,
        warnings: warnings,
      );
}

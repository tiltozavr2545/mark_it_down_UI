import 'dart:typed_data';

import '../stream_info.dart';
import 'conversion_failure.dart';
import 'conversion_limits.dart';
import 'conversion_request.dart';
import 'conversion_result.dart';
import 'converters/csv_converter.dart';
import 'converters/docx_converter.dart';
import 'converters/epub_converter.dart';
import 'converters/html_converter.dart';
import 'converters/ipynb_converter.dart';
import 'converters/json_converter.dart';
import 'converters/plain_text_converter.dart';
import 'converters/pptx_converter.dart';
import 'converters/xlsx_converter.dart';
import 'converters/xml_converter.dart';
import 'converters/zip_converter.dart';
import 'document_converter.dart';

/// Итог прогона через реестр: либо результат, либо один из трёх понятных
/// отказов. См. `docs/conversion-pipeline.md#ошибки`.
sealed class ConversionOutcome {
  const ConversionOutcome();
}

class ConversionSuccess extends ConversionOutcome {
  final ConversionResult result;

  const ConversionSuccess(this.result);
}

class ConversionError extends ConversionOutcome {
  final ConversionFailure failure;

  const ConversionError(this.failure);
}

/// Хранит конвертеры, отсортированные по [DocumentConverter.priority], и
/// отдаёт файл первому, чей `accepts()` сказал «да». См.
/// `docs/conversion-pipeline.md#2-реестр-конвертеров`.
class ConverterRegistry {
  final List<DocumentConverter> _converters;

  ConverterRegistry(List<DocumentConverter> converters)
    : _converters = [...converters]
        ..sort((a, b) => a.priority.compareTo(b.priority));

  /// Пять текстовых конвертеров Этапа 1 и шесть форматов Этапа 2, в
  /// правильном порядке приоритетов. PDF/сайдкар добавятся на следующих
  /// этапах — реестр это не хардкодит, фабрика просто называет то, что уже
  /// реализовано.
  factory ConverterRegistry.defaultRegistry() => ConverterRegistry([
    const CsvConverter(),
    const JsonConverter(),
    const XmlConverter(),
    const IpynbConverter(),
    const DocxConverter(),
    const XlsxConverter(),
    const PptxConverter(),
    const EpubConverter(),
    const ZipConverter(),
    const HtmlConverter(),
    const PlainTextConverter(),
  ]);

  Future<ConversionOutcome> convert(
    Uint8List bytes,
    StreamInfo info, {
    ConversionLimits limits = ConversionLimits.defaults,
    int depth = 0,
  }) => _convert(
    bytes,
    info,
    limits: limits,
    depth: depth,
    budget: _RecursionBudget(),
  );

  /// Делает всё то же, что [convert], но делит один [_RecursionBudget] со
  /// всеми вложенными вызовами через `recurse` — иначе `maxFilesInArchive` и
  /// суммарный распакованный объём считались бы заново на каждом уровне
  /// вложенности, а не по всему дереву (`zip` в `zip`). См.
  /// `docs/conversion-pipeline.md#3-конвертация`.
  Future<ConversionOutcome> _convert(
    Uint8List bytes,
    StreamInfo info, {
    required ConversionLimits limits,
    required int depth,
    required _RecursionBudget budget,
  }) async {
    if (depth > limits.maxRecursionDepth) {
      return ConversionError(
        LimitExceededFailure(
          'глубина вложенности превышает предел ${limits.maxRecursionDepth}',
        ),
      );
    }

    if (info.lengthBytes > limits.maxInMemoryBytes) {
      return ConversionError(
        LimitExceededFailure(
          'размер файла ${_megabytes(info.lengthBytes)} МБ превышает предел '
          '${_megabytes(limits.maxInMemoryBytes)} МБ',
        ),
      );
    }

    budget.filesVisited++;
    if (budget.filesVisited > limits.maxFilesInArchive) {
      return ConversionError(
        LimitExceededFailure(
          'число файлов в архиве превышает предел ${limits.maxFilesInArchive}',
        ),
      );
    }

    budget.extractedBytes += info.lengthBytes;
    if (budget.extractedBytes > limits.maxInMemoryBytes) {
      return ConversionError(
        LimitExceededFailure(
          'суммарный распакованный размер ${_megabytes(budget.extractedBytes)} МБ '
          'превышает предел ${_megabytes(limits.maxInMemoryBytes)} МБ',
        ),
      );
    }

    final converter = _converters.firstWhereOrNull(
      (c) => c.accepts(info, bytes),
    );
    if (converter == null) {
      return ConversionError(UnsupportedFormatFailure(info.detectedType.label));
    }

    final request = ConversionRequest(
      bytes: bytes,
      info: info,
      limits: limits,
      recurse: (nestedBytes, nestedInfo) => _convert(
        nestedBytes,
        nestedInfo,
        limits: limits,
        depth: depth + 1,
        budget: budget,
      ),
    );

    final stopwatch = Stopwatch()..start();
    try {
      final result = await converter.convert(request);
      return ConversionSuccess(result.withElapsed(stopwatch.elapsed));
    } on ConversionCorruptedException catch (e) {
      return ConversionError(
        CorruptedFileFailure(converterId: converter.id, reason: e.reason),
      );
    } on ConversionLimitExceededException catch (e) {
      return ConversionError(LimitExceededFailure(e.reason));
    } catch (_) {
      return ConversionError(
        CorruptedFileFailure(
          converterId: converter.id,
          reason: 'не удалось прочитать содержимое файла',
        ),
      );
    }
  }
}

/// Общий на всё дерево рекурсии счётчик — см. [ConverterRegistry._convert].
class _RecursionBudget {
  int filesVisited = 0;
  int extractedBytes = 0;
}

String _megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

extension<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}

import 'dart:typed_data';

import '../stream_info.dart';
import 'conversion_failure.dart';
import 'conversion_limits.dart';
import 'conversion_request.dart';
import 'conversion_result.dart';
import 'converters/audio_converter.dart';
import 'converters/csv_converter.dart';
import 'converters/docx_converter.dart';
import 'converters/epub_converter.dart';
import 'converters/html_converter.dart';
import 'converters/image_converter.dart';
import 'converters/ipynb_converter.dart';
import 'converters/json_converter.dart';
import 'converters/pdf_converter.dart';
import 'converters/plain_text_converter.dart';
import 'converters/pptx_converter.dart';
import 'converters/xlsx_converter.dart';
import 'converters/xml_converter.dart';
import 'converters/zip_converter.dart';
import 'document_converter.dart';
import 'ocr/tesseract_ocr.dart';
import 'speech/whisper_transcriber.dart';

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

  /// Пять текстовых конвертеров Этапа 1, шесть форматов Этапа 2, `pdf`
  /// Этапа 3, изображения и аудио Этапа 6, в правильном порядке приоритетов. [extra] — то, что реестр не
  /// хардкодит: на десктопе сюда приезжает `SidecarConverter` (Этап 4),
  /// на мобильных список пуст.
  ///
  /// [ocr] — где лежат модели Tesseract; без него картинки и PDF-сканы
  /// отдаются без распознанного текста (так гоняются фикстуры: их вывод не
  /// должен зависеть от версии движка на машине). [transcription] — то же
  /// для речи в аудио (whisper.cpp).
  factory ConverterRegistry.defaultRegistry({
    List<DocumentConverter> extra = const [],
    OcrSettings? ocr,
    TranscriptionSettings? transcription,
  }) => ConverterRegistry([
    ...extra,
    const CsvConverter(),
    const JsonConverter(),
    const XmlConverter(),
    const IpynbConverter(),
    const DocxConverter(),
    const XlsxConverter(),
    const PptxConverter(),
    const EpubConverter(),
    const ZipConverter(),
    PdfConverter(ocr: ocr),
    ImageConverter(ocr: ocr),
    AudioConverter(transcription: transcription),
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

    budget.filesVisited++;
    if (budget.filesVisited > limits.maxFilesInArchive) {
      return ConversionError(
        LimitExceededFailure(
          'число файлов в архиве превышает предел ${limits.maxFilesInArchive}',
        ),
      );
    }

    // Сам файл верхнего уровня не считается: предела на его размер нет,
    // бюджет — только на то, что из него распаковано.
    if (depth > 0) budget.extractedBytes += info.lengthBytes;
    if (budget.extractedBytes > limits.maxExtractedBytes) {
      return ConversionError(
        LimitExceededFailure(
          'суммарный распакованный размер ${_megabytes(budget.extractedBytes)} МБ '
          'превышает предел ${_megabytes(limits.maxExtractedBytes)} МБ',
        ),
      );
    }

    final candidates = _converters.where((c) => c.accepts(info, bytes));
    if (candidates.isEmpty) {
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

    // Обычно отвечает первый подошедший конвертер, и его отказ окончателен.
    // Исключение — [ConversionDeclinedException] (так отказывается сайдкар):
    // тогда идём к следующему подошедшему, а если он справился — добавляем в
    // результат пометку, что сработал запасной путь. Если запасного нет или
    // он тоже не справился, возвращается отказ первого, а не безликая
    // ошибка последнего.
    ConversionDeclinedException? declined;
    final stopwatch = Stopwatch()..start();
    for (final converter in candidates) {
      try {
        final result = await converter.convert(request);
        final withElapsed = result.withElapsed(stopwatch.elapsed);
        return ConversionSuccess(
          declined == null
              ? withElapsed
              : withElapsed.withWarnings([
                  ConversionWarning(declined.fallbackWarning),
                  ...withElapsed.warnings,
                ]),
        );
      } on ConversionDeclinedException catch (e) {
        declined ??= e;
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
    return ConversionError(declined!.failure);
  }
}

/// Общий на всё дерево рекурсии счётчик — см. [ConverterRegistry._convert].
class _RecursionBudget {
  int filesVisited = 0;
  int extractedBytes = 0;
}

String _megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

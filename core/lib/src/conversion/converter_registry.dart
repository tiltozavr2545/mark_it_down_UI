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
import 'converters/msg_converter.dart';
import 'converters/pdf_converter.dart';
import 'converters/plain_text_converter.dart';
import 'converters/pptx_converter.dart';
import 'converters/rss_converter.dart';
import 'converters/xls_converter.dart';
import 'converters/xlsx_converter.dart';
import 'converters/wikipedia_converter.dart';
import 'converters/xml_converter.dart';
import 'converters/youtube_converter.dart';
import 'converters/zip_converter.dart';
import 'document_converter.dart';
import 'ocr/tesseract_ocr.dart';
import 'speech/whisper_transcriber.dart';
import '../web/web_fetcher.dart';

/// The outcome of a run through the registry: either a result, or one
/// of three clear declines. See
/// `docs/conversion-pipeline.md#ошибки`.
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

/// Holds converters sorted by [DocumentConverter.priority], and hands
/// the file to the first one whose `accepts()` said "yes". See
/// `docs/conversion-pipeline.md#2-реестр-конвертеров`.
class ConverterRegistry {
  final List<DocumentConverter> _converters;

  ConverterRegistry(List<DocumentConverter> converters)
    : _converters = [...converters]
        ..sort((a, b) => a.priority.compareTo(b.priority));

  /// The five text converters from Stage 1, the six formats from Stage
  /// 2, `pdf` from Stage 3, images and audio from Stage 6, in the right
  /// priority order. [extra] is what the registry doesn't hardcode: on
  /// desktop, `SidecarConverter` (Stage 4) arrives here; on mobile the
  /// list is empty.
  ///
  /// [ocr] is where the Tesseract models live; without it, images and
  /// scanned PDFs come out with no recognized text (that's how the
  /// fixtures are run: their output must not depend on the engine
  /// version on the machine). [transcription] is the same for speech in
  /// audio (whisper.cpp). [web] is the network for "link" mode: YouTube
  /// captions; the YouTube and Wikipedia converters only act on pages
  /// downloaded via a link (`StreamInfo.url`), captions need [web].
  factory ConverterRegistry.defaultRegistry({
    List<DocumentConverter> extra = const [],
    OcrSettings? ocr,
    TranscriptionSettings? transcription,
    WebFetcher? web,
  }) => ConverterRegistry([
    ...extra,
    YouTubeConverter(web: web),
    const WikipediaConverter(),
    const CsvConverter(),
    const JsonConverter(),
    const RssConverter(),
    const XmlConverter(),
    const IpynbConverter(),
    const DocxConverter(),
    const XlsxConverter(),
    const XlsConverter(),
    const MsgConverter(),
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

  /// Does everything [convert] does, but shares one [_RecursionBudget]
  /// with all nested calls via `recurse` — otherwise `maxFilesInArchive`
  /// and the total extracted volume would be counted afresh at every
  /// nesting level instead of across the whole tree (a `zip` inside a
  /// `zip`). See
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

    // The top-level file itself isn't counted: there's no limit on its
    // own size, the budget is only for what's extracted from it.
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

    // Normally the first matching converter answers, and its decline is
    // final. The exception is [ConversionDeclinedException] (the way a
    // sidecar declines): then we move to the next match, and if it
    // succeeds, we add a note to the result that the fallback path
    // kicked in. If there's no fallback, or it fails too, the first
    // one's decline is returned, not the last one's faceless error.
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

/// A counter shared across the whole recursion tree — see
/// [ConverterRegistry._convert].
class _RecursionBudget {
  int filesVisited = 0;
  int extractedBytes = 0;
}

String _megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

import 'dart:typed_data';

import '../../markdown_writer.dart' as md;
import '../../stream_info.dart';
import '../../type_detection/detected_type.dart';
import '../../type_detection/zip_family.dart';
import '../conversion_failure.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../converter_registry.dart';
import '../document_converter.dart';
import '../failure_text.dart';

/// A regular archive (not OOXML/EPUB/APK — those are already separated out
/// by `refineZipFamily`) — recursion through `request.recurse` over each
/// file, with limits that [ConverterRegistry] now tracks across the whole
/// tree (`zip` inside `zip`), not this converter. See
/// `docs/conversion-pipeline.md#3-конвертация`.
///
/// An exceeded limit on a nested file is a hard failure for the whole
/// archive (like any other [LimitExceededFailure]), not a warning: the
/// limit signals that it's unsafe to continue, not that one file simply
/// failed to convert. Any other error on a nested file is a warning and a
/// skip — the rest of the archive's files keep processing (a partial
/// result).
///
/// An honest caveat: `archive` unpacks a file's contents in one call, with
/// no way to interrupt it midway — the registry's budget is checked
/// against the actual byte count only after each file has been unpacked,
/// not against its header. This protects against an archive made of many
/// files; it does not protect against a single file that itself expands
/// into gigabytes. For this project's scale that's a deliberate trade-off,
/// not an oversight.
class ZipConverter implements DocumentConverter {
  const ZipConverter();

  @override
  String get id => 'zip';

  @override
  double get priority => 0.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) =>
      info.detectedType.kind == FileKind.zipArchive;

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final archive = decodeZip(request.bytes);
    if (archive == null) {
      throw const ConversionCorruptedException(
        'не удалось прочитать как zip-архив',
      );
    }

    final warnings = <ConversionWarning>[];
    final blocks = <String>[];

    for (final file in archive.files) {
      if (!file.isFile) continue;
      final bytes = file.content;
      final info = StreamInfo.fromHead(bytes, filename: file.name);
      final outcome = await request.recurse(bytes, info);

      switch (outcome) {
        case ConversionSuccess(result: final result):
          blocks.add('${md.heading(2, file.name)}\n\n${result.markdown}');
        case ConversionError(failure: final failure):
          if (failure is LimitExceededFailure) {
            throw ConversionLimitExceededException(failure.description);
          }
          warnings.add(
            ConversionWarning(
              'файл "${file.name}": ${describeFailure(failure)}',
            ),
          );
      }
    }

    return ConversionResult(
      markdown: blocks.join('\n\n'),
      converterId: 'zip',
      elapsed: Duration.zero,
      warnings: warnings,
    );
  }
}

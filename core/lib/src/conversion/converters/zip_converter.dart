import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../markdown_writer.dart' as md;
import '../../stream_info.dart';
import '../../type_detection/detected_type.dart';
import '../conversion_failure.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../converter_registry.dart';
import '../document_converter.dart';
import '../failure_text.dart';

/// Обычный архив (не OOXML/EPUB/APK — те уже разведены `refineZipFamily`) —
/// рекурсия через `request.recurse` по каждому файлу, с лимитами, которые
/// теперь считает [ConverterRegistry] по всему дереву (`zip` в `zip`), а не
/// этот конвертер. См. `docs/conversion-pipeline.md#3-конвертация`.
///
/// Превышенный лимит на вложенном файле — хард-фейл всего архива (как и
/// любой другой [LimitExceededFailure]), а не warning: лимит сигналит, что
/// дальше идти небезопасно, а не что один файл не повезло конвертировать.
/// Любая другая ошибка на вложенном файле — warning и пропуск, остальные
/// файлы архива продолжают обрабатываться (частичный результат).
///
/// Честная оговорка: `archive` распаковывает содержимое файла одним вызовом,
/// без возможности прервать его на середине — бюджет в реестре проверяется
/// по факту полученных байт уже после распаковки каждого файла, а не по
/// заголовку. От архива из множества файлов это защищает; от одного файла,
/// который сам разворачивается в гигабайты, — нет. Для масштаба этого
/// проекта это сознательный компромисс, не недосмотр.
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
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(request.bytes, verify: false);
    } catch (_) {
      throw const ConversionCorruptedException(
        'не удалось прочитать как zip-архив',
      );
    }

    final warnings = <ConversionWarning>[];
    final blocks = <String>[];

    for (final file in archive.files) {
      if (!file.isFile) continue;
      final content = file.content;
      if (content is! List<int>) continue;

      final bytes = Uint8List.fromList(content);
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

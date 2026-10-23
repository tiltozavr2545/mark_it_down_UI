import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../stream_info.dart';
import '../../type_detection/detected_type.dart';
import '../../type_detection/zip_family.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../converter_registry.dart';
import '../document_converter.dart';
import '../failure_text.dart';

/// `META-INF/container.xml` → `content.opf` (порядок глав через `spine`) →
/// каждая глава через `HtmlConverter` Этапа 1, по тому же реестру —
/// `request.recurse`, а не прямой вызов. Ошибка на одной главе не валит всю
/// книгу: `warnings` + главу пропускаем, остальное отдаём. См.
/// `docs/implementation-plan.md#этап-2-office-02`.
class EpubConverter implements DocumentConverter {
  const EpubConverter();

  @override
  String get id => 'epub';

  @override
  double get priority => 0.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) =>
      info.detectedType.kind == FileKind.epub;

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final archive = decodeZip(request.bytes);
    if (archive == null) {
      throw const ConversionCorruptedException(
        'не удалось прочитать как zip-пакет',
      );
    }

    final containerXml = _readXml(archive, 'META-INF/container.xml');
    final opfPath = containerXml
        ?.findAllElements('rootfile')
        .firstOrNull
        ?.getAttribute('full-path');
    if (opfPath == null) {
      throw const ConversionCorruptedException(
        'не найден content.opf (META-INF/container.xml)',
      );
    }

    final opfXml = _readXml(archive, opfPath);
    if (opfXml == null) {
      throw ConversionCorruptedException('файл $opfPath отсутствует в архиве');
    }
    final opfDir = opfPath.contains('/')
        ? opfPath.substring(0, opfPath.lastIndexOf('/'))
        : '';

    final manifest = <String, String>{};
    for (final item in opfXml.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id == null || href == null) continue;
      manifest[id] = opfDir.isEmpty ? href : '$opfDir/$href';
    }

    final warnings = <ConversionWarning>[];
    final chapters = <String>[];

    for (final itemref in opfXml.findAllElements('itemref')) {
      final href = manifest[itemref.getAttribute('idref')];
      if (href == null) continue;

      final file = archive.findFile(href);
      final bytes = file?.content;
      if (bytes == null) {
        warnings.add(ConversionWarning('глава "$href" отсутствует в архиве'));
        continue;
      }

      final info = StreamInfo.fromHead(bytes, filename: href);
      final outcome = await request.recurse(bytes, info);
      switch (outcome) {
        case ConversionSuccess(result: final result):
          chapters.add(result.markdown);
        case ConversionError(failure: final failure):
          warnings.add(
            ConversionWarning('глава "$href": ${describeFailure(failure)}'),
          );
      }
    }

    final title = opfXml
        .findAllElements('title', namespace: '*')
        .firstOrNull
        ?.innerText
        .trim();

    return ConversionResult(
      markdown: chapters.join('\n\n---\n\n'),
      converterId: 'epub',
      elapsed: Duration.zero,
      title: (title == null || title.isEmpty) ? null : title,
      warnings: warnings,
    );
  }
}

XmlDocument? _readXml(Archive archive, String path) {
  final file = archive.findFile(path);
  final content = file?.content;
  if (content == null) return null;
  try {
    return XmlDocument.parse(utf8.decode(content, allowMalformed: true));
  } on XmlException {
    return null;
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

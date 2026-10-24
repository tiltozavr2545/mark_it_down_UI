import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../../markdown_writer.dart' as md;
import '../../stream_info.dart';
import '../../type_detection/detected_type.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';
import '../ooxml/ooxml_package.dart';

/// `ppt/presentation.xml` → slides in order. The slide title (the
/// `title`/`ctrTitle` placeholder) → `##`, the rest of the text as
/// paragraphs, speaker notes as a separate block below the slide. See
/// `docs/implementation-plan.md#этап-2-office-02`.
class PptxConverter implements DocumentConverter {
  const PptxConverter();

  @override
  String get id => 'pptx';

  @override
  double get priority => 0.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) =>
      info.detectedType.kind == FileKind.pptx;

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final pkg = OoxmlPackage.read(request.bytes);
    final presentation = pkg.partXml('ppt/presentation.xml');
    if (presentation == null) {
      throw const ConversionCorruptedException(
        'не удалось разобрать ppt/presentation.xml',
      );
    }

    final rels = pkg.relationshipsFor('ppt/presentation.xml');
    final blocks = <String>[];
    var number = 0;

    for (final sldId in presentation.findAllElements('p:sldId')) {
      number++;
      final path = rels[sldId.getAttribute('r:id')];
      final slideXml = path == null ? null : pkg.partXml(path);
      if (slideXml == null) continue;
      blocks.add(_renderSlide(number, path!, slideXml, pkg));
    }

    return ConversionResult(
      markdown: blocks.join('\n\n'),
      converterId: 'pptx',
      elapsed: Duration.zero,
      title: pkg.coreTitle(),
    );
  }
}

String _renderSlide(
  int number,
  String slidePath,
  XmlDocument slideXml,
  OoxmlPackage pkg,
) {
  String? title;
  final bodyParagraphs = <String>[];

  for (final shape in slideXml.findAllElements('p:sp')) {
    final text = _shapeText(shape);
    if (text.isEmpty) continue;

    final placeholderType = shape
        .findAllElements('p:ph')
        .firstOrNull
        ?.getAttribute('type');
    if (title == null &&
        (placeholderType == 'title' || placeholderType == 'ctrTitle')) {
      title = text;
    } else {
      bodyParagraphs.add(text);
    }
  }

  final blocks = [md.heading(2, title ?? 'Слайд $number'), ...bodyParagraphs];

  final notesPath = pkg.relationshipTargetForType(slidePath, 'notesSlide');
  final notesXml = notesPath == null ? null : pkg.partXml(notesPath);
  final notesText = notesXml == null ? '' : _notesText(notesXml);
  if (notesText.isNotEmpty) {
    blocks.add('${md.bold('Заметки докладчика:')}\n$notesText');
  }

  return blocks.join('\n\n');
}

String _shapeText(XmlElement shape) {
  final txBody = shape.getElement('p:txBody');
  if (txBody == null) return '';
  return txBody
      .findElements('a:p')
      .map(_paragraphText)
      .where((text) => text.isNotEmpty)
      .join('\n');
}

String _notesText(XmlDocument notesXml) => notesXml
    .findAllElements('a:p')
    .map(_paragraphText)
    .where((text) => text.isNotEmpty)
    .join('\n');

String _paragraphText(XmlElement paragraph) => md.escapeInline(
  paragraph.findAllElements('a:t').map((t) => t.innerText).join(),
);

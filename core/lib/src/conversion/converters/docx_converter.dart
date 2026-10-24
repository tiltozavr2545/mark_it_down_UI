import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../../markdown_writer.dart' as md;
import '../../stream_info.dart';
import '../../type_detection/detected_type.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';
import '../ooxml/ooxml_package.dart';

/// `word/document.xml` → Markdown. The first of the OOXML formats, see
/// `docs/implementation-plan.md#этап-2-office-02` for why it's first.
class DocxConverter implements DocumentConverter {
  const DocxConverter();

  @override
  String get id => 'docx';

  @override
  double get priority => 0.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) =>
      info.detectedType.kind == FileKind.docx;

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final pkg = OoxmlPackage.read(request.bytes);
    final document = pkg.partXml('word/document.xml');
    if (document == null) {
      throw const ConversionCorruptedException(
        'не удалось разобрать word/document.xml',
      );
    }
    final body = document.rootElement.getElement('w:body');
    if (body == null) {
      throw const ConversionCorruptedException('в документе нет w:body');
    }

    final rels = pkg.relationshipsFor('word/document.xml');
    final numbering = _Numbering.parse(pkg.partXml('word/numbering.xml'));
    final footnotes = _parseFootnotes(pkg.partXml('word/footnotes.xml'));

    final counterByLevel = <int, int>{};
    final numIdByLevel = <int, int>{};
    final markerWidthByLevel = <int, int>{};
    final usedFootnotes = <String>[];
    final blocks = <String>[];
    // Consecutive list items are joined with a single newline (a tight
    // list); other blocks with a blank line. Otherwise every item would
    // become a "paragraph" of a loose list, doubling the line count in a
    // long list.
    final isListItem = <bool>[];

    for (final child in body.childElements) {
      switch (child.name.qualified) {
        case 'w:p':
          final block = _renderParagraph(
            child,
            rels,
            numbering,
            counterByLevel,
            numIdByLevel,
            markerWidthByLevel,
            usedFootnotes,
          );
          if (block != null && block.text.isNotEmpty) {
            blocks.add(block.text);
            isListItem.add(block.isListItem);
          }
        case 'w:tbl':
          // `md.table` ends with its own `\n` after the last row — without
          // trimming this leaves an extra blank line before the next
          // block, which already adds `\n\n` when joining.
          final table = _renderTable(child).trimRight();
          if (table.isNotEmpty) {
            blocks.add(table);
            isListItem.add(false);
          }
      }
    }

    if (usedFootnotes.isNotEmpty) {
      blocks.add(
        usedFootnotes.map((id) => '[^$id]: ${footnotes[id] ?? ''}').join('\n'),
      );
      isListItem.add(false);
    }

    final markdown = StringBuffer();
    for (var i = 0; i < blocks.length; i++) {
      if (i > 0) {
        markdown.write(isListItem[i] && isListItem[i - 1] ? '\n' : '\n\n');
      }
      markdown.write(blocks[i]);
    }

    return ConversionResult(
      markdown: markdown.toString(),
      converterId: 'docx',
      elapsed: Duration.zero,
      title: pkg.coreTitle(),
    );
  }
}

typedef _Block = ({String text, bool isListItem});

_Block? _renderParagraph(
  XmlElement p,
  Map<String, String> rels,
  _Numbering numbering,
  Map<int, int> counterByLevel,
  Map<int, int> numIdByLevel,
  Map<int, int> markerWidthByLevel,
  List<String> usedFootnotes,
) {
  final pPr = p.getElement('w:pPr');
  final styleId = pPr?.getElement('w:pStyle')?.getAttribute('w:val');
  final numPr = pPr?.getElement('w:numPr');

  final inline = p.childElements
      .where((e) => e.name.qualified != 'w:pPr')
      .map((e) => _renderInline(e, rels, usedFootnotes))
      .join();

  final heading = _headingLevel(styleId);
  if (heading != null) {
    return inline.trim().isEmpty
        ? null
        : (text: md.heading(heading, inline.trim()), isListItem: false);
  }

  if (numPr != null) {
    final ilvl =
        int.tryParse(numPr.getElement('w:ilvl')?.getAttribute('w:val') ?? '') ??
        0;
    final numId =
        int.tryParse(
          numPr.getElement('w:numId')?.getAttribute('w:val') ?? '',
        ) ??
        0;

    // A deeper level under a new parent starts over — counters below the
    // current level don't survive a return to it.
    counterByLevel.removeWhere((level, _) => level > ilvl);
    numIdByLevel.removeWhere((level, _) => level > ilvl);
    markerWidthByLevel.removeWhere((level, _) => level > ilvl);

    if (numIdByLevel[ilvl] != numId) {
      counterByLevel[ilvl] = 1;
    } else {
      counterByLevel[ilvl] = (counterByLevel[ilvl] ?? 0) + 1;
    }
    numIdByLevel[ilvl] = numId;

    final marker = numbering.isBullet(numId, ilvl)
        ? '-'
        : '${counterByLevel[ilvl]}.';
    markerWidthByLevel[ilvl] = marker.length + 1;

    // A nested item is indented by the width of its parent's marker
    // (`- ` — 2, `1. ` — 3, `10. ` — 4): with less indentation CommonMark
    // doesn't treat it as a child, and a list under a numbered item
    // collapses flat. A level with no parent in the document (the list
    // started straight at `ilvl=1`) falls back to 2.
    var indent = 0;
    for (var level = 0; level < ilvl; level++) {
      indent += markerWidthByLevel[level] ?? 2;
    }
    return (text: '${' ' * indent}$marker $inline', isListItem: true);
  }

  return inline.isEmpty ? null : (text: inline, isListItem: false);
}

/// One pass over the direct children of `w:p` (except `w:pPr`) — ordinary
/// `w:r` and `w:hyperlink`, which wraps its `w:r` children in a link as a
/// whole.
String _renderInline(
  XmlElement node,
  Map<String, String> rels,
  List<String> usedFootnotes,
) {
  switch (node.name.qualified) {
    case 'w:r':
      return _renderRun(node, rels, usedFootnotes);
    case 'w:hyperlink':
      final href = rels[node.getAttribute('r:id')];
      final text = node.findAllElements('w:t').map((t) => t.innerText).join();
      return href == null ? md.escapeInline(text) : md.link(text, href);
    default:
      return '';
  }
}

/// One `w:r`: an image placeholder, a footnote, or text with bold/italic.
String _renderRun(
  XmlElement run,
  Map<String, String> rels,
  List<String> usedFootnotes,
) {
  final drawing = run.getElement('w:drawing');
  if (drawing != null) {
    final embedId = drawing
        .findAllElements('a:blip')
        .firstOrNull
        ?.getAttribute('r:embed');
    final target = embedId == null ? null : rels[embedId];
    final name = target == null ? 'image' : target.split('/').last;
    return '![]($name)';
  }

  final footnoteRef = run.getElement('w:footnoteReference');
  if (footnoteRef != null) {
    final id = footnoteRef.getAttribute('w:id') ?? '';
    usedFootnotes.add(id);
    return '[^$id]';
  }

  final text = run.findElements('w:t').map((t) => t.innerText).join();
  if (text.isEmpty) return '';

  final rPr = run.getElement('w:rPr');
  final isBold = rPr?.getElement('w:b') != null;
  final isItalic = rPr?.getElement('w:i') != null;
  if (isBold && isItalic) return '***${md.escapeInline(text)}***';
  if (isBold) return md.bold(text);
  if (isItalic) return md.italic(text);
  return md.escapeInline(text);
}

int? _headingLevel(String? styleId) {
  if (styleId == null) return null;
  final match = RegExp(r'^Heading([1-6])$').firstMatch(styleId);
  return match == null ? null : int.parse(match.group(1)!);
}

/// Markdown tables cannot nest — a nested `w:tbl` inside a cell collapses
/// into flat text (rows joined with `\n`, cells with `|`), not recursive
/// Markdown. Run formatting (bold/italic/links) inside cells is dropped
/// for the same reason: `md.table` escapes cell content itself, and
/// re-escaping already-rendered markup would break it.
String _renderTable(XmlElement tbl) {
  final rows = tbl
      .findElements('w:tr')
      .map((tr) => tr.findElements('w:tc').map(_cellPlainText).toList())
      .toList();
  if (rows.isEmpty) return '';
  final headers = rows.first;
  final body = rows.skip(1).toList();
  return md.table(headers, body);
}

String _cellPlainText(XmlElement tc) {
  final parts = <String>[];
  for (final child in tc.childElements) {
    switch (child.name.qualified) {
      case 'w:p':
        final text = child
            .findAllElements('w:t')
            .map((t) => t.innerText)
            .join();
        if (text.isNotEmpty) parts.add(text);
      case 'w:tbl':
        final nested = child
            .findElements('w:tr')
            .map(
              (tr) => tr.findElements('w:tc').map(_cellPlainText).join(' | '),
            )
            .join('\n');
        if (nested.isNotEmpty) parts.add(nested);
    }
  }
  return parts.join('\n');
}

Map<String, String> _parseFootnotes(XmlDocument? doc) {
  if (doc == null) return const {};
  final result = <String, String>{};
  for (final footnote in doc.findAllElements('w:footnote')) {
    // `separator`/`continuationSeparator` are internal Word bookkeeping
    // entries, not real document footnotes.
    if (footnote.getAttribute('w:type') != null) continue;
    final id = footnote.getAttribute('w:id');
    if (id == null) continue;
    result[id] = footnote.findAllElements('w:t').map((t) => t.innerText).join();
  }
  return result;
}

/// Resolves `numId` → `bullet`/not-`bullet` through `abstractNum`. An
/// unknown `numId` or level falls back to a numbered list — a reasonable
/// default for a list nothing is known about.
class _Numbering {
  final Map<int, int> _numToAbstract;
  final Map<int, Map<int, String>> _abstractLevels;

  const _Numbering(this._numToAbstract, this._abstractLevels);

  factory _Numbering.parse(XmlDocument? doc) {
    if (doc == null) return const _Numbering({}, {});

    final abstractLevels = <int, Map<int, String>>{};
    for (final abstractNum in doc.findAllElements('w:abstractNum')) {
      final id = int.tryParse(
        abstractNum.getAttribute('w:abstractNumId') ?? '',
      );
      if (id == null) continue;
      final levels = <int, String>{};
      for (final lvl in abstractNum.findElements('w:lvl')) {
        final ilvl = int.tryParse(lvl.getAttribute('w:ilvl') ?? '');
        final fmt = lvl.getElement('w:numFmt')?.getAttribute('w:val');
        if (ilvl != null && fmt != null) levels[ilvl] = fmt;
      }
      abstractLevels[id] = levels;
    }

    final numToAbstract = <int, int>{};
    for (final num in doc.findAllElements('w:num')) {
      final numId = int.tryParse(num.getAttribute('w:numId') ?? '');
      final abstractId = int.tryParse(
        num.getElement('w:abstractNumId')?.getAttribute('w:val') ?? '',
      );
      if (numId != null && abstractId != null) {
        numToAbstract[numId] = abstractId;
      }
    }

    return _Numbering(numToAbstract, abstractLevels);
  }

  bool isBullet(int numId, int ilvl) {
    final abstractId = _numToAbstract[numId];
    if (abstractId == null) return false;
    return _abstractLevels[abstractId]?[ilvl] == 'bullet';
  }
}

import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../../markdown_writer.dart' as md;
import '../../stream_info.dart';
import '../../type_detection/detected_type.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';
import '../ooxml/ooxml_package.dart';

/// `word/document.xml` → Markdown. Первый из OOXML-форматов, см.
/// `docs/implementation-plan.md#этап-2-office-02` — почему именно он первый.
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
    final usedFootnotes = <String>[];
    final blocks = <String>[];

    for (final child in body.childElements) {
      switch (child.name.qualified) {
        case 'w:p':
          final block = _renderParagraph(
            child,
            rels,
            numbering,
            counterByLevel,
            numIdByLevel,
            usedFootnotes,
          );
          if (block != null && block.isNotEmpty) blocks.add(block);
        case 'w:tbl':
          // `md.table` заканчивается собственным `\n` после последней
          // строки — без обрезки это даёт лишнюю пустую строку перед
          // следующим блоком, который и так добавляет `\n\n` при склейке.
          final table = _renderTable(child).trimRight();
          if (table.isNotEmpty) blocks.add(table);
      }
    }

    if (usedFootnotes.isNotEmpty) {
      blocks.add(
        usedFootnotes.map((id) => '[^$id]: ${footnotes[id] ?? ''}').join('\n'),
      );
    }

    return ConversionResult(
      markdown: blocks.join('\n\n'),
      converterId: 'docx',
      elapsed: Duration.zero,
      title: pkg.coreTitle(),
    );
  }
}

String? _renderParagraph(
  XmlElement p,
  Map<String, String> rels,
  _Numbering numbering,
  Map<int, int> counterByLevel,
  Map<int, int> numIdByLevel,
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
    return inline.trim().isEmpty ? null : md.heading(heading, inline.trim());
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

    // Более глубокий уровень под новым родителем начинается заново —
    // счётчики ниже текущего уровня не переживают возврат на него.
    counterByLevel.removeWhere((level, _) => level > ilvl);
    numIdByLevel.removeWhere((level, _) => level > ilvl);

    if (numIdByLevel[ilvl] != numId) {
      counterByLevel[ilvl] = 1;
    } else {
      counterByLevel[ilvl] = (counterByLevel[ilvl] ?? 0) + 1;
    }
    numIdByLevel[ilvl] = numId;

    final marker = numbering.isBullet(numId, ilvl)
        ? '-'
        : '${counterByLevel[ilvl]}.';
    return '${'  ' * ilvl}$marker $inline';
  }

  return inline.isEmpty ? null : inline;
}

/// Один прогон по прямым детям `w:p` (кроме `w:pPr`) — обычные `w:r` и
/// `w:hyperlink`, который оборачивает свои `w:r` в ссылку целиком.
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

/// Один `w:r`: картинка-заглушка, сноска, либо текст с полужирным/курсивом.
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

/// Таблицы в Markdown не умеют вкладываться — вложенная `w:tbl` внутри
/// ячейки схлопывается в плоский текст (строки через `\n`, ячейки через
/// `|`), а не рекурсивный Markdown. Форматирование runs (bold/italic/ссылки)
/// внутри ячеек не переносится по той же причине: `md.table` сам
/// экранирует содержимое ячейки, и повторная экранировка уже готовой
/// разметки её бы сломала.
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
    // `separator`/`continuationSeparator` — служебные записи Word, не
    // настоящие сноски документа.
    if (footnote.getAttribute('w:type') != null) continue;
    final id = footnote.getAttribute('w:id');
    if (id == null) continue;
    result[id] = footnote.findAllElements('w:t').map((t) => t.innerText).join();
  }
  return result;
}

/// Резолв `numId` → `bullet`/не-`bullet` через `abstractNum`. Неизвестный
/// `numId` или уровень — фоллбэк на нумерованный список, разумное
/// умолчание для списка, про который ничего не известно.
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

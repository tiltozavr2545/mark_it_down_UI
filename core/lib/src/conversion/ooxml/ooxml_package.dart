import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../document_converter.dart';

/// Тонкая обёртка над `archive` для частей OOXML-пакета (`docx`/`xlsx`/
/// `pptx` — все три одно и то же zip+xml устройство, см.
/// `docs/implementation-plan.md#этап-2-office-02`). `epub` этот слой не
/// использует — у него свой `mimetype`/`container.xml`/`content.opf`.
class OoxmlPackage {
  final Archive _archive;

  OoxmlPackage._(this._archive);

  factory OoxmlPackage.read(Uint8List bytes) {
    try {
      return OoxmlPackage._(ZipDecoder().decodeBytes(bytes, verify: false));
    } catch (_) {
      throw const ConversionCorruptedException(
        'не удалось прочитать как zip-пакет',
      );
    }
  }

  bool hasPart(String path) => _archive.findFile(path) != null;

  Uint8List? partBytes(String path) {
    final file = _archive.findFile(path);
    if (file == null) return null;
    final content = file.content;
    if (content is List<int>) return Uint8List.fromList(content);
    return null;
  }

  /// `null`, если части нет или она не разбирается как XML — отсутствие
  /// необязательной части (например, `numbering.xml`) не повреждённость
  /// файла, конвертер должен просто обойтись без неё.
  XmlDocument? partXml(String path) {
    final bytes = partBytes(path);
    if (bytes == null) return null;
    try {
      return XmlDocument.parse(utf8.decode(bytes, allowMalformed: true));
    } on XmlException {
      return null;
    }
  }

  /// `r:id` → путь, резолвленный относительно директории [partPath], через
  /// `<директория>/_rels/<имя файла>.rels`. Внешние связи
  /// (`TargetMode="External"` — типично гиперссылки на `http(s)://`)
  /// возвращаются как есть, без попытки трактовать их как путь внутри
  /// пакета.
  Map<String, String> relationshipsFor(String partPath) {
    final (dir, doc) = _relationshipsDoc(partPath);
    if (doc == null) return const {};

    final result = <String, String>{};
    for (final rel in doc.findAllElements('Relationship')) {
      final id = rel.getAttribute('Id');
      final target = rel.getAttribute('Target');
      if (id == null || target == null) continue;
      final isExternal =
          rel.getAttribute('TargetMode') == 'External' ||
          target.contains('://');
      result[id] = isExternal ? target : _resolveRelativePath(dir, target);
    }
    return result;
  }

  /// Путь первой связи части [partPath], чей `Type` заканчивается на
  /// [typeSuffix] (например, `notesSlide`) — для случаев, когда нужная
  /// связь ищется по типу, а не по `r:id` из самой части (заметки
  /// докладчика в `pptx` не ссылаются на свою `notesSlide` изнутри XML).
  String? relationshipTargetForType(String partPath, String typeSuffix) {
    final (dir, doc) = _relationshipsDoc(partPath);
    if (doc == null) return null;
    for (final rel in doc.findAllElements('Relationship')) {
      final type = rel.getAttribute('Type');
      final target = rel.getAttribute('Target');
      if (type != null && target != null && type.endsWith(typeSuffix)) {
        return _resolveRelativePath(dir, target);
      }
    }
    return null;
  }

  (String, XmlDocument?) _relationshipsDoc(String partPath) {
    final slash = partPath.lastIndexOf('/');
    final dir = slash < 0 ? '' : partPath.substring(0, slash);
    final name = slash < 0 ? partPath : partPath.substring(slash + 1);
    final relsPath = dir.isEmpty ? '_rels/$name.rels' : '$dir/_rels/$name.rels';
    return (dir, partXml(relsPath));
  }

  /// `docProps/core.xml` → `<dc:title>`, общее для всех трёх форматов.
  String? coreTitle() {
    final doc = partXml('docProps/core.xml');
    if (doc == null) return null;
    final title = doc
        .findAllElements('title', namespace: '*')
        .firstOrNull
        ?.innerText
        .trim();
    return (title == null || title.isEmpty) ? null : title;
  }
}

/// `target` относительно `baseDir`, с разрешением `..`/`.` — Target в
/// `.rels` пишется относительно директории той части, к которой относится
/// файл связей, а не относительно корня пакета.
String _resolveRelativePath(String baseDir, String target) {
  final combined = baseDir.isEmpty ? target : '$baseDir/$target';
  final segments = <String>[];
  for (final segment in combined.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isNotEmpty) segments.removeLast();
    } else {
      segments.add(segment);
    }
  }
  return segments.join('/');
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../type_detection/zip_family.dart';

import '../document_converter.dart';

/// A thin wrapper over `archive` for parts of an OOXML package
/// (`docx`/`xlsx`/`pptx` — all three are the same zip+xml setup, see
/// `docs/implementation-plan.md#этап-2-office-02`). `epub` doesn't use
/// this layer — it has its own `mimetype`/`container.xml`/`content.opf`.
class OoxmlPackage {
  final Archive _archive;

  OoxmlPackage._(this._archive);

  factory OoxmlPackage.read(Uint8List bytes) {
    final archive = decodeZip(bytes);
    if (archive == null) {
      throw const ConversionCorruptedException(
        'не удалось прочитать как zip-пакет',
      );
    }
    return OoxmlPackage._(archive);
  }

  bool hasPart(String path) => _archive.findFile(path) != null;

  Uint8List? partBytes(String path) {
    return _archive.findFile(path)?.content;
  }

  /// `null` if the part is missing or doesn't parse as XML — a missing
  /// optional part (e.g. `numbering.xml`) isn't file corruption, the
  /// converter should simply do without it.
  XmlDocument? partXml(String path) {
    final bytes = partBytes(path);
    if (bytes == null) return null;
    try {
      return XmlDocument.parse(utf8.decode(bytes, allowMalformed: true));
    } on XmlException {
      return null;
    }
  }

  /// `r:id` → a path resolved relative to [partPath]'s directory, via
  /// `<directory>/_rels/<file name>.rels`. External relationships
  /// (`TargetMode="External"` — typically hyperlinks to `http(s)://`)
  /// are returned as-is, with no attempt to treat them as a path inside
  /// the package.
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

  /// The path of the first relationship of part [partPath] whose `Type`
  /// ends with [typeSuffix] (e.g. `notesSlide`) — for cases where the
  /// needed relationship is looked up by type rather than by an `r:id`
  /// from the part itself (speaker notes in `pptx` don't reference their
  /// own `notesSlide` from inside the XML).
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

  /// `docProps/core.xml` → `<dc:title>`, common to all three formats.
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

/// `target` relative to `baseDir`, resolving `..`/`.` — a Target in
/// `.rels` is written relative to the directory of the part the
/// relationships file belongs to, not relative to the package root. The
/// exception is a `Target` with a leading `/`: it's absolute, from the
/// package root (that's how openpyxl writes it:
/// `/xl/worksheets/sheet1.xml`), and the base directory isn't prepended
/// to it.
String _resolveRelativePath(String baseDir, String target) {
  final combined = baseDir.isEmpty || target.startsWith('/')
      ? target
      : '$baseDir/$target';
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

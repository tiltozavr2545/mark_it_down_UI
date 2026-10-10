import 'dart:convert';

import '../../type_detection/detected_type.dart';

/// Какие форматы сайдкар знает по id (`--format` в его протоколе) и каким
/// [FileKind] они соответствуют. Идентификатор из манифеста, которого здесь
/// нет, игнорируется: приложение не обязано уметь всё, что умеет сайдкар.
const Map<String, FileKind> sidecarFormatKinds = {
  'pdf': FileKind.pdf,
  'docx': FileKind.docx,
  'xlsx': FileKind.xlsx,
  'xls': FileKind.xls,
  'pptx': FileKind.pptx,
  'msg': FileKind.msg,
};

/// `manifest.json` сайдкара — какие форматы он берёт на себя и чем собран.
/// См. `docs/python-sidecar.md`.
class SidecarManifest {
  /// Единственная известная версия схемы. Любая другая — сайдкар из будущего
  /// (или чужой), и регистрировать то, чей протокол мы не знаем, нельзя.
  static const supportedSchema = 1;

  final String markitdownVersion;
  final String pythonVersion;

  /// Только форматы, которые приложение знает (см. [sidecarFormatKinds]).
  final Set<String> formats;

  const SidecarManifest({
    required this.markitdownVersion,
    required this.pythonVersion,
    required this.formats,
  });

  /// `null` на всё, что не манифест версии 1: невалидный JSON, не объект,
  /// другая `schema`, нет списка `formats`, или в нём нет ни одного
  /// известного формата. Не бросает — «битый манифест» означает «сайдкара
  /// нет», а не падение приложения.
  static SidecarManifest? tryParse(String source) {
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException {
      return null;
    }
    if (json is! Map<String, Object?>) return null;
    if (json['schema'] != supportedSchema) return null;

    final rawFormats = json['formats'];
    if (rawFormats is! List) return null;
    final formats = {
      for (final f in rawFormats)
        if (f is String && sidecarFormatKinds.containsKey(f)) f,
    };
    if (formats.isEmpty) return null;

    final markitdown = json['markitdown'];
    final python = json['python'];
    return SidecarManifest(
      markitdownVersion: markitdown is String ? markitdown : '?',
      pythonVersion: python is String ? python : '?',
      formats: formats,
    );
  }
}

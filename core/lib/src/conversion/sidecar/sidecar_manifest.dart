import 'dart:convert';

import '../../type_detection/detected_type.dart';

/// Which formats the sidecar knows by id (`--format` in its protocol) and
/// which [FileKind] they correspond to. An identifier from the manifest
/// that isn't here is ignored: the app isn't obligated to know everything
/// the sidecar knows.
const Map<String, FileKind> sidecarFormatKinds = {
  'pdf': FileKind.pdf,
  'docx': FileKind.docx,
  'xlsx': FileKind.xlsx,
  'xls': FileKind.xls,
  'pptx': FileKind.pptx,
  'msg': FileKind.msg,
};

/// The sidecar's `manifest.json` — which formats it takes on and what it
/// was built from. See `docs/python-sidecar.md`.
class SidecarManifest {
  /// The only known schema version. Any other — the sidecar is from the
  /// future (or a stranger), and registering a protocol we don't know is
  /// not allowed.
  static const supportedSchema = 1;

  final String markitdownVersion;
  final String pythonVersion;

  /// Only the formats the app knows about (see [sidecarFormatKinds]).
  final Set<String> formats;

  const SidecarManifest({
    required this.markitdownVersion,
    required this.pythonVersion,
    required this.formats,
  });

  /// `null` for anything that isn't a version-1 manifest: invalid JSON,
  /// not an object, a different `schema`, no `formats` list, or not a
  /// single known format in it. Does not throw — a "broken manifest"
  /// means "there's no sidecar", not an app crash.
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

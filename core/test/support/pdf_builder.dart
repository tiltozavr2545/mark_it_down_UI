import 'dart:convert';
import 'dart:typed_data';

/// Builds a minimal valid PDF out of [pageCount] blank pages — just
/// enough to test decisions that depend on the page count (the sidecar
/// threshold) without multi-page fixtures in the repository. The pages
/// have no text: the Dart converter will return empty Markdown with a
/// warning.
Uint8List buildBlankPdf(int pageCount) {
  // 1 — the catalog, 2 — the page tree, 3.. — the pages.
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Count $pageCount '
        '/Kids [${[for (var i = 0; i < pageCount; i++) '${i + 3} 0 R'].join(' ')}] >>',
    for (var i = 0; i < pageCount; i++)
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>',
  ];

  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length); // ASCII only — characters equal bytes
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xrefOffset = out.length;
  out
    ..write('xref\n0 ${objects.length + 1}\n')
    ..write('0000000000 65535 f \n');
  for (final offset in offsets) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out
    ..write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n')
    ..write('startxref\n$xrefOffset\n%%EOF\n');
  return Uint8List.fromList(ascii.encode(out.toString()));
}

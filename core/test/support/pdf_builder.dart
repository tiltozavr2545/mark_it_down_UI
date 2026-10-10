import 'dart:convert';
import 'dart:typed_data';

/// Собирает минимальный валидный PDF из [pageCount] пустых страниц — ровно
/// настолько, чтобы проверить решения, зависящие от числа страниц (порог
/// сайдкара), без многостраничных фикстур в репозитории. Текста на страницах
/// нет: Dart-конвертер отдаст пустой Markdown с предупреждением.
Uint8List buildBlankPdf(int pageCount) {
  // 1 — каталог, 2 — дерево страниц, 3.. — страницы.
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
    offsets.add(out.length); // только ASCII — символы равны байтам
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

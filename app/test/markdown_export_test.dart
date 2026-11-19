import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:markitdown_ui/src/markdown_export.dart';

void main() {
  test(
    'separate Markdown files keep their content and avoid collisions',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'markitdown-export-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final existing = File.fromUri(folder.uri.resolve('notes.md'));
      await existing.writeAsString('Existing Markdown');
      final names = <String>{};

      final results = await Future.wait([
        saveMarkdownInDirectory(
          folder,
          base: markdownBase(filename: 'notes.docx'),
          markdown: '# Один\n',
          usedNames: names,
        ),
        saveMarkdownInDirectory(
          folder,
          base: markdownBase(filename: 'notes.pdf'),
          markdown: '# Два\n',
          usedNames: names,
        ),
      ]);

      expect(await existing.readAsString(), 'Existing Markdown');
      expect(
        results.map((file) => file.uri.pathSegments.last),
        unorderedEquals(['notes (2).md', 'notes (3).md']),
      );
      expect(await results[0].readAsString(), '# Один\n');
      expect(await results[1].readAsString(), '# Два\n');
    },
  );

  test('names are valid for .md on Windows and preserve Unicode', () {
    expect(markdownBase(filename: 'CON.report.pdf'), '_CON.report');
    expect(markdownBase(title: '../Лекции: семестр?'), '.. Лекции семестр');
    expect(markdownBase(title: '.'), 'converted');
    expect(markdownBase(title: '📄' * 62), '📄' * 60);
  });
}

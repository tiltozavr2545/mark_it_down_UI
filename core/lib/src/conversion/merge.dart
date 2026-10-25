import '../markdown_writer.dart' as md;
import 'conversion_result.dart';

/// One already-converted source in a merge: the name its heading shows and
/// its result. [url] is set for a page fetched by link — then the heading is
/// a link to it.
class MergePart {
  final String name;
  final String? url;
  final ConversionResult result;

  const MergePart(this.name, this.result, {this.url});
}

/// Joins several converted files into one document, in the order given:
/// each file under a `# name` heading, files separated by `---`.
///
/// The file's own Markdown goes in as-is, headings included — the author's
/// decision: shifting them a level down would make the merge differ from
/// converting the same file alone. Warnings are kept, each prefixed with
/// the file's name, otherwise "a scan with no text" can't be traced back to
/// one of five PDFs.
///
/// Nothing here converts: the parts are results that already succeeded. A
/// file that failed never gets this far — the merge list doesn't allow
/// merging while one is in it (author's decision: an error stops the whole
/// merge rather than leaving a gap in it).
ConversionResult mergeResults(List<MergePart> parts) {
  final blocks = [
    for (final part in parts)
      [
        md.heading(
          1,
          part.url == null
              ? md.escapeInline(part.name)
              : md.link(part.name, part.url!),
        ),
        // Leading blank lines would double the gap after the heading, and a
        // trailing newline would leave one before the separator; spaces at
        // the start of the first line can be an indented code block, so
        // only line breaks are trimmed there.
        part.result.markdown.replaceFirst(RegExp(r'^(\s*\n)+'), '').trimRight(),
      ].where((block) => block.isNotEmpty).join('\n\n'),
  ];
  return ConversionResult(
    markdown: '${blocks.join('\n\n---\n\n')}\n',
    converterId: 'merge',
    elapsed: parts.fold(
      Duration.zero,
      (sum, part) => sum + part.result.elapsed,
    ),
    warnings: [
      for (final part in parts)
        for (final warning in part.result.warnings)
          ConversionWarning('${part.name}: ${warning.message}'),
    ],
  );
}

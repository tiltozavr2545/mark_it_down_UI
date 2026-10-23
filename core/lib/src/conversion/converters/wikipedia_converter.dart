import 'dart:typed_data';

import 'package:html/parser.dart' as html_parser;

import '../../stream_info.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';
import 'html_converter.dart';
import 'youtube_converter.dart' show isHtml;

/// Статья Wikipedia (режим «ссылка»): только содержимое статьи
/// (`#mw-content-text`) под её заголовком, без меню, боковых панелей и
/// скриптов. Порт `WikipediaConverter` markitdown; HTML → Markdown — тот же
/// `html2md`, что у [HtmlConverter].
class WikipediaConverter implements DocumentConverter {
  const WikipediaConverter();

  @override
  String get id => 'wikipedia';

  @override
  double get priority => 0.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) {
    final url = info.url;
    if (url == null ||
        !RegExp(r'^https?://[a-zA-Z]{2,3}\.wikipedia\.org/').hasMatch(url)) {
      return false;
    }
    return isHtml(info, head);
  }

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final document = html_parser.parse(decodeHtmlBytes(request));
    final body = document.querySelector('div#mw-content-text');
    if (body == null) return const HtmlConverter().convert(request);

    var title =
        document.querySelector('span.mw-page-title-main')?.text ??
        document.querySelector('title')?.text;
    title = title?.trim();
    if (title != null && title.isEmpty) title = null;

    // «[править | править код]» у каждого раздела — кнопки, а не текст.
    for (final edit in body.querySelectorAll('.mw-editsection')) {
      edit.remove();
    }
    final markdown = htmlToMarkdown(body, baseUrl: request.info.url);
    return ConversionResult(
      markdown: title == null ? markdown : '# $title\n\n$markdown',
      converterId: id,
      elapsed: Duration.zero,
      title: title,
    );
  }
}

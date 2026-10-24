import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:html2md/html2md.dart' as html2md;
import 'package:xml/xml.dart';

import '../../markdown_writer.dart' as md;
import '../../stream_info.dart';
import '../../text_decoding.dart';
import '../../type_detection/detected_type.dart';
import '../conversion_failure.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';
import 'html_converter.dart' show resolveHtmlLinks, resolveUrl;

/// An RSS 2.0 or Atom feed → Markdown: channel title, then a section per
/// entry (title, date, description and full text). A port of markitdown's
/// `RssConverter` — the same choice of fields, the same rules for the Atom
/// types `text`/`html`/`xhtml` and `xml:base`; HTML inside entries is
/// converted to Markdown by the same `html2md` as [HtmlConverter], not
/// markdownify, so body markup can differ from markitdown in small ways.
///
/// Accepts `.rss`/`.atom` and XML whose root is `<rss>` or `<feed>`
/// (including a file with no extension, and a server response fetched by
/// link). If parsing shows it's not a feed, declines in favor of
/// [XmlConverter].
class RssConverter implements DocumentConverter {
  const RssConverter();

  @override
  String get id => 'rss';

  @override
  double get priority => 0.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) {
    if (info.detectedType.kind != FileKind.text) return false;
    final extension = info.extension;
    if (extension == 'rss' || extension == 'atom') return true;
    final mime = (info.mimeType ?? '').toLowerCase();
    if (mime.startsWith('application/rss') ||
        mime.startsWith('application/atom')) {
      return true;
    }
    final candidate =
        extension == null ||
        extension == 'xml' ||
        mime.startsWith('text/xml') ||
        mime.startsWith('application/xml');
    return candidate && _feedRootPattern.hasMatch(_asciiHead(head));
  }

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(decodeTextBytes(request.bytes).content);
    } on XmlException {
      throw _notAFeed;
    }
    final feed = _Feed(document, request.info.url ?? '');
    final (markdown, title) = switch (feed.type) {
      'rss' => feed.rss(),
      'atom' => feed.atom(),
      _ => throw _notAFeed,
    };
    return ConversionResult(
      markdown: md.normalizeLikeMarkitdown(markdown).trim(),
      converterId: id,
      elapsed: Duration.zero,
      title: title,
    );
  }
}

/// Not a feed — let [XmlConverter] show it; if it can't either, the user
/// will see that.
const _notAFeed = ConversionDeclinedException(
  failure: CorruptedFileFailure(
    converterId: 'rss',
    reason: 'не удалось разобрать ленту RSS/Atom',
  ),
  fallbackWarning: 'файл похож на ленту RSS/Atom, но разобрать её не удалось',
);

/// The document root after the XML declaration, comments and DOCTYPE.
final _feedRootPattern = RegExp(
  r'^\s*(?:<\?[\s\S]*?\?>\s*|<!--[\s\S]*?-->\s*|<!DOCTYPE[^>]*>\s*)*'
  r'<(?:rss|(?:[\w.-]+:)?feed)[\s/>]',
);

String _asciiHead(Uint8List head) {
  final buffer = StringBuffer();
  var start = 0;
  if (head.length >= 3 && head[0] == 0xEF && head[1] == 0xBB) start = 3;
  for (var i = start; i < head.length && i < start + 4096; i++) {
    buffer.writeCharCode(head[i] < 0x80 ? head[i] : 0x20);
  }
  return buffer.toString();
}

const _atomNamespace = 'http://www.w3.org/2005/Atom';
const _xhtmlNamespace = 'http://www.w3.org/1999/xhtml';
const _contentNamespace = 'http://purl.org/rss/1.0/modules/content/';
const _xmlNamespace = 'http://www.w3.org/XML/1998/namespace';

/// Boundaries that stay as line breaks when markup is reduced to plain
/// text (titles, dates). Inline elements don't add whitespace:
/// `co<b>op</b>erate` is one word.
const _textBreakElements = {
  'address', 'article', 'aside', 'blockquote', 'br', 'dd', 'div', 'dl', //
  'dt', 'figcaption', 'figure', 'footer', 'h1', 'h2', 'h3', 'h4', 'h5', //
  'h6', 'header', 'hr', 'li', 'main', 'nav', 'ol', 'p', 'pre', 'section', //
  'table', 'td', 'th', 'tr', 'ul',
};

enum _Kind { text, html, xhtml, binary }

class _Feed {
  final XmlDocument document;
  final String documentUrl;

  _Feed(this.document, this.documentUrl);

  XmlElement get root => document.rootElement;

  String? get type {
    if (root.name.qualified == 'rss') return 'rss';
    final ns = root.name.namespaceUri;
    if (root.name.local == 'feed' &&
        (ns == null || ns == _atomNamespace) &&
        _children(root, 'entry').isNotEmpty) {
      return 'atom';
    }
    return null;
  }

  (String, String?) rss() {
    final channel = _child(root, 'channel');
    if (channel == null) throw _notAFeed;
    final channelTitle = _flattened(channel, 'title');
    // The channel description is text, while entry descriptions are HTML.
    final channelDescription = _data(channel, 'description', _Kind.text);
    final out = StringBuffer();
    if (channelTitle != null) out.write('# $channelTitle\n');
    if (channelDescription != null) out.write('$channelDescription\n');
    for (final item in _children(channel, 'item')) {
      final title = _flattened(item, 'title');
      final description = _data(item, 'description', _Kind.html);
      final published = _flattened(item, 'pubDate');
      final content = _data(item, 'content:encoded', _Kind.html);
      if (title != null) out.write('\n## $title\n');
      if (published != null) out.write('Published on: $published\n');
      final body = [
        for (final (value, tag) in [
          (description, 'description'),
          (content, 'content:encoded'),
        ])
          if (value != null) _htmlToMarkdown(value, _fieldBase(item, tag)),
      ].where((part) => part.isNotEmpty).join('\n\n');
      _appendBody(out, body);
    }
    return (out.toString(), channelTitle);
  }

  (String, String?) atom() {
    final title = _flattened(root, 'title', atomText: true);
    final subtitle = _flattened(root, 'subtitle', atomText: true);
    final out = StringBuffer();
    if (title != null) out.write('# $title\n');
    if (subtitle != null) out.write('$subtitle\n');
    for (final entry in _children(root, 'entry')) {
      final entryTitle = _flattened(entry, 'title', atomText: true);
      final summary = _atomContent(entry, 'summary');
      final updated = _flattened(entry, 'updated');
      final content = _atomContent(entry, 'content');
      if (entryTitle != null) out.write('\n## $entryTitle\n');
      if (updated != null) out.write('Updated on: $updated\n');
      final body = [
        for (final (value, tag) in [(summary, 'summary'), (content, 'content')])
          if (value.$1 case final text? when text.isNotEmpty)
            value.$2 ? _htmlToMarkdown(text, _fieldBase(entry, tag)) : text,
      ].where((part) => part.isNotEmpty).join('\n\n');
      _appendBody(out, body);
    }
    return (out.toString(), title);
  }

  void _appendBody(StringBuffer out, String body) {
    if (body.isEmpty) return;
    final current = out.toString();
    if (current.isNotEmpty && !current.endsWith('\n')) out.write('\n\n');
    out.write(body);
  }

  /// Fields are picked among direct children in the owner's namespace —
  /// not borrowing `<title>` from nested elements.
  List<XmlElement> _children(XmlElement element, String tag) {
    final String? namespace;
    final String local;
    if (tag == 'content:encoded') {
      namespace = _contentNamespace;
      local = 'encoded';
    } else {
      namespace = element.name.namespaceUri;
      local = tag;
    }
    return element.childElements
        .where((c) => c.name.namespaceUri == namespace && c.name.local == local)
        .toList();
  }

  XmlElement? _child(XmlElement element, String tag) =>
      _children(element, tag).firstOrNull;

  String? _data(XmlElement element, String tag, _Kind kind) {
    final node = _child(element, tag);
    if (node == null) return null;
    final text = _readContent(node, kind);
    return text.isEmpty ? null : text;
  }

  /// A value for a title or a date line: indentation the feed was wrapped
  /// with is stripped — otherwise `#` would end up alone and the heading
  /// would fall into the body text.
  String? _flattened(XmlElement element, String tag, {bool atomText = false}) {
    String? value;
    if (atomText) {
      final (text, isMarkup) = _atomContent(element, tag);
      value = text != null && text.isNotEmpty && isMarkup
          ? _plainTextOfHtml(text)
          : text;
    } else {
      value = _data(element, tag, _Kind.text);
    }
    if (value == null) return null;
    final parts = _splitLines(
      value,
    ).map((p) => p.trim()).where((p) => p.isNotEmpty);
    return parts.isEmpty ? null : parts.join(' ');
  }

  /// Atom text (`title`, `summary`) or `content`, plus an "is markup" flag.
  (String?, bool) _atomContent(XmlElement entry, String tag) {
    final node = _child(entry, tag);
    if (node == null) return (null, true);
    final kind = _atomKind(
      node.getAttribute('type') ?? '',
      allowMediaTypes: tag == 'content',
    );
    if (kind == _Kind.binary) return (null, true);
    var text = _readContent(node, kind);
    if (kind != _Kind.text) return (text.isEmpty ? null : text, true);
    // Plain text carries no markup: only the indentation the element was
    // laid out with in the feed is stripped — otherwise it would read as
    // a code block.
    final lines = _splitLines(text);
    if (lines.length > 1) {
      text = '${lines.first}\n${_dedent(lines.sublist(1))}';
    }
    return (text.trim(), false);
  }

  /// The `type` attribute per RFC 4287 (3.1 and 4.1.3.1): text constructs
  /// only get `text`/`html`/`xhtml`, while `content` also gets a MIME
  /// type.
  _Kind _atomKind(String type, {required bool allowMediaTypes}) {
    type = type.trim().toLowerCase();
    if (type.isEmpty || type == 'text') return _Kind.text;
    if (type == 'html') return _Kind.html;
    if (type == 'xhtml') return _Kind.xhtml;
    if (!allowMediaTypes) return _Kind.text;
    final media = type.split(';').first.trim();
    if (media == 'text/html') return _Kind.html;
    if (media.endsWith('+xml') || media.endsWith('/xml')) return _Kind.xhtml;
    if (media.startsWith('text/')) return _Kind.text;
    return _Kind.binary;
  }

  /// Text, HTML-encoded text, or embedded XML — in document order. Text
  /// right inside an HTML-kind field is the HTML string itself; text
  /// inside real XML elements is literal and gets escaped. The traversal
  /// uses a stack: nesting comes straight from the file.
  String _readContent(XmlElement element, _Kind kind) {
    final parts = StringBuffer();
    final stack = <Object>[...element.children.reversed];
    while (stack.isNotEmpty) {
      final child = stack.removeLast();
      if (child is String) {
        parts.write(child);
      } else if (child is XmlText || child is XmlCDATA) {
        final text = (child as XmlNode).value ?? '';
        if (kind == _Kind.text ||
            (kind == _Kind.html && identical(child.parent, element))) {
          parts.write(text);
        } else {
          parts.write(_escape(text));
        }
      } else if (child is XmlElement) {
        if (kind == _Kind.text) {
          if (_textBreakElements.contains(child.name.local.toLowerCase())) {
            parts.write('\n');
            stack.add('\n');
          }
        } else {
          final name = child.name.namespaceUri == _xhtmlNamespace
              ? child.name.local
              : child.name.qualified;
          final attrs = child.attributes
              .map(
                (a) =>
                    ' ${a.name.qualified}="${_escape(a.value, quote: true)}"',
              )
              .join();
          if (child.children.isNotEmpty) {
            parts.write('<$name$attrs>');
            stack.add('</$name>');
          } else {
            parts.write('<$name$attrs/>');
          }
        }
        stack.addAll(child.children.reversed);
      }
    }
    return parts.toString();
  }

  /// `xml:base` from the root down to field [tag]: relative overrides are
  /// resolved against the parent's base, with the document's own address
  /// as the starting point.
  String _fieldBase(XmlElement element, String tag) {
    final bases = <String>[];
    XmlNode? node = _child(element, tag);
    while (node != null) {
      if (node is XmlElement) {
        // The `xml:` prefix is bound to the XML namespace implicitly, and
        // `package:xml` doesn't resolve that — hence trying the qualified
        // name too.
        final base =
            node.getAttribute('base', namespace: _xmlNamespace) ??
            node.getAttribute('xml:base');
        if (base != null) bases.add(base);
      }
      node = node.parent;
    }
    var base = documentUrl;
    for (final reference in bases.reversed) {
      base = resolveUrl(base, reference);
    }
    return base;
  }
}

/// Entry HTML → Markdown, with relative links and images resolved
/// against [baseUrl] and nested `xml:base`.
String _htmlToMarkdown(String html, String baseUrl) {
  try {
    final fragment = html_parser.parseFragment(html);
    if (baseUrl.isNotEmpty) resolveHtmlLinks(fragment, baseUrl);
    return html2md.convert(fragment.outerHtml).trim();
  } catch (_) {
    return html;
  }
}

/// Plain text of HTML: line breaks around block elements.
String _plainTextOfHtml(String html) {
  final buffer = StringBuffer();
  void walk(dom.Node node) {
    if (node is dom.Text) {
      buffer.write(node.text);
      return;
    }
    final block =
        node is dom.Element && _textBreakElements.contains(node.localName);
    if (block) buffer.write('\n');
    for (final child in node.nodes) {
      walk(child);
    }
    if (block) buffer.write('\n');
  }

  walk(html_parser.parseFragment(html));
  return buffer.toString();
}

List<String> _splitLines(String text) {
  final lines = text.split(RegExp(r'\r\n|\r|\n'));
  // Like `str.splitlines()`: a trailing line break doesn't produce an
  // empty final line.
  if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
  return lines;
}

/// `textwrap.dedent`: the common indentation of non-blank lines is
/// stripped; lines made up only of whitespace become empty.
String _dedent(List<String> lines) {
  String? common;
  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final indent = RegExp(r'^[ \t]*').firstMatch(line)!.group(0)!;
    if (common == null) {
      common = indent;
    } else {
      var i = 0;
      while (i < common.length && i < indent.length && common[i] == indent[i]) {
        i++;
      }
      common = common.substring(0, i);
    }
  }
  final cut = common?.length ?? 0;
  return lines
      .map((line) => line.trim().isEmpty ? '' : line.substring(cut))
      .join('\n');
}

String _escape(String text, {bool quote = false}) {
  var result = text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  if (quote) {
    result = result.replaceAll('"', '&quot;').replaceAll("'", '&#x27;');
  }
  return result;
}

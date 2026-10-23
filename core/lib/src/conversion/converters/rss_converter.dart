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

/// Лента RSS 2.0 или Atom → Markdown: заголовок канала, по разделу на
/// запись (заголовок, дата, описание и полный текст). Порт `RssConverter`
/// markitdown — тот же выбор полей, те же правила для Atom-типов
/// `text`/`html`/`xhtml` и `xml:base`; HTML внутри записей переводит в
/// Markdown тот же `html2md`, что и [HtmlConverter], а не markdownify,
/// поэтому разметка тел может отличаться от markitdown мелочами.
///
/// Берёт `.rss`/`.atom` и XML, у которого корень — `<rss>` или `<feed>`
/// (в том числе файл без расширения и ответ сервера по ссылке). Если
/// разбор показал, что это не лента, отказывается в пользу [XmlConverter].
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

/// Не лента — пусть XML покажет [XmlConverter]; если и он не сможет,
/// пользователь увидит это.
const _notAFeed = ConversionDeclinedException(
  failure: CorruptedFileFailure(
    converterId: 'rss',
    reason: 'не удалось разобрать ленту RSS/Atom',
  ),
  fallbackWarning: 'файл похож на ленту RSS/Atom, но разобрать её не удалось',
);

/// Корень документа после объявления XML, комментариев и DOCTYPE.
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

/// Границы, которые остаются переводами строки, когда разметка сводится к
/// плоскому тексту (заголовки, даты). Строчные элементы пробелов не дают:
/// `co<b>op</b>erate` — одно слово.
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
    // Описание канала — текст, а описания записей — HTML.
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

  /// Поля выбираются среди прямых потомков в пространстве имён владельца —
  /// не заимствуя `<title>` у вложенных элементов.
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

  /// Значение для заголовка или строки с датой: отступы, которыми ленту
  /// раскладывают по строкам, убираются — иначе `#` остался бы один, а
  /// заголовок ушёл бы в текст.
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

  /// Текст Atom (`title`, `summary`) или `content` и флаг «это разметка».
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
    // Простой текст разметки не несёт: снимается только отступ, которым
    // элемент выложен в ленте, — иначе он прочитался бы как блок кода.
    final lines = _splitLines(text);
    if (lines.length > 1) {
      text = '${lines.first}\n${_dedent(lines.sublist(1))}';
    }
    return (text.trim(), false);
  }

  /// Атрибут `type` по RFC 4287 (3.1 и 4.1.3.1): у текстовых конструкций
  /// только `text`/`html`/`xhtml`, у `content` — ещё и MIME-тип.
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

  /// Текст, закодированный HTML или встроенный XML — в порядке документа.
  /// Текст прямо в поле HTML-записи — сама HTML-строка; текст внутри
  /// настоящих XML-элементов — буквальный и экранируется. Обход — стеком:
  /// вложенность приходит из файла.
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

  /// `xml:base` от корня до поля [tag]: относительные переопределения
  /// разрешаются от базы родителя, начало — адрес самого документа.
  String _fieldBase(XmlElement element, String tag) {
    final bases = <String>[];
    XmlNode? node = _child(element, tag);
    while (node != null) {
      if (node is XmlElement) {
        // Префикс `xml:` связан с пространством имён XML неявно, и
        // `package:xml` его не разрешает — поэтому и по полному имени.
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

/// HTML записи → Markdown, с относительными ссылками и картинками,
/// разрешёнными от [baseUrl] и вложенных `xml:base`.
String _htmlToMarkdown(String html, String baseUrl) {
  try {
    final fragment = html_parser.parseFragment(html);
    if (baseUrl.isNotEmpty) resolveHtmlLinks(fragment, baseUrl);
    return html2md.convert(fragment.outerHtml).trim();
  } catch (_) {
    return html;
  }
}

/// Плоский текст HTML: переводы строки вокруг блочных элементов.
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
  // Как `str.splitlines()`: завершающий перевод строки не даёт пустой
  // последней строки.
  if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
  return lines;
}

/// `textwrap.dedent`: общий отступ непустых строк снимается, строки из
/// одних пробелов становятся пустыми.
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

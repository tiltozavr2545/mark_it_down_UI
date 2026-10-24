import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:html2md/html2md.dart' as html2md;

import '../../stream_info.dart';
import '../../text_decoding.dart';
import '../../type_detection/detected_type.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';

/// A generic format, but not a true catch-all: priority sits between
/// specific formats (`0.0`) and `plain text` (`10.0`), and `accepts()`
/// checks for real HTML signals — otherwise it would claim any text file
/// before `plain text` got a chance. See
/// `docs/conversion-pipeline.md#2-реестр-конвертеров`.
class HtmlConverter implements DocumentConverter {
  const HtmlConverter();

  @override
  String get id => 'html';

  @override
  double get priority => 9.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) {
    if (info.detectedType.kind != FileKind.text) return false;
    if (info.extension == 'html' || info.extension == 'htm') return true;
    // A page fetched from a URL: the server itself says it's HTML.
    final mime = (info.mimeType ?? '').toLowerCase();
    if (mime.startsWith('text/html') || mime.startsWith('application/xhtml')) {
      return true;
    }
    return _looksLikeHtml(head);
  }

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final document = html_parser.parse(decodeHtmlBytes(request));
    final title = document.querySelector('title')?.text.trim();

    String markdown;
    try {
      markdown = htmlToMarkdown(
        document.body ?? document.documentElement ?? document,
        baseUrl: request.info.url,
      );
    } catch (_) {
      throw const ConversionCorruptedException('не удалось разобрать HTML');
    }

    return ConversionResult(
      markdown: markdown,
      converterId: 'html',
      elapsed: Duration.zero,
      title: (title == null || title.isEmpty) ? null : title,
    );
  }
}

/// HTML → Markdown via `html2md`, like markitdown: `script`/`style` are
/// stripped first (otherwise the page's CSS ends up in the text), then, if
/// the page's address is known ([baseUrl]), relative links and images are
/// resolved against it — `/wiki/…` in text copied out of the app would
/// otherwise lead nowhere.
String htmlToMarkdown(dom.Node root, {String? baseUrl}) {
  for (final junk in _querySelectorAll(
    root,
    'script, style, noscript, template',
  )) {
    junk.remove();
  }
  if (baseUrl != null && baseUrl.isNotEmpty) resolveHtmlLinks(root, baseUrl);
  final html = switch (root) {
    dom.Element(:final outerHtml) => outerHtml,
    dom.Document(:final outerHtml) => outerHtml,
    dom.DocumentFragment(:final outerHtml) => outerHtml,
    _ => root.text ?? '',
  };
  return html2md.convert(html);
}

List<dom.Element> _querySelectorAll(dom.Node root, String selector) =>
    switch (root) {
      dom.Element() => root.querySelectorAll(selector),
      dom.Document() => root.querySelectorAll(selector),
      dom.DocumentFragment() => root.querySelectorAll(selector),
      _ => const [],
    };

/// Resolves `href` on links and `src`/`data-src` on images against
/// [baseUrl], honoring nested `xml:base` (Atom feeds). Stack-based
/// traversal: the nesting comes from the network.
void resolveHtmlLinks(dom.Node root, String baseUrl) {
  final stack = <(dom.Node, String)>[(root, baseUrl)];
  while (stack.isNotEmpty) {
    final (node, inherited) = stack.removeLast();
    var current = inherited;
    if (node is dom.Element) {
      final override = node.attributes['xml:base'];
      if (override != null) current = resolveUrl(inherited, override);
      final attributes = switch (node.localName) {
        'a' => const ['href'],
        'img' => const ['src', 'data-src'],
        _ => const <String>[],
      };
      for (final attribute in attributes) {
        final reference = node.attributes[attribute];
        // An anchor on the same page (`#cite_note-1`) — leave it: that way
        // it still reads in the text as a footnote link.
        if (reference == null || reference.startsWith('#')) continue;
        if (reference.isNotEmpty || attribute == 'href') {
          node.attributes[attribute] = resolveUrl(current, reference);
        }
      }
    }
    for (final child in node.nodes) {
      stack.add((child, current));
    }
  }
}

/// [reference] against [base]; a malformed address is returned as-is.
/// `Uri` percent-encodes Cyrillic as `%D0%A0…` — such sequences are
/// decoded back (`/wiki/Расширение`), while structural ASCII characters
/// (`%20`, `%29`) stay encoded: otherwise a space or a parenthesis would
/// break the Markdown link.
String resolveUrl(String base, String reference) {
  if (base.isEmpty) return reference;
  final String resolved;
  try {
    resolved = Uri.parse(base).resolve(reference).toString();
  } on FormatException {
    return reference;
  }
  return resolved.replaceAllMapped(RegExp(r'(?:%[89A-Fa-f][0-9A-Fa-f])+'), (m) {
    final run = m.group(0)!;
    final bytes = [
      for (var i = 0; i < run.length; i += 3)
        int.parse(run.substring(i + 1, i + 3), radix: 16),
    ];
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return run;
    }
  });
}

bool _looksLikeHtml(Uint8List head) {
  final sample = StringBuffer();
  for (final byte in head.take(2048)) {
    if (byte < 128) sample.writeCharCode(byte);
  }
  final text = sample.toString().toLowerCase();
  return text.contains('<html') ||
      text.contains('<!doctype html') ||
      text.contains('<body');
}

/// HTML text: encoding from the response's `Content-Type`
/// (`charset=windows-1251`) when the page was fetched from a URL,
/// otherwise the same guess used for any text ([decodeTextBytes]).
String decodeHtmlBytes(ConversionRequest request) {
  final charset = RegExp(
    r'charset\s*=\s*"?([\w-]+)',
    caseSensitive: false,
  ).firstMatch(request.info.mimeType ?? '')?.group(1)?.toLowerCase();
  final codepage = switch (charset) {
    'utf-8' || 'utf8' => 65001,
    'windows-1251' || 'cp1251' => 1251,
    'windows-1252' || 'cp1252' => 1252,
    'koi8-r' => 20866,
    'iso-8859-1' || 'latin1' => 28591,
    'ibm866' || 'cp866' => 866,
    _ => null,
  };
  if (codepage == null || codepage == 65001) {
    return decodeTextBytes(request.bytes).content;
  }
  return decodeCodepage(request.bytes, codepage);
}

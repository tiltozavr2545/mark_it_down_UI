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

/// Общий формат, но не настоящий catch-all: приоритет между конкретными
/// форматами (`0.0`) и `plain text` (`10.0`), и `accepts()` проверяет
/// реальные html-сигналы — иначе он забрал бы себе любой текстовый файл
/// раньше `plain text`. См. `docs/conversion-pipeline.md#2-реестр-конвертеров`.
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
    // Страница по ссылке: сервер сам говорит, что это HTML.
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

/// HTML → Markdown через `html2md`, как у markitdown: сначала выбрасываются
/// `script`/`style` (иначе CSS страницы попадает в текст), затем, если
/// известен адрес страницы ([baseUrl]), относительные ссылки и картинки
/// разрешаются от него — `/wiki/…` в тексте, скопированном из приложения,
/// никуда не ведёт.
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

/// Разрешает `href` ссылок и `src`/`data-src` картинок от [baseUrl], с
/// учётом вложенных `xml:base` (лента Atom). Обход стеком: вложенность
/// приходит из сети.
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
        // Якорь на той же странице (`#cite_note-1`) — оставить: так он
        // читается в тексте как ссылка на сноску.
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

/// [reference] от [base]; битый адрес — как есть. `Uri` кодирует
/// кириллицу в `%D0%A0…` — такие последовательности раскодируются обратно
/// (`/wiki/Расширение`), а служебные ASCII-символы (`%20`, `%29`) остаются
/// закодированными: иначе пробел или скобка сломали бы Markdown-ссылку.
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

/// Текст HTML: кодировка из `Content-Type` ответа (`charset=windows-1251`),
/// если страница скачана по ссылке, иначе — та же догадка, что для любого
/// текста ([decodeTextBytes]).
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

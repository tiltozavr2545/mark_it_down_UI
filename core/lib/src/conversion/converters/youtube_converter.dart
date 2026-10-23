import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import '../../markdown_writer.dart' as md;
import '../../stream_info.dart';
import '../../text_decoding.dart';
import '../../web/url_conversion.dart';
import '../../web/web_fetcher.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';
import 'html_converter.dart';

/// Страница видео YouTube (режим «ссылка») → название, просмотры, ключевые
/// слова, длительность, описание и субтитры. Порт `YouTubeConverter`
/// markitdown — тот же вид Markdown. Субтитры markitdown берёт пакетом
/// `youtube_transcript_api`; здесь — тот же путь руками: ключ InnerTube со
/// страницы, запрос `player` от имени Android-клиента (ответ веб-клиента
/// без токена субтитры не отдаёт), XML дорожки. Это не официальный API:
/// YouTube его меняет, поэтому сбой субтитров — предупреждение, а не отказ.
///
/// Без [web] (тесты, файл `.html` с диска) субтитры не запрашиваются.
class YouTubeConverter implements DocumentConverter {
  const YouTubeConverter({this.web});

  final WebFetcher? web;

  @override
  String get id => 'youtube';

  @override
  double get priority => 0.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) {
    final url = info.url;
    if (url == null || youtubeVideoId(url) == null) return false;
    return isHtml(info, head);
  }

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final html = decodeTextBytes(request.bytes).content;
    final document = html_parser.parse(html);
    final metadata = _metadata(document);
    final playerResponse = _jsonAfter(html, 'var ytInitialPlayerResponse = ');
    final details = playerResponse?['videoDetails'];

    final initialData = _jsonAfter(html, 'var ytInitialData = ');
    final description = _findKey(initialData, 'attributedDescriptionBodyText');
    if (description is Map && description['content'] is String) {
      metadata['description'] = description['content'] as String;
    }

    final out = StringBuffer();
    final title = _first(metadata, ['title', 'og:title', 'name']) ?? '';
    if (title.isNotEmpty) out.write('\n## $title\n');

    final stats = StringBuffer();
    final views =
        _first(metadata, ['interactionCount']) ??
        (details is Map ? details['viewCount'] as String? : null);
    if (views != null) stats.write('- **Views:** $views\n');
    final keywords = _first(metadata, ['keywords']);
    if (keywords != null) stats.write('- **Keywords:** $keywords\n');
    final runtime = _first(metadata, ['duration']);
    if (runtime != null) stats.write('- **Runtime:** $runtime\n');
    if (stats.isNotEmpty) out.write('\n### Video Metadata\n$stats\n');

    final text = _first(metadata, ['description', 'og:description']);
    if (text != null) out.write('\n### Description\n$text\n');

    final warnings = <ConversionWarning>[];
    final videoId = youtubeVideoId(request.info.url!);
    final fetcher = web;
    if (fetcher != null && videoId != null) {
      final transcript = await _transcript(fetcher, html, videoId, warnings);
      if (transcript != null) out.write('\n### Transcript\n$transcript\n');
    } else {
      warnings.add(
        const ConversionWarning(
          'субтитры не запрашивались: нет доступа к сети',
        ),
      );
    }

    if (out.isEmpty) {
      // Не страница видео (капча, заглушка) — как у markitdown, обычный HTML.
      return const HtmlConverter().convert(request);
    }
    return ConversionResult(
      markdown: md.normalizeLikeMarkitdown('# YouTube\n$out').trim(),
      converterId: id,
      elapsed: Duration.zero,
      title: title.isEmpty ? null : title,
      warnings: warnings,
    );
  }
}

/// Номер видео из ссылки YouTube (`watch?v=`, `youtu.be/`, `shorts/`,
/// `embed/`) или `null`.
String? youtubeVideoId(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final host = uri.host.toLowerCase();
  final parts = uri.pathSegments.where((p) => p.isNotEmpty).toList();
  if (host == 'youtu.be' || host == 'www.youtu.be') {
    return parts.firstOrNull;
  }
  if (host == 'youtube.com' ||
      host == 'www.youtube.com' ||
      host == 'm.youtube.com') {
    if (parts.firstOrNull == 'watch') return uri.queryParameters['v'];
    if ((parts.firstOrNull == 'shorts' || parts.firstOrNull == 'embed') &&
        parts.length > 1) {
      return parts[1];
    }
  }
  return null;
}

/// HTML по ответу сервера, расширению или содержимому.
bool isHtml(StreamInfo info, Uint8List head) {
  final mime = (info.mimeType ?? '').toLowerCase();
  if (mime.startsWith('text/html') || mime.startsWith('application/xhtml')) {
    return true;
  }
  final extension = info.extension;
  if (extension == 'html' || extension == 'htm') return true;
  return const HtmlConverter().accepts(info, head);
}

/// `<title>` и `<meta>` с `itemprop`/`property`/`name` — как словарь у
/// markitdown: более поздний тег с тем же ключом перекрывает ранний.
Map<String, String> _metadata(dom.Document document) {
  final metadata = <String, String>{};
  final title = document.querySelector('title')?.text;
  if (title != null && title.isNotEmpty) metadata['title'] = title;
  for (final meta in document.querySelectorAll('meta')) {
    for (final attribute in meta.attributes.keys) {
      if (attribute case 'itemprop' || 'property' || 'name') {
        final key = meta.attributes[attribute] ?? '';
        final content = meta.attributes['content'] ?? '';
        if (key.isNotEmpty && content.isNotEmpty) metadata[key] = content;
        break;
      }
    }
  }
  return metadata;
}

String? _first(Map<String, String> metadata, List<String> keys) {
  for (final key in keys) {
    if (metadata.containsKey(key)) return metadata[key];
  }
  return null;
}

/// JSON-объект, который на странице идёт сразу после [marker]
/// (`var ytInitialData = {…};`). Конец ищется по балансу скобок с учётом
/// строк — регулярное выражение на мегабайтном JSON ненадёжно.
Map<String, dynamic>? _jsonAfter(String html, String marker) {
  final start = html.indexOf(marker);
  if (start < 0) return null;
  final open = start + marker.length;
  if (open >= html.length || html[open] != '{') return null;
  var depth = 0;
  var inString = false;
  for (var i = open; i < html.length; i++) {
    final c = html.codeUnitAt(i);
    if (inString) {
      if (c == 0x5C) {
        i++; // экранированный символ
      } else if (c == 0x22) {
        inString = false;
      }
      continue;
    }
    if (c == 0x22) {
      inString = true;
    } else if (c == 0x7B) {
      depth++;
    } else if (c == 0x7D && --depth == 0) {
      try {
        final value = jsonDecode(html.substring(open, i + 1));
        return value is Map<String, dynamic> ? value : null;
      } on FormatException {
        return null;
      }
    }
  }
  return null;
}

/// Первое значение по ключу где угодно в дереве JSON — обход стеком.
Object? _findKey(Object? json, String key) {
  final stack = <Object?>[json];
  while (stack.isNotEmpty) {
    final node = stack.removeLast();
    if (node is Map) {
      if (node.containsKey(key)) return node[key];
      stack.addAll(node.values.toList().reversed);
    } else if (node is List) {
      stack.addAll(node.reversed);
    }
  }
  return null;
}

/// Текст субтитров одной строкой, как у markitdown, или `null` (причина —
/// в [warnings]).
Future<String?> _transcript(
  WebFetcher fetcher,
  String html,
  String videoId,
  List<ConversionWarning> warnings,
) async {
  const unavailable = ConversionWarning(
    'субтитры получить не удалось — YouTube мог изменить способ их выдачи',
  );
  final key = RegExp(
    r'"INNERTUBE_API_KEY"\s*:\s*"([^"]+)"',
  ).firstMatch(html)?.group(1);
  if (key == null) {
    warnings.add(unavailable);
    return null;
  }
  try {
    final player = await fetcher.postJson(
      Uri.https('www.youtube.com', '/youtubei/v1/player', {'key': key}),
      {
        'context': {
          'client': {'clientName': 'ANDROID', 'clientVersion': '20.10.38'},
        },
        'videoId': videoId,
      },
      headers: youtubeConsentHeaders(Uri.https('www.youtube.com')),
    );
    if (!player.ok) {
      warnings.add(unavailable);
      return null;
    }
    final response = jsonDecode(utf8.decode(player.body));
    final tracks = _findKey(response, 'captionTracks');
    if (tracks is! List || tracks.isEmpty) {
      warnings.add(const ConversionWarning('у видео нет субтитров'));
      return null;
    }
    final track = _pickTrack(tracks.whereType<Map>().toList());
    final baseUrl = track?['baseUrl'];
    if (baseUrl is! String) {
      warnings.add(unavailable);
      return null;
    }
    final xml = await fetcher.get(
      Uri.parse(baseUrl.replaceAll('&fmt=srv3', '')),
    );
    if (!xml.ok) {
      warnings.add(unavailable);
      return null;
    }
    final document = XmlDocument.parse(utf8.decode(xml.body));
    final parts = [
      for (final text in document.findAllElements('text'))
        // В XML сущности экранированы дважды (`&amp;#39;`): после разбора
        // XML остаётся HTML-сущность.
        html_parser
            .parseFragment(text.innerText)
            .text!
            .replaceAll('\n', ' ')
            .trim(),
    ].where((p) => p.isNotEmpty);
    if (parts.isEmpty) {
      warnings.add(const ConversionWarning('субтитры у видео пустые'));
      return null;
    }
    final language = track!['languageCode'];
    final generated = track['kind'] == 'asr';
    warnings.add(
      ConversionWarning(
        'субтитры${language is String ? ' ($language)' : ''} взяты с '
        'YouTube${generated ? ' — созданы автоматически, возможны ошибки' : ''}',
      ),
    );
    return parts.join(' ');
  } on WebFetchException catch (e) {
    warnings.add(ConversionWarning('субтитры не скачались: ${e.reason}'));
    return null;
  } on FormatException {
    warnings.add(unavailable);
    return null;
  } on XmlException {
    warnings.add(unavailable);
    return null;
  }
}

/// Какую дорожку брать. Язык самого видео — у автоматической (`asr`):
/// YouTube распознаёт речь на языке оригинала. Лучше всего — ручные
/// субтитры на этом языке; дальше ручные русские, английские; затем
/// автоматические; затем любая.
Map? _pickTrack(List<Map> tracks) {
  bool manual(Map t) => t['kind'] != 'asr';
  String language(Map t) =>
      (t['languageCode'] as String? ?? '').split('-').first.toLowerCase();
  final original = tracks.where((t) => !manual(t)).map(language).firstOrNull;
  for (final wanted in [?original, 'ru', 'en']) {
    final found = tracks
        .where((t) => manual(t) && language(t) == wanted)
        .firstOrNull;
    if (found != null) return found;
  }
  return tracks.where((t) => !manual(t)).firstOrNull ?? tracks.firstOrNull;
}

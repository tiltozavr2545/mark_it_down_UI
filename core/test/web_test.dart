import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';
import 'package:markitdown_core/src/conversion/converters/youtube_converter.dart'
    show youtubeVideoId;
import 'package:test/test.dart';

/// "Link" mode without real internet access: a local HTTP server instead
/// of websites and a swapped-in [WebFetcher] instead of YouTube. Live
/// checks (YouTube, Wikipedia, PDF by link) are manual, see
/// `docs/format-coverage.md#решения-09-ссылки`.
void main() {
  group('parseUserUrl', () {
    test('link as-is', () {
      expect(
        parseUserUrl(' https://example.com/a?b=1 ').toString(),
        'https://example.com/a?b=1',
      );
    });

    test(
      'link inside "Share" text — the first one, without a trailing period',
      () {
        expect(
          parseUserUrl('Смотри: https://youtu.be/abc123. Классно!').toString(),
          'https://youtu.be/abc123',
        );
      },
    );

    test('no scheme — https', () {
      expect(
        parseUserUrl('ru.wikipedia.org/wiki/Markdown').toString(),
        'https://ru.wikipedia.org/wiki/Markdown',
      );
    });

    test('not a link — null', () {
      expect(parseUserUrl('просто текст'), isNull);
      expect(parseUserUrl(''), isNull);
      expect(parseUserUrl('ftp://example.com/file'), isNull);
    });
  });

  group('convertUrl via a local server', () {
    late HttpServer server;
    late String base;
    final registry = ConverterRegistry.defaultRegistry();

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        final response = request.response;
        switch (request.uri.path) {
          case '/page':
            response.headers.contentType = ContentType.html;
            response.write(
              '<html><head><title>Страница</title>'
              '<style>body{color:red}</style><script>var x=1;</script>'
              '</head><body><h1>Заголовок</h1>'
              '<p>Текст со <a href="/wiki/Ссылка">ссылкой</a> и '
              '<a href="#note">сноской</a>.</p></body></html>',
            );
          case '/cp1251':
            response.headers.set(
              'Content-Type',
              'text/html; charset=windows-1251',
            );
            response.add(_cp1251('<html><body><p>Привет</p></body></html>'));
          case '/download':
            response.headers
              ..set('Content-Type', 'application/octet-stream')
              ..set(
                'Content-Disposition',
                "attachment; filename*=UTF-8''%D0%B4%D0%B0%D0%BD%D0%BD%D1%8B%D0%B5.csv",
              );
            response.write('a,b\n1,2\n');
          case '/feed':
            // Without a charset `write` encodes as Latin-1 — the bytes are written as-is.
            response.headers.set('Content-Type', 'application/rss+xml');
            response.add(
              utf8.encode(
                '<rss><channel><title>Лента</title><item><title>Запись</title>'
                '<description>&lt;a href="/post"&gt;пост&lt;/a&gt;</description>'
                '</item></channel></rss>',
              ),
            );
          case '/old':
            response.redirect(Uri.parse('$base/page'));
          default:
            response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });
    });

    tearDownAll(() => server.close(force: true));

    Future<UrlConversion> convert(String path) =>
        convertUrl('$base$path', registry);

    ConversionResult success(UrlConversion c) =>
        (c.outcome as ConversionSuccess).result;

    test(
      'HTML: no script/style, links are relative to the page address',
      () async {
        final c = await convert('/page');
        final result = success(c);
        expect(result.converterId, 'html');
        expect(result.title, 'Страница');
        expect(result.markdown, isNot(contains('color:red')));
        expect(result.markdown, isNot(contains('var x')));
        expect(result.markdown, contains('[ссылкой]($base/wiki/Ссылка)'));
        expect(result.markdown, contains('[сноской](#note)'));
        expect(c.info!.url, '$base/page');
      },
    );

    test('redirect: links are relative to the final address', () async {
      final c = await convert('/old');
      expect(c.info!.url, '$base/page');
      expect(success(c).markdown, contains('($base/wiki/Ссылка)'));
    });

    test('encoding from Content-Type', () async {
      expect(success(await convert('/cp1251')).markdown, 'Привет');
    });

    test(
      'filename from Content-Disposition (RFC 5987) — type follows it',
      () async {
        final c = await convert('/download');
        expect(c.info!.filename, 'данные.csv');
        expect(success(c).converterId, 'csv');
      },
    );

    test(
      'feed by response type, links are relative to the feed address',
      () async {
        final result = success(await convert('/feed'));
        expect(result.converterId, 'rss');
        expect(result.markdown, contains('[пост]($base/post)'));
      },
    );

    test('404 — a clear network failure', () async {
      final c = await convert('/missing');
      expect(c.info, isNull);
      final failure = (c.outcome as ConversionError).failure;
      expect((failure as NetworkFailure).description, contains('HTTP 404'));
    });

    test('server unreachable — a failure, not an exception', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      final c = await convertUrl('http://127.0.0.1:$port/', registry);
      expect(
        ((c.outcome as ConversionError).failure as NetworkFailure).description,
        contains('нет соединения'),
      );
    });

    test('not a link — failure with no request', () async {
      final c = await convertUrl('просто текст', registry);
      expect((c.outcome as ConversionError).failure, isA<NetworkFailure>());
    });
  });

  group('YouTube', () {
    final page = Uint8List.fromList(utf8.encode(_youtubePage));

    Future<ConversionResult> convert(WebFetcher? web) async {
      final info = StreamInfo.fromHead(
        page,
        mimeType: 'text/html; charset=utf-8',
        url: 'https://www.youtube.com/watch?v=abc123&feature=youtu.be',
      );
      final outcome = await ConverterRegistry.defaultRegistry(
        web: web,
      ).convert(page, info);
      return (outcome as ConversionSuccess).result;
    }

    test('metadata and description — same as markitdown', () async {
      final result = await convert(null);
      expect(result.converterId, 'youtube');
      expect(
        result.markdown,
        '# YouTube\n'
        '\n'
        '## Лекция 1\n'
        '\n'
        '### Video Metadata\n'
        '- **Views:** 1234\n'
        '- **Keywords:** история, лекция\n'
        '- **Runtime:** PT10M5S\n'
        '\n'
        '### Description\n'
        'Полное описание\n'
        'во две строки',
      );
      expect(result.title, 'Лекция 1');
    });

    test('subtitles: manual in the video language beats automatic', () async {
      final web = _FakeYouTube();
      final result = await convert(web);
      expect(
        result.markdown,
        endsWith("### Transcript\nДобрый день. Это «лекция» & пример's."),
      );
      expect(web.fetchedTrack, 'ru-manual');
      expect(web.playerKey, 'KEY123');
      expect(
        result.warnings.single.message,
        'субтитры (ru-RU) взяты с YouTube',
      );
    });

    test('the video has no subtitles — a warning, not a failure', () async {
      final result = await convert(_FakeYouTube(tracks: const []));
      expect(result.markdown, isNot(contains('Transcript')));
      expect(result.warnings.single.message, 'у видео нет субтитров');
    });

    test('network fails on subtitles — the description still stays', () async {
      final result = await convert(_FakeYouTube(fail: true));
      expect(result.markdown, contains('### Description'));
      expect(
        result.warnings.single.message,
        startsWith('субтитры не скачались'),
      );
    });

    test('the same page from disk (no url) — plain HTML', () async {
      final info = StreamInfo.fromHead(page, filename: 'watch.html');
      final outcome = await ConverterRegistry.defaultRegistry().convert(
        page,
        info,
      );
      expect((outcome as ConversionSuccess).result.converterId, 'html');
    });

    test('video id from various kinds of links', () {
      expect(youtubeVideoId('https://youtu.be/abc?t=5'), 'abc');
      expect(youtubeVideoId('https://m.youtube.com/watch?v=abc&list=x'), 'abc');
      expect(youtubeVideoId('https://www.youtube.com/shorts/abc'), 'abc');
      expect(youtubeVideoId('https://www.youtube.com/embed/abc'), 'abc');
      expect(youtubeVideoId('https://www.youtube.com/@channel'), isNull);
      expect(youtubeVideoId('https://example.com/watch?v=abc'), isNull);
    });
  });

  test('Wikipedia: article only, no "edit" buttons', () async {
    final page = Uint8List.fromList(
      utf8.encode(
        '<html><head><title>Markdown — Википедия</title></head><body>'
        '<nav>меню сайта</nav>'
        '<h1><span class="mw-page-title-main">Markdown</span></h1>'
        '<div id="mw-content-text"><h2>История<span class="mw-editsection">'
        '[<a href="/w/index.php?action=edit">править</a>]</span></h2>'
        '<p>Создан <a href="/wiki/Грубер">Грубером</a>.</p></div>'
        '</body></html>',
      ),
    );
    final info = StreamInfo.fromHead(
      page,
      mimeType: 'text/html',
      url: 'https://ru.wikipedia.org/wiki/Markdown',
    );
    final result =
        (await ConverterRegistry.defaultRegistry().convert(page, info)
                as ConversionSuccess)
            .result;
    expect(result.converterId, 'wikipedia');
    expect(result.title, 'Markdown');
    expect(result.markdown, startsWith('# Markdown\n\n'));
    expect(result.markdown, isNot(contains('меню')));
    expect(result.markdown, isNot(contains('править')));
    expect(
      result.markdown,
      contains('[Грубером](https://ru.wikipedia.org/wiki/Грубер)'),
    );
  });
}

Uint8List _cp1251(String text) => Uint8List.fromList([
  for (final c in text.codeUnits)
    if (c < 0x80)
      c
    else if (c >= 0x410 && c <= 0x44F)
      c - 0x410 + 0xC0
    else
      0x3F,
]);

/// The video page the way YouTube serves it — only what's needed.
const _youtubePage = '''
<html><head><title>Лекция 1 - YouTube</title>
<meta name="title" content="Лекция 1">
<meta name="description" content="Короткое описание">
<meta name="keywords" content="история, лекция">
<meta itemprop="duration" content="PT10M5S">
</head><body>
<script>var ytInitialPlayerResponse = {"videoDetails":{"viewCount":"1234","title":"{не скобка}"}};</script>
<script>var ytInitialData = {"a":[{"attributedDescriptionBodyText":{"content":"Полное описание\\nво две строки"}}]};</script>
<script>ytcfg.set({"INNERTUBE_API_KEY":"KEY123"});</script>
</body></html>
''';

class _FakeYouTube extends WebFetcher {
  final List<Map<String, String>> tracks;
  final bool fail;
  String? playerKey;
  String? fetchedTrack;

  _FakeYouTube({
    this.tracks = const [
      {'languageCode': 'en', 'baseUrl': 'https://yt/en-manual'},
      {'languageCode': 'ru', 'kind': 'asr', 'baseUrl': 'https://yt/ru-asr'},
      {'languageCode': 'ru-RU', 'baseUrl': 'https://yt/ru-manual'},
    ],
    this.fail = false,
  });

  @override
  Future<WebResponse> postJson(
    Uri url,
    Object body, {
    Map<String, String> headers = const {},
  }) async {
    if (fail) throw const WebFetchException('нет соединения с сервером');
    playerKey = url.queryParameters['key'];
    return _response(
      url,
      jsonEncode({
        'captions': {
          'playerCaptionsTracklistRenderer': {'captionTracks': tracks},
        },
      }),
    );
  }

  @override
  Future<WebResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    fetchedTrack = url.pathSegments.last;
    return _response(
      url,
      '<?xml version="1.0" encoding="utf-8" ?><transcript>'
      '<text start="0" dur="1">Добрый день.</text>'
      '<text start="1" dur="1">Это «лекция»\n&amp;amp; пример&amp;#39;s.</text>'
      '</transcript>',
    );
  }

  WebResponse _response(Uri url, String body) => WebResponse(
    url: url,
    statusCode: 200,
    contentType: 'application/json',
    contentDisposition: null,
    body: Uint8List.fromList(utf8.encode(body)),
  );
}

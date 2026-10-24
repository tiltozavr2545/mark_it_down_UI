import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The only place in the app that talks to the network — see
/// `docs/offline-and-privacy.md`. The network is needed only by "link"
/// mode: downloading a page or file at an address the person pasted
/// themselves or shared (and, for YouTube, that video's captions). The
/// user's own files are never sent out from here: the only requests are
/// a `GET` to that address and a `POST` to YouTube with the video id. CI
/// checks that `HttpClient`/sockets don't show up outside
/// `core/lib/src/web/`.
///
/// `dart:io`, not the `http` package: no added dependencies, and the
/// "no networking packages in `pub deps`" check stays valid for
/// everything else.
class WebFetcher {
  /// How long to wait for the connection and for each next chunk of the
  /// response.
  final Duration timeout;

  /// Nothing larger than this gets downloaded: an endless stream (radio,
  /// an infinite feed) would otherwise eat up memory. The same order of
  /// magnitude as an unpacked archive.
  final int maxBytes;

  const WebFetcher({
    this.timeout = const Duration(seconds: 30),
    this.maxBytes = 1024 * 1024 * 1024,
  });

  /// An honest `User-Agent`, not a browser-like one: bot protection
  /// (w3.org) rejects a fake "Chrome" with none of a real browser's other
  /// headers with a 403, and Wikipedia's own rules ask for a descriptive
  /// UA. YouTube serves the video page either way.
  static const userAgent =
      'MarkItDownUI (+https://github.com/tiltozavr2545/mark_it_down_UI)';

  Future<WebResponse> get(Uri url, {Map<String, String> headers = const {}}) =>
      _send('GET', url, headers: headers);

  Future<WebResponse> postJson(
    Uri url,
    Object body, {
    Map<String, String> headers = const {},
  }) => _send(
    'POST',
    url,
    headers: {...headers, 'Content-Type': 'application/json'},
    body: utf8.encode(jsonEncode(body)),
  );

  Future<WebResponse> _send(
    String method,
    Uri url, {
    required Map<String, String> headers,
    List<int>? body,
  }) async {
    if (url.scheme != 'http' && url.scheme != 'https') {
      throw const WebFetchException(
        'поддерживаются только ссылки http и https',
      );
    }
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..userAgent = userAgent
      ..autoUncompress = true;
    try {
      final request = await client.openUrl(method, url).timeout(timeout);
      request.followRedirects = true;
      request.maxRedirects = 10;
      headers.forEach(request.headers.set);
      if (body != null) request.add(body);
      final response = await request.close().timeout(timeout);

      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          throw WebFetchException(
            'ответ больше ${maxBytes ~/ (1024 * 1024)} МБ — скачивание '
            'остановлено',
          );
        }
      }
      final finalUrl = response.redirects.isEmpty
          ? url
          : url.resolveUri(response.redirects.last.location);
      return WebResponse(
        url: finalUrl,
        statusCode: response.statusCode,
        contentType: response.headers.value(HttpHeaders.contentTypeHeader),
        contentDisposition: response.headers.value('content-disposition'),
        body: builder.takeBytes(),
      );
    } on WebFetchException {
      rethrow;
    } on TimeoutException {
      throw const WebFetchException('сервер не ответил вовремя');
    } on HandshakeException {
      throw const WebFetchException(
        'не удалось установить защищённое соединение',
      );
    } on SocketException {
      throw const WebFetchException(
        'нет соединения с сервером — проверьте интернет и адрес',
      );
    } on RedirectException {
      throw const WebFetchException('слишком много перенаправлений');
    } on HttpException {
      throw const WebFetchException('сервер ответил некорректно');
    } finally {
      client.close(force: true);
    }
  }
}

class WebResponse {
  /// The address after redirects — the page's links are resolved against
  /// it.
  final Uri url;
  final int statusCode;
  final String? contentType;
  final String? contentDisposition;
  final Uint8List body;

  const WebResponse({
    required this.url,
    required this.statusCode,
    required this.contentType,
    required this.contentDisposition,
    required this.body,
  });

  bool get ok => statusCode >= 200 && statusCode < 300;
}

/// A network failure; [reason] is already human-readable, not an
/// exception's raw text.
class WebFetchException implements Exception {
  final String reason;

  const WebFetchException(this.reason);

  @override
  String toString() => reason;
}

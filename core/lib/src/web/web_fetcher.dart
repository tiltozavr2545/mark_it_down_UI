import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Единственное место в приложении, которое ходит в сеть, — см.
/// `docs/offline-and-privacy.md`. Сеть нужна только режиму «ссылка»: по
/// адресу, который человек сам вставил или которым поделился, скачать
/// страницу или файл (и, для YouTube, субтитры этого видео). Файлы
/// пользователя отсюда никуда не отправляются: запросы — только `GET` по
/// этому адресу и `POST` к YouTube с номером видео. CI проверяет, что
/// `HttpClient`/сокеты не встречаются вне `core/lib/src/web/`.
///
/// `dart:io`, а не пакет `http`: зависимостей не прибавляется, и проверка
/// «нет сетевых пакетов в `pub deps`» остаётся в силе для всего остального.
class WebFetcher {
  /// Сколько ждать соединения и каждого следующего куска ответа.
  final Duration timeout;

  /// Больше этого не качается: поток без конца (радио, бесконечная лента)
  /// иначе съел бы память. Тот же порядок, что у распакованного архива.
  final int maxBytes;

  const WebFetcher({
    this.timeout = const Duration(seconds: 30),
    this.maxBytes = 1024 * 1024 * 1024,
  });

  /// Честный `User-Agent`, а не браузерный: поддельный «Chrome» без
  /// остальных заголовков браузера защита от ботов (w3.org) отсекает с
  /// 403, а Wikipedia по своим правилам просит описательный UA. YouTube
  /// отдаёт страницу видео и так.
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
  /// Адрес после перенаправлений — от него разрешаются ссылки страницы.
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

/// Сетевой сбой; [reason] — уже для человека, без текста исключения.
class WebFetchException implements Exception {
  final String reason;

  const WebFetchException(this.reason);

  @override
  String toString() => reason;
}

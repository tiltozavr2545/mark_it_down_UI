import 'dart:typed_data';

import '../conversion/conversion_failure.dart';
import '../conversion/converter_registry.dart';
import '../stream_info.dart';
import 'web_fetcher.dart';

/// Итог режима «ссылка»: что скачалось ([info] — `null`, если скачать не
/// удалось) и результат конвейера.
class UrlConversion {
  final StreamInfo? info;
  final ConversionOutcome outcome;

  const UrlConversion(this.info, this.outcome);
}

/// Скачанное по ссылке: байты и то, что о них сказал сервер.
class DownloadedUrl {
  final Uint8List bytes;

  /// Из `Content-Disposition` или из пути, если он похож на файл.
  final String? filename;

  /// `Content-Type` целиком, с `charset`.
  final String? mimeType;

  /// Адрес после перенаправлений.
  final String url;

  const DownloadedUrl({
    required this.bytes,
    required this.filename,
    required this.mimeType,
    required this.url,
  });

  StreamInfo get info => StreamInfo.fromHead(
    bytes,
    filename: filename,
    mimeType: mimeType,
    url: url,
  );
}

/// Ссылка → байты. Бросает [WebFetchException] с причиной для человека:
/// не ссылка, нет сети, сервер ответил ошибкой.
Future<DownloadedUrl> downloadUrl(
  String input, {
  WebFetcher fetcher = const WebFetcher(),
}) async {
  final url = parseUserUrl(input);
  if (url == null) {
    throw const WebFetchException('это не похоже на ссылку http или https');
  }
  final response = await fetcher.get(url, headers: youtubeConsentHeaders(url));
  if (!response.ok) {
    throw WebFetchException(_describeStatus(response.statusCode));
  }
  return DownloadedUrl(
    bytes: response.body,
    filename: _filenameOf(response),
    mimeType: response.contentType,
    url: response.url.toString(),
  );
}

/// Ссылка → скачать → тот же конвейер, что и для файла. Как `convert_uri`
/// у markitdown: тип берётся из ответа (`Content-Type`, имя из
/// `Content-Disposition` или из пути), содержимое распознаётся по байтам,
/// а адрес попадает в [StreamInfo.url] — по нему конвертеры YouTube и
/// Wikipedia узнают свои страницы, а HTML и ленты разрешают относительные
/// ссылки. Ссылка на PDF или docx даёт тот же результат, что и файл.
///
/// [registry] должен знать [fetcher] (`defaultRegistry(web: …)`) — иначе
/// YouTube отдаст описание без субтитров.
Future<UrlConversion> convertUrl(
  String input,
  ConverterRegistry registry, {
  WebFetcher fetcher = const WebFetcher(),
}) async {
  final DownloadedUrl downloaded;
  try {
    downloaded = await downloadUrl(input, fetcher: fetcher);
  } on WebFetchException catch (e) {
    return UrlConversion(null, ConversionError(NetworkFailure(e.reason)));
  }
  final info = downloaded.info;
  return UrlConversion(info, await registry.convert(downloaded.bytes, info));
}

/// Ссылка из того, что вставил человек или чем поделилось приложение:
/// «Смотри https://youtu.be/… » — первая ссылка в тексте; `example.com/a`
/// без схемы — `https://`. `null` — ссылки нет.
Uri? parseUserUrl(String input) {
  final text = input.trim();
  final match = RegExp(r'https?://\S+', caseSensitive: false).firstMatch(text);
  var candidate = match?.group(0);
  if (candidate == null) {
    // Без схемы — только если весь ввод похож на один адрес: «домен.зона…».
    if (!RegExp(
      r'^[\w.-]+\.[a-z]{2,}(?:[/?#]\S*)?$',
      caseSensitive: false,
    ).hasMatch(text)) {
      return null;
    }
    candidate = 'https://$text';
  }
  // Знаки препинания, которыми ссылка кончается в тексте, — не её часть.
  candidate = candidate.replaceFirst(RegExp(r'[.,;:!?)»"\]]+$'), '');
  final uri = Uri.tryParse(candidate);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri;
}

/// YouTube в Европе вместо страницы видео отдаёт страницу согласия на
/// cookie; этот cookie означает «отказался от необязательных» — то, что
/// и нужно приложению без аккаунта.
Map<String, String> youtubeConsentHeaders(Uri url) {
  final host = url.host.toLowerCase();
  final youtube =
      host == 'youtu.be' ||
      host == 'youtube.com' ||
      host.endsWith('.youtube.com');
  return youtube ? const {'Cookie': 'SOCS=CAI; CONSENT=PENDING+987'} : const {};
}

String? _filenameOf(WebResponse response) {
  final disposition = response.contentDisposition;
  if (disposition != null) {
    final encoded = RegExp(
      r"filename\*\s*=\s*([\w-]+)''([^;]+)",
      caseSensitive: false,
    ).firstMatch(disposition);
    if (encoded != null) {
      try {
        return Uri.decodeComponent(encoded.group(2)!.trim());
      } on ArgumentError {
        // битое %-кодирование — пробуем простое имя
      }
    }
    final plain = RegExp(
      r'filename\s*=\s*"?([^";]+)"?',
      caseSensitive: false,
    ).firstMatch(disposition);
    if (plain != null) return plain.group(1)!.trim();
  }
  // Имя из пути — только если похоже на файл (`/report.pdf`), а не на
  // страницу (`/wiki/Markdown`): иначе «Markdown» без расширения сбил бы
  // подсказку типа.
  final segments = response.url.pathSegments.where((s) => s.isNotEmpty);
  if (segments.isEmpty) return null;
  final last = segments.last;
  // Расширение начинается с буквы: `1706.03762` (arXiv) — не файл.
  return RegExp(r'\.[A-Za-z][A-Za-z0-9]{0,4}$').hasMatch(last) ? last : null;
}

String _describeStatus(int status) => switch (status) {
  401 || 403 =>
    'сервер не пускает по этой ссылке (HTTP $status): нужен вход '
        'или доступ закрыт',
  404 || 410 => 'по этой ссылке ничего нет (HTTP $status)',
  429 => 'сервер просит подождать: слишком много запросов (HTTP 429)',
  >= 500 => 'ошибка на стороне сервера (HTTP $status), попробуйте позже',
  _ => 'сервер ответил ошибкой (HTTP $status)',
};

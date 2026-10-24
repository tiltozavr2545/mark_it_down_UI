import 'dart:typed_data';

import '../conversion/conversion_failure.dart';
import '../conversion/converter_registry.dart';
import '../stream_info.dart';
import 'web_fetcher.dart';

/// The outcome of "link" mode: what got downloaded ([info] is `null` if
/// the download failed) and the pipeline's result.
class UrlConversion {
  final StreamInfo? info;
  final ConversionOutcome outcome;

  const UrlConversion(this.info, this.outcome);
}

/// What was downloaded from a link: the bytes and what the server said
/// about them.
class DownloadedUrl {
  final Uint8List bytes;

  /// From `Content-Disposition`, or from the path if it looks like a
  /// file.
  final String? filename;

  /// The whole `Content-Type`, with `charset`.
  final String? mimeType;

  /// The address after redirects.
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

/// A link → bytes. Throws [WebFetchException] with a human-readable
/// reason: not a link, no network, the server returned an error.
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

/// A link → download → the same pipeline as for a file. Like
/// markitdown's `convert_uri`: the type comes from the response
/// (`Content-Type`, the name from `Content-Disposition` or from the
/// path), the content is detected from the bytes, and the address lands
/// in [StreamInfo.url] — the YouTube and Wikipedia converters recognize
/// their own pages by it, and HTML and feeds resolve relative links by
/// it. A link to a PDF or docx gives the same result as the file would.
///
/// [registry] must know about [fetcher] (`defaultRegistry(web: …)`) —
/// otherwise YouTube returns the description without captions.
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

/// A link out of whatever the person pasted or an app shared: "Check out
/// https://youtu.be/…" — the first link in the text; `example.com/a`
/// with no scheme gets `https://`. `null` means there's no link.
Uri? parseUserUrl(String input) {
  final text = input.trim();
  final match = RegExp(r'https?://\S+', caseSensitive: false).firstMatch(text);
  var candidate = match?.group(0);
  if (candidate == null) {
    // No scheme — only if the whole input looks like a single address:
    // "domain.tld...".
    if (!RegExp(
      r'^[\w.-]+\.[a-z]{2,}(?:[/?#]\S*)?$',
      caseSensitive: false,
    ).hasMatch(text)) {
      return null;
    }
    candidate = 'https://$text';
  }
  // Punctuation the link ends with in the text isn't part of it.
  candidate = candidate.replaceFirst(RegExp(r'[.,;:!?)»"\]]+$'), '');
  final uri = Uri.tryParse(candidate);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri;
}

/// In Europe, YouTube returns a cookie-consent page instead of the video
/// page; this cookie means "declined the optional ones" — exactly what an
/// app with no account needs.
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
        // broken %-encoding — fall back to the plain name
      }
    }
    final plain = RegExp(
      r'filename\s*=\s*"?([^";]+)"?',
      caseSensitive: false,
    ).firstMatch(disposition);
    if (plain != null) return plain.group(1)!.trim();
  }
  // A name from the path only if it looks like a file (`/report.pdf`),
  // not a page (`/wiki/Markdown`): otherwise "Markdown" with no
  // extension would throw off the type hint.
  final segments = response.url.pathSegments.where((s) => s.isNotEmpty);
  if (segments.isEmpty) return null;
  final last = segments.last;
  // An extension starts with a letter: `1706.03762` (arXiv) isn't a file.
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

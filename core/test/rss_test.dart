import 'dart:convert';
import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';
import 'package:test/test.dart';

/// The boundary between a feed and plain XML: [ConverterRegistry] must
/// hand a feed to the `rss` converter, and the rest of XML to `xml`, even
/// when the root looks like a feed.
void main() {
  final registry = ConverterRegistry.defaultRegistry();

  Future<ConversionResult> convert(
    String text, {
    String? filename,
    String? mimeType,
    String? url,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(text));
    final info = StreamInfo.fromHead(
      bytes,
      filename: filename,
      mimeType: mimeType,
      url: url,
    );
    return (await registry.convert(bytes, info) as ConversionSuccess).result;
  }

  const rss =
      '<rss version="2.0"><channel><title>Канал</title>'
      '<item><title>Запись</title>'
      '<description>&lt;a href="/a"&gt;ссылка&lt;/a&gt;</description>'
      '</item></channel></rss>';

  test('RSS in .xml — a feed, not a fenced XML block', () async {
    final result = await convert(rss, filename: 'feed.xml');
    expect(result.converterId, 'rss');
    expect(result.markdown, startsWith('# Канал\n\n## Запись'));
    expect(result.title, 'Канал');
  });

  test('server response with no filename: feed recognized by type and root', () async {
    final result = await convert(
      rss,
      mimeType: 'application/rss+xml; charset=utf-8',
      url: 'https://example.com/feed/',
    );
    expect(result.converterId, 'rss');
    // The relative link is resolved against the feed's address.
    expect(result.markdown, contains('[ссылка](https://example.com/a)'));
  });

  test('<feed> with no entries — not Atom: goes to the XML converter', () async {
    final result = await convert(
      '<feed xmlns="http://www.w3.org/2005/Atom"><title>t</title></feed>',
      filename: 'empty.xml',
    );
    expect(result.converterId, 'xml');
    expect(result.warnings.single.message, contains('похож на ленту RSS/Atom'));
  });

  test('plain XML is not counted as a feed', () async {
    final result = await convert('<root><a>1</a></root>', filename: 'x.xml');
    expect(result.converterId, 'xml');
    expect(result.warnings, isEmpty);
  });

  test('a broken feed in .rss — shown as plain text', () async {
    final bytes = Uint8List.fromList(utf8.encode('<rss><channel>'));
    final info = StreamInfo.fromHead(bytes, filename: 'broken.rss');
    final outcome = await registry.convert(bytes, info);
    // A broken feed in .rss is picked up by plain text — a partial result
    // is more useful than a failure.
    expect(outcome, isA<ConversionSuccess>());
    expect((outcome as ConversionSuccess).result.converterId, isNot('rss'));
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';
import 'package:test/test.dart';

/// Граница между лентой и просто XML: [ConverterRegistry] должен отдать
/// ленту конвертеру `rss`, а остальной XML — `xml`, даже когда корень
/// похож на ленту.
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

  test('RSS в .xml — лента, а не фенс-блок XML', () async {
    final result = await convert(rss, filename: 'feed.xml');
    expect(result.converterId, 'rss');
    expect(result.markdown, startsWith('# Канал\n\n## Запись'));
    expect(result.title, 'Канал');
  });

  test('ответ сервера без имени: лента узнаётся по типу и корню', () async {
    final result = await convert(
      rss,
      mimeType: 'application/rss+xml; charset=utf-8',
      url: 'https://example.com/feed/',
    );
    expect(result.converterId, 'rss');
    // Относительная ссылка разрешается от адреса ленты.
    expect(result.markdown, contains('[ссылка](https://example.com/a)'));
  });

  test('<feed> без записей — не Atom: отдаёт XML-конвертер', () async {
    final result = await convert(
      '<feed xmlns="http://www.w3.org/2005/Atom"><title>t</title></feed>',
      filename: 'empty.xml',
    );
    expect(result.converterId, 'xml');
    expect(result.warnings.single.message, contains('похож на ленту RSS/Atom'));
  });

  test('обычный XML лентой не считается', () async {
    final result = await convert('<root><a>1</a></root>', filename: 'x.xml');
    expect(result.converterId, 'xml');
    expect(result.warnings, isEmpty);
  });

  test('битая лента в .rss — показывается простым текстом', () async {
    final bytes = Uint8List.fromList(utf8.encode('<rss><channel>'));
    final info = StreamInfo.fromHead(bytes, filename: 'broken.rss');
    final outcome = await registry.convert(bytes, info);
    // Битую ленту в .rss подхватывает простой текст — частичный результат
    // полезнее отказа.
    expect(outcome, isA<ConversionSuccess>());
    expect((outcome as ConversionSuccess).result.converterId, isNot('rss'));
  });
}

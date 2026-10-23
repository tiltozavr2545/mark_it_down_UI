import 'dart:convert';
import 'dart:typed_data';

import 'package:html2md/html2md.dart' as html2md;

import '../../markdown_writer.dart' as md;
import '../../stream_info.dart';
import '../../text_decoding.dart';
import '../../type_detection/detected_type.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';
import '../ole2/compound_file.dart';

/// Письмо Outlook (`.msg`): свойства MAPI из OLE2-контейнера. Вывод
/// повторяет `OutlookMsgConverter` markitdown символ в символ — те же
/// заголовки (From — адрес отправителя, To — строка получателей, Subject),
/// те же правила кодировок, — чтобы письмо читалось одинаково на десктопе,
/// где первым идёт сайдкар, и на Android, где есть только этот конвертер.
///
/// Сверх markitdown — одно: письмо без текстового тела (только HTML)
/// отдаёт HTML-тело, переведённое в Markdown, а не пустой раздел.
/// Тело в RTF (`PR_RTF_COMPRESSED`) не читается — как и у markitdown.
class MsgConverter implements DocumentConverter {
  const MsgConverter();

  @override
  String get id => 'msg';

  @override
  double get priority => 0.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) =>
      info.detectedType.kind == FileKind.msg;

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final _Message message;
    try {
      message = _Message(CompoundFile.parse(request.bytes));
    } on FormatException {
      throw const ConversionCorruptedException(
        'не удалось разобрать письмо Outlook',
      );
    }

    final longs = message.longProperties();
    final messageCodepage = longs[_prMessageCodepage];
    final internetCodepage = longs[_prInternetCodepage];
    final headerCodepage = messageCodepage ?? internetCodepage;
    final bodyCodepage = internetCodepage ?? messageCodepage;

    final headers = {
      'From': message.string(_prSenderEmailAddress, headerCodepage),
      'To': message.string(_prDisplayTo, headerCodepage),
      'Subject': message.string(_prSubject, headerCodepage),
    };

    final buffer = StringBuffer('# Email Message\n\n');
    for (final MapEntry(:key, :value) in headers.entries) {
      if (value != null && value.isNotEmpty) buffer.write('**$key:** $value\n');
    }
    buffer.write('\n## Content\n\n');

    final warnings = <ConversionWarning>[];
    final body = message.string(_prBody, bodyCodepage);
    if (body != null && body.isNotEmpty) {
      buffer.write(body);
    } else {
      final html = message.htmlBody(bodyCodepage);
      if (html != null) {
        buffer.write(html2md.convert(html));
        warnings.add(
          const ConversionWarning(
            'у письма нет текстового тела — содержимое взято из HTML-версии',
          ),
        );
      }
    }

    final subject = headers['Subject'];
    return ConversionResult(
      markdown: md.normalizeLikeMarkitdown(buffer.toString().trim()),
      converterId: id,
      elapsed: Duration.zero,
      title: subject == null || subject.isEmpty ? null : subject,
      warnings: warnings,
    );
  }
}

const _prSubject = 0x0037;
const _prSenderEmailAddress = 0x0C1F;
const _prDisplayTo = 0x0E04;
const _prBody = 0x1000;
const _prHtml = 0x1013;
const _prMessageCodepage = 0x3FFD;
const _prInternetCodepage = 0x3FDE;

const _ptLong = 0x0003;
const _ptString8 = '001E';
const _ptUnicode = '001F';
const _ptBinary = '0102';

class _Message {
  final CompoundFile file;

  _Message(this.file);

  Uint8List? _stream(String name) {
    final entry = file.child(file.root, name);
    if (entry == null || entry.type != CfbEntryType.stream) return null;
    try {
      return file.read(entry);
    } on FormatException {
      return null;
    }
  }

  String _streamName(int tag, String type) =>
      '__substg1.0_${tag.toRadixString(16).toUpperCase().padLeft(4, '0')}'
      '$type';

  /// Свойства фиксированной длины (PT_LONG) лежат не отдельными потоками, а
  /// записями по 16 байт в `__properties_version1.0` — после заголовка в
  /// 32 байта у письма верхнего уровня.
  Map<int, int> longProperties() {
    final data = _stream('__properties_version1.0');
    final result = <int, int>{};
    if (data == null) return result;
    final view = ByteData.sublistView(data);
    for (var offset = 32; offset + 16 <= data.length; offset += 16) {
      final tag = view.getUint32(offset, Endian.little);
      if (tag & 0xFFFF == _ptLong) {
        result[tag >> 16] = view.getUint32(offset + 8, Endian.little);
      }
    }
    return result;
  }

  /// Строковое свойство: сначала PT_UNICODE (UTF-16LE), иначе PT_STRING8 в
  /// кодовой странице письма — письмо хранит одно из двух, в зависимости от
  /// того, сохранено оно в Unicode или в старом формате.
  String? string(int tag, int? codepage) {
    final unicode = _stream(_streamName(tag, _ptUnicode));
    if (unicode != null) {
      final text = _decodeUtf16(unicode).trim();
      if (text.isNotEmpty) return text;
    }
    final ansi = _stream(_streamName(tag, _ptString8));
    if (ansi == null) return null;
    var end = ansi.length;
    while (end > 0 && ansi[end - 1] == 0) {
      end--;
    }
    if (end == 0) return null;
    return decodeCodepage(Uint8List.sublistView(ansi, 0, end), codepage).trim();
  }

  /// HTML-тело: обычно PT_BINARY в кодировке письма, иногда строка.
  String? htmlBody(int? codepage) {
    final binary = _stream(_streamName(_prHtml, _ptBinary));
    if (binary != null && binary.isNotEmpty) {
      return codepage == null
          ? decodeTextBytes(binary).content
          : decodeCodepage(binary, codepage);
    }
    return string(_prHtml, codepage);
  }
}

/// UTF-16LE, как `bytes.decode('utf-16-le')` у markitdown: нечётный хвост и
/// одинокие суррогаты — повод не падать, а заменить символ.
String _decodeUtf16(Uint8List bytes) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return utf8.decode(utf8.encode(String.fromCharCodes(units)));
}

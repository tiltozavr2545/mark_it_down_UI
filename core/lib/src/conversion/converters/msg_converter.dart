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

/// An Outlook message (`.msg`): MAPI properties from the OLE2 container.
/// The output matches markitdown's `OutlookMsgConverter` character for
/// character — the same headers (From — sender address, To — recipient
/// string, Subject), the same encoding rules — so the message reads the
/// same on desktop, where the sidecar runs first, and on Android, where
/// this converter is the only one.
///
/// One thing goes beyond markitdown: a message with no text body (HTML
/// only) returns the HTML body converted to Markdown instead of an empty
/// section. The RTF body (`PR_RTF_COMPRESSED`) is not read — same as
/// markitdown.
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

  /// Fixed-length properties (PT_LONG) aren't stored as separate streams
  /// but as 16-byte records in `__properties_version1.0` — after a 32-byte
  /// header for a top-level message.
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

  /// String property: PT_UNICODE (UTF-16LE) first, otherwise PT_STRING8 in
  /// the message's codepage — a message stores one or the other, depending
  /// on whether it was saved in Unicode or the old format.
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

  /// HTML body: usually PT_BINARY in the message's encoding, sometimes a
  /// string.
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

/// UTF-16LE, like markitdown's `bytes.decode('utf-16-le')`: an odd trailing
/// byte or a lone surrogate is a reason to substitute a character, not to
/// throw.
String _decodeUtf16(Uint8List bytes) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return utf8.decode(utf8.encode(String.fromCharCodes(units)));
}

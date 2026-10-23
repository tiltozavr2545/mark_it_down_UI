import 'dart:typed_data';

import '../../text_decoding.dart';
import '../spreadsheet/sheet_markdown.dart';

/// Разбор потока `Workbook` (BIFF8, Excel 97–2003) и `Book` (BIFF5/7,
/// Excel 5–95) — ровно то, что нужно для таблицы: листы, ячейки со
/// значениями, объединения, даты. Форматирование, формулы (кроме
/// кэшированного значения), графики и макросы не читаются. Спецификация —
/// MS-XLS; поведение на спорных местах сверено с `xlrd`, которым читает
/// `.xls` сам markitdown.
///
/// Бросает [FormatException] на нечитаемый поток и [XlsUnsupported] на то,
/// что прочитать можно было бы, но не здесь (пароль, BIFF2–4).
class BiffWorkbook {
  final List<BiffSheet> sheets;

  /// Листы, которые не удалось прочитать, — пропускаются с предупреждением,
  /// а не топят всю книгу.
  final List<String> unreadableSheets;

  const BiffWorkbook(this.sheets, this.unreadableSheets);

  factory BiffWorkbook.parse(Uint8List stream) =>
      _WorkbookParser(stream).parse();
}

class BiffSheet {
  final String name;

  /// Строка → столбец → значение, индексы с нуля.
  final Map<int, Map<int, String>> cells;
  final List<MergeRange> merges;

  const BiffSheet(this.name, this.cells, this.merges);
}

/// Файл узнан, но этот разбор его не прочитает; [reason] — для человека.
class XlsUnsupported implements Exception {
  final String reason;

  const XlsUnsupported(this.reason);

  @override
  String toString() => reason;
}

// Идентификаторы записей BIFF.
const _bof = 0x0809;
const _eof = 0x000A;
const _continue = 0x003C;
const _filePass = 0x002F;
const _codePage = 0x0042;
const _dateMode = 0x0022;
const _format = 0x041E;
const _xf = 0x00E0;
const _boundSheet = 0x0085;
const _sst = 0x00FC;
const _number = 0x0203;
const _rk = 0x027E;
const _mulRk = 0x00BD;
const _labelSst = 0x00FD;
const _label = 0x0204;
const _rString = 0x00D6;
const _boolErr = 0x0205;
const _formula = 0x0006;
const _string = 0x0207;
const _mergedCells = 0x00E5;

/// Старые BOF (BIFF2–4): книга такого возраста целиком в одном листе, и
/// встречается сейчас только в архивах — честный отказ, а не догадки.
const _oldBofs = {0x0009, 0x0209, 0x0409};

class _Record {
  final int id;
  final int offset;
  final Uint8List data;

  _Record(this.id, this.offset, this.data);
}

class _WorkbookParser {
  final Uint8List stream;
  late final ByteData _view = ByteData.sublistView(stream);

  bool _biff8 = true;
  int? _codepage;
  bool _date1904 = false;
  final _formats = <int, String>{};
  final _xfFormats = <int>[];
  final _sharedStrings = <String>[];

  _WorkbookParser(this.stream);

  _Record? _recordAt(int offset) {
    if (offset + 4 > stream.length) return null;
    final id = _view.getUint16(offset, Endian.little);
    final length = _view.getUint16(offset + 2, Endian.little);
    final end = offset + 4 + length;
    if (end > stream.length) {
      throw const FormatException('xls: запись за концом потока');
    }
    return _Record(id, offset, Uint8List.sublistView(stream, offset + 4, end));
  }

  int _next(_Record r) => r.offset + 4 + r.data.length;

  BiffWorkbook parse() {
    final first = _recordAt(0);
    if (first == null) throw const FormatException('xls: пустой поток');
    if (_oldBofs.contains(first.id)) {
      throw const XlsUnsupported('слишком старая версия Excel (до Excel 5)');
    }
    if (first.id != _bof || first.data.length < 4) {
      throw const FormatException('xls: поток не начинается с BOF');
    }
    final version = _u16(first.data, 0);
    _biff8 = version == 0x0600;
    if (!_biff8 && version != 0x0500) {
      throw const XlsUnsupported('неизвестная версия формата Excel');
    }

    final sheetDecls = <(String, int)>[];
    var offset = _next(first);
    while (true) {
      final record = _recordAt(offset);
      if (record == null || record.id == _eof) break;
      offset = _next(record);
      switch (record.id) {
        case _filePass:
          throw const XlsUnsupported('файл защищён паролем');
        case _codePage:
          _codepage = _u16(record.data, 0);
        case _dateMode:
          _date1904 = _u16(record.data, 0) == 1;
        case _format:
          _readFormat(record.data);
        case _xf:
          _xfFormats.add(_u16(record.data, 2));
        case _boundSheet:
          final decl = _readBoundSheet(record.data);
          if (decl != null) sheetDecls.add(decl);
        case _sst:
          final parts = [record.data];
          while (true) {
            final next = _recordAt(offset);
            if (next == null || next.id != _continue) break;
            parts.add(next.data);
            offset = _next(next);
          }
          _readSst(_Segments(parts));
      }
    }

    final sheets = <BiffSheet>[];
    final unreadable = <String>[];
    for (final (name, position) in sheetDecls) {
      try {
        sheets.add(_readSheet(name, position));
      } on FormatException {
        unreadable.add(name);
      } on RangeError {
        unreadable.add(name);
      }
    }
    return BiffWorkbook(sheets, unreadable);
  }

  void _readFormat(Uint8List data) {
    final index = _u16(data, 0);
    final segments = _Segments([Uint8List.sublistView(data, 2)]);
    _formats[index] = _biff8
        ? segments.unicodeString(segments.u16())
        : _decode(segments.bytes(segments.u8()));
  }

  /// Имя и смещение BOF листа; `null` для графиков, макросов и модулей VBA
  /// — у них нет ячеек.
  (String, int)? _readBoundSheet(Uint8List data) {
    final position = ByteData.sublistView(data).getUint32(0, Endian.little);
    final type = data[5];
    final segments = _Segments([Uint8List.sublistView(data, 6)]);
    final length = segments.u8();
    final name = _biff8
        ? segments.unicodeString(length)
        : _decode(segments.bytes(length));
    return type == 0 ? (name, position) : null;
  }

  /// SST: общая таблица строк BIFF8. Строки продолжаются в записях CONTINUE,
  /// и если разрыв приходится на символы, продолжение начинается с нового
  /// байта флагов — см. [_Segments.unicodeString].
  void _readSst(_Segments s) {
    s.u32(); // всего ссылок на строки
    final unique = s.u32();
    for (var i = 0; i < unique && !s.atEnd; i++) {
      _sharedStrings.add(s.richString());
    }
  }

  BiffSheet _readSheet(String name, int position) {
    final bof = _recordAt(position);
    if (bof == null || bof.id != _bof) {
      throw const FormatException('xls: смещение листа не указывает на BOF');
    }
    final cells = <int, Map<int, String>>{};
    final merges = <MergeRange>[];
    void put(int row, int col, String value) =>
        cells.putIfAbsent(row, () => {})[col] = value;

    // Внутри листа бывают вложенные BOF…EOF (встроенные графики) — их
    // записи не про ячейки этого листа.
    var depth = 0;
    (int, int)? pendingFormulaString;
    var offset = _next(bof);
    while (true) {
      final record = _recordAt(offset);
      if (record == null) break;
      offset = _next(record);
      final d = record.data;
      if (record.id == _bof) {
        depth++;
        continue;
      }
      if (record.id == _eof) {
        if (depth == 0) break;
        depth--;
        continue;
      }
      if (depth > 0) continue;

      switch (record.id) {
        case _number when d.length >= 14:
          put(_u16(d, 0), _u16(d, 2), _numberText(_f64(d, 6), _u16(d, 4)));
        case _rk when d.length >= 10:
          put(_u16(d, 0), _u16(d, 2), _numberText(_rkValue(d, 6), _u16(d, 4)));
        case _mulRk when d.length >= 6:
          final row = _u16(d, 0);
          final firstCol = _u16(d, 2);
          final count = (d.length - 6) ~/ 6;
          for (var i = 0; i < count; i++) {
            final at = 4 + i * 6;
            put(
              row,
              firstCol + i,
              _numberText(_rkValue(d, at + 2), _u16(d, at)),
            );
          }
        case _labelSst when d.length >= 10:
          final index = ByteData.sublistView(d).getUint32(6, Endian.little);
          if (index < _sharedStrings.length) {
            put(_u16(d, 0), _u16(d, 2), _sharedStrings[index]);
          }
        case _label || _rString when d.length >= 8:
          final s = _Segments([Uint8List.sublistView(d, 6)]);
          final length = s.u16();
          put(
            _u16(d, 0),
            _u16(d, 2),
            _biff8 ? s.unicodeString(length) : _decode(s.bytes(length)),
          );
        case _boolErr when d.length >= 8:
          put(
            _u16(d, 0),
            _u16(d, 2),
            d[7] == 0 ? (d[6] == 0 ? 'FALSE' : 'TRUE') : _errorText(d[6]),
          );
        case _formula when d.length >= 14:
          final row = _u16(d, 0);
          final col = _u16(d, 2);
          if (d[12] == 0xFF && d[13] == 0xFF) {
            switch (d[6]) {
              case 0: // строка — в следующей записи STRING
                pendingFormulaString = (row, col);
              case 1:
                put(row, col, d[8] == 0 ? 'FALSE' : 'TRUE');
              case 2:
                put(row, col, _errorText(d[8]));
              case 3:
                put(row, col, '');
            }
          } else {
            put(row, col, _numberText(_f64(d, 6), _u16(d, 4)));
          }
        case _string:
          final target = pendingFormulaString;
          pendingFormulaString = null;
          if (target == null) break;
          final parts = [d];
          while (true) {
            final next = _recordAt(offset);
            if (next == null || next.id != _continue) break;
            parts.add(next.data);
            offset = _next(next);
          }
          final s = _Segments(parts);
          final length = s.u16();
          put(
            target.$1,
            target.$2,
            _biff8 ? s.unicodeString(length) : _decode(s.bytes(length)),
          );
        case _mergedCells when d.length >= 2:
          final count = _u16(d, 0);
          for (var i = 0; i < count && 2 + i * 8 + 8 <= d.length; i++) {
            final at = 2 + i * 8;
            final firstRow = _u16(d, at);
            final lastRow = _u16(d, at + 2);
            final firstCol = _u16(d, at + 4);
            final lastCol = _u16(d, at + 6);
            if (lastRow < firstRow || lastCol < firstCol) continue;
            // Одна ячейка «объединена сама с собой» — так пишут некоторые
            // генераторы; это не объединение.
            if (lastRow == firstRow && lastCol == firstCol) continue;
            merges.add((
              firstRow,
              firstCol,
              lastRow - firstRow + 1,
              lastCol - firstCol + 1,
            ));
          }
      }
    }
    return BiffSheet(name, cells, merges);
  }

  /// Число по стилю ячейки [xfIndex]: дата — `yyyy-MM-dd`, остальное — как
  /// в xlsx, без хвоста `.0` у целых.
  String _numberText(double value, int xfIndex) {
    if (xfIndex < _xfFormats.length) {
      final format = _xfFormats[xfIndex];
      if (isExcelDateFormat(format, _formats[format])) {
        final date = formatExcelDate(value, date1904: _date1904);
        if (date != null) return date;
      }
    }
    return formatSpreadsheetNumber(value);
  }

  String _decode(Uint8List bytes) => decodeCodepage(bytes, _codepage);
}

/// Число так, как его записал бы xlsx: целое — без `.0`, дробное — самым
/// коротким представлением.
String formatSpreadsheetNumber(double value) {
  if (value.isFinite &&
      value == value.truncateToDouble() &&
      value.abs() < 1e15) {
    return value.toInt().toString();
  }
  return value.toString();
}

String _errorText(int code) => switch (code) {
  0x00 => '#NULL!',
  0x07 => '#DIV/0!',
  0x0F => '#VALUE!',
  0x17 => '#REF!',
  0x1D => '#NAME?',
  0x24 => '#NUM!',
  0x2A => '#N/A',
  _ => '#ERROR',
};

/// RK — упакованное число: целое в 30 битах или старшие 30 бит double, и
/// флаг «разделить на 100».
double _rkValue(Uint8List d, int offset) {
  final rk = ByteData.sublistView(d).getUint32(offset, Endian.little);
  double value;
  if (rk & 2 != 0) {
    value = (rk.toSigned(32) >> 2).toDouble();
  } else {
    final bits = ByteData(8)..setUint32(4, rk & 0xFFFFFFFC, Endian.little);
    value = bits.getFloat64(0, Endian.little);
  }
  return rk & 1 != 0 ? value / 100 : value;
}

int _u16(Uint8List d, int offset) =>
    ByteData.sublistView(d).getUint16(offset, Endian.little);

double _f64(Uint8List d, int offset) =>
    ByteData.sublistView(d).getFloat64(offset, Endian.little);

/// Данные записи и её CONTINUE подряд — как один поток байтов, но с
/// памятью о границах: строка BIFF8, разорванная посреди символов,
/// продолжается с нового байта флагов (сжатая/UTF-16 может смениться).
class _Segments {
  final List<Uint8List> _parts;
  int _part = 0;
  int _pos = 0;

  _Segments(this._parts);

  bool get atEnd {
    _skipExhausted();
    return _part >= _parts.length;
  }

  void _skipExhausted() {
    while (_part < _parts.length && _pos >= _parts[_part].length) {
      _part++;
      _pos = 0;
    }
  }

  int u8() {
    _skipExhausted();
    if (_part >= _parts.length) {
      throw const FormatException('xls: строка за концом записи');
    }
    return _parts[_part][_pos++];
  }

  int u16() => u8() | (u8() << 8);

  int u32() => u16() | (u16() << 16);

  Uint8List bytes(int count) {
    final out = Uint8List(count);
    for (var i = 0; i < count; i++) {
      out[i] = u8();
    }
    return out;
  }

  void skip(int count) {
    for (var i = 0; i < count; i++) {
      u8();
    }
  }

  /// XLUnicodeString после поля длины: байт флагов, затем символы.
  String unicodeString(int length) {
    final flags = u8();
    return _chars(length, flags & 1 != 0);
  }

  /// Строка SST целиком: длина, флаги, необязательные счётчики
  /// форматирования и фонетики, символы, затем сами эти блоки (пропускаются).
  String richString() {
    final length = u16();
    final flags = u8();
    final runs = flags & 0x08 != 0 ? u16() : 0;
    final extSize = flags & 0x04 != 0 ? u32() : 0;
    final text = _chars(length, flags & 1 != 0);
    skip(runs * 4 + extSize);
    return text;
  }

  String _chars(int length, bool wide) {
    final units = <int>[];
    while (units.length < length) {
      if (_part >= _parts.length) {
        throw const FormatException('xls: строка за концом записи');
      }
      final part = _parts[_part];
      if (_pos >= part.length) {
        // Разрыв посреди символов: следующая CONTINUE начинается с байта
        // флагов, кодировка символов может смениться.
        _part++;
        _pos = 0;
        if (_part >= _parts.length) {
          throw const FormatException('xls: строка за концом записи');
        }
        wide = _parts[_part][_pos++] & 1 != 0;
        continue;
      }
      if (wide) {
        if (_pos + 2 > part.length) {
          throw const FormatException('xls: символ разорван границей записи');
        }
        units.add(part[_pos] | (part[_pos + 1] << 8));
        _pos += 2;
      } else {
        // Сжатая строка BIFF8 — младшие байты UTF-16, то есть Latin-1, а не
        // кодовая страница книги.
        units.add(part[_pos++]);
      }
    }
    return String.fromCharCodes(units);
  }
}

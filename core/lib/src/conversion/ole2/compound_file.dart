import 'dart:typed_data';

/// Полный разбор OLE Compound File (CFB, MS-CFB): каталог как дерево и
/// чтение потоков, включая мелкие из mini stream. Нужен `xls` (поток
/// `Workbook`) и `msg` (свойства в потоках `__substg1.0_*` и подкаталогах
/// получателей и вложений). Для распознавания типа хватает одних имён —
/// это `type_detection/ole2_directory.dart`, он легче и терпит обрезанный
/// файл.
///
/// Смещениям внутри файла верить нельзя, как и заголовку zip: цепочка
/// секторов может замыкаться, номер — указывать за конец, размер потока —
/// быть больше файла. Поэтому каждая цепочка проходится с ограничением на
/// число шагов, а всё, что не сходится, — [FormatException], которую
/// конвертер превращает в понятный отказ.
class CompoundFile {
  final Uint8List _bytes;
  final int _sectorSize;
  final int _miniSectorSize;
  final int _miniStreamCutoff;
  final List<int> _fat;
  final List<int> _miniFat;
  final List<CfbEntry> _entries;
  Uint8List? _miniStream;

  CompoundFile._(
    this._bytes,
    this._sectorSize,
    this._miniSectorSize,
    this._miniStreamCutoff,
    this._fat,
    this._miniFat,
    this._entries,
  );

  /// Бросает [FormatException], если [bytes] не разбираются как CFB.
  factory CompoundFile.parse(Uint8List bytes) {
    const headerSize = 512;
    if (bytes.length < headerSize) {
      throw const FormatException('OLE2: файл короче заголовка');
    }
    final data = ByteData.sublistView(bytes);
    const signature = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) {
        throw const FormatException('OLE2: нет сигнатуры');
      }
    }

    final sectorShift = data.getUint16(0x1E, Endian.little);
    if (sectorShift != 9 && sectorShift != 12) {
      throw const FormatException('OLE2: неизвестный размер сектора');
    }
    final miniShift = data.getUint16(0x20, Endian.little);
    if (miniShift != 6) {
      throw const FormatException('OLE2: неизвестный размер мини-сектора');
    }
    final sectorSize = 1 << sectorShift;
    final fatSectorCount = data.getUint32(0x2C, Endian.little);
    final firstDirectorySector = data.getUint32(0x30, Endian.little);
    final miniStreamCutoff = data.getUint32(0x38, Endian.little);
    final firstMiniFatSector = data.getUint32(0x3C, Endian.little);
    final firstDifatSector = data.getUint32(0x44, Endian.little);
    final difatSectorCount = data.getUint32(0x48, Endian.little);

    final reader = _SectorReader(bytes, sectorSize);

    // Номера секторов FAT: до 109 в заголовке, остальные — цепочкой DIFAT.
    final fatSectorIds = <int>[];
    for (var i = 0; i < 109 && fatSectorIds.length < fatSectorCount; i++) {
      final id = data.getUint32(0x4C + i * 4, Endian.little);
      if (_isRegular(id)) fatSectorIds.add(id);
    }
    var difatSector = firstDifatSector;
    final perDifat = sectorSize ~/ 4 - 1;
    for (
      var i = 0;
      i < difatSectorCount &&
          _isRegular(difatSector) &&
          fatSectorIds.length < fatSectorCount;
      i++
    ) {
      final sector = reader.sector(difatSector);
      final view = ByteData.sublistView(sector);
      for (var j = 0; j < perDifat && j * 4 + 4 <= sector.length; j++) {
        final id = view.getUint32(j * 4, Endian.little);
        if (_isRegular(id)) fatSectorIds.add(id);
      }
      if (sector.length < sectorSize) break;
      difatSector = view.getUint32(perDifat * 4, Endian.little);
    }

    final fat = <int>[];
    for (final id in fatSectorIds) {
      fat.addAll(_uint32s(reader.sector(id)));
    }

    final directory = _readChain(reader, fat, firstDirectorySector);
    final entries = <CfbEntry>[];
    for (var offset = 0; offset + 128 <= directory.length; offset += 128) {
      entries.add(CfbEntry._parse(directory, offset, entries.length));
    }
    if (entries.isEmpty || entries.first.type != CfbEntryType.root) {
      throw const FormatException('OLE2: нет корневой записи каталога');
    }

    final miniFat = _isRegular(firstMiniFatSector)
        ? _uint32s(_readChain(reader, fat, firstMiniFatSector))
        : const <int>[];

    return CompoundFile._(
      bytes,
      sectorSize,
      1 << miniShift,
      miniStreamCutoff,
      fat,
      miniFat,
      entries,
    );
  }

  CfbEntry get root => _entries.first;

  /// Непосредственные потомки хранилища [storage] в порядке дерева
  /// (красно-чёрное дерево по имени: левый — правый — потомок).
  List<CfbEntry> children(CfbEntry storage) {
    final result = <CfbEntry>[];
    final visited = <int>{};
    final stack = <int>[];
    var current = storage.childId;
    // Обход по порядку без рекурсии: дерево приходит из файла и может быть
    // сколь угодно глубоким или зацикленным.
    while (true) {
      while (_isEntry(current) && visited.add(current)) {
        stack.add(current);
        current = _entries[current].leftId;
      }
      if (stack.isEmpty) break;
      final entry = _entries[stack.removeLast()];
      if (entry.type != CfbEntryType.empty) result.add(entry);
      current = entry.rightId;
    }
    return result;
  }

  /// Потомок [storage] по имени. Имена в CFB сравниваются без учёта
  /// регистра.
  CfbEntry? child(CfbEntry storage, String name) {
    final lower = name.toLowerCase();
    for (final entry in children(storage)) {
      if (entry.name.toLowerCase() == lower) return entry;
    }
    return null;
  }

  /// Содержимое потока. Размер берётся из каталога, но не больше, чем
  /// реально нашлось в цепочке: обрезанный файл даёт обрезанный поток, а не
  /// исключение посреди разбора.
  Uint8List read(CfbEntry stream) {
    if (stream.type != CfbEntryType.stream) {
      throw const FormatException('OLE2: это не поток');
    }
    if (stream.size == 0) return Uint8List(0);
    if (stream.size < _miniStreamCutoff) {
      final mini = _miniStream ??= _readRootMiniStream();
      final out = BytesBuilder(copy: false);
      var sector = stream.startSector;
      var steps = 0;
      final limit = mini.length ~/ _miniSectorSize + 1;
      while (_isRegular(sector) && out.length < stream.size) {
        if (++steps > limit) {
          throw const FormatException('OLE2: цикл в цепочке mini-FAT');
        }
        final start = sector * _miniSectorSize;
        if (start >= mini.length) break;
        final end = (start + _miniSectorSize).clamp(0, mini.length);
        out.add(Uint8List.sublistView(mini, start, end));
        if (sector >= _miniFat.length) break;
        sector = _miniFat[sector];
      }
      return _truncate(out.takeBytes(), stream.size);
    }
    final reader = _SectorReader(_bytes, _sectorSize);
    return _truncate(
      _readChain(reader, _fat, stream.startSector, maxBytes: stream.size),
      stream.size,
    );
  }

  Uint8List _readRootMiniStream() {
    final reader = _SectorReader(_bytes, _sectorSize);
    return _truncate(
      _readChain(reader, _fat, root.startSector, maxBytes: root.size),
      root.size,
    );
  }

  bool _isEntry(int id) => _isRegular(id) && id < _entries.length;
}

enum CfbEntryType { empty, storage, stream, root }

/// Запись каталога CFB: хранилище (папка), поток или корень.
class CfbEntry {
  final int id;
  final String name;
  final CfbEntryType type;
  final int leftId;
  final int rightId;
  final int childId;
  final int startSector;
  final int size;

  const CfbEntry._(
    this.id,
    this.name,
    this.type,
    this.leftId,
    this.rightId,
    this.childId,
    this.startSector,
    this.size,
  );

  factory CfbEntry._parse(Uint8List directory, int offset, int id) {
    final data = ByteData.sublistView(directory, offset, offset + 128);
    final nameLength = data.getUint16(64, Endian.little);
    final units = <int>[];
    // Длина в байтах включает завершающий нулевой символ UTF-16.
    for (var i = 0; i + 2 <= nameLength - 2 && i + 2 <= 64; i += 2) {
      units.add(data.getUint16(i, Endian.little));
    }
    final type = switch (directory[offset + 66]) {
      1 => CfbEntryType.storage,
      2 => CfbEntryType.stream,
      5 => CfbEntryType.root,
      _ => CfbEntryType.empty,
    };
    // Размер — 64 бита, но в версии 3 старшая половина бывает мусором;
    // потоки больше 4 ГБ этому приложению всё равно не встретятся.
    final size = data.getUint32(120, Endian.little);
    return CfbEntry._(
      id,
      String.fromCharCodes(units),
      type,
      data.getUint32(68, Endian.little),
      data.getUint32(72, Endian.little),
      data.getUint32(76, Endian.little),
      data.getUint32(116, Endian.little),
      size,
    );
  }

  @override
  String toString() => 'CfbEntry($name, $type, $size)';
}

/// `0xFFFFFFFA` и выше — служебные значения (конец цепочки, свободный
/// сектор, сектор FAT/DIFAT), а не номера.
bool _isRegular(int id) => id < 0xFFFFFFFA;

class _SectorReader {
  final Uint8List bytes;
  final int sectorSize;

  _SectorReader(this.bytes, this.sectorSize);

  int get sectorCount => (bytes.length + sectorSize - 1) ~/ sectorSize;

  /// Сектор N лежит со смещением (N + 1) * размер: «нулевой» — заголовок.
  /// Последний сектор файла бывает недописан — отдаётся то, что есть.
  Uint8List sector(int id) {
    final offset = (id + 1) * sectorSize;
    if (id < 0 || offset >= bytes.length) {
      throw FormatException('OLE2: сектор $id за концом файла');
    }
    final end = (offset + sectorSize).clamp(0, bytes.length);
    return Uint8List.sublistView(bytes, offset, end);
  }
}

Uint8List _readChain(
  _SectorReader reader,
  List<int> fat,
  int first, {
  int? maxBytes,
}) {
  final out = BytesBuilder(copy: false);
  var sector = first;
  var steps = 0;
  while (_isRegular(sector)) {
    if (++steps > reader.sectorCount) {
      throw const FormatException('OLE2: цикл в цепочке секторов');
    }
    out.add(reader.sector(sector));
    if (maxBytes != null && out.length >= maxBytes) break;
    if (sector >= fat.length) break;
    sector = fat[sector];
  }
  return out.takeBytes();
}

Uint8List _truncate(Uint8List bytes, int size) =>
    bytes.length <= size ? bytes : Uint8List.sublistView(bytes, 0, size);

List<int> _uint32s(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return [
    for (var i = 0; i + 4 <= bytes.length; i += 4)
      data.getUint32(i, Endian.little),
  ];
}

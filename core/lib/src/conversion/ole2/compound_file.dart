import 'dart:typed_data';

/// A full parse of an OLE Compound File (CFB, MS-CFB): the directory as a
/// tree, and reading streams, including the small ones from the mini
/// stream. Needed for `xls` (the `Workbook` stream) and `msg` (properties
/// in `__substg1.0_*` streams and recipient/attachment subdirectories). For
/// type detection, names alone are enough — that's
/// `type_detection/ole2_directory.dart`, which is lighter and tolerates a
/// truncated file.
///
/// Offsets inside the file can't be trusted, same as a zip header: a
/// sector chain can loop, a number can point past the end, a stream's size
/// can exceed the file. So every chain is walked with a cap on the number
/// of steps, and anything that doesn't add up becomes a [FormatException],
/// which the converter turns into a clear, readable failure.
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

  /// Throws [FormatException] if [bytes] doesn't parse as CFB.
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

    // FAT sector numbers: up to 109 in the header, the rest via the DIFAT
    // chain.
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

  /// The immediate children of [storage] in tree order (a red-black tree
  /// keyed by name: left — right — child).
  List<CfbEntry> children(CfbEntry storage) {
    final result = <CfbEntry>[];
    final visited = <int>{};
    final stack = <int>[];
    var current = storage.childId;
    // Non-recursive in-order traversal: the tree comes from the file and
    // can be arbitrarily deep or cyclic.
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

  /// The child of [storage] by name. Names in CFB are compared case-
  /// insensitively.
  CfbEntry? child(CfbEntry storage, String name) {
    final lower = name.toLowerCase();
    for (final entry in children(storage)) {
      if (entry.name.toLowerCase() == lower) return entry;
    }
    return null;
  }

  /// The stream's content. The size is taken from the directory, but
  /// capped at what's actually found in the chain: a truncated file gives
  /// a truncated stream, not an exception mid-parse.
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

/// A CFB directory entry: a storage (folder), a stream, or the root.
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
    // The byte length includes the trailing UTF-16 null character.
    for (var i = 0; i + 2 <= nameLength - 2 && i + 2 <= 64; i += 2) {
      units.add(data.getUint16(i, Endian.little));
    }
    final type = switch (directory[offset + 66]) {
      1 => CfbEntryType.storage,
      2 => CfbEntryType.stream,
      5 => CfbEntryType.root,
      _ => CfbEntryType.empty,
    };
    // The size is 64-bit, but in version 3 the high half can be garbage;
    // streams over 4 GB won't show up for this app anyway.
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

/// `0xFFFFFFFA` and above are reserved values (end of chain, free sector,
/// a FAT/DIFAT sector), not numbers.
bool _isRegular(int id) => id < 0xFFFFFFFA;

class _SectorReader {
  final Uint8List bytes;
  final int sectorSize;

  _SectorReader(this.bytes, this.sectorSize);

  int get sectorCount => (bytes.length + sectorSize - 1) ~/ sectorSize;

  /// Sector N sits at offset (N + 1) * size: sector "zero" is the header.
  /// The file's last sector can be incomplete — whatever's there is
  /// returned.
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

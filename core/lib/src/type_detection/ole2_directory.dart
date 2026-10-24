import 'dart:typed_data';

/// Minimal parsing of an OLE Compound File (CFB, MS-CFB): only the
/// directory — entry names. Extracts nothing from streams and does not
/// parse the mini-FAT: to distinguish `.xls` / `.msg` / `.doc` / `.ppt` it
/// is enough to know which streams live inside (`Workbook`,
/// `__properties_version1.0`, `WordDocument`, …), and the directory itself
/// is stored entirely in regular sectors.
///
/// Returns `null` if the file does not parse as a CFB, or the needed
/// sectors lie outside [bytes] (e.g. not the whole file was passed) — the
/// caller then falls back to the extension hint. Parsing is guarded
/// against looping sector chains and inflated headers: how many sectors
/// can be traversed is bounded by the length of the bytes themselves.
List<String>? readOle2EntryNames(Uint8List bytes) {
  const headerSize = 512;
  if (bytes.length < headerSize) return null;
  final data = ByteData.sublistView(bytes);

  final sectorShift = data.getUint16(0x1E, Endian.little);
  // Version 3 — 512-byte sectors (shift 9), version 4 — 4096 bytes (shift 12).
  if (sectorShift != 9 && sectorShift != 12) return null;
  final sectorSize = 1 << sectorShift;

  final firstDirectorySector = data.getUint32(0x30, Endian.little);
  final fatSectorCount = data.getUint32(0x2C, Endian.little);
  final firstDifatSector = data.getUint32(0x44, Endian.little);
  final difatSectorCount = data.getUint32(0x48, Endian.little);

  // Sector N lies at offset (N + 1) * sectorSize: the file's "zeroth"
  // sector is the header.
  final maxSectors = bytes.length ~/ sectorSize;
  int? sectorOffset(int id) {
    if (id >= maxSectors) return null;
    final offset = (id + 1) * sectorSize;
    if (offset + sectorSize > bytes.length) return null;
    return offset;
  }

  const endOfChain = 0xFFFFFFFE;
  const freeSector = 0xFFFFFFFF;
  bool isRegular(int id) => id < 0xFFFFFFFA;

  // FAT sectors: first up to 109 from the header, then the DIFAT chain.
  final fatSectorIds = <int>[];
  for (var i = 0; i < 109 && fatSectorIds.length < fatSectorCount; i++) {
    final id = data.getUint32(0x4C + i * 4, Endian.little);
    if (id == freeSector) break;
    if (isRegular(id)) fatSectorIds.add(id);
  }
  var difatSector = firstDifatSector;
  for (
    var i = 0;
    i < difatSectorCount &&
        isRegular(difatSector) &&
        fatSectorIds.length < fatSectorCount;
    i++
  ) {
    final offset = sectorOffset(difatSector);
    if (offset == null) return null;
    final perSector = sectorSize ~/ 4 - 1;
    for (var j = 0; j < perSector; j++) {
      final id = data.getUint32(offset + j * 4, Endian.little);
      if (isRegular(id)) fatSectorIds.add(id);
    }
    difatSector = data.getUint32(offset + perSector * 4, Endian.little);
  }

  final fat = <int>[];
  for (final id in fatSectorIds) {
    final offset = sectorOffset(id);
    if (offset == null) return null;
    for (var j = 0; j < sectorSize ~/ 4; j++) {
      fat.add(data.getUint32(offset + j * 4, Endian.little));
    }
  }

  final names = <String>[];
  var sector = firstDirectorySector;
  var steps = 0;
  while (isRegular(sector)) {
    if (++steps > maxSectors) return null; // loop in the chain
    final offset = sectorOffset(sector);
    if (offset == null) return null;

    for (var entry = 0; entry < sectorSize ~/ 128; entry++) {
      final base = offset + entry * 128;
      final type = bytes[base + 66]; // 0 empty, 1 directory, 2 stream, 5 root
      if (type == 0) continue;
      final nameLength = data.getUint16(base + 64, Endian.little);
      if (nameLength < 2 || nameLength > 64) continue;
      // Length includes the trailing UTF-16 null terminator.
      final nameBytes = bytes.sublist(base, base + nameLength - 2);
      names.add(_decodeUtf16le(nameBytes));
    }

    if (sector >= fat.length) break;
    final next = fat[sector];
    if (next == endOfChain) break;
    sector = next;
  }

  return names.isEmpty ? null : names;
}

String _decodeUtf16le(Uint8List bytes) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(units);
}

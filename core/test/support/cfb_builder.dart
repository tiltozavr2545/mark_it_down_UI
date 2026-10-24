import 'dart:typed_data';

/// Builds a minimal OLE Compound File (CFB) with the given entry names in
/// the directory — just enough to test recognizing `.xls` / `.msg` /
/// `.doc` without real files. The streams have no content: the detector
/// only needs the names.
///
/// Layout: header, sector 0 is the FAT, sectors 1..k are the directory
/// (chained when there are more entries than fit in one sector).
/// [sectorShift] 9 is like version 3 (512 bytes), 12 is version 4 (4096).
/// [loopDirectory] closes the directory chain onto itself — a check of
/// the loop guard.
Uint8List buildCfb(
  List<String> streamNames, {
  int sectorShift = 9,
  bool loopDirectory = false,
}) {
  final sectorSize = 1 << sectorShift;
  final entries = ['Root Entry', ...streamNames];
  final perSector = sectorSize ~/ 128;
  final dirSectors = (entries.length + perSector - 1) ~/ perSector;
  final totalSectors = 1 + dirSectors; // FAT + directory

  final out = Uint8List(sectorSize * (1 + totalSectors));
  final data = ByteData.sublistView(out);
  const endOfChain = 0xFFFFFFFE;
  const free = 0xFFFFFFFF;
  const fatSect = 0xFFFFFFFD;

  // Header.
  out.setAll(0, [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]);
  data.setUint16(0x18, 0x003E, Endian.little); // minor version
  data.setUint16(0x1A, sectorShift == 9 ? 3 : 4, Endian.little);
  data.setUint16(0x1C, 0xFFFE, Endian.little); // little-endian
  data.setUint16(0x1E, sectorShift, Endian.little);
  data.setUint16(0x20, 6, Endian.little); // mini sector shift
  data.setUint32(0x28, sectorShift == 9 ? 0 : dirSectors, Endian.little);
  data.setUint32(0x2C, 1, Endian.little); // number of FAT sectors
  data.setUint32(0x30, 1, Endian.little); // first directory sector
  data.setUint32(0x38, 4096, Endian.little); // mini stream cutoff
  data.setUint32(0x3C, endOfChain, Endian.little); // first mini-FAT
  data.setUint32(0x44, endOfChain, Endian.little); // first DIFAT
  for (var i = 0; i < 109; i++) {
    data.setUint32(0x4C + i * 4, i == 0 ? 0 : free, Endian.little);
  }

  // FAT (sector 0 → offset sectorSize).
  final fatBase = sectorSize;
  for (var i = 0; i < sectorSize ~/ 4; i++) {
    data.setUint32(fatBase + i * 4, free, Endian.little);
  }
  data.setUint32(fatBase, fatSect, Endian.little); // sector 0 is the FAT itself
  for (var s = 1; s <= dirSectors; s++) {
    final next = s < dirSectors ? s + 1 : (loopDirectory ? 1 : endOfChain);
    data.setUint32(fatBase + s * 4, next, Endian.little);
  }

  // Directory (sector N → offset (N + 1) * sectorSize).
  for (var i = 0; i < entries.length; i++) {
    final sector = 1 + i ~/ perSector;
    final base = (sector + 1) * sectorSize + (i % perSector) * 128;
    final name = entries[i];
    for (var c = 0; c < name.length; c++) {
      data.setUint16(base + c * 2, name.codeUnitAt(c), Endian.little);
    }
    data.setUint16(base + 64, (name.length + 1) * 2, Endian.little);
    out[base + 66] = i == 0 ? 5 : 2; // root / stream
    out[base + 67] = 1; // black
    data.setUint32(base + 68, free, Endian.little);
    data.setUint32(base + 72, free, Endian.little);
    data.setUint32(base + 76, free, Endian.little);
  }
  return out;
}

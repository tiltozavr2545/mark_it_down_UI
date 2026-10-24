import 'dart:typed_data';

import 'detected_type.dart';
import 'ole2_directory.dart';

bool _startsWith(Uint8List bytes, List<int> signature) {
  if (bytes.length < signature.length) return false;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return false;
  }
  return true;
}

const _pdfSignature = [0x25, 0x50, 0x44, 0x46, 0x2D]; // %PDF-
const _ole2Signature = [
  0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, // OLE2 compound file
];
const _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
const _jpegSignature = [0xFF, 0xD8, 0xFF];
const _gifSignature = [0x47, 0x49, 0x46, 0x38]; // GIF8
const _bmpSignature = [0x42, 0x4D]; // BM
const _tiffLittleEndian = [0x49, 0x49, 0x2A, 0x00]; // II*\0
const _tiffBigEndian = [0x4D, 0x4D, 0x00, 0x2A]; // MM\0*

/// `ftyp` brands under which still images for HEIF/AVIF are written. The
/// same `ftyp` box also opens MP4/M4A/MOV — hence the check is by brand, not
/// just the `ftyp` word: otherwise video and audio from a phone would turn
/// into a "picture".
const _heifBrands = {
  'heic',
  'heix',
  'heim',
  'heis',
  'hevc',
  'hevx',
  'mif1',
  'msf1',
  'avif',
  'avis',
};

/// Three variants of the zip signature: regular, empty archive, multi-disk
/// archive. The difference between them doesn't matter for format
/// detection — [refineZipFamily] takes it from there.
const _zipSignatures = [
  [0x50, 0x4B, 0x03, 0x04],
  [0x50, 0x4B, 0x05, 0x06],
  [0x50, 0x4B, 0x07, 0x08],
];

bool isPdf(Uint8List head) => _startsWith(head, _pdfSignature);

bool isOle2Compound(Uint8List head) => _startsWith(head, _ole2Signature);

bool isZipSignature(Uint8List head) =>
    _zipSignatures.any((signature) => _startsWith(head, signature));

bool _isWebp(Uint8List head) => _isRiff(head, 'WEBP');

/// The `ftyp` brand (`heic`, `M4A `, `isom`…) or `null` if the file doesn't
/// start with a `ftyp` box.
String? _ftypBrand(Uint8List head) {
  if (head.length < 12) return null;
  if (String.fromCharCodes(head.sublist(4, 8)) != 'ftyp') return null;
  return String.fromCharCodes(head.sublist(8, 12));
}

/// `HEIF`: `[size]ftyp<brand>` at the start of the file, see [_heifBrands].
bool _isHeif(Uint8List head) => _heifBrands.contains(_ftypBrand(head));

/// Image signatures — a cheap way to tell them apart from other binary
/// formats.
DetectedType? detectImageSignature(Uint8List head) {
  if (_startsWith(head, _pngSignature)) {
    return const DetectedType(FileKind.png, 'PNG');
  }
  if (_startsWith(head, _jpegSignature)) {
    return const DetectedType(FileKind.jpeg, 'JPEG');
  }
  if (_startsWith(head, _gifSignature)) {
    return const DetectedType(FileKind.gif, 'GIF');
  }
  if (_isWebp(head)) {
    return const DetectedType(FileKind.webp, 'WebP');
  }
  if (_startsWith(head, _tiffLittleEndian) ||
      _startsWith(head, _tiffBigEndian)) {
    return const DetectedType(FileKind.tiff, 'TIFF');
  }
  if (_isHeif(head)) {
    return const DetectedType(FileKind.heic, 'HEIC');
  }
  if (_startsWith(head, _bmpSignature)) {
    return const DetectedType(FileKind.bmp, 'BMP');
  }
  return null;
}

/// An OLE2 container alone doesn't tell us whether we're looking at `.doc`,
/// `.xls`, `.msg`, or `.ppt` — they all share one signature. They're
/// distinguished by the stream names in the CFB directory
/// ([readOle2EntryNames]): `Workbook`/`Book` — Excel,
/// `__properties_version1.0` and `__substg1.0_*` — Outlook `.msg`,
/// `WordDocument` — Word, `PowerPoint Document` — PowerPoint. The extension
/// is only a fallback hint for when the directory couldn't be read
/// (truncated file, nonstandard container): it can lie too.
DetectedType describeOle2(Uint8List head, String? extension) {
  final names = readOle2EntryNames(head);
  if (names != null) {
    if (names.any(
      (n) =>
          n == '__properties_version1.0' ||
          n.startsWith('__substg1.0_') ||
          n.startsWith('__recip_version1.0_') ||
          n.startsWith('__attach_version1.0_'),
    )) {
      return const DetectedType(FileKind.msg, 'Outlook-сообщение (.msg)');
    }
    if (names.contains('Workbook') || names.contains('Book')) {
      return const DetectedType(FileKind.xls, 'Excel 97–2003 (.xls)');
    }
    if (names.contains('WordDocument')) {
      return const DetectedType(FileKind.doc, 'Word 97–2003 (.doc)');
    }
    if (names.contains('PowerPoint Document')) {
      return const DetectedType(FileKind.ppt, 'PowerPoint 97–2003 (.ppt)');
    }
  }

  const knownExtensions = {'doc', 'xls', 'msg', 'ppt'};
  if (extension != null && knownExtensions.contains(extension)) {
    return DetectedType(
      FileKind.ole2Compound,
      'OLE2-контейнер, похоже на .$extension (по расширению)',
    );
  }
  return const DetectedType(
    FileKind.ole2Compound,
    'OLE2-контейнер (.doc / .xls / .msg)',
  );
}

/// The length of the ID3v2 tag including its header (and footer, if
/// present), or `null` if the file doesn't start with one. The size is
/// "synchsafe": 7 bits in each of the four bytes.
int? id3v2Length(Uint8List head) {
  if (head.length < 10 ||
      head[0] != 0x49 ||
      head[1] != 0x44 ||
      head[2] != 0x33) {
    return null;
  }
  // Version 2-4: a text file starting with "ID3" would have a printable
  // character in this spot.
  if (head[3] < 2 || head[3] > 4 || head[4] == 0xFF) return null;
  if ((head[6] | head[7] | head[8] | head[9]) >= 0x80) return null;
  final size = (head[6] << 21) | (head[7] << 14) | (head[8] << 7) | head[9];
  final hasFooter = head[3] == 4 && head[5] & 0x10 != 0;
  return 10 + size + (hasFooter ? 10 : 0);
}

/// MPEG audio frame header, Layer I-III. Checks not only the sync word (11
/// set bits) but also forbidden field values: otherwise any binary junk
/// starting with `0xFFE…` would turn into "MP3". ADTS (AAC) with the same
/// sync word is excluded by the layer = 00 field.
bool isMpegAudioFrame(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 4 > bytes.length) return false;
  final b1 = bytes[offset + 1];
  final b2 = bytes[offset + 2];
  return bytes[offset] == 0xFF &&
      b1 & 0xE0 == 0xE0 &&
      (b1 >> 3) & 3 != 1 && // version: reserved
      (b1 >> 1) & 3 != 0 && // layer: reserved (and ADTS)
      b2 >> 4 != 0x0F && // bitrate: forbidden index
      (b2 >> 2) & 3 != 3; // sample rate: reserved
}

/// Audio and ISO BMFF containers. Called after images: HEIF shares the
/// `ftyp` box with MP4, and they can only be told apart by brand.
DetectedType? detectMediaSignature(Uint8List head, String? extension) {
  final id3 = id3v2Length(head);
  if (id3 != null) {
    // ID3 can also precede FLAC. If the tag is longer than what was read
    // (a large cover image), we can't look past it — then the extension
    // is the fallback hint.
    final flacAfterTag = _startsWith(
      Uint8List.sublistView(head, id3.clamp(0, head.length)),
      _flacSignature,
    );
    if (flacAfterTag || (id3 >= head.length && extension == 'flac')) {
      return const DetectedType(FileKind.flac, 'FLAC');
    }
    return const DetectedType(FileKind.mp3, 'MP3');
  }
  if (_startsWith(head, _flacSignature)) {
    return const DetectedType(FileKind.flac, 'FLAC');
  }
  if (_startsWith(head, _oggSignature)) {
    return const DetectedType(FileKind.ogg, 'Ogg');
  }
  if (_isRiff(head, 'WAVE')) {
    return const DetectedType(FileKind.wav, 'WAV');
  }
  final brand = _ftypBrand(head);
  if (brand != null) {
    return DetectedType(FileKind.mp4, switch (brand) {
      'M4A ' || 'M4B ' || 'M4P ' || 'F4A ' => 'M4A (аудио MPEG-4)',
      'qt  ' => 'MOV (QuickTime)',
      _ when brand.startsWith('3g') => '3GP',
      _ => 'MP4',
    });
  }
  if (isMpegAudioFrame(head, 0)) {
    return const DetectedType(FileKind.mp3, 'MP3');
  }
  return null;
}

const _flacSignature = [0x66, 0x4C, 0x61, 0x43]; // fLaC
const _oggSignature = [0x4F, 0x67, 0x67, 0x53]; // OggS

bool _isRiff(Uint8List head, String form) =>
    head.length >= 12 &&
    String.fromCharCodes(head.sublist(0, 4)) == 'RIFF' &&
    String.fromCharCodes(head.sublist(8, 12)) == form;

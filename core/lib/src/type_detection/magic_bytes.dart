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

/// Марки `ftyp`, под которыми пишутся неподвижные изображения HEIF/AVIF.
/// Та же коробка `ftyp` открывает и MP4/M4A/MOV — поэтому по марке, а не по
/// одному слову `ftyp`: иначе видео и аудио с телефона стали бы «картинкой».
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

/// Три варианта сигнатуры zip: обычный, пустой архив, архив из нескольких
/// дисков. Для распознавания формата различие между ними не важно — дальше
/// за дело берётся [refineZipFamily].
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

/// Марка `ftyp` (`heic`, `M4A `, `isom`…) или `null`, если файл не
/// начинается с коробки `ftyp`.
String? _ftypBrand(Uint8List head) {
  if (head.length < 12) return null;
  if (String.fromCharCodes(head.sublist(4, 8)) != 'ftyp') return null;
  return String.fromCharCodes(head.sublist(8, 12));
}

/// `HEIF`: `[размер]ftyp<марка>` в начале файла, см. [_heifBrands].
bool _isHeif(Uint8List head) => _heifBrands.contains(_ftypBrand(head));

/// Сигнатуры картинок — дёшево отличить от прочих бинарных форматов.
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

/// OLE2-контейнер сам по себе не говорит, `.doc`, `.xls`, `.msg` или `.ppt`
/// перед нами — все они делят одну сигнатуру. Различаются по именам потоков
/// в каталоге CFB ([readOle2EntryNames]): `Workbook`/`Book` — Excel,
/// `__properties_version1.0` и `__substg1.0_*` — Outlook `.msg`,
/// `WordDocument` — Word, `PowerPoint Document` — PowerPoint. Расширение —
/// только запасная подсказка, когда каталог прочитать не удалось (обрезанный
/// файл, нестандартный контейнер): оно может и врать.
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

/// Длина тега ID3v2 вместе с заголовком (и футером, если он есть) или
/// `null`, если файл с него не начинается. Размер — «synchsafe»: по 7 бит
/// в каждом из четырёх байтов.
int? id3v2Length(Uint8List head) {
  if (head.length < 10 ||
      head[0] != 0x49 ||
      head[1] != 0x44 ||
      head[2] != 0x33) {
    return null;
  }
  // Версия 2–4: у текстового файла, начинающегося с «ID3», на этом месте
  // печатный символ.
  if (head[3] < 2 || head[3] > 4 || head[4] == 0xFF) return null;
  if ((head[6] | head[7] | head[8] | head[9]) >= 0x80) return null;
  final size = (head[6] << 21) | (head[7] << 14) | (head[8] << 7) | head[9];
  final hasFooter = head[3] == 4 && head[5] & 0x10 != 0;
  return 10 + size + (hasFooter ? 10 : 0);
}

/// Заголовок кадра MPEG-аудио Layer I–III. Проверяется не только
/// синхрослово (11 единиц), но и запрещённые значения полей: иначе любой
/// бинарный мусор с `0xFFE…` в начале стал бы «MP3». ADTS (AAC) с тем же
/// синхрословом отсекается полем layer = 00.
bool isMpegAudioFrame(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 4 > bytes.length) return false;
  final b1 = bytes[offset + 1];
  final b2 = bytes[offset + 2];
  return bytes[offset] == 0xFF &&
      b1 & 0xE0 == 0xE0 &&
      (b1 >> 3) & 3 != 1 && // версия: зарезервировано
      (b1 >> 1) & 3 != 0 && // layer: зарезервировано (и ADTS)
      b2 >> 4 != 0x0F && // битрейт: запрещённый индекс
      (b2 >> 2) & 3 != 3; // частота: зарезервировано
}

/// Аудио и контейнеры ISO BMFF. Вызывается после картинок: HEIF делит с
/// MP4 коробку `ftyp`, и отличить их можно только по марке.
DetectedType? detectMediaSignature(Uint8List head, String? extension) {
  final id3 = id3v2Length(head);
  if (id3 != null) {
    // ID3 бывает и перед FLAC. Если тег длиннее прочитанного (большая
    // обложка), заглянуть за него нельзя — тогда подсказка расширения.
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

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../markdown_writer.dart' as md;
import '../../stream_info.dart';
import '../../type_detection/detected_type.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';
import '../image/exif_reader.dart';
import '../image/image_container.dart';
import '../image/image_size.dart';
import '../ocr/tesseract_ocr.dart';

const _imageKinds = {
  FileKind.png,
  FileKind.jpeg,
  FileKind.gif,
  FileKind.bmp,
  FileKind.webp,
  FileKind.tiff,
  FileKind.heic,
};

/// Formats that Leptonica decodes in both builds (Android and desktop, see
/// `tesseract/build.sh`) — their bytes go into OCR as-is.
const _ocrKinds = {FileKind.jpeg, FileKind.png, FileKind.bmp};

/// Our builds' Leptonica doesn't know these (no giflib, libwebp, libtiff),
/// so pure Dart (`package:image`) decodes them: the first frame is
/// re-encoded to PNG and goes down the same path. Neither of them decodes
/// HEIC.
const _dartDecodedKinds = {FileKind.gif, FileKind.webp, FileKind.tiff};

/// An image → a list of metadata: format, size, and whatever is in the
/// EXIF (camera, date, shooting parameters, geotag, captions), and with
/// [ocr] — also the recognized text. There's no hard failure here: the
/// format is recognized by its signature, and even without EXIF and with a
/// corrupted header there's something to say. See
/// `docs/format-coverage.md#решения-этапа-6`.
class ImageConverter implements DocumentConverter {
  const ImageConverter({this.ocr});

  final OcrSettings? ocr;

  @override
  String get id => 'image';

  @override
  double get priority => 0.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) =>
      _imageKinds.contains(info.detectedType.kind);

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final bytes = request.bytes;
    final kind = request.info.detectedType.kind;
    final warnings = <ConversionWarning>[];

    ExifData? exif;
    var exifDamaged = false;
    try {
      final block = findExifBlock(bytes, kind);
      if (block != null) {
        exif = readExif(block);
        exifDamaged = exif == null || exif.damaged;
      }
    } on RangeError {
      // Container and TIFF parsing checks bounds itself; if it missed a
      // check somewhere, that's no reason to lose the format and size we
      // already have.
      exif = null;
      exifDamaged = true;
    }
    if (exifDamaged) {
      warnings.add(
        const ConversionWarning(
          'метаданные EXIF повреждены — показано то, что удалось прочитать',
        ),
      );
    }

    final fields = <(String, String?)>[
      ('Формат', request.info.detectedType.label),
      ('Размер', _size(bytes, kind, exif)?.toString()),
    ];
    if (exif != null) fields.addAll(_exifFields(exif));

    final location = exif == null ? null : _location(exif.gps);
    if (location != null) {
      fields.add(('Геометка', location));
      warnings.add(
        const ConversionWarning(
          'в результате есть геометка — координаты места съёмки; если не '
          'хотите ими делиться, удалите эту строку перед отправкой',
        ),
      );
    }
    final text = _recognize(bytes, kind, exif, warnings);

    final lines = [
      for (final (label, value) in fields)
        if (value != null) '- ${md.bold('$label:')} ${md.escapeInline(value)}',
    ];
    final blocks = [
      lines.join('\n'),
      if (text != null && text.isNotEmpty) ...[
        md.heading(2, 'Текст на изображении'),
        for (final paragraph in text) md.escapeInline(paragraph),
      ],
    ];
    return ConversionResult(
      markdown: blocks.join('\n\n'),
      converterId: id,
      elapsed: Duration.zero,
      title: exif?.image[_xpTitle]?.utf16LeText,
      warnings: warnings,
    );
  }

  /// Paragraphs of recognized text; `null` means OCR wasn't run. Anything
  /// that went wrong goes into [warnings], not an exception: the metadata
  /// is already there.
  List<String>? _recognize(
    Uint8List bytes,
    FileKind kind,
    ExifData? exif,
    List<ConversionWarning> warnings,
  ) {
    final settings = ocr;
    if (settings == null) {
      warnings.add(
        const ConversionWarning(
          'текст с изображения не распознаётся — в результате только '
          'метаданные',
        ),
      );
      return null;
    }
    if (!_ocrKinds.contains(kind) && !_dartDecodedKinds.contains(kind)) {
      warnings.add(
        ConversionWarning(
          'распознавание текста для ${_kindName(kind)} не поддерживается — '
          'в результате только метаданные',
        ),
      );
      return null;
    }
    final engine = TesseractOcr.open(settings);
    if (engine == null) {
      warnings.add(
        const ConversionWarning(
          'распознавание текста недоступно: нет движка OCR или языковых '
          'моделей',
        ),
      );
      return null;
    }
    try {
      final encoded = _ocrKinds.contains(kind) ? bytes : _pngForOcr(bytes);
      final result = encoded == null
          ? null
          : engine.recognizeEncoded(
              encoded,
              quarterTurns: _quarterTurns(exif?.image[_orientation]?.ints),
            );
      if (result == null) {
        warnings.add(
          const ConversionWarning(
            'изображение не удалось декодировать для распознавания текста',
          ),
        );
        return null;
      }
      final paragraphs = ocrParagraphs(result.text);
      if (paragraphs.isEmpty) {
        warnings.add(const ConversionWarning('текст на изображении не найден'));
        return paragraphs;
      }
      warnings.add(
        ConversionWarning(
          'текст распознан OCR (${engine.engine}) — возможны ошибки '
          'распознавания',
        ),
      );
      if (result.confidence < lowOcrConfidence) {
        warnings.add(
          ConversionWarning(
            'уверенность распознавания низкая (${result.confidence} из 100) '
            '— проверьте текст',
          ),
        );
      }
      return paragraphs;
    } finally {
      engine.dispose();
    }
  }
}

/// The first GIF/WebP/TIFF frame → PNG for Leptonica. Transparency is
/// composited onto a white background: otherwise Tesseract sees a
/// sticker's or animation's transparent background as black, and black
/// text on it disappears. `null` means it didn't decode.
Uint8List? _pngForOcr(Uint8List bytes) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes, frame: 0);
  } catch (_) {
    return null;
  }
  if (decoded == null) return null;
  var frame = decoded;
  if (frame.hasAlpha) {
    final background = img.Image(
      width: frame.width,
      height: frame.height,
      numChannels: 3,
    )..clear(img.ColorRgb8(255, 255, 255));
    frame = img.compositeImage(background, frame);
  }
  // Minimal compression: the PNG only lives until recognition finishes,
  // and the time to pack a large frame in pure Dart is noticeable.
  return img.encodePng(frame, level: 1);
}

String _kindName(FileKind kind) => switch (kind) {
  FileKind.heic => 'HEIC',
  _ => 'этого формата',
};

/// EXIF `Orientation` → how many times to rotate 90° clockwise so the
/// text sits upright. Mirrored variants (2, 4, 5, 7) don't occur in
/// document photos — for those only a rotation without a flip is applied.
int _quarterTurns(List<int>? orientation) => switch (_first(orientation)) {
  3 || 4 => 2,
  5 || 6 => 1,
  7 || 8 => 3,
  _ => 0,
};

// Main IFD tags.
const _imageWidth = 0x0100;
const _imageLength = 0x0101;
const _imageDescription = 0x010E;
const _make = 0x010F;
const _model = 0x0110;
const _orientation = 0x0112;
const _software = 0x0131;
const _artist = 0x013B;
const _copyright = 0x8298;
const _xpTitle = 0x9C9B;
const _xpComment = 0x9C9C;
const _xpAuthor = 0x9C9D;
const _xpKeywords = 0x9C9E;

// Exif IFD tags.
const _exposureTime = 0x829A;
const _fNumber = 0x829D;
const _iso = 0x8827;
const _dateTimeOriginal = 0x9003;
const _dateTimeDigitized = 0x9004;
const _offsetTimeOriginal = 0x9011;
const _focalLength = 0x920A;
const _userComment = 0x9286;
const _pixelXDimension = 0xA002;
const _pixelYDimension = 0xA003;
const _lensModel = 0xA434;

// GPS IFD tags.
const _gpsLatitudeRef = 0x0001;
const _gpsLatitude = 0x0002;
const _gpsLongitudeRef = 0x0003;
const _gpsLongitude = 0x0004;
const _gpsAltitudeRef = 0x0005;
const _gpsAltitude = 0x0006;

/// Captions that cameras set on their own are not a photo description —
/// just noise.
const _cameraDefaultDescriptions = {
  'OLYMPUS DIGITAL CAMERA',
  'SONY DSC',
  'DIGITAL CAMERA',
  'EXIF_JPEG_PICTURE',
  'DEFAULT',
};

/// From the header, and if the format has nowhere to take it from
/// (`TIFF`) or it's corrupted — from EXIF: first the TIFF main image size,
/// then `PixelXDimension`/`PixelYDimension`.
ImageSize? _size(Uint8List bytes, FileKind kind, ExifData? exif) {
  final fromHeader = readImageSize(bytes, kind);
  if (fromHeader != null || exif == null) return fromHeader;
  ImageSize? pair(Map<int, ExifEntry> ifd, int widthTag, int heightTag) {
    final width = ifd[widthTag]?.ints ?? const [];
    final height = ifd[heightTag]?.ints ?? const [];
    if (width.isEmpty || height.isEmpty) return null;
    if (width.first <= 0 || height.first <= 0) return null;
    return ImageSize(width.first, height.first);
  }

  return (kind == FileKind.tiff
          ? pair(exif.image, _imageWidth, _imageLength)
          : null) ??
      pair(exif.exif, _pixelXDimension, _pixelYDimension);
}

List<(String, String?)> _exifFields(ExifData exif) {
  final image = exif.image;
  final details = exif.exif;

  final description = image[_imageDescription]?.text;
  return [
    ('Название', image[_xpTitle]?.utf16LeText),
    (
      'Описание',
      description == null ||
              _cameraDefaultDescriptions.contains(description.toUpperCase())
          ? null
          : description,
    ),
    (
      'Комментарий',
      details[_userComment]?.userComment ?? image[_xpComment]?.utf16LeText,
    ),
    ('Ключевые слова', image[_xpKeywords]?.utf16LeText),
    ('Автор', image[_artist]?.text ?? image[_xpAuthor]?.utf16LeText),
    ('Авторские права', image[_copyright]?.text),
    ('Камера', _camera(image[_make]?.text, image[_model]?.text)),
    ('Объектив', details[_lensModel]?.text),
    (
      'Снято',
      _date(
        details[_dateTimeOriginal]?.text ?? details[_dateTimeDigitized]?.text,
        details[_offsetTimeOriginal]?.text,
      ),
    ),
    ('Параметры съёмки', _shooting(details)),
    ('Программа', image[_software]?.text),
    ('Ориентация', _orientationText(image[_orientation]?.ints)),
  ];
}

/// `Canon` + `Canon EOS 5D` → `Canon EOS 5D`; `Apple` + `iPhone 12` →
/// `Apple iPhone 12`. The first word of the make is compared: `NIKON
/// CORPORATION` writes the model as `NIKON D750`.
String? _camera(String? make, String? model) {
  if (make == null) return model;
  if (model == null) return make;
  final brand = make.split(' ').first.toLowerCase();
  return model.toLowerCase().startsWith(brand) ? model : '$make $model';
}

/// `2024:07:14 18:32:05` → `2024-07-14 18:32:05`, with the UTC offset if
/// it was recorded. Cameras write a zero date (`0000:00:00 …`) instead of
/// "not set".
String? _date(String? raw, String? offset) {
  if (raw == null) return null;
  final match = RegExp(r'^(\d{4}):(\d{2}):(\d{2})(.*)$').firstMatch(raw);
  if (match == null) return raw;
  if (match[1] == '0000') return null;
  final date = '${match[1]}-${match[2]}-${match[3]}${match[4]}';
  return offset == null ? date : '$date (UTC$offset)';
}

/// Exposure time, aperture, ISO, focal length — on one line, the way
/// photographers write them: `1/250 с, f/2.8, ISO 200, 50 мм` (output
/// stays in the Russian-language format).
String? _shooting(Map<int, ExifEntry> details) {
  final parts = <String>[];

  final exposure = _first(details[_exposureTime]?.rationals);
  if (exposure != null) {
    final (num, den) = exposure;
    if (num > 0 && den > 0) {
      parts.add(
        num < den ? '1/${(den / num).round()} с' : '${_decimal(num / den)} с',
      );
    }
  }

  final fNumber = _ratio(details[_fNumber]?.rationals);
  if (fNumber != null && fNumber > 0) parts.add('f/${_decimal(fNumber)}');

  final iso = _first(details[_iso]?.ints);
  if (iso != null && iso > 0) parts.add('ISO $iso');

  final focal = _ratio(details[_focalLength]?.rationals);
  if (focal != null && focal > 0) parts.add('${_decimal(focal)} мм');

  return parts.isEmpty ? null : parts.join(', ');
}

/// The `Orientation` tag's value — how to rotate the stored pixels to
/// display the photo correctly. `1` (as-is) is not written out.
String? _orientationText(List<int>? value) => switch (_first(value)) {
  2 => 'отразить по горизонтали',
  3 => 'повернуть на 180°',
  4 => 'отразить по вертикали',
  5 => 'отразить по горизонтали и повернуть на 90° против часовой',
  6 => 'повернуть на 90° по часовой',
  7 => 'отразить по горизонтали и повернуть на 90° по часовой',
  8 => 'повернуть на 90° против часовой',
  _ => null,
};

/// Latitude and longitude in decimal degrees (6 digits — about 10 cm),
/// and altitude if present. `0, 0` is how "no satellites found" gets
/// written, not a coordinate in the Gulf of Guinea.
String? _location(Map<int, ExifEntry> gps) {
  final latitude = _degrees(gps[_gpsLatitude], gps[_gpsLatitudeRef], 'S');
  final longitude = _degrees(gps[_gpsLongitude], gps[_gpsLongitudeRef], 'W');
  if (latitude == null || longitude == null) return null;
  if (latitude.abs() > 90 || longitude.abs() > 180) return null;
  if (latitude == 0 && longitude == 0) return null;

  final position =
      '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';
  final altitude = _ratio(gps[_gpsAltitude]?.rationals);
  if (altitude == null) return position;
  final belowSeaLevel = _first(gps[_gpsAltitudeRef]?.ints) == 1;
  return '$position, высота ${(belowSeaLevel ? -altitude : altitude).round()} м';
}

/// Degrees, minutes, seconds as three fractions → signed decimal degrees.
double? _degrees(ExifEntry? value, ExifEntry? ref, String negativeRef) {
  final parts = value?.rationals ?? const [];
  if (parts.length != 3 || parts.any((p) => p.$2 == 0)) return null;
  final degrees =
      parts[0].$1 / parts[0].$2 +
      parts[1].$1 / parts[1].$2 / 60 +
      parts[2].$1 / parts[2].$2 / 3600;
  return ref?.text?.toUpperCase() == negativeRef ? -degrees : degrees;
}

T? _first<T>(List<T>? values) =>
    values == null || values.isEmpty ? null : values.first;

double? _ratio(List<(int, int)>? values) {
  final value = _first(values);
  if (value == null || value.$2 == 0) return null;
  return value.$1 / value.$2;
}

/// `2.8` → `2.8`, `50.0` → `50`: a stray `.0` in `f/4.0` looks machine-made.
String _decimal(double value) {
  final rounded = (value * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.round().toString()
      : rounded.toString();
}

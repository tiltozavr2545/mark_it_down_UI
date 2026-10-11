import 'dart:typed_data';

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

/// Форматы, которые декодирует Leptonica обеих сборок (Android и десктоп,
/// см. `tesseract/build.sh`), — только их можно отдать в OCR.
const _ocrKinds = {FileKind.jpeg, FileKind.png, FileKind.bmp};

/// Изображение → список метаданных: формат, размер и то, что есть в EXIF
/// (камера, дата, параметры съёмки, геометка, подписи), а с [ocr] — и
/// распознанный текст. Отказа здесь не бывает: формат опознан по
/// сигнатуре, и даже без EXIF и с битым заголовком есть что сказать. См.
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
      // Разбор контейнера и TIFF проверяет границы сам; если где-то не
      // проверил — это не повод терять формат и размер, которые уже есть.
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

  /// Абзацы распознанного текста; `null` — OCR не запускался. Всё, что
  /// пошло не так, — в [warnings], не исключением: метаданные уже есть.
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
    if (!_ocrKinds.contains(kind)) {
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
      final result = engine.recognizeEncoded(
        bytes,
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

String _kindName(FileKind kind) => switch (kind) {
  FileKind.gif => 'GIF',
  FileKind.webp => 'WebP',
  FileKind.tiff => 'TIFF',
  FileKind.heic => 'HEIC',
  _ => 'этого формата',
};

/// EXIF `Orientation` → сколько раз повернуть на 90° по часовой, чтобы
/// текст встал ровно. Зеркальные варианты (2, 4, 5, 7) у фото документов не
/// встречаются — для них только поворот без отражения.
int _quarterTurns(List<int>? orientation) => switch (_first(orientation)) {
  3 || 4 => 2,
  5 || 6 => 1,
  7 || 8 => 3,
  _ => 0,
};

// Теги основного IFD.
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

// Теги IFD Exif.
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

// Теги IFD GPS.
const _gpsLatitudeRef = 0x0001;
const _gpsLatitude = 0x0002;
const _gpsLongitudeRef = 0x0003;
const _gpsLongitude = 0x0004;
const _gpsAltitudeRef = 0x0005;
const _gpsAltitude = 0x0006;

/// Подписи, которые камеры ставят сами, — это не описание снимка, а шум.
const _cameraDefaultDescriptions = {
  'OLYMPUS DIGITAL CAMERA',
  'SONY DSC',
  'DIGITAL CAMERA',
  'EXIF_JPEG_PICTURE',
  'DEFAULT',
};

/// По заголовку, а если у формата его негде взять (`TIFF`) или он
/// битый — из EXIF: сначала размер основного изображения TIFF, потом
/// `PixelXDimension`/`PixelYDimension`.
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
/// `Apple iPhone 12`. Сравнивается первое слово марки: `NIKON CORPORATION`
/// пишет модель как `NIKON D750`.
String? _camera(String? make, String? model) {
  if (make == null) return model;
  if (model == null) return make;
  final brand = make.split(' ').first.toLowerCase();
  return model.toLowerCase().startsWith(brand) ? model : '$make $model';
}

/// `2024:07:14 18:32:05` → `2024-07-14 18:32:05`, со смещением от UTC, если
/// оно записано. Нулевую дату (`0000:00:00 …`) камеры пишут вместо
/// «не задана».
String? _date(String? raw, String? offset) {
  if (raw == null) return null;
  final match = RegExp(r'^(\d{4}):(\d{2}):(\d{2})(.*)$').firstMatch(raw);
  if (match == null) return raw;
  if (match[1] == '0000') return null;
  final date = '${match[1]}-${match[2]}-${match[3]}${match[4]}';
  return offset == null ? date : '$date (UTC$offset)';
}

/// Выдержка, диафрагма, ISO, фокусное расстояние — одной строкой, как их
/// пишут фотографы: `1/250 с, f/2.8, ISO 200, 50 мм`.
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

/// Значение тега `Orientation` — как повернуть сохранённые пиксели, чтобы
/// показать снимок правильно. `1` (как есть) не пишется.
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

/// Широта и долгота в десятичных градусах (6 знаков — около 10 см), и
/// высота, если есть. `0, 0` — так пишут «спутников не нашли», а не
/// координаты в Гвинейском заливе.
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

/// Градусы, минуты, секунды тремя дробями → десятичные градусы со знаком.
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

/// `2.8` → `2.8`, `50.0` → `50`: лишний `.0` в `f/4.0` выглядит машинно.
String _decimal(double value) {
  final rounded = (value * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.round().toString()
      : rounded.toString();
}

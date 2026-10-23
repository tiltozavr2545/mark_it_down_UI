import 'dart:typed_data';

import 'type_detection/detected_type.dart';
import 'type_detection/type_detector.dart';

/// То, что известно о файле до разбора: имя, размер, и то, что удалось
/// понять по содержимому. Поля повторяют markitdown осознанно — см.
/// `docs/conversion-pipeline.md#1-распознавание-типа`.
class StreamInfo {
  /// Имя файла от источника — может быть любым, включая пустое.
  final String? filename;

  /// Расширение из [filename], в нижнем регистре, без точки. `null`, если
  /// расширения нет — распространённый случай для файлов из мессенджеров.
  final String? extension;

  /// MIME от ОС (drag&drop/share) — на Android часто `application/octet-stream`,
  /// доверять ему нельзя.
  final String? mimeType;

  /// Полный размер файла в байтах.
  final int lengthBytes;

  /// Результат распознавания по магическим байтам.
  final DetectedType detectedType;

  /// Путь к файлу на диске, если он там лежит (диалог выбора, drag&drop).
  /// Нужен сайдкару, который получает путь аргументом, а не байты; если
  /// `null` (буфер обмена, вложенный файл архива), конвертер пишет
  /// временный файл сам. Конвертеры Dart-ядра его не читают.
  final String? localPath;

  /// Адрес, с которого файл скачан (режим «вставить ссылку»), — как
  /// `stream_info.url` у markitdown: от него разрешаются относительные
  /// ссылки в HTML и лентах. У файлов с диска `null`.
  final String? url;

  const StreamInfo({
    required this.filename,
    required this.extension,
    required this.mimeType,
    required this.lengthBytes,
    required this.detectedType,
    this.localPath,
    this.url,
  });

  /// [head] — первые байты файла, достаточные для распознавания (для
  /// небольших файлов можно передать файл целиком). [lengthBytes] — полный
  /// размер файла, который может быть больше, чем `head.length`.
  factory StreamInfo.fromHead(
    Uint8List head, {
    String? filename,
    String? mimeType,
    int? lengthBytes,
    String? localPath,
    String? url,
  }) {
    final extension = _extensionOf(filename);
    return StreamInfo(
      filename: filename,
      extension: extension,
      mimeType: mimeType,
      lengthBytes: lengthBytes ?? head.length,
      detectedType: detectType(head, extension: extension),
      localPath: localPath,
      url: url,
    );
  }

  @override
  String toString() =>
      'StreamInfo(filename: $filename, lengthBytes: $lengthBytes, '
      'detectedType: $detectedType)';
}

String? _extensionOf(String? filename) {
  if (filename == null) return null;
  final dot = filename.lastIndexOf('.');
  if (dot <= 0 || dot == filename.length - 1) return null;
  return filename.substring(dot + 1).toLowerCase();
}

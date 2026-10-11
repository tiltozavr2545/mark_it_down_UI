import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:markitdown_core/markitdown_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Модели Tesseract, которые приложение везёт ассетами (`tesseract/fetch.sh`
/// кладёт их в `assets/tessdata/`).
const _models = ['rus', 'eng'];

Future<OcrSettings?>? _settings;

/// Где лежат модели OCR — один раз за запуск, на главном изоляте (ассеты и
/// каталоги приложения из изолята конвертации недоступны). `null` — OCR не
/// будет: конвертеры отдадут метаданные и напишут, что распознавание
/// недоступно. Ошибка здесь не роняет конвертацию — OCR необязателен.
Future<OcrSettings?> ocrSettings() => _settings ??= _prepare();

Future<OcrSettings?> _prepare() async {
  try {
    final dir = Platform.isAndroid
        ? await _copyAssetsToDisk()
        : _desktopAssetsDir();
    if (dir == null) return null;
    return OcrSettings(tessdataDir: dir);
  } on Object {
    return null;
  }
}

/// Windows (и Linux): ассеты Flutter лежат обычными файлами рядом с `.exe`
/// — `data/flutter_assets/assets/tessdata/`, читать можно на месте.
String? _desktopAssetsDir() {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final dir = p.join(exeDir, 'data', 'flutter_assets', 'assets', 'tessdata');
  final complete = _models.every(
    (m) => File(p.join(dir, '$m.traineddata')).existsSync(),
  );
  return complete ? dir : null;
}

/// Android: ассеты внутри APK, а Tesseract читает модели с диска. Копируем в
/// каталог приложения один раз; при обновлении приложения (другой размер
/// файла) — заново. Пишем во временный файл и переименовываем, чтобы
/// прерванное копирование не оставило обрезанную модель.
Future<String?> _copyAssetsToDisk() async {
  final support = await getApplicationSupportDirectory();
  final dir = Directory(p.join(support.path, 'tessdata'));
  await dir.create(recursive: true);
  for (final model in _models) {
    final ByteData data;
    try {
      data = await rootBundle.load('assets/tessdata/$model.traineddata');
    } on FlutterError {
      return null; // сборка без моделей (fetch.sh не запускали)
    }
    final target = File(p.join(dir.path, '$model.traineddata'));
    if (target.existsSync() && target.lengthSync() == data.lengthInBytes) {
      continue;
    }
    final partial = File('${target.path}.part');
    await partial.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    await partial.rename(target.path);
  }
  return dir.path;
}

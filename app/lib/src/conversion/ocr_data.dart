import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:markitdown_core/markitdown_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'bundled_assets.dart';

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

/// Windows (и Linux): модели читаются на месте, рядом с `.exe`.
String? _desktopAssetsDir() {
  final dir = desktopAssetDir('tessdata');
  final complete = _models.every(
    (m) => File(p.join(dir, '$m.traineddata')).existsSync(),
  );
  return complete ? dir : null;
}

/// Android: Tesseract читает модели с диска — копируем из APK один раз; при
/// обновлении приложения (другой размер файла) — заново.
Future<String?> _copyAssetsToDisk() async {
  final support = await getApplicationSupportDirectory();
  final dir = Directory(p.join(support.path, 'tessdata'));
  await dir.create(recursive: true);
  for (final model in _models) {
    try {
      await copyAssetToDisk(
        'assets/tessdata/$model.traineddata',
        File(p.join(dir.path, '$model.traineddata')),
      );
    } on FlutterError {
      return null; // сборка без моделей (fetch.sh не запускали)
    }
  }
  return dir.path;
}

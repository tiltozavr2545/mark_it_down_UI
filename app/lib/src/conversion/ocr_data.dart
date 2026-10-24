import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:markitdown_core/markitdown_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'bundled_assets.dart';

/// Tesseract models the app ships as assets (`tesseract/fetch.sh` puts them
/// in `assets/tessdata/`).
const _models = ['rus', 'eng'];

Future<OcrSettings?>? _settings;

/// Where the OCR models live — resolved once per run, on the main isolate
/// (assets and app directories aren't available from the conversion
/// isolate). `null` means there will be no OCR: converters return metadata
/// and note that recognition is unavailable. A failure here doesn't bring
/// down the conversion — OCR is optional.
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

/// Windows (and Linux): models are read in place, next to the `.exe`.
String? _desktopAssetsDir() {
  final dir = desktopAssetDir('tessdata');
  final complete = _models.every(
    (m) => File(p.join(dir, '$m.traineddata')).existsSync(),
  );
  return complete ? dir : null;
}

/// Android: Tesseract reads models from disk — we copy them from the APK
/// once; on an app update (different file size) — again.
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
      return null; // build without models (fetch.sh wasn't run)
    }
  }
  return dir.path;
}

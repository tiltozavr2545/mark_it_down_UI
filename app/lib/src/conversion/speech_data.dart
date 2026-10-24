import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:markitdown_core/markitdown_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'bundled_assets.dart';

/// The model manifest that `whisper/fetch.sh` places next to them in
/// `assets/whisper/`: Whisper small and Silero VAD — name, size, sha256.
const _manifest = 'assets/whisper/models.json';

Future<TranscriptionSettings?>? _settings;

/// Where the speech-recognition models live — resolved once per run, on
/// the main isolate (assets and app directories aren't available from the
/// conversion isolate). `null` means no recognition will happen: the
/// converter returns metadata and notes that it's unavailable.
///
/// Called only for audio, not on startup like OCR: on Android the first
/// call after install copies a 265 MB model from the APK to disk — seconds
/// that someone converting a PDF doesn't need to spend.
Future<TranscriptionSettings?> transcriptionSettings() =>
    _settings ??= _prepare();

class _Model {
  final String file;
  final int size;
  final String sha256;

  _Model(Map<String, dynamic> json)
    : file = json['file'] as String,
      size = json['size'] as int,
      sha256 = json['sha256'] as String;

  /// Name of the on-disk copy on Android: a different model version gets a
  /// different name, even if the length is the same.
  String get diskName => '${sha256.substring(0, 12)}-$file';
}

Future<TranscriptionSettings?> _prepare() async {
  try {
    final Map<String, dynamic> manifest;
    try {
      manifest = jsonDecode(await rootBundle.loadString(_manifest));
    } on FlutterError {
      return null; // build without models (whisper/fetch.sh wasn't run)
    }
    final model = _Model(manifest['model'] as Map<String, dynamic>);
    final vad = _Model(manifest['vad'] as Map<String, dynamic>);
    final (modelPath, vadPath) = Platform.isAndroid
        ? await _copyAssetsToDisk(model, vad)
        : _desktopAssets(model, vad);
    if (modelPath == null) return null;
    final temp = await getTemporaryDirectory();
    return TranscriptionSettings(
      modelPath: modelPath,
      vadModelPath: vadPath,
      tempDir: temp.path,
    );
  } on Object {
    _settings = null; // don't cache a failure: e.g. disk ran out of space
    return null;
  }
}

/// Windows (and Linux): models are read in place, next to the `.exe`.
(String?, String?) _desktopAssets(_Model model, _Model vad) {
  final dir = desktopAssetDir('whisper');
  String? path(_Model m) {
    final file = File(p.join(dir, m.file));
    return file.existsSync() ? file.path : null;
  }

  return (path(model), path(vad));
}

/// Android: whisper.cpp reads the model from disk — we copy it from the APK
/// once (the manifest tells us whether the copy already on disk matches,
/// without reading the model into memory); after a model update — again,
/// deleting the old one.
///
/// Cost: the model sits twice — in the APK and on disk (~530 MB combined),
/// and while copying, `rootBundle.load` reads it into memory whole. Why this
/// instead of reading straight from the APK —
/// `docs/format-coverage.md#решения-транскрипции-08`.
Future<(String?, String?)> _copyAssetsToDisk(_Model model, _Model vad) async {
  final support = await getApplicationSupportDirectory();
  final dir = Directory(p.join(support.path, 'whisper'));
  await dir.create(recursive: true);
  for (final m in [model, vad]) {
    await copyAssetToDisk(
      'assets/whisper/${m.file}',
      File(p.join(dir.path, m.diskName)),
      size: m.size,
    );
  }
  final keep = {model.diskName, vad.diskName};
  await for (final entity in dir.list()) {
    if (entity is File && !keep.contains(p.basename(entity.path))) {
      await entity.delete();
    }
  }
  return (p.join(dir.path, model.diskName), p.join(dir.path, vad.diskName));
}

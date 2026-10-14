import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:markitdown_core/markitdown_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'bundled_assets.dart';

/// Опись моделей, которую `whisper/fetch.sh` кладёт рядом с ними в
/// `assets/whisper/`: Whisper small и Silero VAD — имя, размер, sha256.
const _manifest = 'assets/whisper/models.json';

Future<TranscriptionSettings?>? _settings;

/// Где лежат модели распознавания речи — один раз за запуск, на главном
/// изоляте (ассеты и каталоги приложения из изолята конвертации
/// недоступны). `null` — распознавания не будет: конвертер отдаст
/// метаданные и напишет, что оно недоступно.
///
/// Зовётся только для аудио, а не на старте, как OCR: на Android первый
/// вызов после установки копирует 265 МБ модели из APK на диск — секунды,
/// которые не нужны тому, кто конвертирует PDF.
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

  /// Имя копии на диске Android: другая версия модели — другое имя, даже
  /// если длина та же.
  String get diskName => '${sha256.substring(0, 12)}-$file';
}

Future<TranscriptionSettings?> _prepare() async {
  try {
    final Map<String, dynamic> manifest;
    try {
      manifest = jsonDecode(await rootBundle.loadString(_manifest));
    } on FlutterError {
      return null; // сборка без моделей (whisper/fetch.sh не запускали)
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
    _settings = null; // не кэшируем сбой: например, кончилось место на диске
    return null;
  }
}

/// Windows (и Linux): модели читаются на месте, рядом с `.exe`.
(String?, String?) _desktopAssets(_Model model, _Model vad) {
  final dir = desktopAssetDir('whisper');
  String? path(_Model m) {
    final file = File(p.join(dir, m.file));
    return file.existsSync() ? file.path : null;
  }

  return (path(model), path(vad));
}

/// Android: whisper.cpp читает модель с диска — копируем из APK один раз
/// (опись говорит, совпадает ли уже лежащая копия, без чтения модели в
/// память); после обновления модели — заново, старую удаляем.
///
/// Цена: модель лежит дважды — в APK и на диске (≈530 МБ вместе), а при
/// копировании `rootBundle.load` читает её в память целиком. Почему так, а
/// не чтение прямо из APK, — `docs/format-coverage.md#решения-транскрипции-08`.
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

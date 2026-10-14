/// Модели, которые читает нативный код (Tesseract, whisper.cpp), едут
/// ассетами Flutter, а библиотекам нужен путь на диске. Общее для OCR
/// (`ocr_data.dart`) и речи (`speech_data.dart`).
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Windows (и Linux): ассеты Flutter лежат обычными файлами рядом с `.exe`
/// — `data/flutter_assets/assets/<sub>/`, читать можно на месте.
String desktopAssetDir(String sub) => p.join(
  File(Platform.resolvedExecutable).parent.path,
  'data',
  'flutter_assets',
  'assets',
  sub,
);

/// Android: ассеты внутри APK — копируем [asset] в [target] один раз. Уже
/// лежащая копия совпадает, если её длина равна [size] (известен заранее —
/// сравнение без чтения ассета в память) или, без него, длине ассета.
/// Пишем во временный файл и переименовываем, чтобы прерванное
/// копирование не оставило обрезанную модель; недописанный — удаляем.
///
/// [FlutterError] — ассета нет в сборке.
Future<void> copyAssetToDisk(String asset, File target, {int? size}) async {
  bool upToDate(int length) =>
      target.existsSync() && target.lengthSync() == length;

  if (size != null && upToDate(size)) return;
  final data = await rootBundle.load(asset);
  if (size == null && upToDate(data.lengthInBytes)) return;
  final partial = File('${target.path}.part');
  try {
    await partial.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    await partial.rename(target.path);
  } on Object {
    try {
      if (partial.existsSync()) await partial.delete();
    } on FileSystemException {
      // Не удалось — перезапишется при следующей попытке.
    }
    rethrow;
  }
}

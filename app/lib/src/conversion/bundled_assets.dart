/// Models read by native code (Tesseract, whisper.cpp) travel as Flutter
/// assets, but the libraries need a path on disk. Shared by OCR
/// (`ocr_data.dart`) and speech (`speech_data.dart`).
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Windows (and Linux): Flutter assets sit as plain files next to the
/// `.exe` — `data/flutter_assets/assets/<sub>/`, readable in place.
String desktopAssetDir(String sub) => p.join(
  File(Platform.resolvedExecutable).parent.path,
  'data',
  'flutter_assets',
  'assets',
  sub,
);

/// Android: assets are inside the APK — we copy [asset] to [target] once.
/// The copy already on disk matches if its length equals [size] (known
/// ahead of time — a comparison without reading the asset into memory) or,
/// without it, the asset's length. We write to a temp file and rename it,
/// so an interrupted copy doesn't leave a truncated model; an unfinished
/// one gets deleted.
///
/// [FlutterError] — the asset isn't in the build.
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
      // Didn't work — it will be overwritten on the next attempt.
    }
    rethrow;
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

const _androidExport = MethodChannel('markitdown_ui/markdown_export');

String markdownBase({String? filename, String? title}) {
  String source = filename ?? title ?? '';
  if (filename != null) {
    final dot = filename.lastIndexOf('.');
    if (dot > 0) source = filename.substring(0, dot);
  }
  final cleaned = source
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  // Leave room for the suffix and extension even on UTF-8 filesystems.
  final limited = String.fromCharCodes(
    cleaned.runes.take(60),
  ).replaceAll(RegExp(r'[. ]+$'), '');
  if (limited.isEmpty) return 'converted';
  if (RegExp(
    r'^(?:con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(limited)) {
    return '_$limited';
  }
  return limited;
}

Future<({int saved, int failed})?> saveMarkdownBatch(
  Iterable<({String base, String markdown})> documents, {
  required String dialogTitle,
}) async {
  final android = Platform.isAndroid;
  final folder = android
      ? await _androidExport.invokeMethod<String>('chooseFolder')
      : await FilePicker.getDirectoryPath(
          dialogTitle: dialogTitle,
          lockParentWindow: true,
        );
  if (folder == null) return null;

  final usedNames = <String>{};
  var saved = 0;
  var failed = 0;
  for (final document in documents) {
    try {
      if (android) {
        final name = _nextName(document.base, usedNames);
        await _androidExport.invokeMethod<void>('write', {
          'folder': folder,
          'name': name,
          'bytes': utf8.encode(document.markdown),
        });
      } else {
        await saveMarkdownInDirectory(
          Directory(folder),
          base: document.base,
          markdown: document.markdown,
          usedNames: usedNames,
        );
      }
      saved++;
    } on PlatformException {
      failed++;
    } on FileSystemException {
      failed++;
    }
  }
  return (saved: saved, failed: failed);
}

String _nextName(String base, Set<String> usedNames) {
  var name = '$base.md';
  for (var suffix = 2; !usedNames.add(name.toLowerCase()); suffix++) {
    name = '$base ($suffix).md';
  }
  return name;
}

/// Reserves a new path before writing, so simultaneous exports and files
/// already in the destination folder are safe.
Future<File> saveMarkdownInDirectory(
  Directory folder, {
  required String base,
  required String markdown,
  required Set<String> usedNames,
}) async {
  final file = File(p.join(folder.path, _nextName(base, usedNames)));
  try {
    await file.create(exclusive: true);
  } on FileSystemException {
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      rethrow;
    }
    return saveMarkdownInDirectory(
      folder,
      base: base,
      markdown: markdown,
      usedNames: usedNames,
    );
  }
  try {
    return await file.writeAsString(markdown, flush: true);
  } on FileSystemException {
    try {
      await file.delete();
    } on FileSystemException {
      // Keep the original write error if the destination became inaccessible.
    }
    rethrow;
  }
}

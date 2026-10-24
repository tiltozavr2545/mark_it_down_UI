// Checks two implementations against each other: the Dart core vs. the
// Python sidecar (the real markitdown) on all fixtures from
// `test/fixtures/`. Stage 4, plan item 5.
//
//   make compare-sidecar
//   # or by hand, from core/:
//   MARKITDOWN_SIDECAR_DIR=../sidecar/dist/macos-x86_64 \
//   MARKITDOWN_PDFIUM_PATH=../pdfium/native/host/libpdfium.dylib \
//     dart run tool/compare_sidecar.dart [--out build/sidecar-compare]
//
// What it does: takes every fixture (except `*.expected.md`) that the
// sidecar picks up per the manifest, gets Markdown both ways, and
// writes a report. Doesn't go through the registry's fallback chain:
// Dart uses `defaultRegistry()` with no sidecar; the sidecar uses a
// registry of just one `SidecarConverter`, so "the sidecar failed"
// never gets masked by the Dart result.
//
// Text normalization is minimal and explicit (see [normalize]): only
// line breaks, trailing whitespace, and trailing blank lines. Everything
// else, including pdfminer's `\f`, is left as-is — that's the point of
// comparison.
//
// Report (default `core/build/sidecar-compare/`, `build/` is in
// .gitignore):
//   summary.md                    a summary across all fixtures
//   <format>/<name>.dart.md       normalized output of the Dart core
//   <format>/<name>.sidecar.md    normalized output of the sidecar
//   <format>/<name>.diff          a line-by-line diff (`-` Dart, `+` sidecar)
//
// Discussion of the differences and their classification live in
// docs/format-coverage.md, "Сверка с эталоном". Exit code 0 if the
// sidecar was found (differences are something to review, not an
// error); 2 if there's no sidecar.
import 'dart:io';
import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  var outDir = p.join('build', 'sidecar-compare');
  var fixturesDir = p.join('test', 'fixtures');
  var sidecarDir = Platform.environment[SidecarConverter.sidecarDirEnvVar];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--out':
        outDir = args[++i];
      case '--fixtures':
        fixturesDir = args[++i];
      case '--sidecar-dir':
        sidecarDir = args[++i];
      default:
        stderr.writeln('неизвестный аргумент: ${args[i]}');
        exit(64);
    }
  }

  if (sidecarDir == null || sidecarDir.isEmpty) {
    stderr.writeln(
      'Не задан каталог сайдкара: ${SidecarConverter.sidecarDirEnvVar} '
      'или --sidecar-dir. Собрать: make sidecar.',
    );
    exit(2);
  }
  final sidecar = SidecarConverter.fromDirectory(sidecarDir);
  if (sidecar == null) {
    stderr.writeln('В $sidecarDir нет рабочего сайдкара (make sidecar).');
    exit(2);
  }

  final dartRegistry = ConverterRegistry.defaultRegistry();
  final sidecarRegistry = ConverterRegistry([sidecar]);

  final sorted =
      Directory(fixturesDir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => !f.path.endsWith('.expected.md'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final out = Directory(outDir);
  if (out.existsSync()) out.deleteSync(recursive: true);
  out.createSync(recursive: true);

  final rows = <_Row>[];
  for (final file in sorted) {
    final bytes = Uint8List.fromList(file.readAsBytesSync());
    final name = p.relative(file.path, from: fixturesDir);
    final info = StreamInfo.fromHead(
      bytes,
      filename: p.basename(file.path),
      localPath: file.absolute.path,
    );
    if (!sidecar.accepts(info, bytes)) continue;

    final dart = await _run(dartRegistry, bytes, info);
    final side = await _run(sidecarRegistry, bytes, info);
    final row = _Row(name, info.detectedType.label, dart, side);
    rows.add(row);
    _writeFiles(out, row);
  }

  File(p.join(outDir, 'summary.md')).writeAsStringSync(_summary(rows));
  stdout.write(_console(rows));
  stdout.writeln('\nОтчёт: ${p.absolute(outDir)}/summary.md');
}

/// Minimal normalization before comparing. Deliberately leaves alone
/// whitespace within a line, blank lines between blocks, and `\f`.
String normalize(String text) {
  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t]+$'), ''))
      .toList();
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines.isEmpty ? '' : '${lines.join('\n')}\n';
}

class _Side {
  /// `null` if the converter declined.
  final String? markdown;
  final String? error;
  final List<String> warnings;
  final Duration elapsed;

  _Side({this.markdown, this.error, this.warnings = const [], Duration? time})
    : elapsed = time ?? Duration.zero;
}

Future<_Side> _run(
  ConverterRegistry registry,
  Uint8List bytes,
  StreamInfo info,
) async {
  final stopwatch = Stopwatch()..start();
  final outcome = await registry.convert(bytes, info);
  stopwatch.stop();
  return switch (outcome) {
    ConversionSuccess(:final result) => _Side(
      markdown: normalize(result.markdown),
      warnings: [
        for (final w in result.warnings)
          // The "converterId: sidecar …" line is the same for every file
          // and is just noise in the report.
          if (!w.message.startsWith('converterId: sidecar')) w.message,
      ],
      time: stopwatch.elapsed,
    ),
    ConversionError(:final failure) => _Side(
      error: _describe(failure),
      time: stopwatch.elapsed,
    ),
  };
}

String _describe(ConversionFailure failure) => switch (failure) {
  UnsupportedFormatFailure(:final detectedTypeLabel) =>
    'не поддерживается: $detectedTypeLabel',
  CorruptedFileFailure(:final converterId, :final reason) =>
    '$converterId: $reason',
  LimitExceededFailure(:final description) => 'лимит: $description',
  NetworkFailure(:final description) => 'сеть: $description',
};

class _Row {
  final String name;
  final String type;
  final _Side dart;
  final _Side sidecar;

  _Row(this.name, this.type, this.dart, this.sidecar);

  /// One of: `same`, `diff`, `sidecar-only` (Dart has no converter for it,
  /// or it declined), `sidecar-failed`, `both-failed`.
  String get status {
    if (dart.markdown != null && sidecar.markdown != null) {
      return dart.markdown == sidecar.markdown ? 'same' : 'diff';
    }
    if (dart.markdown == null && sidecar.markdown != null) {
      return 'sidecar-only';
    }
    if (dart.markdown != null) return 'sidecar-failed';
    return 'both-failed';
  }
}

void _writeFiles(Directory out, _Row row) {
  final base = p.join(out.path, p.withoutExtension(row.name));
  Directory(p.dirname(base)).createSync(recursive: true);
  // The source extension is part of the name so that `simple.docx` and
  // `simple.pdf` in the same format directory don't overwrite each other.
  final stem = '$base.${p.extension(row.name).replaceFirst('.', '')}';
  if (row.dart.markdown != null) {
    File('$stem.dart.md').writeAsStringSync(row.dart.markdown!);
  }
  if (row.sidecar.markdown != null) {
    File('$stem.sidecar.md').writeAsStringSync(row.sidecar.markdown!);
  }
  if (row.status == 'diff') {
    File(
      '$stem.diff',
    ).writeAsStringSync(lineDiff(row.dart.markdown!, row.sidecar.markdown!));
  }
}

String _summary(List<_Row> rows) {
  final b = StringBuffer()
    ..writeln('# Сверка Dart-ядра и сайдкара')
    ..writeln()
    ..writeln(
      'Нормализация: переводы строк, хвостовые пробелы, хвостовые пустые '
      'строки. В diff `-` — Dart-ядро, `+` — сайдкар (markitdown).',
    )
    ..writeln()
    ..writeln('| фикстура | тип | результат | Dart, мс | сайдкар, мс |')
    ..writeln('|---|---|---|---|---|');
  for (final r in rows) {
    b.writeln(
      '| ${r.name} | ${r.type} | ${_statusText(r)} | '
      '${r.dart.elapsed.inMilliseconds} | ${r.sidecar.elapsed.inMilliseconds} |',
    );
  }
  for (final r in rows) {
    b
      ..writeln()
      ..writeln('## ${r.name}')
      ..writeln()
      ..writeln('Результат: ${_statusText(r)}');
    if (r.dart.error != null) b.writeln('\nDart: ${r.dart.error}');
    if (r.sidecar.error != null) b.writeln('\nСайдкар: ${r.sidecar.error}');
    if (r.dart.warnings.isNotEmpty) {
      b.writeln('\nwarnings Dart: ${r.dart.warnings.join(' | ')}');
    }
    if (r.sidecar.warnings.isNotEmpty) {
      b.writeln('\nwarnings сайдкара: ${r.sidecar.warnings.join(' | ')}');
    }
    if (r.status == 'diff') {
      b
        ..writeln()
        ..writeln('```diff')
        ..write(lineDiff(r.dart.markdown!, r.sidecar.markdown!))
        ..writeln('```');
    }
  }
  return b.toString();
}

String _statusText(_Row r) => switch (r.status) {
  'same' => 'совпало',
  'diff' => 'РАСХОЖДЕНИЕ',
  'sidecar-only' => 'только сайдкар (у Dart: ${r.dart.error ?? 'нет'})',
  'sidecar-failed' => 'СБОЙ САЙДКАРА (${r.sidecar.error})',
  _ => 'сбой обоих',
};

String _console(List<_Row> rows) {
  final b = StringBuffer();
  final width = rows.fold<int>(
    0,
    (m, r) => r.name.length > m ? r.name.length : m,
  );
  for (final r in rows) {
    b.writeln('${r.name.padRight(width)}  ${_statusText(r)}');
  }
  final counts = <String, int>{};
  for (final r in rows) {
    counts[r.status] = (counts[r.status] ?? 0) + 1;
  }
  b.writeln(
    '\nвсего ${rows.length}: '
    '${counts.entries.map((e) => '${e.key} ${e.value}').join(', ')}',
  );
  return b.toString();
}

/// A line-by-line diff via longest common subsequence. For large inputs
/// (n·m > 4 million) it trims the common prefix and suffix and shows the
/// remainder as a wholesale replacement — good enough for the report.
String lineDiff(String a, String b) {
  List<String> split(String s) => s.isEmpty
      ? <String>[]
      : (s.endsWith('\n') ? s.substring(0, s.length - 1) : s).split('\n');
  final x = split(a);
  final y = split(b);

  var start = 0;
  while (start < x.length && start < y.length && x[start] == y[start]) {
    start++;
  }
  var endX = x.length;
  var endY = y.length;
  while (endX > start && endY > start && x[endX - 1] == y[endY - 1]) {
    endX--;
    endY--;
  }
  final mid = x.sublist(start, endX);
  final other = y.sublist(start, endY);

  final out = StringBuffer();
  // Make the invisible `\f` (pdfminer's page break) visible, otherwise
  // the lines look the same.
  void emit(String prefix, String line) =>
      out.writeln('$prefix${line.replaceAll('\f', '<FF>')}');

  for (var i = 0; i < start; i++) {
    emit(' ', x[i]);
  }
  if (mid.length * other.length > 4000000) {
    for (final l in mid) {
      emit('-', l);
    }
    for (final l in other) {
      emit('+', l);
    }
  } else {
    final lcs = List.generate(
      mid.length + 1,
      (_) => List.filled(other.length + 1, 0),
    );
    for (var i = mid.length - 1; i >= 0; i--) {
      for (var j = other.length - 1; j >= 0; j--) {
        lcs[i][j] = mid[i] == other[j]
            ? lcs[i + 1][j + 1] + 1
            : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
      }
    }
    var i = 0;
    var j = 0;
    while (i < mid.length && j < other.length) {
      if (mid[i] == other[j]) {
        emit(' ', mid[i]);
        i++;
        j++;
      } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
        emit('-', mid[i++]);
      } else {
        emit('+', other[j++]);
      }
    }
    while (i < mid.length) {
      emit('-', mid[i++]);
    }
    while (j < other.length) {
      emit('+', other[j++]);
    }
  }
  for (var i = endX; i < x.length; i++) {
    emit(' ', x[i]);
  }
  return out.toString();
}

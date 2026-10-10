import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:markitdown_core/markitdown_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/cfb_builder.dart';

/// Фейковый сайдкар: каталог в стандартной раскладке, где «интерпретатор» —
/// shell-скрипт, эмулирующий протокол из `docs/python-sidecar.md`. Сценарий
/// берётся из файла `mode` рядом (по умолчанию `ok`), а не из содержимого
/// входного файла — чтобы гонять через реестр настоящие фикстуры. Скрипт
/// пишет в каталог следы вызова (`last_input_path`, `last_format`,
/// `input_copy`, `pid`), по которым тесты проверяют аргументы, временный
/// файл и факт убийства процесса. Нужен только `/bin/sh` — работает на
/// macOS и Linux (CI).
const _fakePython = r'''#!/bin/sh
here="$(cd "$(dirname "$0")/../.." && pwd)"
in=""; fmt=""; extra=""
while [ $# -gt 0 ]; do
  case "$1" in
    --in) in="$2"; shift 2;;
    --format) fmt="$2"; shift 2;;
    *) extra="$extra $1"; shift;;
  esac
done
echo "$in" > "$here/last_input_path"
echo "$fmt" > "$here/last_format"
echo "$extra" > "$here/last_extra_args"
cp "$in" "$here/input_copy" 2>/dev/null
mode="ok"
[ -f "$here/mode" ] && mode="$(cat "$here/mode")"
case "$mode" in
  ok)
    size="$(wc -c < "$in" | tr -d ' ')"
    printf '{"markdown": "# Fake\\nformat=%s bytes=%s", "title": "Fake title", "warnings": ["w1", "w2"]}' "$fmt" "$size"
    exit 0;;
  exit1) echo "Traceback: secret stderr text" >&2; exit 1;;
  exit2) echo "unsupported" >&2; exit 2;;
  exit3) echo "corrupt" >&2; exit 3;;
  garbage) echo "this is not json"; exit 0;;
  prefixed) echo "Loading model..."; printf '{"markdown": "x", "title": null, "warnings": []}'; exit 0;;
  wrongshape) printf '{"markdown": 5, "title": null, "warnings": []}'; exit 0;;
  hang) echo $$ > "$here/pid"; exec sleep 600;;
esac
exit 99
''';

class _FakeSidecar {
  final Directory dir;

  _FakeSidecar(this.dir);

  static Future<_FakeSidecar> create(
    Directory parent, {
    String? manifest,
    String name = 'sidecar',
  }) async {
    final dir = Directory(p.join(parent.path, name))
      ..createSync(recursive: true);
    final python = File(p.join(dir.path, 'python', 'bin', 'python3'))
      ..createSync(recursive: true)
      ..writeAsStringSync(_fakePython);
    await Process.run('chmod', ['+x', python.path]);
    File(p.join(dir.path, 'run.py')).writeAsStringSync('# fake\n');
    File(p.join(dir.path, 'manifest.json')).writeAsStringSync(
      manifest ??
          jsonEncode({
            'schema': 1,
            'markitdown': '0.1.2',
            'python': '3.12.3',
            'formats': ['pdf', 'docx', 'xlsx', 'xls', 'pptx', 'msg'],
          }),
    );
    return _FakeSidecar(dir);
  }

  set mode(String mode) =>
      File(p.join(dir.path, 'mode')).writeAsStringSync(mode);

  String read(String name) =>
      File(p.join(dir.path, name)).readAsStringSync().trim();

  bool has(String name) => File(p.join(dir.path, name)).existsSync();
}

StreamInfo _info(FileKind kind, String label, {String? localPath, int? size}) =>
    StreamInfo(
      filename: 'file',
      extension: null,
      mimeType: null,
      lengthBytes: size ?? 0,
      detectedType: DetectedType(kind, label),
      localPath: localPath,
    );

ConversionRequest _request(Uint8List bytes, StreamInfo info) =>
    ConversionRequest(
      bytes: bytes,
      info: info,
      limits: ConversionLimits.defaults,
      recurse: (_, _) => throw UnimplementedError(),
    );

final _docxInfo = _info(FileKind.docx, 'OOXML Word (.docx)');
final _payload = Uint8List.fromList(utf8.encode('payload-bytes'));

void main() {
  late Directory root;
  late Directory scratch; // «системная временная папка» для SidecarConverter
  late _FakeSidecar fake;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('sidecar_test_');
    scratch = Directory(p.join(root.path, 'tmp'))..createSync();
    fake = await _FakeSidecar.create(root);
  });

  tearDown(() => root.deleteSync(recursive: true));

  SidecarConverter converter({
    Duration timeout = const Duration(seconds: 20),
    int? maxOutputBytes,
  }) {
    final base = SidecarConverter.fromDirectory(
      fake.dir.path,
      timeout: timeout,
      tempDirectory: scratch,
    )!;
    if (maxOutputBytes == null) return base;
    return SidecarConverter(
      formats: base.formats,
      commandBuilder: base.commandBuilder,
      timeout: timeout,
      tempDirectory: scratch,
      maxOutputBytes: maxOutputBytes,
    );
  }

  Future<ConversionDeclinedException> declined(SidecarConverter c) async {
    try {
      await c.convert(_request(_payload, _docxInfo));
    } on ConversionDeclinedException catch (e) {
      return e;
    }
    fail('ожидался отказ сайдкара');
  }

  group('протокол', () {
    test('успех: markdown, title, warnings и пометка сайдкара', () async {
      final result = await converter().convert(_request(_payload, _docxInfo));

      expect(result.converterId, 'sidecar');
      expect(result.markdown, '# Fake\nformat=docx bytes=13');
      expect(result.title, 'Fake title');
      final messages = result.warnings.map((w) => w.message).toList();
      expect(messages.first, contains('converterId: sidecar'));
      expect(messages.first, contains('markitdown 0.1.2'));
      expect(messages.first, contains('Python 3.12.3'));
      expect(messages.skip(1), ['w1', 'w2']);
    });

    test('команда: python3 -I -B run.py --in <путь> --format <id>', () async {
      await converter().convert(_request(_payload, _docxInfo));

      expect(fake.read('last_extra_args'), '-I -B ${fake.dir.path}/run.py');
      expect(fake.read('last_format'), 'docx');
      expect(p.extension(fake.read('last_input_path')), '.docx');
      expect(fake.read('input_copy'), 'payload-bytes');
    });

    test('подмена команды: фабрика получает путь и id формата', () async {
      final calls = <String>[];
      final c = SidecarConverter(
        formats: {'xls'},
        tempDirectory: scratch,
        commandBuilder: (path, format) {
          calls.add('$format:${p.extension(path)}');
          return SidecarCommand('/bin/sh', [
            '-c',
            'printf \'{"markdown": "m"}\'',
          ]);
        },
      );
      final result = await c.convert(
        _request(_payload, _info(FileKind.xls, 'Excel 97–2003 (.xls)')),
      );
      expect(calls, ['xls:.xls']);
      expect(result.markdown, 'm');
      expect(result.title, isNull);
    });

    test('код 2 → «не поддерживается»', () async {
      fake.mode = 'exit2';
      final e = await declined(converter());
      expect(e.failure, isA<UnsupportedFormatFailure>());
      expect(
        (e.failure as UnsupportedFormatFailure).detectedTypeLabel,
        'OOXML Word (.docx)',
      );
    });

    test('код 3 → «файл повреждён»', () async {
      fake.mode = 'exit3';
      final e = await declined(converter());
      expect(e.failure, isA<CorruptedFileFailure>());
      expect((e.failure as CorruptedFileFailure).converterId, 'sidecar');
    });

    test('код 1 → общая ошибка; stderr только в диагностике', () async {
      fake.mode = 'exit1';
      final e = await declined(converter());
      expect(e.failure, isA<CorruptedFileFailure>());
      expect(e.diagnostics, contains('secret stderr text'));
      // Пользовательские тексты не содержат stderr.
      final userFacing = [
        e.fallbackWarning,
        (e.failure as CorruptedFileFailure).reason,
      ];
      for (final text in userFacing) {
        expect(text, isNot(contains('secret')));
        expect(text, isNot(contains('Traceback')));
      }
    });

    test('неизвестный код выхода → общая ошибка', () async {
      fake.mode = 'bogus';
      final e = await declined(converter());
      expect(e.failure, isA<CorruptedFileFailure>());
    });

    for (final mode in ['garbage', 'prefixed', 'wrongshape']) {
      test('код 0, но ответ не по протоколу ($mode) → ошибка', () async {
        fake.mode = mode;
        final e = await declined(converter());
        expect(e.failure, isA<CorruptedFileFailure>());
      });
    }

    test('таймаут: процесс реально убит, ошибка — «лимит»', () async {
      fake.mode = 'hang';
      final stopwatch = Stopwatch()..start();
      final e = await declined(
        converter(timeout: const Duration(milliseconds: 1500)),
      );
      stopwatch.stop();

      expect(e.failure, isA<LimitExceededFailure>());
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 15)));
      final pid = fake.read('pid');
      final alive = Process.runSync('kill', ['-0', pid]).exitCode == 0;
      expect(alive, isFalse, reason: 'процесс $pid должен быть убит');
    });

    test('слишком большой вывод → процесс убит, ошибка — «лимит»', () async {
      final e = await declined(converter(maxOutputBytes: 10));
      expect(e.failure, isA<LimitExceededFailure>());
    });

    test('интерпретатор не запускается → ошибка, а не исключение', () async {
      final c = SidecarConverter(
        formats: {'docx'},
        tempDirectory: scratch,
        commandBuilder: (_, _) => const SidecarCommand('/нет/такого', []),
      );
      final e = await declined(c);
      expect(e.failure, isA<CorruptedFileFailure>());
    });
  });

  group('временные файлы', () {
    test('байты без пути → временный файл, удалён после успеха', () async {
      await converter().convert(_request(_payload, _docxInfo));
      expect(fake.has('input_copy'), isTrue); // файл существовал при вызове
      expect(scratch.listSync(), isEmpty);
    });

    for (final mode in ['exit1', 'exit2', 'exit3', 'garbage', 'hang']) {
      test('удалён и при ошибке ($mode)', () async {
        fake.mode = mode;
        await declined(converter(timeout: const Duration(seconds: 1)));
        expect(scratch.listSync(), isEmpty);
      });
    }

    test(
      'есть localPath → передаётся он, временный файл не создаётся',
      () async {
        final local = File(p.join(root.path, 'мой документ.docx'))
          ..writeAsStringSync('on-disk');
        final info = _info(
          FileKind.docx,
          'OOXML Word (.docx)',
          localPath: local.path,
        );
        final result = await converter().convert(_request(_payload, info));

        expect(fake.read('last_input_path'), local.path);
        expect(fake.read('input_copy'), 'on-disk');
        expect(result.markdown, contains('bytes=7'));
        expect(scratch.listSync(), isEmpty);
        expect(local.existsSync(), isTrue, reason: 'чужой файл не удаляем');
      },
    );

    test('localPath указывает в никуда → откат на временный файл', () async {
      final info = _info(
        FileKind.docx,
        'OOXML Word (.docx)',
        localPath: p.join(root.path, 'нет.docx'),
      );
      await converter().convert(_request(_payload, info));
      expect(fake.read('input_copy'), 'payload-bytes');
      expect(scratch.listSync(), isEmpty);
    });
  });

  group('манифест и регистрация', () {
    Future<SidecarConverter?> load(String manifest) async {
      final other = await _FakeSidecar.create(
        root,
        manifest: manifest,
        name: 'm${manifest.hashCode}',
      );
      return SidecarConverter.fromDirectory(other.dir.path);
    }

    test('приоритет −1.0, id sidecar', () {
      final c = converter();
      expect(c.priority, -1.0);
      expect(c.id, 'sidecar');
    });

    test('регистрируется только на форматы из манифеста', () async {
      final c = (await load(
        jsonEncode({
          'schema': 1,
          'markitdown': '1',
          'python': '3',
          'formats': ['xls', 'msg', 'rtf'], // rtf приложению неизвестен
        }),
      ))!;
      expect(c.formats, {'xls', 'msg'});

      final xls = _info(FileKind.xls, 'xls');
      final msg = _info(FileKind.msg, 'msg');
      expect(c.accepts(xls, Uint8List(0)), isTrue);
      expect(c.accepts(msg, Uint8List(0)), isTrue);
      expect(c.accepts(_docxInfo, Uint8List(0)), isFalse);
      expect(c.accepts(_info(FileKind.pdf, 'PDF'), Uint8List(0)), isFalse);
      expect(c.accepts(_info(FileKind.text, 'Текст'), Uint8List(0)), isFalse);
    });

    test('docx вне манифеста идёт Dart-конвертеру', () async {
      final c = (await load(
        jsonEncode({
          'schema': 1,
          'markitdown': '1',
          'python': '3',
          'formats': ['xls'],
        }),
      ))!;
      final registry = ConverterRegistry.defaultRegistry(extra: [c]);
      final bytes = File('test/fixtures/docx/simple.docx').readAsBytesSync();
      final outcome = await registry.convert(
        bytes,
        StreamInfo.fromHead(bytes, filename: 'simple.docx'),
      );
      expect((outcome as ConversionSuccess).result.converterId, 'docx');
    });

    for (final (name, manifest) in [
      ('битый JSON', '{не json'),
      ('не объект', '[1, 2]'),
      ('неизвестная schema', '{"schema": 2, "formats": ["pdf"]}'),
      ('schema строкой', '{"schema": "1", "formats": ["pdf"]}'),
      ('нет schema', '{"formats": ["pdf"]}'),
      ('нет formats', '{"schema": 1}'),
      ('formats не список', '{"schema": 1, "formats": "pdf"}'),
      ('ни одного известного формата', '{"schema": 1, "formats": ["rtf"]}'),
    ]) {
      test('$name → сайдкар не регистрируется, без исключений', () async {
        expect(await load(manifest), isNull);
      });
    }

    test('нет каталога / манифеста / интерпретатора → null', () {
      expect(SidecarConverter.fromDirectory(p.join(root.path, 'нет')), isNull);
      File(p.join(fake.dir.path, 'manifest.json')).deleteSync();
      expect(SidecarConverter.fromDirectory(fake.dir.path), isNull);
    });

    test('нет интерпретатора → null', () {
      File(p.join(fake.dir.path, 'python', 'bin', 'python3')).deleteSync();
      expect(SidecarConverter.fromDirectory(fake.dir.path), isNull);
    });
  });

  group('поиск каталога (discover)', () {
    test('MARKITDOWN_SIDECAR_DIR на десктопе', () {
      for (final os in ['macos', 'linux', 'windows']) {
        final c = SidecarConverter.discover(
          environment: {SidecarConverter.sidecarDirEnvVar: fake.dir.path},
          operatingSystem: os,
        );
        // На Windows раскладка python отличается; важно лишь, что gate
        // платформы не отсекает десктоп.
        if (os != 'windows') expect(c, isNotNull, reason: os);
      }
    });

    test('на Android и iOS — никогда, даже с переменной', () {
      for (final os in ['android', 'ios', 'fuchsia']) {
        expect(
          SidecarConverter.discover(
            environment: {SidecarConverter.sidecarDirEnvVar: fake.dir.path},
            operatingSystem: os,
          ),
          isNull,
          reason: os,
        );
      }
    });

    test(
      'macOS: Contents/Resources/sidecar рядом с исполняемым файлом',
      () async {
        final contents = Directory(p.join(root.path, 'X.app', 'Contents'))
          ..createSync(recursive: true);
        await _FakeSidecar.create(
          Directory(p.join(contents.path, 'Resources'))..createSync(),
        );
        final c = SidecarConverter.discover(
          environment: const {},
          operatingSystem: 'macos',
          resolvedExecutable: p.join(contents.path, 'MacOS', 'X'),
        );
        expect(c, isNotNull);
      },
    );

    test('нет каталога → null, без ошибок', () {
      expect(
        SidecarConverter.discover(
          environment: const {},
          operatingSystem: 'macos',
          resolvedExecutable: p.join(root.path, 'Y.app/Contents/MacOS/Y'),
        ),
        isNull,
      );
      expect(
        SidecarConverter.discover(
          environment: const {},
          operatingSystem: 'linux',
        ),
        isNull,
      );
    });

    test('переменная задана, но каталог негодный → null, без подмены', () {
      expect(
        SidecarConverter.discover(
          environment: {
            SidecarConverter.sidecarDirEnvVar: p.join(root.path, 'нет'),
          },
          operatingSystem: 'macos',
        ),
        isNull,
      );
    });
  });

  group('в реестре: откат на Dart-конвертер', () {
    final docx = File('test/fixtures/docx/simple.docx').readAsBytesSync();
    final dartMarkdown = File(
      'test/fixtures/docx/simple.expected.md',
    ).readAsStringSync();

    Future<ConversionOutcome> convertDocx() {
      final registry = ConverterRegistry.defaultRegistry(extra: [converter()]);
      return registry.convert(
        docx,
        StreamInfo.fromHead(docx, filename: 'simple.docx'),
      );
    }

    test('успех сайдкара — его результат, а не Dart-ядра', () async {
      final result = (await convertDocx() as ConversionSuccess).result;
      expect(result.converterId, 'sidecar');
      expect(result.markdown, startsWith('# Fake'));
      expect(result.elapsed, isNot(Duration.zero));
    });

    for (final mode in ['exit1', 'exit2', 'exit3', 'garbage']) {
      test('$mode → результат Dart-реализации с пометкой', () async {
        fake.mode = mode;
        final result = (await convertDocx() as ConversionSuccess).result;
        expect(result.converterId, 'docx');
        expect(result.markdown, dartMarkdown.trimRight());
        expect(result.warnings.first.message, contains('сайдкар не смог'));
        expect(result.warnings.first.message, isNot(contains('secret')));
      });
    }

    test('таймаут → тоже откат на Dart', () async {
      fake.mode = 'hang';
      final registry = ConverterRegistry.defaultRegistry(
        extra: [converter(timeout: const Duration(milliseconds: 1500))],
      );
      final outcome = await registry.convert(
        docx,
        StreamInfo.fromHead(docx, filename: 'simple.docx'),
      );
      final result = (outcome as ConversionSuccess).result;
      expect(result.converterId, 'docx');
      expect(result.warnings.first.message, contains('время ожидания'));
    });

    test(
      'Dart-конвертер тоже не справился → отказ, без утечки stderr',
      () async {
        fake.mode = 'exit1';
        final broken = Uint8List.fromList([...docx.take(200)]);
        final registry = ConverterRegistry.defaultRegistry(
          extra: [converter()],
        );
        final outcome = await registry.convert(
          broken,
          _info(FileKind.docx, 'OOXML Word (.docx)', size: broken.length),
        );
        expect(outcome, isA<ConversionError>());
        expect(
          (outcome as ConversionError).failure,
          isA<CorruptedFileFailure>(),
        );
      },
    );

    group('xls/msg: запасного нет — отказ сайдкара и есть ответ', () {
      final xls = buildCfb(['Workbook']);
      Future<ConversionOutcome> convertXls() =>
          ConverterRegistry.defaultRegistry(
            extra: [converter()],
          ).convert(xls, StreamInfo.fromHead(xls, filename: 'book.xls'));

      test('успех', () async {
        final result = (await convertXls() as ConversionSuccess).result;
        expect(result.converterId, 'sidecar');
        expect(result.markdown, contains('format=xls'));
      });

      test('код 2 → UnsupportedFormatFailure', () async {
        fake.mode = 'exit2';
        final failure = (await convertXls() as ConversionError).failure;
        expect(failure, isA<UnsupportedFormatFailure>());
      });

      test('код 3 → CorruptedFileFailure', () async {
        fake.mode = 'exit3';
        final failure = (await convertXls() as ConversionError).failure;
        expect(failure, isA<CorruptedFileFailure>());
      });

      test('код 1 → CorruptedFileFailure', () async {
        fake.mode = 'exit1';
        final failure = (await convertXls() as ConversionError).failure;
        expect(failure, isA<CorruptedFileFailure>());
      });
    });
  });
}

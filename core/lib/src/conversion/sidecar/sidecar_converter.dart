import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../stream_info.dart';
import '../conversion_failure.dart';
import '../conversion_request.dart';
import '../conversion_result.dart';
import '../document_converter.dart';
import '../pdf/pdf_text_extraction.dart';
import 'sidecar_manifest.dart';

/// Что запустить для одного вызова сайдкара.
class SidecarCommand {
  final String executable;
  final List<String> arguments;

  const SidecarCommand(this.executable, this.arguments);
}

/// Собирает команду запуска: [inputPath] — файл на диске, [formatId] — id
/// формата (`pdf`, `docx`, …). Единственное место, где известно, как
/// выглядит вызов; в тестах подставляется фейковый сайдкар.
typedef SidecarCommandBuilder =
    SidecarCommand Function(String inputPath, String formatId);

/// Настоящий markitdown на десктопе — просто ещё один конвертер с
/// приоритетом −1.0, см.
/// `docs/conversion-pipeline.md#сайдкар--просто-ещё-один-конвертер`.
/// Один вызов — один подпроцесс по протоколу из `docs/python-sidecar.md`:
///
/// ```
/// <dir>/python/bin/python3 -I -B <dir>/run.py --in <path> --format <id>
/// stdout: {"markdown": str, "title": str|null, "warnings": [str, ...]}
/// выход: 0 успех | 2 не поддерживается | 3 битый файл | 1 прочее
/// ```
///
/// **Любой отказ — это [ConversionDeclinedException], а не окончательная
/// ошибка**: реестр тогда пробует следующий конвертер, который принимает тот
/// же формат (Dart-реализация `pdf`/`docx`/`xlsx`/`pptx`), а пользователь
/// увидит отказ сайдкара, только если запасного нет (`xls`/`msg` на
/// десктопе — это всё равно «только сайдкар»). Почему так: сайдкар — усиление
/// поверх Dart-ядра, а не замена; зависший или упавший подпроцесс не должен
/// отнимать у человека результат, который Dart-ядро отдаёт само («частичный
/// результат полезнее отказа»). Для кода 3 это тоже верно: `pdfminer`
/// строже PDFium, а по-настоящему битый файл Dart-конвертер всё равно
/// отвергнет — со своим, обычно более точным, описанием места повреждения.
///
/// stderr сайдкара пользователю не показывается никогда — только в
/// [ConversionDeclinedException.diagnostics].
class SidecarConverter implements DocumentConverter {
  /// Форматы, на которые сайдкар отзывается (подмножество
  /// [sidecarFormatKinds]).
  final Set<String> formats;

  final SidecarCommandBuilder commandBuilder;

  /// После этого подпроцесс убивается, а вызов превращается в обычный отказ
  /// (с откатом на Dart-конвертер), а не в вечное ожидание. По умолчанию
  /// запас на большой PDF при холодном старте Python.
  final Duration timeout;

  /// Где создавать временные файлы для данных, у которых нет пути на диске.
  /// По умолчанию — системная временная папка.
  final Directory? tempDirectory;

  /// Предел размера stdout: сайдкар, который выдал больше, убивается — иначе
  /// мусорный вывод съел бы память процесса приложения.
  final int maxOutputBytes;

  final String? markitdownVersion;
  final String? pythonVersion;

  /// PDF длиннее этого числа страниц сайдкар отклоняет, не запуская Python, —
  /// реестр отдаёт файл Dart-конвертеру. `null` — без предела (сверка с
  /// эталоном, интеграционные тесты). Почему — см. [appFormats].
  final int? maxPdfPages;

  SidecarConverter({
    required Set<String> formats,
    required this.commandBuilder,
    this.timeout = const Duration(seconds: 120),
    this.tempDirectory,
    this.maxOutputBytes = 200 * 1024 * 1024,
    this.markitdownVersion,
    this.pythonVersion,
    this.maxPdfPages,
  }) : formats = Set.unmodifiable(
         formats.where(sidecarFormatKinds.containsKey),
       );

  /// Стандартная раскладка каталога сайдкара. Возвращает `null`, если
  /// каталога, манифеста, `run.py` или интерпретатора нет, манифест битый или
  /// с неизвестной `schema` — «сайдкара нет» не ошибка, а штатное состояние
  /// (мобильные, сборка без него).
  ///
  /// [onlyFormats] сужает список из манифеста (пустое пересечение — тоже
  /// `null`: регистрировать нечего); без него — все форматы манифеста.
  static SidecarConverter? fromDirectory(
    String directory, {
    Duration timeout = const Duration(seconds: 120),
    Directory? tempDirectory,
    Set<String>? onlyFormats,
    int? maxPdfPages,
  }) {
    final manifestFile = File(_join(directory, 'manifest.json'));
    final python = _join(
      directory,
      Platform.isWindows ? 'python/python.exe' : 'python/bin/python3',
    );
    final runPy = _join(directory, 'run.py');

    SidecarManifest? manifest;
    try {
      if (!File(python).existsSync() || !File(runPy).existsSync()) return null;
      manifest = SidecarManifest.tryParse(manifestFile.readAsStringSync());
    } on FileSystemException {
      return null;
    }
    if (manifest == null) return null;
    final formats = onlyFormats == null
        ? manifest.formats
        : manifest.formats.intersection(onlyFormats);
    if (formats.isEmpty) return null;

    return SidecarConverter(
      formats: formats,
      commandBuilder: (inputPath, formatId) => SidecarCommand(python, [
        '-I',
        '-B',
        runPy,
        '--in',
        inputPath,
        '--format',
        formatId,
      ]),
      timeout: timeout,
      tempDirectory: tempDirectory,
      markitdownVersion: manifest.markitdownVersion,
      pythonVersion: manifest.pythonVersion,
      maxPdfPages: maxPdfPages,
    );
  }

  /// На что сайдкар идёт первым в приложении — решение автора по Этапу 5,
  /// п. 5 (`docs/implementation-plan.md`). Сайдкар в десятки раз медленнее
  /// Dart-ядра (PDF на 300 страниц — 112 с против 1,2 с, xlsx на 50 тыс.
  /// строк — 55 с против 4,4 с), а по сверке Этапа 4 в `docx`/`xlsx`/`pptx`
  /// Dart не хуже. Поэтому первым он идёт только там, где даёт то, чего у
  /// Dart нет: `xls`/`msg` (только он) и `pdf` (таблицы) — и для `pdf` лишь
  /// до [appMaxPdfPages] страниц. `docx`/`xlsx`/`pptx` сайдкар по-прежнему
  /// умеет — как эталон для `make compare-sidecar`, а не как путь в
  /// приложении.
  static const appFormats = {'pdf', 'xls', 'msg'};

  /// Порог для PDF в приложении: ≈0,37 с на страницу у сайдкара — около
  /// 20 с в худшем случае. Длиннее — Dart-ядро с предупреждением, что
  /// таблицы извлечены текстом.
  static const appMaxPdfPages = 50;

  /// Ищет сайдкар там, где он должен лежать на этой платформе:
  ///
  /// 1. `MARKITDOWN_SIDECAR_DIR` — для разработки и тестов (по образцу
  ///    `MARKITDOWN_PDFIUM_PATH`). Если переменная задана, другие места не
  ///    смотрятся: неверный путь не должен молча подменяться бандлом.
  /// 2. macOS: `Contents/Resources/sidecar` рядом с исполняемым файлом
  ///    бандла (`X.app/Contents/MacOS/X`).
  /// 3. Windows: `sidecar\` в каталоге `.exe` — туда его кладёт
  ///    `install(DIRECTORY …)` в `app/windows/CMakeLists.txt`, и так же он
  ///    лежит в распакованном zip.
  ///
  /// На Android и iOS — всегда `null`, даже если переменная задана: сайдкара
  /// там нет и не будет (нативные колёса под мобильные ABI не существуют).
  /// Найденный сайдкар ограничен [appFormats] и [appMaxPdfPages] — это
  /// путь приложения. Параметры нужны тестам; в приложении вызывается без
  /// аргументов.
  static SidecarConverter? discover({
    Map<String, String>? environment,
    String? operatingSystem,
    String? resolvedExecutable,
    Duration timeout = const Duration(seconds: 120),
  }) {
    final os = operatingSystem ?? Platform.operatingSystem;
    if (os != 'macos' && os != 'linux' && os != 'windows') return null;

    final override = (environment ?? Platform.environment)[sidecarDirEnvVar];
    final executable = File(resolvedExecutable ?? Platform.resolvedExecutable);
    final String directory;
    if (override != null && override.isNotEmpty) {
      directory = override;
    } else if (os == 'macos') {
      // X.app/Contents/MacOS/X → X.app/Contents/Resources/sidecar
      directory = _join(executable.parent.parent.path, 'Resources/sidecar');
    } else if (os == 'windows') {
      // Release\markitdown_ui.exe → Release\sidecar
      directory = _join(executable.parent.path, 'sidecar');
    } else {
      return null;
    }
    return fromDirectory(
      directory,
      timeout: timeout,
      onlyFormats: appFormats,
      maxPdfPages: appMaxPdfPages,
    );
  }

  static const sidecarDirEnvVar = 'MARKITDOWN_SIDECAR_DIR';

  @override
  String get id => 'sidecar';

  @override
  double get priority => -1.0;

  @override
  bool accepts(StreamInfo info, Uint8List head) {
    final formatId = _formatIdFor(info);
    return formatId != null && formats.contains(formatId);
  }

  @override
  Future<ConversionResult> convert(ConversionRequest request) async {
    final info = request.info;
    final formatId = _formatIdFor(info)!;

    final maxPages = maxPdfPages;
    if (formatId == 'pdf' && maxPages != null) {
      // Не открылось — пусть сайдкар попробует сам: откат на Dart при его
      // отказе всё равно есть.
      final pages = countPdfPages(request.bytes);
      if (pages != null && pages > maxPages) {
        throw ConversionDeclinedException(
          failure: LimitExceededFailure(
            'PDF длиннее $maxPages страниц ($pages) не обрабатывается сайдкаром',
          ),
          fallbackWarning:
              'PDF длиннее $maxPages страниц ($pages) обработан Dart-ядром, '
              'а не сайдкаром: так в десятки раз быстрее, но таблицы '
              'извлечены как текст',
        );
      }
    }

    // Временная папка создаётся только если у файла нет пути на диске, и
    // удаляется здесь же, в finally: владеет файлом вызывающий, а не
    // сайдкар (иначе непонятно, кто отвечает за удаление).
    Directory? scratch;
    try {
      final String inputPath;
      final localPath = info.localPath;
      if (localPath != null && await File(localPath).exists()) {
        inputPath = File(localPath).absolute.path;
      } else {
        scratch = await (tempDirectory ?? Directory.systemTemp).createTemp(
          'markitdown_sidecar_',
        );
        final file = File(_join(scratch.path, 'input.$formatId'));
        await file.writeAsBytes(request.bytes, flush: true);
        inputPath = file.path;
      }

      final run = await _run(commandBuilder(inputPath, formatId));
      return _interpret(run, info, formatId);
    } finally {
      if (scratch != null) {
        try {
          await scratch.delete(recursive: true);
        } on FileSystemException {
          // Удалить не вышло (антивирус, занятый файл) — не повод ронять
          // уже готовый результат.
        }
      }
    }
  }

  ConversionResult _interpret(_Run run, StreamInfo info, String formatId) {
    final diagnostics = run.stderr.isEmpty ? null : run.stderr;

    Never decline(ConversionFailure failure, String why) =>
        throw ConversionDeclinedException(
          failure: failure,
          fallbackWarning: 'сайдкар не смог обработать файл ($why)',
          diagnostics: diagnostics,
        );

    const genericFailure = CorruptedFileFailure(
      converterId: 'sidecar',
      reason: 'не удалось обработать файл',
    );

    if (run.spawnError != null) {
      decline(genericFailure, 'не запустился');
    }
    if (run.timedOut) {
      decline(
        LimitExceededFailure(
          'время обработки сайдкаром превысило ${timeout.inSeconds} с',
        ),
        'превышено время ожидания ${timeout.inSeconds} с',
      );
    }
    if (run.outputOverflow) {
      decline(
        LimitExceededFailure(
          'вывод сайдкара превысил ${maxOutputBytes ~/ (1024 * 1024)} МБ',
        ),
        'слишком большой вывод',
      );
    }

    switch (run.exitCode) {
      case 0:
        break;
      case 2:
        decline(
          UnsupportedFormatFailure(info.detectedType.label),
          'формат не поддерживается',
        );
      case 3:
        decline(
          CorruptedFileFailure(
            converterId: 'sidecar',
            reason: 'файл повреждён: ${info.detectedType.label} не читается',
          ),
          'файл не читается',
        );
      default:
        decline(genericFailure, 'код выхода ${run.exitCode}');
    }

    final parsed = _parseOutput(run.stdout);
    if (parsed == null) decline(genericFailure, 'некорректный ответ');

    final version = [
      if (markitdownVersion != null) 'markitdown $markitdownVersion',
      if (pythonVersion != null) 'Python $pythonVersion',
    ].join(', ');
    return ConversionResult(
      markdown: parsed.markdown,
      title: parsed.title,
      converterId: 'sidecar',
      elapsed: Duration.zero,
      warnings: [
        // По этой строке при разборе «почему у меня вышло не так» видно, что
        // сработал сайдкар, а не Dart-ядро (результаты могут расходиться).
        ConversionWarning(
          'converterId: sidecar — формат ${info.detectedType.label} '
          'обработан Python-сайдкаром${version.isEmpty ? '' : ' ($version)'}, '
          'а не Dart-ядром: на мобильных платформах результат может отличаться',
        ),
        for (final w in parsed.warnings) ConversionWarning(w),
      ],
    );
  }

  /// Запуск подпроцесса с таймаутом и ограничением вывода. Не бросает —
  /// всё, что пошло не так, возвращается полями [_Run], а решает
  /// [_interpret].
  Future<_Run> _run(SidecarCommand command) async {
    final Process process;
    try {
      process = await Process.start(command.executable, command.arguments);
    } on ProcessException catch (e) {
      return _Run(spawnError: e.message);
    }

    // Сайдкар ничего не читает из stdin; закрываем, чтобы не повис на чтении.
    unawaited(process.stdin.close().catchError((_) {}));

    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    var overflow = false;

    final stdoutDone = process.stdout.forEach((chunk) {
      if (overflow) return;
      out.add(chunk);
      if (out.length > maxOutputBytes) {
        overflow = true;
        process.kill(ProcessSignal.sigkill);
      }
    });
    // stderr — только для разработчика; первых 16 КБ хватает, остальное
    // читаем и выбрасываем, иначе подпроцесс встанет на полном канале.
    final stderrDone = process.stderr.forEach((chunk) {
      if (err.length < 16 * 1024) err.add(chunk);
    });

    var timedOut = false;
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
      exitCode = await process.exitCode;
    }

    // Потомок, унаследовавший каналы, мог бы держать их открытыми после
    // смерти процесса — не ждём бесконечно.
    try {
      await Future.wait([
        stdoutDone,
        stderrDone,
      ]).timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // Берём то, что успели прочитать.
    }

    return _Run(
      exitCode: exitCode,
      stdout: out.takeBytes(),
      stderr: utf8.decode(err.takeBytes(), allowMalformed: true).trim(),
      timedOut: timedOut,
      outputOverflow: overflow,
    );
  }
}

class _Run {
  final int exitCode;
  final Uint8List stdout;
  final String stderr;
  final bool timedOut;
  final bool outputOverflow;
  final String? spawnError;

  _Run({
    this.exitCode = -1,
    Uint8List? stdout,
    this.stderr = '',
    this.timedOut = false,
    this.outputOverflow = false,
    this.spawnError,
  }) : stdout = stdout ?? Uint8List(0);
}

class _Output {
  final String markdown;
  final String? title;
  final List<String> warnings;

  _Output(this.markdown, this.title, this.warnings);
}

/// Строгий разбор протокола: ровно один JSON-объект, `markdown` — строка,
/// `title` — строка или `null`, `warnings` — список строк. Любое отклонение
/// (в том числе лишний текст вокруг JSON из-за `print` в библиотеке) — `null`.
_Output? _parseOutput(Uint8List stdout) {
  try {
    final json = jsonDecode(utf8.decode(stdout));
    if (json is! Map<String, Object?>) return null;
    final markdown = json['markdown'];
    final title = json['title'];
    final warnings = json['warnings'] ?? const <Object?>[];
    if (markdown is! String) return null;
    if (title != null && title is! String) return null;
    if (warnings is! List || warnings.any((w) => w is! String)) return null;
    return _Output(markdown, title as String?, warnings.cast<String>());
  } on FormatException {
    return null;
  }
}

String? _formatIdFor(StreamInfo info) {
  final kind = info.detectedType.kind;
  for (final entry in sidecarFormatKinds.entries) {
    if (entry.value == kind) return entry.key;
  }
  return null;
}

String _join(String base, String relative) =>
    '$base${Platform.pathSeparator}'
    '${relative.replaceAll('/', Platform.pathSeparator)}';

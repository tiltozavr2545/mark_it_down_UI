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

/// What to run for a single sidecar invocation.
class SidecarCommand {
  final String executable;
  final List<String> arguments;

  const SidecarCommand(this.executable, this.arguments);
}

/// Builds the launch command: [inputPath] — the file on disk, [formatId] —
/// the format id (`pdf`, `docx`, …). The only place that knows what the
/// invocation looks like; tests substitute a fake sidecar here.
typedef SidecarCommandBuilder =
    SidecarCommand Function(String inputPath, String formatId);

/// The real markitdown on desktop — just another converter with priority
/// −1.0, see
/// `docs/conversion-pipeline.md#сайдкар--просто-ещё-один-конвертер`.
/// One call — one subprocess following the protocol from
/// `docs/python-sidecar.md`:
///
/// ```
/// <dir>/python/bin/python3 -I -B <dir>/run.py --in <path> --format <id>
/// stdout: {"markdown": str, "title": str|null, "warnings": [str, ...]}
/// exit code: 0 success | 2 unsupported | 3 corrupted file | 1 other
/// ```
///
/// **Any decline is a [ConversionDeclinedException], not a final error**:
/// the registry then tries the next converter that accepts the same format
/// (a Dart implementation exists for all its formats; for `xls`/`msg` —
/// since 0.9), and the user only sees the sidecar's decline if the fallback
/// also fails. Why: the sidecar is an enhancement on top of the Dart core,
/// not a replacement; a hung or crashed subprocess should not take away from
/// the person a result the Dart core can produce on its own ("a partial
/// result is more useful than a failure"). This also holds for code 3:
/// `pdfminer` is stricter than PDFium, and a genuinely corrupted file is
/// rejected by the Dart converter anyway — with its own, usually more
/// precise, description of where the corruption is.
///
/// The sidecar's stderr is never shown to the user — only in
/// [ConversionDeclinedException.diagnostics].
class SidecarConverter implements DocumentConverter {
  /// The formats the sidecar responds to (a subset of
  /// [sidecarFormatKinds]).
  final Set<String> formats;

  final SidecarCommandBuilder commandBuilder;

  /// After this the subprocess is killed and the call turns into an
  /// ordinary decline (falling back to the Dart converter) instead of
  /// waiting forever. The default leaves headroom for a large PDF on a cold
  /// Python start.
  final Duration timeout;

  /// Where to create temp files for data that has no path on disk.
  /// Defaults to the system temp directory.
  final Directory? tempDirectory;

  /// The stdout size limit: a sidecar that outputs more than this is
  /// killed — otherwise the garbage output would eat up the app process's
  /// memory.
  final int maxOutputBytes;

  final String? markitdownVersion;
  final String? pythonVersion;

  /// A PDF longer than this many pages is declined by the sidecar without
  /// launching Python — the registry hands the file to the Dart converter.
  /// `null` means no limit (reference comparison, integration tests). Why —
  /// see [appFormats].
  final int? maxPdfPages;

  /// A PDF that has scanned pages (no text, just an image) is declined by
  /// the sidecar without launching Python: pdfminer would return empty text
  /// for them as a "success", and OCR in the Dart core would never run.
  /// Enabled in the app when OCR is available (Stage 6): scanned text
  /// matters more than tables on the other pages.
  final bool scannedPdfToDart;

  SidecarConverter({
    required Set<String> formats,
    required this.commandBuilder,
    this.timeout = const Duration(seconds: 120),
    this.tempDirectory,
    this.maxOutputBytes = 200 * 1024 * 1024,
    this.markitdownVersion,
    this.pythonVersion,
    this.maxPdfPages,
    this.scannedPdfToDart = false,
  }) : formats = Set.unmodifiable(
         formats.where(sidecarFormatKinds.containsKey),
       );

  /// The standard sidecar directory layout. Returns `null` if the
  /// directory, manifest, `run.py` or interpreter is missing, or the
  /// manifest is corrupted or has an unknown `schema` — "no sidecar" is not
  /// an error but a normal state (mobile, a build without it).
  ///
  /// [onlyFormats] narrows down the manifest's list (an empty intersection
  /// also yields `null`: nothing to register); without it, all of the
  /// manifest's formats are used.
  static SidecarConverter? fromDirectory(
    String directory, {
    Duration timeout = const Duration(seconds: 120),
    Directory? tempDirectory,
    Set<String>? onlyFormats,
    int? maxPdfPages,
    bool scannedPdfToDart = false,
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
      scannedPdfToDart: scannedPdfToDart,
    );
  }

  /// What the sidecar runs first for in the app — the author's decision for
  /// Stage 5, item 5 (`docs/implementation-plan.md`). The sidecar is tens of
  /// times slower than the Dart core (a 300-page PDF — 112s vs 1.2s, an
  /// xlsx with 50k rows — 55s vs 4.4s), and by the Stage 4 comparison the
  /// Dart core is no worse for `docx`/`xlsx`/`pptx`. So it only runs first
  /// where it offers something Dart didn't have: `xls`/`msg` (before 0.9 —
  /// it was the only option; since 0.9 Dart has its own parser and the
  /// sidecar stays as a fallback — removing them from here is the author's
  /// call) and `pdf` (tables) — and for `pdf` only up to [appMaxPdfPages]
  /// pages. The sidecar can still handle `docx`/`xlsx`/`pptx` — as a
  /// reference for `make compare-sidecar`, not as an app code path.
  static const appFormats = {'pdf', 'xls', 'msg'};

  /// The PDF threshold for the app: ≈0.37s per page for the sidecar — about
  /// 20s in the worst case. Longer than that — the Dart core, with a
  /// warning that tables were extracted as text.
  static const appMaxPdfPages = 50;

  /// Looks for the sidecar where it should live on this platform:
  ///
  /// 1. `MARKITDOWN_SIDECAR_DIR` — for development and tests (following the
  ///    pattern of `MARKITDOWN_PDFIUM_PATH`). If the variable is set, no
  ///    other locations are checked: a wrong path must not be silently
  ///    swapped for the bundled one.
  /// 2. macOS: `Contents/Resources/sidecar` next to the bundle's executable
  ///    (`X.app/Contents/MacOS/X`).
  /// 3. Windows: `sidecar\` in the `.exe`'s directory — placed there by
  ///    `install(DIRECTORY …)` in `app/windows/CMakeLists.txt`, and it sits
  ///    there the same way in the unpacked zip.
  ///
  /// On Android and iOS — always `null`, even if the variable is set: there
  /// is no sidecar there and never will be (native wheels for mobile ABIs
  /// don't exist). The discovered sidecar is limited to [appFormats] and
  /// [appMaxPdfPages] — this is the app's code path. [scannedPdfToDart] —
  /// the app passes `true` when OCR is available. The remaining parameters
  /// are for tests.
  static SidecarConverter? discover({
    bool scannedPdfToDart = false,
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
      scannedPdfToDart: scannedPdfToDart,
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
      // Couldn't be opened — let the sidecar try itself: there's still a
      // fallback to Dart if it declines.
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
    if (formatId == 'pdf' &&
        scannedPdfToDart &&
        pdfHasScanPages(request.bytes) == true) {
      throw const ConversionDeclinedException(
        failure: UnsupportedFormatFailure('PDF со сканированными страницами'),
        fallbackWarning:
            'в PDF есть сканированные страницы — он обработан Dart-ядром с '
            'OCR, а не сайдкаром: таблицы извлечены как текст',
      );
    }

    // The temp directory is only created if the file has no path on disk,
    // and is removed right here, in finally: the caller owns the file, not
    // the sidecar (otherwise it's unclear who's responsible for deletion).
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
          // Deletion failed (antivirus, a locked file) — not a reason to
          // drop an already-ready result.
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
        // This line makes it clear, when debugging "why did I get something
        // different", that the sidecar ran rather than the Dart core
        // (results can differ).
        ConversionWarning(
          'converterId: sidecar — формат ${info.detectedType.label} '
          'обработан Python-сайдкаром${version.isEmpty ? '' : ' ($version)'}, '
          'а не Dart-ядром: на мобильных платформах результат может отличаться',
        ),
        for (final w in parsed.warnings) ConversionWarning(w),
      ],
    );
  }

  /// Runs the subprocess with a timeout and an output limit. Doesn't
  /// throw — anything that goes wrong is returned via [_Run]'s fields, and
  /// [_interpret] decides what to do.
  Future<_Run> _run(SidecarCommand command) async {
    final Process process;
    try {
      process = await Process.start(command.executable, command.arguments);
    } on ProcessException catch (e) {
      return _Run(spawnError: e.message);
    }

    // The sidecar never reads stdin; close it so it doesn't hang waiting to
    // read.
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
    // stderr is for developers only; the first 16 KB is enough, the rest is
    // read and discarded, otherwise the subprocess would block on a full
    // pipe.
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

    // A child process that inherited the pipes could keep them open after
    // the process dies — don't wait forever.
    try {
      await Future.wait([
        stdoutDone,
        stderrDone,
      ]).timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // Take what we managed to read so far.
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

/// Strict protocol parsing: exactly one JSON object, `markdown` is a string,
/// `title` is a string or `null`, `warnings` is a list of strings. Any
/// deviation (including extra text around the JSON caused by a library's
/// `print`) yields `null`.
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

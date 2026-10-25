import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markitdown_core/markitdown_core.dart';
import 'package:markitdown_ui/main.dart';
import 'package:markitdown_ui/src/file_intake/file_intake_controller.dart';
import 'package:markitdown_ui/src/merge/merge_controller.dart';

const _ru = Locale('ru');

void main() {
  testWidgets('empty screen offers to pick a file', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MarkItDownApp(locale: _ru)),
    );

    expect(find.text('Перетащите файл сюда'), findsOneWidget);
    expect(find.text('Выбрать файл'), findsOneWidget);
  });

  testWidgets('spinner and file are shown during conversion', (tester) async {
    final fakeInfo = StreamInfo(
      filename: 'отчёт.docx',
      extension: 'docx',
      mimeType: null,
      lengthBytes: 188416,
      detectedType: const DetectedType(FileKind.docx, 'OOXML Word (.docx)'),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fileIntakeControllerProvider.overrideWith(
            () =>
                _FakeFileIntakeController(FileIntakeState.converting(fakeInfo)),
          ),
        ],
        child: const MarkItDownApp(locale: _ru),
      ),
    );

    expect(find.text('отчёт.docx'), findsOneWidget);
    expect(find.text('OOXML Word (.docx), 184 КБ'), findsOneWidget);
    expect(find.text('Конвертируется…'), findsOneWidget);
  });

  testWidgets('speech recognition — percentage and "Stop"', (tester) async {
    final controller = _FakeFileIntakeController(
      FileIntakeState.converting(
        _voiceInfo,
        transcribing: true,
        speechProgress: 42,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fileIntakeControllerProvider.overrideWith(() => controller),
        ],
        child: const MarkItDownApp(locale: _ru),
      ),
    );

    expect(find.text('Распознаётся речь… 42 %'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.42,
    );
    await tester.tap(find.text('Остановить'));
    expect(controller.stopped, isTrue);
  });

  testWidgets('after "Stop" — waiting for the chunk, button is disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fileIntakeControllerProvider.overrideWith(
            () => _FakeFileIntakeController(
              FileIntakeState.converting(
                _voiceInfo,
                transcribing: true,
                speechProgress: 42,
                stopping: true,
              ),
            ),
          ),
        ],
        child: const MarkItDownApp(locale: _ru),
      ),
    );

    expect(find.textContaining('Останавливается'), findsOneWidget);
    final button = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('Остановить'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('successful conversion shows markdown preview', (tester) async {
    final fakeInfo = StreamInfo(
      filename: 'заметка.txt',
      extension: 'txt',
      mimeType: null,
      lengthBytes: 11,
      detectedType: const DetectedType(FileKind.text, 'Текст (.txt)'),
    );
    const result = ConversionResult(
      markdown: 'Hello world',
      converterId: 'plain_text',
      elapsed: Duration.zero,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fileIntakeControllerProvider.overrideWith(
            () => _FakeFileIntakeController(
              FileIntakeState.ready(fakeInfo, result),
            ),
          ),
        ],
        child: const MarkItDownApp(locale: _ru),
      ),
    );

    expect(find.text('заметка.txt'), findsOneWidget);
    expect(find.text('Hello world'), findsOneWidget);
    expect(find.text('Скопировать'), findsOneWidget);
    expect(find.text('Сохранить как .md'), findsOneWidget);
    expect(find.text('Добавить файлы'), findsOneWidget);
  });

  testWidgets('merge list — row statuses, a failure blocks "Merge"', (
    tester,
  ) async {
    await tester.pumpWidget(_mergeListApp());

    expect(find.text('4 файла для склейки'), findsOneWidget);
    expect(find.text('a.txt'), findsOneWidget);
    expect(
      find.text(
        'Файл повреждён. Не удалось прочитать содержимое: архив обрезан',
      ),
      findsOneWidget,
    );
    expect(find.text('Распознаётся речь… 40 %'), findsOneWidget);
    expect(find.byTooltip('Остановить'), findsOneWidget);
    expect(find.text('https://example.com/a'), findsOneWidget);
    expect(find.text('В очереди'), findsOneWidget);
    expect(
      find.text('Уберите файлы с ошибкой, чтобы склеить остальные.'),
      findsOneWidget,
    );
    final merge = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('Склеить'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );
    expect(merge.onPressed, isNull);
  });

  testWidgets('merge list fits a phone (360 dp) without overflow', (
    tester,
  ) async {
    // Rows carry up to three buttons on the right; an overflow there is
    // reported as an exception and fails the test.
    tester.view.physicalSize = const Size(1080, 2220);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_mergeListApp());
    expect(find.text('Склеить'), findsOneWidget);
    expect(find.byTooltip('Очистить'), findsOneWidget);
  });

  testWidgets('merged result — preview, warnings, back to the list', (
    tester,
  ) async {
    final controller = _FakeMergeController(
      MergeState(
        [
          MergeItem(
            id: 0,
            status: MergeItemStatus.ready,
            info: _txtInfo('a.txt'),
            result: _result('A'),
          ),
          MergeItem(
            id: 1,
            status: MergeItemStatus.ready,
            info: _txtInfo('b.txt'),
            result: _result('B'),
          ),
        ],
        merged: const ConversionResult(
          markdown: '# a.txt\n\nA\n\n---\n\n# b.txt\n\nB\n',
          converterId: 'merge',
          elapsed: Duration.zero,
          warnings: [ConversionWarning('b.txt: скан без текста')],
        ),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [mergeControllerProvider.overrideWith(() => controller)],
        child: const MarkItDownApp(locale: _ru),
      ),
    );

    expect(find.text('Склеено 2 файла'), findsOneWidget);
    expect(find.textContaining('# b.txt'), findsOneWidget);
    expect(find.text('• b.txt: скан без текста'), findsOneWidget);
    expect(find.text('Скопировать'), findsOneWidget);
    await tester.tap(find.text('К списку'));
    expect(controller.wentBack, isTrue);
  });

  testWidgets('unsupported format shows the error screen', (tester) async {
    // `.sketch` — same example as in
    // docs/conversion-pipeline.md#errors: signatures don't match, and it's
    // genuinely "unsupported", not PDF, which we've handled since Stage 3.
    final fakeInfo = StreamInfo(
      filename: 'макет.sketch',
      extension: 'sketch',
      mimeType: null,
      lengthBytes: 2048,
      detectedType: const DetectedType(FileKind.unknown, 'Неизвестный формат'),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fileIntakeControllerProvider.overrideWith(
            () => _FakeFileIntakeController(
              FileIntakeState.failed(
                fakeInfo,
                const UnsupportedFormatFailure('Неизвестный формат'),
              ),
            ),
          ),
        ],
        child: const MarkItDownApp(locale: _ru),
      ),
    );

    expect(find.text('Формат не поддерживается'), findsOneWidget);
    expect(
      find.text(
        'Неизвестный формат — такой формат пока не умеем конвертировать.',
      ),
      findsOneWidget,
    );
    expect(find.text('Выбрать другой файл'), findsOneWidget);
  });

  testWidgets('"Paste link": dialog passes the link to the controller', (
    tester,
  ) async {
    final controller = _FakeFileIntakeController(const FileIntakeState.idle());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fileIntakeControllerProvider.overrideWith(() => controller),
        ],
        child: const MarkItDownApp(locale: _ru),
      ),
    );

    // The clipboard is empty in tests — so is the field.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    await tester.tap(find.text('Вставить ссылку'));
    await tester.pumpAndSettle();
    expect(find.text('Ссылка на страницу или файл'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'youtu.be/abc');
    await tester.tap(find.text('Конвертировать'));
    await tester.pumpAndSettle();
    expect(controller.acceptedUrl, 'youtu.be/abc');
  });

  testWidgets('link is downloading — address and "Downloading…"', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fileIntakeControllerProvider.overrideWith(
            () => _FakeFileIntakeController(
              const FileIntakeState.downloading('https://example.com/a.pdf'),
            ),
          ),
        ],
        child: const MarkItDownApp(locale: _ru),
      ),
    );

    expect(find.text('https://example.com/a.pdf'), findsOneWidget);
    expect(find.text('Скачивается…'), findsOneWidget);
  });

  testWidgets('link failed to download — clear network error', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fileIntakeControllerProvider.overrideWith(
            () => _FakeFileIntakeController(
              const FileIntakeState.failed(
                null,
                NetworkFailure('по этой ссылке ничего нет (HTTP 404)'),
              ),
            ),
          ),
        ],
        child: const MarkItDownApp(locale: _ru),
      ),
    );

    expect(find.text('Не удалось скачать'), findsOneWidget);
    expect(find.text('по этой ссылке ничего нет (HTTP 404)'), findsOneWidget);
  });
}

final _voiceInfo = StreamInfo(
  filename: 'голосовое.ogg',
  extension: 'ogg',
  mimeType: null,
  lengthBytes: 25454,
  detectedType: const DetectedType(FileKind.ogg, 'Ogg'),
);

/// A merge list with one row of each kind: ready, failed, transcribing,
/// and a link waiting its turn.
Widget _mergeListApp() => ProviderScope(
  overrides: [
    mergeControllerProvider.overrideWith(
      () => _FakeMergeController(
        MergeState([
          MergeItem(
            id: 0,
            status: MergeItemStatus.ready,
            info: _txtInfo('a.txt'),
            result: _result('A'),
          ),
          MergeItem(
            id: 1,
            status: MergeItemStatus.failed,
            info: _txtInfo('битый.zip'),
            failure: const CorruptedFileFailure(
              converterId: 'zip',
              reason: 'архив обрезан',
            ),
          ),
          MergeItem(
            id: 2,
            status: MergeItemStatus.converting,
            info: _voiceInfo,
            transcribing: true,
            speechProgress: 40,
          ),
          const MergeItem(
            id: 3,
            status: MergeItemStatus.waiting,
            label: 'https://example.com/a',
          ),
        ]),
      ),
    ),
  ],
  child: const MarkItDownApp(locale: _ru),
);

StreamInfo _txtInfo(String filename) => StreamInfo(
  filename: filename,
  extension: 'txt',
  mimeType: null,
  lengthBytes: 1,
  detectedType: const DetectedType(FileKind.text, 'Текст (.txt)'),
);

ConversionResult _result(String markdown) => ConversionResult(
  markdown: markdown,
  converterId: 'plain_text',
  elapsed: Duration.zero,
);

class _FakeMergeController extends MergeController {
  final MergeState initial;
  bool wentBack = false;

  _FakeMergeController(this.initial);

  @override
  MergeState build() => initial;

  @override
  void backToList() => wentBack = true;
}

class _FakeFileIntakeController extends FileIntakeController {
  final FileIntakeState initial;
  bool stopped = false;

  _FakeFileIntakeController(this.initial);

  @override
  FileIntakeState build() => initial;

  String? acceptedUrl;

  @override
  void stopTranscription() => stopped = true;

  @override
  Future<void> acceptUrl(String text) async => acceptedUrl = text;
}

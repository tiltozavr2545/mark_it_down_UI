import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markitdown_core/markitdown_core.dart';
import 'package:markitdown_ui/main.dart';
import 'package:markitdown_ui/src/file_intake/file_intake_controller.dart';

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

  testWidgets('successful conversion shows markdown preview', (
    tester,
  ) async {
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
  });

  testWidgets('unsupported format shows the error screen', (
    tester,
  ) async {
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

  testWidgets('link is downloading — address and "Downloading…"', (tester) async {
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markitdown_core/markitdown_core.dart';
import 'package:markitdown_ui/main.dart';
import 'package:markitdown_ui/src/file_intake/file_intake_controller.dart';

const _ru = Locale('ru');

void main() {
  testWidgets('пустой экран предлагает выбрать файл', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MarkItDownApp(locale: _ru)),
    );

    expect(find.text('Перетащите файл сюда'), findsOneWidget);
    expect(find.text('Выбрать файл'), findsOneWidget);
  });

  testWidgets('во время конвертации показан спиннер и файл', (tester) async {
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

  testWidgets('успешная конвертация показывает markdown-превью', (
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

  testWidgets('неподдерживаемый формат показывает экран ошибки', (
    tester,
  ) async {
    // `.sketch` — тот же пример, что в
    // docs/conversion-pipeline.md#ошибки: сигнатуры не совпадают, и это
    // честно «не поддерживается», а не PDF, который с Этапа 3 умеем.
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
}

class _FakeFileIntakeController extends FileIntakeController {
  final FileIntakeState initial;

  _FakeFileIntakeController(this.initial);

  @override
  FileIntakeState build() => initial;
}

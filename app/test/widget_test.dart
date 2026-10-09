import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markitdown_core/markitdown_core.dart';
import 'package:markitdown_ui/main.dart';
import 'package:markitdown_ui/src/file_intake/file_intake_controller.dart';

void main() {
  testWidgets('пустой экран предлагает выбрать файл', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MarkItDownApp()));

    expect(find.text('Перетащите файл сюда'), findsOneWidget);
    expect(find.text('Выбрать файл'), findsOneWidget);
  });

  testWidgets('принятый файл показывает имя, размер и тип', (tester) async {
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
            () => _FakeFileIntakeController(FileIntakeState(info: fakeInfo)),
          ),
        ],
        child: const MarkItDownApp(),
      ),
    );

    expect(find.text('отчёт.docx'), findsOneWidget);
    expect(find.text('OOXML Word (.docx), 184 КБ'), findsOneWidget);
    expect(find.text('Выбрать другой файл'), findsOneWidget);
  });
}

class _FakeFileIntakeController extends FileIntakeController {
  final FileIntakeState initial;

  _FakeFileIntakeController(this.initial);

  @override
  FileIntakeState build() => initial;
}

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markitdown_core/markitdown_core.dart';
import 'package:markitdown_ui/src/conversion/convert_picked.dart';
import 'package:markitdown_ui/src/file_intake/picked_file.dart';
import 'package:markitdown_ui/src/merge/merge_controller.dart';

/// The merge list's queue, with conversion replaced: each file's outcome is
/// released by the test, so the order and the in-between states are seen.
void main() {
  late Map<String, Completer<ConversionOutcome>> pending;
  late List<String> started;
  late ProviderContainer container;

  MergeController controller() =>
      container.read(mergeControllerProvider.notifier);
  MergeState state() => container.read(mergeControllerProvider);
  List<MergeItemStatus> statuses() => [
    for (final item in state().items) item.status,
  ];

  PickedFile file(String name) => PickedFile(
    bytes: Uint8List.fromList(utf8.encode('text of $name')),
    filename: name,
  );

  void succeed(String name) => pending[name]!.complete(
    ConversionSuccess(
      ConversionResult(
        markdown: 'text of $name',
        converterId: 'plain_text',
        elapsed: Duration.zero,
      ),
    ),
  );

  void fail(String name) => pending[name]!.complete(
    const ConversionError(
      CorruptedFileFailure(converterId: 'zip', reason: 'обрезан'),
    ),
  );

  setUp(() {
    pending = {};
    started = [];
    container = ProviderContainer(
      overrides: [
        pickedConverterProvider.overrideWithValue((
          file,
          info, {
          required isCurrent,
          speech,
        }) {
          started.add(file.filename!);
          return (pending[file.filename!] = Completer()).future;
        }),
      ],
    );
  });

  tearDown(() => container.dispose());

  test('files are converted one at a time, top to bottom', () async {
    controller().addFiles([file('a.txt'), file('b.txt')]);
    await pumpEventQueue();
    expect(started, ['a.txt']);
    expect(statuses(), [MergeItemStatus.converting, MergeItemStatus.waiting]);
    expect(state().canMerge, isFalse);

    succeed('a.txt');
    await pumpEventQueue();
    expect(started, ['a.txt', 'b.txt']);
    succeed('b.txt');
    await pumpEventQueue();
    expect(statuses(), [MergeItemStatus.ready, MergeItemStatus.ready]);
    expect(state().canMerge, isTrue);
  });

  test('a failed file blocks the merge until it is removed', () async {
    controller().addFiles([file('a.txt'), file('bad.zip'), file('c.txt')]);
    await pumpEventQueue();
    succeed('a.txt');
    await pumpEventQueue();
    fail('bad.zip');
    await pumpEventQueue();
    succeed('c.txt');
    await pumpEventQueue();

    expect(state().hasFailures, isTrue);
    expect(state().canMerge, isFalse);
    controller().merge('(без имени)');
    expect(state().merged, isNull);

    controller().remove(state().items[1].id);
    expect(state().canMerge, isTrue);
    controller().merge('(без имени)');
    expect(
      state().merged!.markdown,
      '# a.txt\n\ntext of a.txt\n\n---\n\n# c.txt\n\ntext of c.txt\n',
    );
  });

  test('the merge follows the reordered list', () async {
    controller().addFiles([file('a.txt'), file('b.txt'), file('c.txt')]);
    for (final name in ['a.txt', 'b.txt', 'c.txt']) {
      await pumpEventQueue();
      succeed(name);
    }
    await pumpEventQueue();

    controller().move(2, 0);
    controller().merge('(без имени)');
    expect(
      RegExp(
        r'^# (.+)$',
        multiLine: true,
      ).allMatches(state().merged!.markdown).map((m) => m[1]),
      ['c.txt', 'a.txt', 'b.txt'],
    );

    controller().backToList();
    expect(state().merged, isNull);
    expect(state().items, hasLength(3));
  });

  test('a single result joins the list without converting again', () async {
    final info = StreamInfo.fromHead(
      Uint8List.fromList(utf8.encode('x')),
      filename: 'first.txt',
    );
    controller().startFrom(
      info,
      const ConversionResult(
        markdown: 'first',
        converterId: 'plain_text',
        elapsed: Duration.zero,
      ),
    );
    controller().addFiles([file('second.txt')]);
    await pumpEventQueue();
    expect(started, ['second.txt']);
    succeed('second.txt');
    await pumpEventQueue();

    controller().merge('(без имени)');
    expect(state().merged!.markdown, startsWith('# first.txt\n\nfirst\n'));
  });

  test('a file removed mid-conversion is dropped, the queue goes on', () async {
    controller().addFiles([file('a.txt'), file('b.txt')]);
    await pumpEventQueue();
    controller().remove(state().items.first.id);
    succeed('a.txt');
    await pumpEventQueue();

    expect(started, ['a.txt', 'b.txt']);
    expect([for (final item in state().items) item.name], ['b.txt']);
  });

  test('"Clear" empties the list; later files start a new one', () async {
    controller().addFiles([file('a.txt'), file('b.txt')]);
    await pumpEventQueue();
    controller().clear();
    expect(state().active, isFalse);

    controller().addFiles([file('c.txt')]);
    succeed('a.txt');
    await pumpEventQueue();
    // b.txt was cleared before its turn — it's never converted.
    expect(started, ['a.txt', 'c.txt']);
    expect([for (final item in state().items) item.name], ['c.txt']);
  });
}

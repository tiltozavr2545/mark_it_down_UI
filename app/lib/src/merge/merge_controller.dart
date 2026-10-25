import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markitdown_core/markitdown_core.dart';

import '../conversion/convert_picked.dart';
import '../file_intake/picked_file.dart';

enum MergeItemStatus { waiting, downloading, converting, ready, failed }

/// One row of the merge list: a file or a link, and how far along it is.
class MergeItem {
  final int id;

  /// What the row is called before the file is known: the filename, or the
  /// link being downloaded.
  final String? label;

  /// `null` until a link is downloaded.
  final StreamInfo? info;
  final MergeItemStatus status;
  final ConversionResult? result;
  final ConversionFailure? failure;

  /// Speech recognition is in progress: show [speechProgress] and "Stop".
  final bool transcribing;

  /// 0-100; 0 means the audio is still decoding or the model is loading.
  final int speechProgress;
  final bool stopping;

  const MergeItem({
    required this.id,
    required this.status,
    this.label,
    this.info,
    this.result,
    this.failure,
    this.transcribing = false,
    this.speechProgress = 0,
    this.stopping = false,
  });

  /// The name under which the file goes into the merge: a page fetched by
  /// link is called by its title, a file by its name.
  String? get name {
    final info = this.info;
    if (info?.url != null) {
      return result?.title ?? info!.filename ?? info!.url;
    }
    return info?.filename ?? label;
  }

  MergeItem copyWith({
    StreamInfo? info,
    MergeItemStatus? status,
    ConversionResult? result,
    ConversionFailure? failure,
    bool? transcribing,
    int? speechProgress,
    bool? stopping,
  }) => MergeItem(
    id: id,
    label: label,
    info: info ?? this.info,
    status: status ?? this.status,
    result: result ?? this.result,
    failure: failure ?? this.failure,
    transcribing: transcribing ?? this.transcribing,
    speechProgress: speechProgress ?? this.speechProgress,
    stopping: stopping ?? this.stopping,
  );
}

class MergeState {
  final List<MergeItem> items;

  /// Set once "Merge" is pressed — the merged preview is on screen.
  final ConversionResult? merged;

  const MergeState(this.items, {this.merged});

  /// The merge list (or its result) is on screen instead of the
  /// single-file flow.
  bool get active => items.isNotEmpty;

  bool get hasFailures =>
      items.any((item) => item.status == MergeItemStatus.failed);

  /// A failed file blocks the whole merge (author's decision: an error stops
  /// everything rather than leaving a gap) — it has to be removed first.
  bool get canMerge =>
      items.isNotEmpty &&
      items.every((item) => item.status == MergeItemStatus.ready);
}

/// The merge list: files and links are converted one at a time as soon as
/// they're added — that's the check that a file isn't corrupted, done
/// before "Merge" rather than halfway through it (author's decision). The
/// merge itself is then instant, and reordering doesn't reconvert anything.
///
/// One at a time, not in parallel: a phone holding several files' bytes
/// and parse trees at once is how the app gets killed; and only one speech
/// recognition can run at a time anyway. A file's bytes are dropped as
/// soon as it's converted — the list keeps only Markdown.
class MergeController extends Notifier<MergeState> {
  /// Sources still waiting in the queue: a [PickedFile] or a link.
  final _pending = <int, Object>{};
  int _nextId = 0;
  bool _running = false;

  /// The item being converted now and its speech-recognition control.
  int? _currentId;
  TranscriptionControl? _control;

  @override
  MergeState build() => const MergeState([]);

  /// "Add files" on a single file's result: that result becomes the first
  /// row, without converting it again.
  void startFrom(StreamInfo info, ConversionResult result) {
    clear();
    state = MergeState([
      MergeItem(
        id: _nextId++,
        status: MergeItemStatus.ready,
        info: info,
        result: result,
      ),
    ]);
  }

  void addFiles(List<PickedFile> files) {
    final added = [
      for (final file in files)
        MergeItem(
          id: _remember(file),
          status: MergeItemStatus.waiting,
          label: file.filename,
          info: infoFor(file),
        ),
    ];
    state = MergeState([...state.items, ...added]);
    _run();
  }

  /// A link — downloaded and converted in its turn, like a file.
  void addUrl(String text) {
    final item = MergeItem(
      id: _remember(text),
      status: MergeItemStatus.waiting,
      label: parseUserUrl(text)?.toString() ?? text,
    );
    state = MergeState([...state.items, item]);
    _run();
  }

  void remove(int id) {
    if (id == _currentId) _control?.cancel();
    _pending.remove(id);
    state = MergeState([
      for (final item in state.items)
        if (item.id != id) item,
    ]);
  }

  /// Moves the item at [from] so that it ends up at index [to].
  void move(int from, int to) {
    final items = [...state.items];
    items.insert(to, items.removeAt(from));
    state = MergeState(items, merged: state.merged);
  }

  /// Stop speech recognition of [id]: what's already recognized becomes its
  /// result, with a warning that the transcript is incomplete.
  void stopTranscription(int id) {
    final control = _control;
    if (id != _currentId || control == null) return;
    control.cancel();
    _update(id, (item) => item.copyWith(stopping: true));
  }

  /// [unnamed] — the heading for a file that came without a name.
  void merge(String unnamed) {
    if (!state.canMerge) return;
    final merged = mergeResults([
      for (final item in state.items)
        MergePart(item.name ?? unnamed, item.result!, url: item.info?.url),
    ]);
    state = MergeState(state.items, merged: merged);
  }

  void backToList() => state = MergeState(state.items);

  void clear() {
    // The isolate can't be stopped, but speech recognition in it can — so
    // it doesn't burn CPU for minutes on a file no longer wanted.
    _control?.cancel();
    _pending.clear();
    state = const MergeState([]);
  }

  int _remember(Object source) {
    final id = _nextId++;
    _pending[id] = source;
    return id;
  }

  bool _has(int id) => state.items.any((item) => item.id == id);

  void _update(int id, MergeItem Function(MergeItem) change) {
    if (!_has(id)) return;
    state = MergeState([
      for (final item in state.items) item.id == id ? change(item) : item,
    ], merged: state.merged);
  }

  /// Converts waiting items top to bottom: the list's order is the order
  /// the person sees, so the first file is ready first.
  Future<void> _run() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final next = state.items
            .where((item) => item.status == MergeItemStatus.waiting)
            .firstOrNull;
        if (next == null) break;
        await _process(next.id);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _process(int id) async {
    final source = _pending.remove(id);
    final PickedFile file;
    if (source is String) {
      _update(id, (item) => item.copyWith(status: MergeItemStatus.downloading));
      final DownloadedUrl downloaded;
      try {
        downloaded = await downloadUrl(source);
      } on WebFetchException catch (e) {
        _update(
          id,
          (item) => item.copyWith(
            status: MergeItemStatus.failed,
            failure: NetworkFailure(e.reason),
          ),
        );
        return;
      }
      file = PickedFile(
        bytes: downloaded.bytes,
        filename: downloaded.filename,
        mimeType: downloaded.mimeType,
        url: downloaded.url,
      );
    } else if (source is PickedFile) {
      file = source;
    } else {
      return;
    }
    if (!_has(id)) return;

    final info = infoFor(file);
    _update(
      id,
      (item) => item.copyWith(status: MergeItemStatus.converting, info: info),
    );
    _currentId = id;
    final ConversionOutcome? outcome;
    try {
      outcome = await ref
          .read(pickedConverterProvider)
          .call(
            file,
            info,
            isCurrent: () => _has(id),
            speech: SpeechHooks(
              onStart: (control) {
                _control = control;
                _update(id, (item) => item.copyWith(transcribing: true));
              },
              onProgress: (progress, stopping) => _update(
                id,
                (item) =>
                    item.copyWith(speechProgress: progress, stopping: stopping),
              ),
              onEnd: (control) {
                if (identical(_control, control)) _control = null;
              },
            ),
          );
    } finally {
      _currentId = null;
    }

    switch (outcome) {
      case null:
        return;
      case ConversionSuccess(result: final result):
        _update(
          id,
          (item) => item.copyWith(
            status: MergeItemStatus.ready,
            result: result,
            transcribing: false,
          ),
        );
      case ConversionError(failure: final failure):
        _update(
          id,
          (item) => item.copyWith(
            status: MergeItemStatus.failed,
            failure: failure,
            transcribing: false,
          ),
        );
    }
  }
}

final mergeControllerProvider = NotifierProvider<MergeController, MergeState>(
  MergeController.new,
);

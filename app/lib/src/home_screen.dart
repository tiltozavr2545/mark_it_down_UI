import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markitdown_core/markitdown_core.dart';
import 'package:super_clipboard/super_clipboard.dart';

import 'file_intake/file_intake_controller.dart';
import 'file_intake/format_size.dart';
import 'file_intake/picked_file.dart';
import 'file_intake/share_intake.dart';
import 'markdown_export.dart';
import 'merge/merge_controller.dart';
import 'workspace.dart';
import '../l10n/generated/app_localizations.dart';

/// Markdown longer than this doesn't render in full — `SelectableText` on a
/// multi-megabyte result freezes the frame solid. The full text still goes
/// to the clipboard and the file; the truncation is only on screen. See
/// `docs/client-architecture.md#large-files`.
const _maxPreviewChars = 20000;

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _dragging = false;
  bool _savingBatch = false;
  int? _previewId;
  OutputMode _mode = OutputMode.separate;
  StreamSubscription<SharedInput>? _shareSubscription;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      final shareIntake = ShareIntake();
      shareIntake.initial().then(_acceptShared);
      _shareSubscription = shareIntake.stream().listen(_acceptShared);
    }
  }

  /// Shared a file — handled as a file; a link (YouTube, browser) — "link"
  /// mode. Text with no link is silently ignored.
  void _acceptShared(SharedInput input) {
    if (input.files.isNotEmpty) {
      _incoming(input.files);
      return;
    }
    final link = input.link;
    if (link != null && parseUserUrl(link) != null) {
      _incoming(const [], link: link);
    }
  }

  Future<String?> _askLink() async {
    // A link from the clipboard goes straight into the field: it was
    // usually just copied. Read on button press, not on startup.
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final copied = clipboard?.text?.trim() ?? '';
    if (!mounted) return null;
    final link = await showDialog<String>(
      context: context,
      builder: (context) =>
          _LinkDialog(initial: parseUserUrl(copied) == null ? '' : copied),
    );
    if (link == null || link.trim().isEmpty) return null;
    return link;
  }

  @override
  void dispose() {
    _shareSubscription?.cancel();
    super.dispose();
  }

  /// Files or a link from a drop or "Share" — sources that can arrive at
  /// any moment. With nothing on screen, one file opens as before and
  /// several go into the queue. A drop or share over an existing result
  /// or queue asks whether to add to it or start over.
  Future<void> _incoming(List<PickedFile> files, {String? link}) async {
    if (!mounted || (files.isEmpty && link == null)) return;
    final single = ref.read(fileIntakeControllerProvider);
    if (ref.read(mergeControllerProvider).active ||
        single.phase == FileIntakePhase.ready) {
      final add = await showDialog<bool>(
        context: context,
        builder: (context) => const _IncomingDialog(),
      );
      if (add == null || !mounted) return;
      if (add) {
        _addToQueue(files, link: link);
        return;
      }
      _clearQueue();
    }

    final intake = ref.read(fileIntakeControllerProvider.notifier);
    if (link != null) {
      intake.acceptUrl(link);
    } else if (files.length == 1) {
      intake.accept(files.single);
    } else {
      intake.clear();
      ref.read(mergeControllerProvider.notifier).addFiles(files);
    }
  }

  /// A single file's visible result becomes the first item in the queue.
  void _addToQueue(List<PickedFile> files, {String? link}) {
    setState(() => _previewId = null);
    final merge = ref.read(mergeControllerProvider.notifier);
    final single = ref.read(fileIntakeControllerProvider);
    if (!ref.read(mergeControllerProvider).active &&
        single.phase == FileIntakePhase.ready) {
      merge.startFrom(single.info!, single.result!);
      ref.read(fileIntakeControllerProvider.notifier).clear();
    }
    if (files.isNotEmpty) merge.addFiles(files);
    if (link != null) merge.addUrl(link);
  }

  void _clearQueue() {
    setState(() => _previewId = null);
    ref.read(mergeControllerProvider.notifier).clear();
  }

  Future<void> _pickFiles({bool add = false}) async {
    try {
      final result = await FilePicker.pickFiles(
        withData: true,
        allowMultiple: true,
      );
      if (!mounted) return;
      final files = [
        for (final file in result?.files ?? const <PlatformFile>[])
          if (file.bytes case final bytes?)
            PickedFile(bytes: bytes, filename: file.name, localPath: file.path),
      ];
      if (files.isEmpty) {
        if (result != null) {
          _showMessage(context, AppLocalizations.of(context)!.pickFailed);
        }
        return;
      }
      if (add) {
        _addToQueue(files);
      } else {
        await _incoming(files);
      }
    } on PlatformException {
      if (mounted) {
        _showMessage(context, AppLocalizations.of(context)!.pickFailed);
      }
    } on FileSystemException {
      if (mounted) {
        _showMessage(context, AppLocalizations.of(context)!.pickFailed);
      }
    }
  }

  Future<void> _pasteLink({bool add = false}) async {
    final link = await _askLink();
    if (!mounted || link == null) return;
    if (add) {
      _addToQueue(const [], link: link);
    } else {
      await _incoming(const [], link: link);
    }
  }

  Future<void> _saveBatch(List<MergeItem> items) async {
    if (_savingBatch) return;
    setState(() => _savingBatch = true);
    final l10n = AppLocalizations.of(context)!;
    try {
      final outcome = await saveMarkdownBatch([
        for (final item in items)
          if (item.result case final result?)
            (base: _itemBase(item), markdown: result.markdown),
      ], dialogTitle: l10n.saveFolderTitle);
      if (!mounted || outcome == null) return;
      _showMessage(context, switch (outcome) {
        (saved: 0, failed: _) => l10n.saveFailed,
        (saved: final saved, failed: 0) => l10n.batchSaved(saved),
        (saved: final saved, failed: final failed) => l10n.batchSavePartial(
          saved,
          failed,
        ),
      });
    } on PlatformException {
      if (mounted) _showMessage(context, l10n.saveFailed);
    } on FileSystemException {
      if (mounted) _showMessage(context, l10n.saveFailed);
    } finally {
      if (mounted) setState(() => _savingBatch = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(fileIntakeControllerProvider);
    final queue = ref.watch(mergeControllerProvider);
    return Scaffold(
      body: SafeArea(
        child: DropTarget(
          onDragEntered: (_) => setState(() => _dragging = true),
          onDragExited: (_) => setState(() => _dragging = false),
          onDragDone: (details) async {
            setState(() => _dragging = false);
            try {
              await _incoming([
                for (final item in details.files)
                  PickedFile(
                    bytes: await item.readAsBytes(),
                    filename: item.name,
                    mimeType: item.mimeType,
                    localPath: item.path,
                  ),
              ]);
            } on IOException {
              if (context.mounted) {
                _showMessage(context, AppLocalizations.of(context)!.pickFailed);
              }
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const WorkspaceHeader(),
              Expanded(
                child: queue.active ? _queueView(queue) : _singleView(state),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _queueView(MergeState queue) {
    final l10n = AppLocalizations.of(context)!;
    final controller = ref.read(mergeControllerProvider.notifier);
    final back = TextButton.icon(
      onPressed: () {
        setState(() => _previewId = null);
        controller.backToList();
      },
      icon: const Icon(Icons.arrow_back),
      label: Text(l10n.backToListButton),
    );
    if (queue.merged case final result?) {
      return _PreviewResult(
        title: l10n.mergedTitle(queue.items.length),
        result: result,
        saveName: _mergedFileName(l10n, queue.items),
        leadingAction: back,
        actions: [
          TextButton(onPressed: _clearQueue, child: Text(l10n.clearButton)),
        ],
      );
    }
    final selected = queue.items
        .where((item) => item.id == _previewId)
        .firstOrNull;
    if (selected?.result case final result?) {
      return _PreviewResult(
        title: selected!.name ?? l10n.noFilename,
        subtitle: _typeAndSize(selected.info),
        result: result,
        saveName: '${_itemBase(selected)}.md',
        leadingAction: back,
        actions: const [],
      );
    }
    return _FileQueue(
      state: queue,
      mode: _mode,
      saving: _savingBatch,
      onModeChanged: (mode) => setState(() => _mode = mode),
      onMove: controller.move,
      onRemove: controller.remove,
      onStop: controller.stopTranscription,
      onPreview: (id) => setState(() => _previewId = id),
      onAddFiles: () => _pickFiles(add: true),
      onAddLink: () => _pasteLink(add: true),
      onMerge: () => controller.merge(l10n.noFilename),
      onSave: () => _saveBatch(queue.items),
      onClear: _clearQueue,
    );
  }

  Widget _singleView(FileIntakeState state) {
    final l10n = AppLocalizations.of(context)!;
    final controller = ref.read(fileIntakeControllerProvider.notifier);
    return switch (state.phase) {
      FileIntakePhase.idle => StartWorkspace(
        dragging: _dragging,
        canDrop: !Platform.isAndroid && !Platform.isIOS,
        mode: _mode,
        onModeChanged: (mode) => setState(() => _mode = mode),
        onPickFiles: _pickFiles,
        onPasteLink: _pasteLink,
      ),
      FileIntakePhase.converting => _Converting(
        state: state,
        onStop: controller.stopTranscription,
      ),
      FileIntakePhase.ready => _PreviewResult(
        title: state.info!.filename ?? state.info!.url ?? l10n.noFilename,
        subtitle: _typeAndSize(state.info),
        result: state.result!,
        saveName:
            '${markdownBase(filename: state.info!.filename, title: state.result!.title)}.md',
        actions: [
          OutlinedButton.icon(
            onPressed: () => _pickFiles(add: true),
            icon: const Icon(Icons.add),
            label: Text(l10n.addFilesButton),
          ),
          TextButton(
            onPressed: controller.clear,
            child: Text(l10n.pickAnotherButton),
          ),
        ],
      ),
      FileIntakePhase.failed => _ConversionError(
        failure: state.failure!,
        onPickAnother: controller.clear,
      ),
    };
  }
}

void _showMessage(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(content: Text(message)));
}

String? _typeAndSize(StreamInfo? info) => info == null
    ? null
    : '${info.detectedType.label}, ${formatSize(info.lengthBytes)}';

class _IncomingDialog extends StatelessWidget {
  const _IncomingDialog();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.incomingTitle),
      content: Text(l10n.incomingBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.startOverButton),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.addButton),
        ),
      ],
    );
  }
}

class _LinkDialog extends StatefulWidget {
  final String initial;

  const _LinkDialog({required this.initial});

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.linkDialogTitle),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(hintText: l10n.linkDialogHint),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.linkDialogNote,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.linkConvertButton)),
      ],
    );
  }
}

class _Converting extends StatelessWidget {
  final FileIntakeState state;
  final VoidCallback onStop;

  const _Converting({required this.state, required this.onStop});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final info = state.info;
    final progress = state.speechProgress;
    final label = info == null
        ? l10n.downloadingLabel
        : !state.transcribing
        ? l10n.convertingLabel
        : state.stopping
        ? l10n.stoppingLabel
        : progress > 0
        ? l10n.transcribingProgressLabel(progress)
        : l10n.transcribingLabel;
    return WorkspacePage(
      child: WorkspacePanel(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              info == null
                  ? state.link ?? ''
                  : info.filename ?? info.url ?? l10n.noFilename,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (info != null) ...[
              const SizedBox(height: 8),
              Text(
                '${info.detectedType.label}, ${formatSize(info.lengthBytes)}',
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Flexible(child: Text(label)),
              ],
            ),
            if (state.transcribing) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: 320,
                child: LinearProgressIndicator(
                  // 0 means the audio is decoding or the model is loading:
                  // the fraction is unknown, so the bar runs indeterminate.
                  value: progress > 0 ? progress / 100 : null,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.transcribingHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: state.stopping ? null : onStop,
                icon: const Icon(Icons.stop),
                label: Text(l10n.stopButton),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A result on screen — one file's or a merge's.
class _PreviewResult extends StatelessWidget {
  final String title;
  final String? subtitle;
  final ConversionResult result;

  /// Suggested name for "Save as .md".
  final String saveName;
  final Widget? leadingAction;

  /// Buttons after "Copy" and "Save".
  final List<Widget> actions;

  const _PreviewResult({
    required this.title,
    required this.result,
    required this.saveName,
    required this.actions,
    this.subtitle,
    this.leadingAction,
  });

  Future<void> _copy(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return;
    final item = DataWriterItem();
    item.add(Formats.plainText(result.markdown));
    item.add(Formats.md(utf8.encode(result.markdown)));
    await clipboard.write([item]);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.copiedConfirmation)));
  }

  Future<void> _save(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final path = await FilePicker.saveFile(
        fileName: saveName,
        type: FileType.custom,
        allowedExtensions: const ['md'],
        bytes: utf8.encode(result.markdown),
      );
      if (path != null && context.mounted) {
        _showMessage(context, l10n.savedConfirmation);
      }
    } on PlatformException {
      if (context.mounted) _showMessage(context, l10n.saveFailed);
    } on FileSystemException {
      if (context.mounted) _showMessage(context, l10n.saveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final truncated = result.markdown.length > _maxPreviewChars;
    final preview = truncated
        ? result.markdown.substring(0, _maxPreviewChars)
        : result.markdown;

    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return WorkspacePage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (leadingAction case final back?) ...[
            Align(alignment: Alignment.centerLeft, child: back),
            const SizedBox(height: 12),
          ],
          Text(title, style: theme.textTheme.titleLarge),
          if (subtitle case final subtitle?) ...[
            const SizedBox(height: 4),
            Text(subtitle, style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => _save(context),
                icon: const Icon(Icons.download_outlined),
                label: Text(l10n.saveAsButton),
              ),
              OutlinedButton.icon(
                onPressed: () => _copy(context),
                icon: const Icon(Icons.copy_outlined),
                label: Text(l10n.copyButton),
              ),
              ...actions,
            ],
          ),
          const SizedBox(height: 18),
          WorkspacePanel(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(
                    children: [
                      Icon(Icons.tag, color: colors.primary, size: 20),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          saveName,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                CallbackShortcuts(
                  bindings: {
                    const SingleActivator(
                      LogicalKeyboardKey.keyC,
                      meta: true,
                    ): () =>
                        _copy(context),
                    const SingleActivator(
                      LogicalKeyboardKey.keyC,
                      control: true,
                    ): () =>
                        _copy(context),
                  },
                  child: Focus(
                    autofocus: true,
                    child: ColoredBox(
                      color: colors.surfaceContainerLow,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: 160,
                          maxHeight: 420,
                        ),
                        child: SingleChildScrollView(
                          primary: false,
                          padding: const EdgeInsets.all(16),
                          child: SelectableText(
                            truncated ? '$preview\n…' : preview,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                              height: 1.55,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (result.warnings.isNotEmpty) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.warningsLabel,
                          style: theme.textTheme.titleSmall,
                        ),
                        for (final warning in result.warnings)
                          Text('• $warning', style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConversionError extends StatelessWidget {
  final ConversionFailure failure;
  final VoidCallback onPickAnother;

  const _ConversionError({required this.failure, required this.onPickAnother});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final (title, body) = _failureText(l10n, failure);
    return WorkspacePage(
      child: WorkspacePanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 32, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(body),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onPickAnother,
              child: Text(l10n.pickAnotherButton),
            ),
          ],
        ),
      ),
    );
  }
}

/// The same three cases (plus the network) on the error screen and in a
/// merge list row — see `docs/conversion-pipeline.md#errors`.
(String, String) _failureText(
  AppLocalizations l10n,
  ConversionFailure failure,
) => switch (failure) {
  UnsupportedFormatFailure(detectedTypeLabel: final label) => (
    l10n.errorUnsupportedTitle,
    l10n.errorUnsupportedBody(label),
  ),
  CorruptedFileFailure(reason: final reason) => (
    l10n.errorCorruptedTitle,
    l10n.errorCorruptedBody(reason),
  ),
  LimitExceededFailure(description: final description) => (
    l10n.errorLimitTitle,
    l10n.errorLimitBody(description),
  ),
  NetworkFailure(description: final description) => (
    l10n.errorNetworkTitle,
    l10n.errorNetworkBody(description),
  ),
};

class _FileQueue extends StatelessWidget {
  final MergeState state;
  final OutputMode mode;
  final bool saving;
  final ValueChanged<OutputMode> onModeChanged;
  final void Function(int from, int to) onMove;
  final ValueChanged<int> onRemove;
  final ValueChanged<int> onStop;
  final ValueChanged<int> onPreview;
  final VoidCallback onAddFiles;
  final VoidCallback onAddLink;
  final VoidCallback onMerge;
  final VoidCallback onSave;
  final VoidCallback onClear;

  const _FileQueue({
    required this.state,
    required this.mode,
    required this.saving,
    required this.onModeChanged,
    required this.onMove,
    required this.onRemove,
    required this.onStop,
    required this.onPreview,
    required this.onAddFiles,
    required this.onAddLink,
    required this.onMerge,
    required this.onSave,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final ready = state.items.where((item) => item.result != null).length;
    final merging = mode == OutputMode.merged;
    final settled = state.items.every(
      (item) =>
          item.status == MergeItemStatus.ready ||
          item.status == MergeItemStatus.failed,
    );
    final hint = merging
        ? state.hasFailures
              ? l10n.mergeFailedHint
              : state.canMerge
              ? l10n.mergeOrderHint
              : l10n.mergeWaitingHint
        : state.hasFailures && ready > 0
        ? l10n.separateFailedHint
        : null;

    return WorkspacePage(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 765;
          final queue = WorkspacePanel(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 5,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: onAddFiles,
                      icon: const Icon(Icons.add),
                      label: Text(l10n.addFilesButton),
                    ),
                    IconButton(
                      onPressed: onAddLink,
                      icon: const Icon(Icons.link),
                      tooltip: l10n.pasteLinkButton,
                    ),
                    IconButton(
                      onPressed: onClear,
                      icon: const Icon(Icons.delete_sweep_outlined),
                      tooltip: l10n.clearButton,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Divider(height: 1),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: wide ? 410 : 300),
                  child: ReorderableListView.builder(
                    shrinkWrap: true,
                    primary: false,
                    buildDefaultDragHandles: false,
                    itemCount: state.items.length,
                    onReorder: (from, to) =>
                        onMove(from, to > from ? to - 1 : to),
                    itemBuilder: (context, index) {
                      final item = state.items[index];
                      return _QueueRow(
                        key: ValueKey(item.id),
                        index: index,
                        item: item,
                        reorderable: merging,
                        onRemove: () => onRemove(item.id),
                        onStop: () => onStop(item.id),
                        onPreview: item.result == null
                            ? null
                            : () => onPreview(item.id),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
          final output = WorkspacePanel(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutputSelector(mode: mode, onChanged: onModeChanged),
                if (hint != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    hint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: merging && state.hasFailures
                          ? theme.colorScheme.error
                          : null,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: merging
                      ? (state.canMerge ? onMerge : null)
                      : (settled && ready > 0 && !saving ? onSave : null),
                  icon: Icon(
                    merging ? Icons.merge : Icons.create_new_folder_outlined,
                  ),
                  label: Text(
                    merging
                        ? l10n.mergeButton
                        : saving
                        ? l10n.savingLabel
                        : l10n.saveFolderButton,
                  ),
                ),
              ],
            ),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.batchTitle, style: theme.textTheme.headlineLarge),
              const SizedBox(height: 6),
              Text(
                l10n.batchCount(ready, state.items.length),
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 20),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: queue),
                    const SizedBox(width: 18),
                    Expanded(flex: 2, child: output),
                  ],
                )
              else ...[
                queue,
                const SizedBox(height: 14),
                output,
              ],
            ],
          );
        },
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  final int index;
  final MergeItem item;
  final bool reorderable;
  final VoidCallback? onPreview;
  final VoidCallback onRemove;
  final VoidCallback onStop;

  const _QueueRow({
    super.key,
    required this.index,
    required this.item,
    required this.reorderable,
    required this.onPreview,
    required this.onRemove,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final typeAndSize = _typeAndSize(item.info);
    final subtitle = switch (item.status) {
      MergeItemStatus.waiting => [
        typeAndSize,
        l10n.waitingLabel,
      ].nonNulls.join(' / '),
      MergeItemStatus.downloading => l10n.downloadingLabel,
      MergeItemStatus.converting =>
        !item.transcribing
            ? l10n.convertingLabel
            : item.stopping
            ? l10n.stoppingLabel
            : item.speechProgress > 0
            ? l10n.transcribingProgressLabel(item.speechProgress)
            : l10n.transcribingLabel,
      MergeItemStatus.ready => typeAndSize ?? '.md',
      MergeItemStatus.failed => switch (_failureText(l10n, item.failure!)) {
        (final title, final body) => '$title. $body',
      },
    };

    return Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.only(left: 4),
          minLeadingWidth: 28,
          horizontalTitleGap: 9,
          onTap: onPreview,
          leading: SizedBox.square(
            dimension: 32,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: colors.primaryContainer,
              ),
              child: Center(
                child: switch (item.status) {
                  MergeItemStatus.waiting => Icon(
                    Icons.schedule,
                    size: 18,
                    color: colors.onPrimaryContainer,
                  ),
                  MergeItemStatus.downloading ||
                  MergeItemStatus.converting => const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  MergeItemStatus.ready => Icon(
                    Icons.task_outlined,
                    size: 19,
                    color: colors.onPrimaryContainer,
                  ),
                  MergeItemStatus.failed => Icon(
                    Icons.error_outline,
                    size: 19,
                    color: colors.error,
                  ),
                },
              ),
            ),
          ),
          title: Text(
            item.name ?? l10n.noFilename,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: item.status == MergeItemStatus.failed
                  ? colors.error
                  : null,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.transcribing)
                IconButton(
                  onPressed: item.stopping ? null : onStop,
                  icon: const Icon(Icons.stop),
                  tooltip: l10n.stopButton,
                ),
              if (onPreview != null)
                IconButton(
                  onPressed: onPreview,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  tooltip: l10n.previewTooltip,
                ),
              IconButton(
                onPressed: onRemove,
                icon: const Icon(Icons.close, size: 19),
                tooltip: l10n.removeTooltip,
              ),
              if (reorderable)
                ReorderableDragStartListener(
                  index: index,
                  child: const MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: SizedBox(
                      width: 32,
                      height: 48,
                      child: Icon(Icons.drag_handle, size: 20),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}

String _itemBase(MergeItem item) => markdownBase(
  filename: item.info?.url == null ? item.name : item.info?.filename,
  title: item.result?.title,
);

/// Named after the first file and how many follow it.
String _mergedFileName(AppLocalizations l10n, List<MergeItem> items) {
  final first = items.first;
  final base = first.info?.url != null
      ? markdownBase(title: first.name)
      : _itemBase(first);
  if (items.length == 1) return '$base.md';
  return '${l10n.mergedFileName(base, items.length - 1)}.md';
}

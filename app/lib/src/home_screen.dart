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
import 'merge/merge_controller.dart';
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
  /// several go straight into a merge; with a result or the merge list on
  /// screen, the person is asked whether to add to it or start over
  /// (author's decision) — silently replacing a merge of five files would
  /// lose work.
  Future<void> _incoming(List<PickedFile> files, {String? link}) async {
    if (files.isEmpty && link == null) return;
    final single = ref.read(fileIntakeControllerProvider);
    if (ref.read(mergeControllerProvider).active ||
        single.phase == FileIntakePhase.ready) {
      final add = await showDialog<bool>(
        context: context,
        builder: (context) => const _IncomingDialog(),
      );
      if (add == null || !mounted) return;
      if (add) {
        _addToMerge(files, link: link);
        return;
      }
      ref.read(mergeControllerProvider.notifier).clear();
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

  /// Adds to the merge list; a single file's result on screen becomes its
  /// first row.
  void _addToMerge(List<PickedFile> files, {String? link}) {
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

  Future<List<PickedFile>> _pickFiles() async {
    final result = await FilePicker.pickFiles(
      withData: true,
      allowMultiple: true,
    );
    return [
      for (final file in result?.files ?? const <PlatformFile>[])
        if (file.bytes case final bytes?)
          PickedFile(bytes: bytes, filename: file.name, localPath: file.path),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(fileIntakeControllerProvider);
    final merge = ref.watch(mergeControllerProvider);
    final mergeController = ref.read(mergeControllerProvider.notifier);
    final merged = merge.merged;

    return Scaffold(
      appBar: AppBar(title: const Text('MarkItDown UI')),
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (details) async {
          setState(() => _dragging = false);
          _incoming([
            for (final item in details.files)
              PickedFile(
                bytes: await item.readAsBytes(),
                filename: item.name,
                mimeType: item.mimeType,
                localPath: item.path,
              ),
          ]);
        },
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: merge.active
                ? merged != null
                      ? _PreviewResult(
                          title: l10n.mergedTitle(merge.items.length),
                          result: merged,
                          saveName: _mergedFileName(l10n, merge.items),
                          actions: [
                            TextButton(
                              onPressed: mergeController.backToList,
                              child: Text(l10n.backToListButton),
                            ),
                            TextButton(
                              onPressed: mergeController.clear,
                              child: Text(l10n.clearButton),
                            ),
                          ],
                        )
                      : _MergeList(
                          state: merge,
                          onMove: mergeController.move,
                          onRemove: mergeController.remove,
                          onStop: mergeController.stopTranscription,
                          onAddFiles: () async {
                            final files = await _pickFiles();
                            if (files.isNotEmpty) {
                              mergeController.addFiles(files);
                            }
                          },
                          onAddLink: () async {
                            final link = await _askLink();
                            if (link != null) mergeController.addUrl(link);
                          },
                          onMerge: () => mergeController.merge(l10n.noFilename),
                          onClear: mergeController.clear,
                        )
                : switch (state.phase) {
                    FileIntakePhase.idle => _EmptyState(
                      dragging: _dragging,
                      onPickFile: () async => _incoming(await _pickFiles()),
                      onPasteLink: () async {
                        final link = await _askLink();
                        if (link != null) _incoming(const [], link: link);
                      },
                    ),
                    FileIntakePhase.converting => _Converting(
                      state: state,
                      onStop: () => ref
                          .read(fileIntakeControllerProvider.notifier)
                          .stopTranscription(),
                    ),
                    FileIntakePhase.ready => _PreviewResult(
                      title:
                          state.info!.filename ??
                          state.info!.url ??
                          l10n.noFilename,
                      subtitle:
                          '${state.info!.detectedType.label}, '
                          '${formatSize(state.info!.lengthBytes)}',
                      result: state.result!,
                      saveName: state.info!.filename != null
                          ? '${_fileBase(state.info!.filename)}.md'
                          : '${_titleBase(state.result!.title)}.md',
                      actions: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            final files = await _pickFiles();
                            if (files.isNotEmpty) _addToMerge(files);
                          },
                          icon: const Icon(Icons.add),
                          label: Text(l10n.addFilesButton),
                        ),
                        TextButton(
                          onPressed: () => ref
                              .read(fileIntakeControllerProvider.notifier)
                              .clear(),
                          child: Text(l10n.pickAnotherButton),
                        ),
                      ],
                    ),
                    FileIntakePhase.failed => _ConversionError(
                      failure: state.failure!,
                      onPickAnother: () => ref
                          .read(fileIntakeControllerProvider.notifier)
                          .clear(),
                    ),
                  },
          ),
        ),
      ),
    );
  }
}

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

class _EmptyState extends StatelessWidget {
  final bool dragging;
  final VoidCallback onPickFile;
  final VoidCallback onPasteLink;

  const _EmptyState({
    required this.dragging,
    required this.onPickFile,
    required this.onPasteLink,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 480, minHeight: 240),
      decoration: BoxDecoration(
        border: Border.all(
          color: dragging
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outlineVariant,
          width: dragging ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.upload_file,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(l10n.dropHint),
          const SizedBox(height: 16),
          FilledButton(onPressed: onPickFile, child: Text(l10n.pickFileButton)),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: onPasteLink,
            icon: const Icon(Icons.link),
            label: Text(l10n.pasteLinkButton),
          ),
        ],
      ),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              info == null
                  ? state.link ?? ''
                  : info.filename ?? info.url ?? l10n.noFilename,
              style: Theme.of(context).textTheme.titleMedium,
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

  /// Buttons after "Copy" and "Save".
  final List<Widget> actions;

  const _PreviewResult({
    required this.title,
    required this.result,
    required this.saveName,
    required this.actions,
    this.subtitle,
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
    final path = await FilePicker.saveFile(
      fileName: saveName,
      type: FileType.custom,
      allowedExtensions: const ['md'],
      bytes: Uint8List.fromList(utf8.encode(result.markdown)),
    );
    if (path == null || !context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.savedConfirmation)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final truncated = result.markdown.length > _maxPreviewChars;
    final preview = truncated
        ? result.markdown.substring(0, _maxPreviewChars)
        : result.markdown;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720, maxHeight: 560),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle case final subtitle?) ...[
                const SizedBox(height: 4),
                Text(subtitle),
              ],
              if (result.warnings.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.warningsLabel,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                for (final warning in result.warnings)
                  Text(
                    '• $warning',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
              const SizedBox(height: 12),
              Flexible(
                child: CallbackShortcuts(
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
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          truncated ? '$preview\n…' : preview,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () => _copy(context),
                    icon: const Icon(Icons.copy),
                    label: Text(l10n.copyButton),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _save(context),
                    icon: const Icon(Icons.save_alt),
                    label: Text(l10n.saveAsButton),
                  ),
                  ...actions,
                ],
              ),
            ],
          ),
        ),
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
    final (title, body) = _failureText(l10n, failure);

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 480),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.error_outline,
            size: 48,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(body, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: onPickAnother,
            child: Text(l10n.pickAnotherButton),
          ),
        ],
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

class _MergeList extends StatelessWidget {
  final MergeState state;
  final void Function(int from, int to) onMove;
  final void Function(int id) onRemove;
  final void Function(int id) onStop;
  final VoidCallback onAddFiles;
  final VoidCallback onAddLink;
  final VoidCallback onMerge;
  final VoidCallback onClear;

  const _MergeList({
    required this.state,
    required this.onMove,
    required this.onRemove,
    required this.onStop,
    required this.onAddFiles,
    required this.onAddLink,
    required this.onMerge,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final (hint, hintColor) = state.hasFailures
        ? (l10n.mergeFailedHint, theme.colorScheme.error)
        : !state.canMerge
        ? (l10n.mergeWaitingHint, null)
        : (l10n.mergeOrderHint, null);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720, maxHeight: 560),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // The secondary actions are icons up here: as four labelled
              // buttons at the bottom they wrapped into four rows on a
              // phone and left the list room for a row and a half.
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.mergeListTitle(state.items.length),
                      style: theme.textTheme.titleMedium,
                    ),
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
              Flexible(
                child: ReorderableListView(
                  shrinkWrap: true,
                  // Handles are explicit on every platform: on Android the
                  // default is a long press anywhere on the row, which
                  // nobody discovers.
                  buildDefaultDragHandles: false,
                  onReorder: (from, to) =>
                      // The list reports the index before removal.
                      onMove(from, to > from ? to - 1 : to),
                  children: [
                    for (final (index, item) in state.items.indexed)
                      _MergeRow(
                        key: ValueKey(item.id),
                        index: index,
                        item: item,
                        onRemove: () => onRemove(item.id),
                        onStop: () => onStop(item.id),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                hint,
                style: theme.textTheme.bodySmall?.copyWith(color: hintColor),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: state.canMerge ? onMerge : null,
                    icon: const Icon(Icons.merge),
                    label: Text(l10n.mergeButton),
                  ),
                  OutlinedButton.icon(
                    onPressed: onAddFiles,
                    icon: const Icon(Icons.add),
                    label: Text(l10n.addFilesButton),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MergeRow extends StatelessWidget {
  final int index;
  final MergeItem item;
  final VoidCallback onRemove;
  final VoidCallback onStop;

  const _MergeRow({
    super.key,
    required this.index,
    required this.item,
    required this.onRemove,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final info = item.info;
    final typeAndSize = info == null
        ? null
        : '${info.detectedType.label}, ${formatSize(info.lengthBytes)}';
    final subtitle = switch (item.status) {
      MergeItemStatus.waiting => [
        typeAndSize,
        l10n.waitingLabel,
      ].nonNulls.join(' · '),
      MergeItemStatus.downloading => l10n.downloadingLabel,
      MergeItemStatus.converting =>
        !item.transcribing
            ? l10n.convertingLabel
            : item.stopping
            ? l10n.stoppingLabel
            : item.speechProgress > 0
            ? l10n.transcribingProgressLabel(item.speechProgress)
            : l10n.transcribingLabel,
      MergeItemStatus.ready => typeAndSize ?? '',
      MergeItemStatus.failed => switch (_failureText(l10n, item.failure!)) {
        (final title, final body) => '$title. $body',
      },
    };

    return ListTile(
      contentPadding: const EdgeInsets.only(left: 4),
      visualDensity: VisualDensity.compact,
      leading: switch (item.status) {
        MergeItemStatus.waiting => Icon(Icons.schedule, color: colors.outline),
        MergeItemStatus.downloading ||
        MergeItemStatus.converting => const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        MergeItemStatus.ready => Icon(
          Icons.check_circle_outline,
          color: colors.primary,
        ),
        MergeItemStatus.failed => Icon(
          Icons.error_outline,
          color: colors.error,
        ),
      },
      title: Text(item.name ?? l10n.noFilename),
      subtitle: Text(
        subtitle,
        style: item.status == MergeItemStatus.failed
            ? TextStyle(color: colors.error)
            : null,
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
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.close),
            tooltip: l10n.removeTooltip,
          ),
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.drag_handle),
            ),
          ),
        ],
      ),
    );
  }
}

/// [filename] without its extension.
String _fileBase(String? filename) {
  if (filename == null || filename.isEmpty) return 'converted';
  final dot = filename.lastIndexOf('.');
  return dot > 0 ? filename.substring(0, dot) : filename;
}

/// A page fetched by link has no filename — its title is used instead,
/// stripped of characters forbidden in Windows filenames, and capped at a
/// reasonable length.
String _titleBase(String? title) {
  final cleaned = (title ?? '')
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) return 'converted';
  return cleaned.length > 100 ? cleaned.substring(0, 100).trim() : cleaned;
}

/// Named after the first file and how many follow it (author's decision):
/// `report_and_2_more.md`.
String _mergedFileName(AppLocalizations l10n, List<MergeItem> items) {
  final first = items.first;
  final base = first.info?.url != null
      ? _titleBase(first.name)
      : _fileBase(first.name);
  if (items.length == 1) return '$base.md';
  return '${l10n.mergedFileName(base, items.length - 1)}.md';
}

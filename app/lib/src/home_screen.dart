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
      _acceptAll(input.files);
      return;
    }
    final link = input.link;
    if (link != null && parseUserUrl(link) != null) {
      ref.read(fileIntakeControllerProvider.notifier).acceptUrl(link);
    }
  }

  Future<void> _pasteLink() async {
    // A link from the clipboard goes straight into the field: it was
    // usually just copied. Read on button press, not on startup.
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final copied = clipboard?.text?.trim() ?? '';
    if (!mounted) return;
    final link = await showDialog<String>(
      context: context,
      builder: (context) =>
          _LinkDialog(initial: parseUserUrl(copied) == null ? '' : copied),
    );
    if (link == null || link.trim().isEmpty) return;
    ref.read(fileIntakeControllerProvider.notifier).acceptUrl(link);
  }

  @override
  void dispose() {
    _shareSubscription?.cancel();
    super.dispose();
  }

  void _acceptAll(List<PickedFile> files) {
    if (files.isEmpty) return;
    ref.read(fileIntakeControllerProvider.notifier).accept(files.first);
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles(withData: true);
    final file = result?.files.firstOrNull;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return;
    _acceptAll([
      PickedFile(bytes: bytes, filename: file.name, localPath: file.path),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(fileIntakeControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('MarkItDown UI')),
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (details) async {
          setState(() => _dragging = false);
          final item = details.files.firstOrNull;
          if (item == null) return;
          final bytes = await item.readAsBytes();
          _acceptAll([
            PickedFile(
              bytes: bytes,
              filename: item.name,
              mimeType: item.mimeType,
              localPath: item.path,
            ),
          ]);
        },
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: switch (state.phase) {
              FileIntakePhase.idle => _EmptyState(
                dragging: _dragging,
                onPickFile: _pickFile,
                onPasteLink: _pasteLink,
              ),
              FileIntakePhase.converting => _Converting(
                state: state,
                onStop: () => ref
                    .read(fileIntakeControllerProvider.notifier)
                    .stopTranscription(),
              ),
              FileIntakePhase.ready => _PreviewResult(
                info: state.info!,
                result: state.result!,
                onPickAnother: () =>
                    ref.read(fileIntakeControllerProvider.notifier).clear(),
              ),
              FileIntakePhase.failed => _ConversionError(
                failure: state.failure!,
                onPickAnother: () =>
                    ref.read(fileIntakeControllerProvider.notifier).clear(),
              ),
            },
          ),
        ),
      ),
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

class _PreviewResult extends StatelessWidget {
  final StreamInfo info;
  final ConversionResult result;
  final VoidCallback onPickAnother;

  const _PreviewResult({
    required this.info,
    required this.result,
    required this.onPickAnother,
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
      fileName: info.filename != null
          ? _markdownFileName(info.filename)
          : _titleFileName(result.title),
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
              Text(
                info.filename ?? info.url ?? l10n.noFilename,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                '${info.detectedType.label}, ${formatSize(info.lengthBytes)}',
              ),
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
                  TextButton(
                    onPressed: onPickAnother,
                    child: Text(l10n.pickAnotherButton),
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

class _ConversionError extends StatelessWidget {
  final ConversionFailure failure;
  final VoidCallback onPickAnother;

  const _ConversionError({required this.failure, required this.onPickAnother});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final (title, body) = switch (failure) {
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

String _markdownFileName(String? originalFilename) {
  if (originalFilename == null || originalFilename.isEmpty) {
    return 'converted.md';
  }
  final dot = originalFilename.lastIndexOf('.');
  final base = dot > 0 ? originalFilename.substring(0, dot) : originalFilename;
  return '$base.md';
}

/// A page fetched by link has no filename — its title is used instead,
/// stripped of characters forbidden in Windows filenames, and capped at a
/// reasonable length.
String _titleFileName(String? title) {
  final cleaned = (title ?? '')
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) return 'converted.md';
  final short = cleaned.length > 100
      ? cleaned.substring(0, 100).trim()
      : cleaned;
  return '$short.md';
}

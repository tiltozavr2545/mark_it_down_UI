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

/// Markdown длиннее этого не рендерится целиком — `SelectableText` на
/// многомегабайтном результате кладёт кадр намертво. В буфер и в файл уходит
/// полный текст, срез — только на экране. См.
/// `docs/client-architecture.md#большие-файлы`.
const _maxPreviewChars = 20000;

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _dragging = false;
  StreamSubscription<List<PickedFile>>? _shareSubscription;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      final shareIntake = ShareIntake();
      shareIntake.initialFiles().then(_acceptAll);
      _shareSubscription = shareIntake.fileStream().listen(_acceptAll);
    }
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
              ),
              FileIntakePhase.converting => _Converting(info: state.info!),
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

  const _EmptyState({required this.dragging, required this.onPickFile});

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
        ],
      ),
    );
  }
}

class _Converting extends StatelessWidget {
  final StreamInfo info;

  const _Converting({required this.info});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              info.filename ?? l10n.noFilename,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text('${info.detectedType.label}, ${formatSize(info.lengthBytes)}'),
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
                Text(l10n.convertingLabel),
              ],
            ),
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
      fileName: _markdownFileName(info.filename),
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
                info.filename ?? l10n.noFilename,
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

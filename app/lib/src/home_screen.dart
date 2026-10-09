import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markitdown_core/markitdown_core.dart';

import 'file_intake/file_intake_controller.dart';
import 'file_intake/format_size.dart';
import 'file_intake/picked_file.dart';
import 'file_intake/share_intake.dart';

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
    _acceptAll([PickedFile(bytes: bytes, filename: file.name)]);
  }

  @override
  Widget build(BuildContext context) {
    final info = ref.watch(fileIntakeControllerProvider).info;

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
            ),
          ]);
        },
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: info == null
                ? _EmptyState(dragging: _dragging, onPickFile: _pickFile)
                : _AcceptedFile(
                    info: info,
                    onPickAnother: () {
                      ref.read(fileIntakeControllerProvider.notifier).clear();
                    },
                  ),
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
          const Text('Перетащите файл сюда'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: onPickFile,
            child: const Text('Выбрать файл'),
          ),
        ],
      ),
    );
  }
}

class _AcceptedFile extends StatelessWidget {
  final StreamInfo info;
  final VoidCallback onPickAnother;

  const _AcceptedFile({required this.info, required this.onPickAnother});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              info.filename ?? '(без имени)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text('${info.detectedType.label}, ${formatSize(info.lengthBytes)}'),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onPickAnother,
              child: const Text('Выбрать другой файл'),
            ),
          ],
        ),
      ),
    );
  }
}

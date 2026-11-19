import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';

enum OutputMode { separate, merged }

class WorkspaceHeader extends StatelessWidget {
  const WorkspaceHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1104),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.primary,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: SizedBox.square(
                    dimension: 36,
                    child: Icon(Icons.tag, size: 24, color: colors.onPrimary),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'MarkItDown UI',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: l10n.localProcessing,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock_outline, size: 17, color: colors.primary),
                      if (MediaQuery.sizeOf(context).width >= 600) ...[
                        const SizedBox(width: 7),
                        Text(
                          l10n.localProcessing,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WorkspacePage extends StatelessWidget {
  final Widget child;

  const WorkspacePage({super.key, required this.child});

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1104),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
          child: child,
        ),
      ),
    ),
  );
}

class WorkspacePanel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;

  const WorkspacePanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class StartWorkspace extends StatelessWidget {
  final bool dragging;
  final bool canDrop;
  final OutputMode mode;
  final ValueChanged<OutputMode> onModeChanged;
  final VoidCallback onPickFiles;
  final VoidCallback onPasteLink;

  const StartWorkspace({
    super.key,
    required this.dragging,
    required this.canDrop,
    required this.mode,
    required this.onModeChanged,
    required this.onPickFiles,
    required this.onPasteLink,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return WorkspacePage(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 640;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.workspaceTitle,
                style: theme.textTheme.headlineLarge?.copyWith(
                  fontSize: wide ? 48 : 34,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                l10n.workspaceIntro,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              SizedBox(height: wide ? 26 : 18),
              _IntakePanel(
                mode: mode,
                dragging: dragging,
                canDrop: canDrop,
                wide: wide,
                onPickFiles: onPickFiles,
                onPasteLink: onPasteLink,
              ),
              SizedBox(height: wide ? 30 : 22),
              OutputSelector(
                mode: mode,
                onChanged: onModeChanged,
                inline: wide,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _IntakePanel extends StatelessWidget {
  final OutputMode mode;
  final bool dragging;
  final bool canDrop;
  final bool wide;
  final VoidCallback onPickFiles;
  final VoidCallback onPasteLink;

  const _IntakePanel({
    required this.mode,
    required this.dragging,
    required this.canDrop,
    required this.wide,
    required this.onPickFiles,
    required this.onPasteLink,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final actions = Padding(
      padding: EdgeInsets.all(wide ? 28 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (wide) ...[
            Icon(Icons.file_upload_outlined, color: colors.primary, size: 29),
            const SizedBox(height: 12),
          ],
          Text(
            canDrop ? l10n.dropTitle : l10n.mobileIntakeTitle,
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: onPickFiles,
                icon: const Icon(Icons.folder_open_outlined),
                label: Text(l10n.chooseFilesButton),
              ),
              TextButton.icon(
                onPressed: onPasteLink,
                icon: const Icon(Icons.link),
                label: Text(l10n.pasteLinkButton),
              ),
            ],
          ),
        ],
      ),
    );
    final art = _ConversionDiagram(mode: mode, wide: wide);
    return Container(
      decoration: BoxDecoration(
        color: dragging ? colors.primaryContainer : colors.surface,
        border: Border.all(
          color: dragging ? colors.primary : colors.outlineVariant,
          width: dragging ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: wide
          ? Row(
              children: [
                Expanded(flex: 3, child: actions),
                Expanded(flex: 2, child: art),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [art, actions],
            ),
    );
  }
}

class OutputSelector extends StatelessWidget {
  final OutputMode mode;
  final ValueChanged<OutputMode> onChanged;
  final bool inline;

  const OutputSelector({
    super.key,
    required this.mode,
    required this.onChanged,
    this.inline = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final labels = [
      (l10n.separateOutput, l10n.separateOutputHint, Icons.file_copy_outlined),
      (l10n.mergedOutput, l10n.mergedOutputHint, Icons.description_outlined),
    ];
    final options = [
      for (final (index, choice) in OutputMode.values.indexed)
        _OutputOption(
          selected: choice == mode,
          title: labels[index].$1,
          hint: labels[index].$2,
          icon: labels[index].$3,
          onTap: () => onChanged(choice),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.outputTitle, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        if (inline)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: options.first),
              const SizedBox(width: 10),
              Expanded(child: options.last),
            ],
          )
        else ...[
          options.first,
          const SizedBox(height: 8),
          options.last,
        ],
      ],
    );
  }
}

class _OutputOption extends StatelessWidget {
  final bool selected;
  final String title;
  final String hint;
  final IconData icon;
  final VoidCallback onTap;

  const _OutputOption({
    required this.selected,
    required this.title,
    required this.hint,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = selected ? colors.onPrimaryContainer : colors.onSurface;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(
        color: selected ? colors.primary : colors.outlineVariant,
      ),
    );
    return Semantics(
      checked: selected,
      inMutuallyExclusiveGroup: true,
      child: Material(
        color: selected ? colors.primaryContainer : colors.surface,
        shape: shape,
        child: InkWell(
          onTap: onTap,
          customBorder: shape,
          focusColor: colors.primary.withValues(alpha: 0.2),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Icon(icon, color: foreground, size: 21),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: foreground,
                        ),
                      ),
                      Text(hint, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ExcludeSemantics(
                  child: Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                    color: selected ? colors.primary : colors.outline,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The same two source pages lead to either two outputs or one.
class _ConversionDiagram extends StatelessWidget {
  final OutputMode mode;
  final bool wide;

  const _ConversionDiagram({required this.mode, required this.wide});

  @override
  Widget build(BuildContext context) {
    final merged = mode == OutputMode.merged;
    return ExcludeSemantics(
      child: ColoredBox(
        color: const Color(0xff403194),
        child: SizedBox(
          height: wide ? 224 : 126,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: 268,
                height: 122,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(painter: _DiagramLines(merged)),
                    ),
                    const Positioned(left: 10, top: 9, child: _Paper('.pdf')),
                    const Positioned(
                      left: 10,
                      bottom: 9,
                      child: _Paper('.docx'),
                    ),
                    Positioned(
                      right: 10,
                      top: merged ? 41 : 9,
                      child: const _Paper('.md', output: true),
                    ),
                    if (!merged)
                      const Positioned(
                        right: 10,
                        bottom: 9,
                        child: _Paper('.md', output: true),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Paper extends StatelessWidget {
  final String label;
  final bool output;

  const _Paper(this.label, {this.output = false});

  @override
  Widget build(BuildContext context) => Container(
    width: 83,
    height: 40,
    decoration: BoxDecoration(
      color: output ? const Color(0xffffcc79) : const Color(0xffeae3ff),
      borderRadius: const BorderRadius.only(
        topLeft: Radius.circular(6),
        topRight: Radius.circular(13),
        bottomLeft: Radius.circular(6),
        bottomRight: Radius.circular(6),
      ),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          output ? Icons.tag : Icons.notes,
          size: 17,
          color: const Color(0xff30225e),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              textScaler: TextScaler.noScaling,
              style: const TextStyle(
                color: Color(0xff30225e),
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _DiagramLines extends CustomPainter {
  final bool merged;

  const _DiagramLines(this.merged);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xffb9a9ff)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    for (final y in [29.0, 93.0]) {
      if (merged) {
        canvas.drawLine(Offset(93, y), Offset(123, y), paint);
        canvas.drawLine(Offset(123, y), const Offset(142, 61), paint);
      } else {
        canvas.drawLine(Offset(93, y), Offset(164, y), paint);
        _arrow(canvas, paint, y);
      }
    }
    if (merged) {
      canvas.drawLine(const Offset(142, 61), const Offset(164, 61), paint);
      _arrow(canvas, paint, 61);
    }
  }

  void _arrow(Canvas canvas, Paint paint, double y) {
    canvas.drawLine(Offset(158, y - 5), Offset(164, y), paint);
    canvas.drawLine(Offset(158, y + 5), Offset(164, y), paint);
  }

  @override
  bool shouldRepaint(_DiagramLines oldDelegate) => merged != oldDelegate.merged;
}

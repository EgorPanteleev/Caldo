import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../services/updates.dart';
import '../theme/app_theme.dart';
import 'date_time_pickers.dart' show SheetAction, showAppSheet;

/// Says a newer Caldo is out: its version, a tap to read what is new in it,
/// Later and Update — and while it downloads, how far it has got.
///
/// Later keeps it away until the app next starts, no longer: an update put
/// off is not an update refused, and Settings offers it meanwhile. A release
/// marked urgent has no Later and stays until it is installed.
class UpdateBanner extends StatelessWidget {
  final Update update;

  const UpdateBanner({super.key, required this.update});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context).color;
    final s = S.of(context);
    final updates = Updates.instance;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Material(
        // A wash of the accent over the panel, so it is told apart from the
        // screen's own cards at a glance.
        color: Color.alphaBlend(accent.withValues(alpha: 0.08), p.panel),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: accent.withValues(alpha: 0.28)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: update.notes.isEmpty
              ? null
              : () => showUpdateSheet(context, update),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: ListenableBuilder(
              listenable: Listenable.merge([updates.progress, updates.hitch]),
              builder: (context, _) {
                final progress = updates.progress.value;
                final hitch = updates.hitch.value;
                final line = switch ((progress, hitch)) {
                  (final double done, _) => s.downloading((done * 100).round()),
                  (_, InstallHitch.allow) => s.allowInstall,
                  (_, InstallHitch.failed) => s.downloadFailed,
                  _ when update.urgent => s.updateImportantLine,
                  _ => s.updateReady,
                };
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _Badge(accent: accent),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _Heading(
                            update: update,
                            line: line,
                            warn: hitch != null && progress == null,
                          ),
                        ),
                        if (update.notes.isNotEmpty)
                          Icon(Icons.chevron_right_rounded, color: p.faint),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (progress != null)
                      _Progress(value: progress, accent: accent)
                    else
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (!update.urgent)
                            TextButton(
                              onPressed: () => updates.later(update),
                              style: TextButton.styleFrom(
                                foregroundColor: p.muted,
                                visualDensity: VisualDensity.compact,
                              ),
                              child: Text(s.later),
                            ),
                          const SizedBox(width: 6),
                          _UpdateButton(
                            accent: accent,
                            onTap: () => updates.start(update),
                          ),
                        ],
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// What is new in [update], with Later and Update at the foot — from the
/// banner, and from Settings once the banner has been put off.
Future<void> showUpdateSheet(BuildContext context, Update update) =>
    showAppSheet<void>(
      context,
      maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      child: _UpdateSheet(update: update),
    );

class _UpdateSheet extends StatelessWidget {
  final Update update;

  const _UpdateSheet({required this.update});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context).color;
    final s = S.of(context);
    final updates = Updates.instance;
    // A heading per release only when there is more than one to tell apart.
    final several = update.notes.length > 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _Badge(accent: accent, size: 44),
              const SizedBox(width: 14),
              Expanded(
                child: _Heading(
                  update: update,
                  line: update.urgent ? s.updateImportantLine : s.whatsNew,
                  big: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          for (final notes in update.notes) ...[
            if (several)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  notes.version,
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            _Notes(text: notes.text),
            const SizedBox(height: 14),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              if (!update.urgent)
                SheetAction(
                  label: s.later,
                  onTap: () {
                    Navigator.of(context).pop();
                    updates.later(update);
                  },
                ),
              SheetAction(
                label: s.update,
                onTap: () {
                  Navigator.of(context).pop();
                  // The banner shows the download, put off or not.
                  updates.offered.value = update;
                  updates.start(update);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A release's notes, read the way they are written: lines ending in a
/// colon are headings, lines starting with a dash are points, the rest are
/// paragraphs.
class _Notes extends StatelessWidget {
  final String text;

  const _Notes({required this.text});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final body = TextStyle(color: p.text, fontSize: 14, height: 1.4);
    final children = <Widget>[];
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) {
        if (children.isNotEmpty) children.add(const SizedBox(height: 8));
      } else if (line.startsWith('- ') || line.startsWith('* ')) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 8, 10, 0),
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: p.muted,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(child: Text(line.substring(2), style: body)),
              ],
            ),
          ),
        );
      } else if (line.endsWith(':') || line.startsWith('#')) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              line.replaceFirst(RegExp(r'^#+\s*'), ''),
              style: body.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        );
      } else {
        children.add(Text(line, style: body));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

/// The version in large, Important beside it when it is, and a line under
/// it.
class _Heading extends StatelessWidget {
  final Update update;
  final String line;
  final bool warn;
  final bool big;

  const _Heading({
    required this.update,
    required this.line,
    this.warn = false,
    this.big = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Caldo ${update.version}',
              style: TextStyle(
                color: p.text,
                fontSize: big ? 18 : 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (update.urgent) const _Important(),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          line,
          style: TextStyle(
            color: warn ? AppColors.overdue : p.muted,
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}

/// A rounded square of the accent with the download arrow on it.
class _Badge extends StatelessWidget {
  final Color accent;
  final double size;

  const _Badge({required this.accent, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(Icons.download_rounded, color: accent, size: size * 0.55),
    );
  }
}

/// Said beside the version of an update not to be put off. Red, the colour
/// already meaning "don't leave this".
class _Important extends StatelessWidget {
  const _Important();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.overdue.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        S.of(context).updateImportant,
        style: const TextStyle(
          color: AppColors.overdue,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// The one filled button: the thing the banner is there to have pressed.
class _UpdateButton extends StatelessWidget {
  final Color accent;
  final VoidCallback onTap;

  const _UpdateButton({required this.accent, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
      child: Text(S.of(context).update),
    );
  }
}

/// How far the download has got, as a rounded bar.
class _Progress extends StatelessWidget {
  final double value;
  final Color accent;

  const _Progress({required this.value, required this.accent});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 52, bottom: 2),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: value,
          minHeight: 5,
          color: accent,
          backgroundColor: p.field,
        ),
      ),
    );
  }
}

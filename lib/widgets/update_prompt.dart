import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../services/updates.dart';
import '../theme/app_theme.dart';
import 'background_surface.dart';

/// Places a regular update above whichever route the user is working in.
class UpdatePrompt extends StatefulWidget {
  final Update? update;
  final GlobalKey<NavigatorState> navigator;
  final Widget child;

  const UpdatePrompt({
    super.key,
    required this.update,
    required this.navigator,
    required this.child,
  });

  @override
  State<UpdatePrompt> createState() => _UpdatePromptState();
}

class _UpdatePromptState extends State<UpdatePrompt> {
  _UpdateRoute? _route;

  @override
  void initState() {
    super.initState();
    if (widget.update != null) _syncPrompt();
  }

  @override
  void didUpdateWidget(UpdatePrompt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.update != oldWidget.update) _syncPrompt();
  }

  void _syncPrompt() {
    // The navigator may still be building when the offer reaches the shell.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = widget.navigator.currentState;
      if (navigator == null) return;
      final update = widget.update;
      final route = _route;
      if (update == null) {
        _route = null;
        if (route != null && route.isActive) navigator.removeRoute(route);
      } else if (route == null) {
        final prompt = _route = _UpdateRoute(update);
        navigator.push(prompt).then((_) {
          if (!mounted || _route != prompt) return;
          // A background operation may pop the navigator directly.
          _route = null;
          _syncPrompt();
          WidgetsBinding.instance.ensureVisualUpdate();
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _UpdateRoute extends PopupRoute<void> {
  final Update initialUpdate;

  _UpdateRoute(this.initialUpdate)
    : super(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        requestFocus: true,
        traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
        directionalTraversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      );

  @override
  bool get barrierDismissible => false;

  @override
  Color get barrierColor => Colors.black45;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 180);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return PopScope<void>(
      canPop: false,
      child: SafeArea(
        child: ValueListenableBuilder<Update?>(
          valueListenable: Updates.instance.offered,
          builder: (context, update, _) =>
              _UpdateDialog(update: update ?? initialUpdate),
        ),
      ),
    );
  }
}

class _UpdateDialog extends StatelessWidget {
  final Update update;

  const _UpdateDialog({required this.update});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context).color;
    final s = S.of(context);
    final updates = Updates.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([updates.progress, updates.hitch]),
      builder: (context, _) {
        final progress = updates.progress.value;
        final hitch = updates.hitch.value;
        final line = switch ((progress, hitch)) {
          (final double done, _) => s.downloading((done * 100).round()),
          (_, InstallHitch.allow) => s.allowInstall,
          (_, InstallHitch.failed) => s.downloadFailed,
          _ => s.updateReady,
        };
        return AlertDialog(
          constraints: const BoxConstraints(maxWidth: 520),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 20,
          ),
          scrollable: true,
          title: Row(
            children: [
              _Badge(accent: accent, size: 44),
              const SizedBox(width: 14),
              Expanded(
                child: _Heading(
                  update: update,
                  line: line,
                  warn: hitch != null && progress == null,
                ),
              ),
            ],
          ),
          content: update.notes.isEmpty
              ? null
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      s.whatsNew,
                      style: TextStyle(
                        color: p.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _ReleaseNotes(notes: update.notes),
                  ],
                ),
          actions: [
            if (progress != null)
              LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
                color: accent,
                backgroundColor: p.field,
              )
            else ...[
              TextButton(
                onPressed: () => updates.later(update),
                style: TextButton.styleFrom(foregroundColor: p.muted),
                child: Text(s.later),
              ),
              _UpdateButton(accent: accent, onTap: () => updates.start(update)),
            ],
          ],
        );
      },
    );
  }
}

/// An urgent update, standing in place of the whole app until it is
/// installed: what is new in it, and Update. Put in for the app's navigator
/// (`main`), so nothing under it is reachable — Back has no route to pop and
/// sends the app away, as on its first screen.
class UpdateWall extends StatelessWidget {
  final Update update;

  const UpdateWall({super.key, required this.update});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context).color;
    final s = S.of(context);
    final updates = Updates.instance;
    return AppScaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListenableBuilder(
              listenable: Listenable.merge([updates.progress, updates.hitch]),
              builder: (context, _) {
                final progress = updates.progress.value;
                final hitch = updates.hitch.value;
                final line = switch ((progress, hitch)) {
                  (final double done, _) => s.downloading((done * 100).round()),
                  (_, InstallHitch.allow) => s.allowInstall,
                  (_, InstallHitch.failed) => s.downloadFailed,
                  _ => s.updateRequired,
                };
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 28, 20, 18),
                      child: Row(
                        children: [
                          _Badge(accent: accent, size: 52),
                          const SizedBox(width: 14),
                          Expanded(
                            child: _Heading(
                              update: update,
                              line: line,
                              warn: hitch != null && progress == null,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                        children: [_ReleaseNotes(notes: update.notes)],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                      child: SizedBox(
                        height: 48,
                        child: progress != null
                            ? Center(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(3),
                                  child: LinearProgressIndicator(
                                    value: progress,
                                    minHeight: 6,
                                    color: accent,
                                    backgroundColor: p.field,
                                  ),
                                ),
                              )
                            : _UpdateButton(
                                accent: accent,
                                onTap: () => updates.start(update),
                              ),
                      ),
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

class _ReleaseNotes extends StatelessWidget {
  final List<ReleaseNotes> notes;

  const _ReleaseNotes({required this.notes});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, release) in notes.indexed) ...[
          if (index > 0) const SizedBox(height: 14),
          if (notes.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                release.version,
                style: TextStyle(
                  color: p.muted,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          _Notes(text: release.text),
        ],
      ],
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

  const _Heading({required this.update, required this.line, this.warn = false});

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
                fontSize: 18,
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
        style: TextStyle(
          color: AppColors.overdue,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

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

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';

/// The screens that share the bar's Tasks tab: the same tasks as a running
/// order of days, as lanes, and as a log of what was ticked.
///
/// Six tabs along a phone's foot was "overwhelmed", and four was asked for.
/// These three are one thing seen three ways, so they went under one tab
/// rather than any of them going behind a menu; the calendar, the vault and
/// Settings keep tabs of their own.
const taskViews = [AppScreen.schedule, AppScreen.board, AppScreen.done];

/// Hands the views still in the app, and the way to switch between them,
/// down to the headers of the three screens. No scope — a desktop's wide
/// window, whose sidebar lists all three, or a screen pumped on its own —
/// and each header is a plain title.
class TaskViews extends InheritedWidget {
  final List<AppScreen> shown;
  final ValueChanged<AppScreen> onSelected;

  const TaskViews({
    super.key,
    required this.shown,
    required this.onSelected,
    required super.child,
  });

  static TaskViews? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TaskViews>();

  static String label(S s, AppScreen view) => switch (view) {
    AppScreen.board => s.board,
    AppScreen.done => s.done,
    _ => s.schedule,
  };

  @override
  bool updateShouldNotify(TaskViews oldWidget) =>
      !listEquals(oldWidget.shown, shown) || oldWidget.onSelected != onSelected;
}

/// The title of a task view with its siblings' names beside it, in the same
/// size and dimmed: the screen's own name is still the title, where it
/// always stood, and the others are a tap away. No row of its own for a
/// switch — the screens are crowded enough at their top already.
///
/// Shrunk rather than cut when the three names are longer than the room
/// the header's buttons leave, as the tabs' names are.
class ViewTitles extends StatelessWidget {
  final AppScreen view;
  final List<AppScreen> shown;
  final ValueChanged<AppScreen> onSelected;

  /// Given to the name of the screen on show, so it is found as the title.
  final Key? titleKey;

  const ViewTitles({
    super.key,
    required this.view,
    required this.shown,
    required this.onSelected,
    this.titleKey,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final style = Theme.of(
      context,
    ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700);
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final other in shown)
            Semantics(
              button: true,
              selected: other == view,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: other == view
                    ? null
                    : () {
                        HapticFeedback.selectionClick();
                        onSelected(other);
                      },
                // Taller than the words and spaced by padding, so a tap
                // between two names or just above one still lands.
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    0,
                    8,
                    other == shown.last ? 0 : 18,
                    8,
                  ),
                  child: Text(
                    TaskViews.label(s, other),
                    key: other == view ? titleKey : null,
                    maxLines: 1,
                    style: style?.copyWith(
                      color: other == view ? p.text : p.faint,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

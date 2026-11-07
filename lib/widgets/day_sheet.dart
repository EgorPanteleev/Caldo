import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../data/holidays.dart';
import '../models/task.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../screens/task_edit_screen.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import 'groups.dart';
import 'quick_add_bar.dart';
import 'reorderable_task_list.dart';
import 'selection.dart';
import 'tick_off.dart';

/// Identifies the day card, for tests and for the calendar that opens it.
const daySheetKey = Key('day-sheet');

/// Opens one day over the bottom of whatever is behind it: its tasks, its
/// holidays and a field to add another. This is what a day in the opened
/// calendar leads to — the grid is filling the screen there, so there is
/// nowhere on it to list the day out.
///
/// A sheet from the foot of the screen rather than a card in the middle of
/// it. The card stood out from both edges to well past half the height, a
/// panel inside a panel with two lines to every task, and a day of six of
/// them filled the screen: "too big and inconvenient to use". The sheet
/// sizes to the day, one line a task, and stops at a little over half the
/// screen, so the top of the month is still there above it; its field is
/// where the thumb already is.
Future<void> showDaySheet(BuildContext context, DateTime day) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    builder: (_) => SelectionScope(
      child: UndoScope(child: _DaySheet(day: day)),
    ),
  );
}

class _DaySheet extends StatefulWidget {
  final DateTime day;

  const _DaySheet({required this.day});

  @override
  State<_DaySheet> createState() => _DaySheetState();
}

class _DaySheetState extends State<_DaySheet> {
  final _quickAdd = TextEditingController();

  /// How much of the day is below the foot of the list, up to the height of
  /// the fade, which comes in with it.
  final _below = ValueNotifier<double>(0);

  /// How much of the screen the sheet may take while the keyboard is away.
  static const _most = 0.56;

  @override
  void dispose() {
    _quickAdd.dispose();
    _below.dispose();
    super.dispose();
  }

  /// Adds an all-day task on this day straight from the field.
  Future<void> _addQuickTask() async {
    final title = _quickAdd.text;
    _quickAdd.clear();
    await quickAddTask(context, day: widget.day, title: title);
  }

  Future<void> _openEditor([Task? task]) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => TaskEditScreen(task: task, initialDate: widget.day),
    ),
  );

  /// The list under the field fades into the sheet while there is more of
  /// it below, as the screens' lists do, rather than ending in a straight
  /// cut across a card. Only while there is: a day that fits has nothing
  /// under the field, and fading it would dim its last task for nothing.
  Widget _faded(Color ground, Widget list) {
    return NotificationListener<Notification>(
      onNotification: (n) {
        final metrics = switch (n) {
          ScrollNotification(depth: 0) => n.metrics,
          ScrollMetricsNotification(depth: 0) => n.metrics,
          _ => null,
        };
        if (metrics != null) {
          _below.value = metrics.extentAfter.clamp(0, GroundFade.height);
        }
        return false;
      },
      child: Stack(
        children: [
          list,
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ValueListenableBuilder<double>(
              valueListenable: _below,
              builder: (context, below, _) => GroundFade(
                ground: ground,
                strength: below / GroundFade.height,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final provider = context.watch<TaskProvider>();
    final country = context.watch<SettingsProvider>().effectiveHolidayCountry;
    final day = dayOf(widget.day);
    final tasks = provider.tasksForDay(day);
    final holidays = Holidays.around(country, day)[day] ?? const <Holiday>[];
    final events = eventsOnShow(context)?.on(day) ?? const [];
    final open = tasks.where((t) => !t.done).length;
    final view = MediaQueryData.fromView(View.of(context));

    final sheet = Material(
      key: daySheetKey,
      color: p.panel,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: p.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          _Header(
            day: day,
            open: open,
            empty: tasks.isEmpty,
            onFullForm: () => _openEditor(),
          ),
          Flexible(
            child: tasks.isEmpty && holidays.isEmpty && events.isEmpty
                // A line, not the placeholder the screens use: an icon and
                // two sentences would make the empty day the tallest sheet.
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
                    child: Text(
                      S.of(context).nothingOnDay,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: p.faint, fontSize: 14),
                    ),
                  )
                : _faded(
                    p.panel,
                    ReorderableTaskList(
                      shrinkWrap: true,
                      dense: true,
                      ground: p.panel,
                      padding: const EdgeInsets.only(top: 2, bottom: 4),
                      holidays: holidays,
                      events: events,
                      day: day,
                      tasks: tasks,
                      listOf: (t) => provider.listById(t.listId),
                      onOpen: _openEditor,
                      onToggle: (task) => tickOff(context, task),
                      isLeaving: provider.isLeaving,
                      isTicking: provider.isTicking,
                      rearranging: provider.rearranging,
                      scope: 'sheet',
                      onReorder: provider.reorder,
                    ),
                  ),
          ),
          QuickAddBar(
            date: day,
            controller: _quickAdd,
            onSubmit: _addQuickTask,
            onFullForm: () => _openEditor(),
          ),
          SizedBox(height: view.viewPadding.bottom),
        ],
      ),
    );

    // A sheet is not lifted for the keyboard the way a screen's field is, so
    // it is held above the keys here. The gesture strip at the foot stays
    // reserved under the field whether or not the keys cover it, as it does
    // on the screens, so the keyboard is measured the way theirs is
    // (`KeyboardGap`) and the field ends where the keys begin.
    return ValueListenableBuilder<double>(
      valueListenable: KeyboardGap.instance.covered,
      builder: (context, _, sheet) {
        final lift = KeyboardGap.of(context);
        final room = view.size.height - view.padding.top - 16;
        return Padding(
          padding: EdgeInsets.only(bottom: lift),
          child: ConstrainedBox(
            // The top of the month stays in sight while the keys are down;
            // with them up, the field and what is just above it matter more.
            constraints: BoxConstraints(
              maxHeight: lift > 0
                  ? room - lift
                  : view.size.height * _most + view.viewPadding.bottom,
            ),
            child: sheet,
          ),
        );
      },
      child: sheet,
    );
  }
}

/// The day across the top of the sheet: the number large and the weekday
/// beside it, how many of its tasks are still open, and the way through to
/// the full form.
class _Header extends StatelessWidget {
  final DateTime day;
  final int open;
  final bool empty;
  final VoidCallback onFullForm;

  const _Header({
    required this.day,
    required this.open,
    required this.empty,
    required this.onFullForm,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 6, 8, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            '${day.day}',
            style: TextStyle(
              color: p.text,
              fontSize: 24,
              height: 1,
              fontWeight: FontWeight.w700,
              // As on the day bar: digit boxes are one width, which at this
              // size shows as a hole between the ones of an 11.
              letterSpacing: -1.4,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              Dates.weekdayLong(day),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.muted,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (!empty)
            Text(
              open == 0
                  ? S.of(context).allClear
                  : S.of(context).openCount(open),
              style: TextStyle(color: p.faint, fontSize: 12.5),
            ),
          IconButton(
            icon: Icon(Icons.pending_actions_outlined, color: p.muted),
            tooltip: S.of(context).addWithForm,
            onPressed: onFullForm,
          ),
        ],
      ),
    );
  }
}

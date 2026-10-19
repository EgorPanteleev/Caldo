import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/holidays.dart';
import '../models/task.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../screens/task_edit_screen.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import 'quick_add_bar.dart';
import 'reorderable_task_list.dart';
import 'screen_header.dart';

/// Identifies the day card, for tests and for the calendar that opens it.
const daySheetKey = Key('day-sheet');

/// Opens one day on top of whatever is behind it: its tasks, its holidays and
/// a field to add another. This is what a day in the opened calendar leads to
/// — the grid is filling the screen there, so there is nowhere on it to list
/// the day out.
Future<void> showDaySheet(BuildContext context, DateTime day) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: Dates.longDay(day),
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, _, _) => _DaySheet(day: day),
    transitionBuilder: (context, animation, _, child) {
      final eased = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      // Grows in from a little under full size, which reads as the day
      // stepping forward out of the grid rather than a panel flying in.
      return FadeTransition(
        opacity: eased,
        child: ScaleTransition(
          scale: Tween(begin: 0.94, end: 1.0).animate(eased),
          child: child,
        ),
      );
    },
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

  @override
  void dispose() {
    _quickAdd.dispose();
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

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final provider = context.watch<TaskProvider>();
    final country = context.watch<SettingsProvider>().effectiveHolidayCountry;
    final day = dayOf(widget.day);
    final tasks = provider.tasksForDay(day);
    final holidays = Holidays.around(country, day)[day] ?? const <Holiday>[];
    final open = tasks.where((t) => !t.done).length;

    // The card is a dialog, so nothing lifts it for the keyboard the way a
    // screen is lifted: the keys arrived over the field at the foot of it and
    // what was being typed was underneath them. Giving the inset back as
    // padding takes the room out of the card instead — the list of the day's
    // tasks is what gives way, and the field stays in sight. The margin above
    // and below closes up at the same time, since on a short screen the
    // keyboard leaves little enough as it is.
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final margin = inset > 0 ? 16.0 : 56.0;

    return Center(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, margin, 16, margin + inset),
        child: Material(
          key: daySheetKey,
          color: p.panel,
          elevation: 8,
          shadowColor: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(26),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Header(day: day, onFullForm: () => _openEditor()),
              // The day's own panel, set into the card: everything that is on
              // the day, and nothing else.
              Flexible(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  decoration: BoxDecoration(
                    color: p.bg,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
                        child: Row(
                          children: [
                            Text(
                              Dates.shortDay(day),
                              style: TextStyle(color: p.muted, fontSize: 13),
                            ),
                            const Spacer(),
                            Text(
                              open == 0 ? 'All clear' : '$open open',
                              style: TextStyle(color: p.faint, fontSize: 12.5),
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: tasks.isEmpty && holidays.isEmpty
                            // Held to a height of its own: the card sizes to
                            // what is on the day, and a day with nothing on it
                            // should not open the largest card of all.
                            ? const SizedBox(
                                height: 200,
                                child: EmptyState(
                                  icon: Icons.event_available_outlined,
                                  title: 'Nothing on this day',
                                  message:
                                      'Add one below, or tap the icon '
                                      'above for the full form.',
                                ),
                              )
                            : ReorderableTaskList(
                                shrinkWrap: true,
                                ground: p.bg,
                                padding: const EdgeInsets.only(
                                  top: 2,
                                  bottom: 10,
                                ),
                                holidays: holidays,
                                tasks: tasks,
                                listOf: (t) => provider.listById(t.listId),
                                onOpen: _openEditor,
                                onToggle: provider.toggleDone,
                                isLeaving: provider.isLeaving,
                                onReorder: provider.reorder,
                              ),
                      ),
                    ],
                  ),
                ),
              ),
              QuickAddBar(
                date: day,
                controller: _quickAdd,
                onSubmit: _addQuickTask,
                onFullForm: () => _openEditor(),
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The day's name across the top of the card: the number large, the weekday
/// beside it, and the way through to the full form on the right.
class _Header extends StatelessWidget {
  final DateTime day;
  final VoidCallback onFullForm;

  const _Header({required this.day, required this.onFullForm});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 16, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            '${day.day}',
            style: TextStyle(
              color: p.text,
              fontSize: 28,
              height: 1,
              fontWeight: FontWeight.w700,
              // As on the day bar: digit boxes are one width, which at this
              // size shows as a hole between the ones of an 11.
              letterSpacing: -1.7,
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
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
          const Spacer(),
          IconButton(
            icon: Icon(Icons.pending_actions_outlined, color: p.muted),
            tooltip: 'Add with a full form',
            onPressed: onFullForm,
          ),
        ],
      ),
    );
  }
}

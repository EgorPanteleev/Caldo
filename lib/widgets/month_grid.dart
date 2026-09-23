import 'package:flutter/material.dart';

import '../models/task.dart';
import '../models/task_list.dart';
import '../providers/task_provider.dart' show dayOf;
import '../theme/app_theme.dart';
import '../utils/dates.dart';

/// The Mon…Sun (or Sun…Sat) column headings that sit above a [MonthGrid].
class WeekdayRow extends StatelessWidget {
  final bool mondayFirst;
  const WeekdayRow({super.key, required this.mondayFirst});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final labels = Dates.weekdayLabels(mondayFirst: mondayFirst);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        children: [
          for (final label in labels)
            Expanded(
              child: Center(
                child: Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    color: p.faint,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One month of day cells. Shared by the Calendar tab and the date picker, so
/// picking a date looks exactly like reading the calendar.
class MonthGrid extends StatelessWidget {
  final DateTime month;
  final DateTime? selected;
  final bool mondayFirst;

  /// Dated tasks keyed by day; each day shows up to three dots for them.
  final Map<DateTime, List<Task>> tasksByDay;

  /// Lists, used to colour a day's dots by the list each task belongs to.
  final List<TaskList> lists;

  final ValueChanged<DateTime> onSelect;

  /// Days outside this range are shown but cannot be picked.
  final DateTime? firstDate;
  final DateTime? lastDate;

  const MonthGrid({
    super.key,
    required this.month,
    required this.selected,
    required this.mondayFirst,
    required this.onSelect,
    this.tasksByDay = const {},
    this.lists = const [],
    this.firstDate,
    this.lastDate,
  });

  @override
  Widget build(BuildContext context) {
    final first = DateTime(month.year, month.month);
    // Sunday is weekday 7 in Dart, so it needs folding back to column 0.
    final lead = mondayFirst ? first.weekday - 1 : first.weekday % 7;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final rows = ((lead + daysInMonth) / 7).ceil();
    final today = dayOf(DateTime.now());

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        children: [
          for (var row = 0; row < rows; row++)
            Expanded(
              child: Row(
                children: [
                  for (var col = 0; col < 7; col++)
                    Expanded(
                      child: Builder(builder: (context) {
                        final day = first.add(
                          Duration(days: row * 7 + col - lead),
                        );
                        final enabled =
                            (firstDate == null || !day.isBefore(firstDate!)) &&
                                (lastDate == null || !day.isAfter(lastDate!));
                        return _DayCell(
                          day: day,
                          inMonth: day.month == month.month,
                          isToday: day == today,
                          isSelected: day == selected,
                          enabled: enabled,
                          tasks: tasksByDay[day] ?? const [],
                          lists: lists,
                          onTap: enabled ? () => onSelect(day) : null,
                        );
                      }),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A single day: its number, a today ring, a selected fill, and up to three
/// dots coloured by the lists the day's tasks belong to.
class _DayCell extends StatelessWidget {
  final DateTime day;
  final bool inMonth;
  final bool isToday;
  final bool isSelected;
  final bool enabled;
  final List<Task> tasks;
  final List<TaskList> lists;
  final VoidCallback? onTap;

  const _DayCell({
    required this.day,
    required this.inMonth,
    required this.isToday,
    required this.isSelected,
    required this.enabled,
    required this.tasks,
    required this.lists,
    required this.onTap,
  });

  Color _colorOf(Task task, Color fallback) {
    for (final list in lists) {
      if (list.id == task.listId) return list.style.color;
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context);
    final open = tasks.where((t) => !t.done).toList();
    final allDone = tasks.isNotEmpty && open.isEmpty;

    final Color numberColor;
    if (isSelected) {
      numberColor = Colors.white;
    } else if (!enabled) {
      numberColor = p.faint.withValues(alpha: 0.4);
    } else if (!inMonth) {
      numberColor = p.faint.withValues(alpha: 0.6);
    } else if (isToday) {
      numberColor = accent.color;
    } else {
      numberColor = p.text;
    }

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: isSelected ? accent.color : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: isToday && !isSelected ? accent.color : Colors.transparent,
              width: 1.4,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${day.day}',
                style: TextStyle(
                  color: numberColor,
                  fontSize: 14,
                  fontWeight:
                      isToday || isSelected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 5,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final task in tasks.take(3))
                      Container(
                        width: 5,
                        height: 5,
                        margin: const EdgeInsets.symmetric(horizontal: 1.5),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isSelected
                              ? Colors.white.withValues(
                                  alpha: task.done ? 0.45 : 1)
                              : _colorOf(task, accent.color).withValues(
                                  alpha: task.done ? 0.3 : (allDone ? 0.5 : 1)),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../data/holidays.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../providers/task_provider.dart' show dayOf;
import '../theme/app_theme.dart';
import '../utils/dates.dart';

/// The Mon…Sun (or Sun…Sat) column headings that sit above a [MonthGrid].
class WeekdayRow extends StatelessWidget {
  final bool mondayFirst;

  /// How far the grid below is opened; the headings are underlined by the
  /// same rule that separates the weeks, so the two arrive together.
  final double expansion;

  const WeekdayRow({
    super.key,
    required this.mondayFirst,
    this.expansion = 0,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final labels = Dates.weekdayLabels(mondayFirst: mondayFirst);
    return Padding(
      // Inset to match the grid, so the rule lines up with the week rules.
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: p.border.withValues(alpha: expansion),
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 6),
          child: Row(
            children: [
              for (var i = 0; i < labels.length; i++)
                Expanded(
                  child: Center(
                    child: Text(
                      labels[i],
                      style: TextStyle(
                        // Sunday sits last when the week starts on Monday
                        // and first when it starts on Sunday.
                        color: i == (mondayFirst ? 6 : 0)
                            ? AppColors.weekend.withValues(alpha: 0.75)
                            : p.faint,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
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

  /// Lists, used to colour a day's marks by the list each task belongs to.
  final List<TaskList> lists;

  /// Public holidays of the month, keyed by day.
  final Map<DateTime, List<Holiday>> holidaysByDay;

  final ValueChanged<DateTime> onSelect;

  /// How far the grid is pulled open, 0 (compact: a marker per task) to 1
  /// (full height: each task's title spelled out in its day).
  final double expansion;

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
    this.holidaysByDay = const {},
    this.expansion = 0,
    this.firstDate,
    this.lastDate,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
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
              // Rules between the weeks, drawn in as the month opens out.
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: row == 0
                      ? null
                      : Border(
                          top: BorderSide(
                            color: p.border.withValues(alpha: expansion),
                          ),
                        ),
                ),
                child: Row(
                  children: [
                    for (var col = 0; col < 7; col++)
                      Expanded(
                        child: Builder(builder: (context) {
                          final day = first.add(
                            Duration(days: row * 7 + col - lead),
                          );
                          final enabled = (firstDate == null ||
                                  !day.isBefore(firstDate!)) &&
                              (lastDate == null || !day.isAfter(lastDate!));
                          return _DayCell(
                            day: day,
                            inMonth: day.month == month.month,
                            isToday: day == today,
                            isSelected: day == selected,
                            enabled: enabled,
                            expansion: expansion,
                            tasks: tasksByDay[day] ?? const [],
                            holidays: holidaysByDay[day] ?? const [],
                            lists: lists,
                            onTap: enabled ? () => onSelect(day) : null,
                          );
                        }),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A single day: its number, a filled badge when it is today, an outline when
/// it is the selected day, and its tasks — shown as lines under the number
/// when the grid is compact and as titles once it is pulled open.
class _DayCell extends StatelessWidget {
  final DateTime day;
  final bool inMonth;
  final bool isToday;
  final bool isSelected;
  final bool enabled;
  final double expansion;
  final List<Task> tasks;
  final List<Holiday> holidays;
  final List<TaskList> lists;
  final VoidCallback? onTap;

  const _DayCell({
    required this.day,
    required this.inMonth,
    required this.isToday,
    required this.isSelected,
    required this.enabled,
    required this.expansion,
    required this.tasks,
    required this.holidays,
    required this.lists,
    required this.onTap,
  });

  TaskList? _listOf(Task task) {
    for (final list in lists) {
      if (list.id == task.listId) return list;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context);
    final open = tasks.where((t) => !t.done).toList();
    final allDone = tasks.isNotEmpty && open.isEmpty;

    // Only Sundays are red; a holiday says so with its green mark instead.
    final isRed = Dates.isSunday(day);

    final Color numberColor;
    if (isToday) {
      // Dark on the light badge — white in dark mode, near-black in light.
      numberColor = p.bg;
    } else if (!enabled) {
      numberColor = p.faint.withValues(alpha: 0.4);
    } else if (!inMonth) {
      numberColor = (isRed ? AppColors.weekend : p.faint)
          .withValues(alpha: isRed ? 0.45 : 0.6);
    } else if (isRed) {
      numberColor = AppColors.weekend;
    } else {
      numberColor = p.text;
    }

    Color taskColor(Task task) =>
        colorOfTask(task, _listOf(task), fallback: accent.color)
            .withValues(alpha: task.done ? 0.35 : (allDone ? 0.55 : 1));

    // Today wears a plain light badge and the selected day a thin neutral
    // outline: the accent on both was far too loud for a grid of numbers.
    final number = Container(
      width: 28,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isToday ? p.text : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${day.day}',
        style: TextStyle(
          color: numberColor,
          fontSize: 13.5,
          fontWeight: isToday || isSelected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: isSelected ? p.muted : Colors.transparent,
              width: 1.4,
            ),
          ),
          child: LayoutBuilder(builder: (context, box) {
            // Everything is positioned from the top of the cell: the number
            // keeps its place whatever the grid height, so the first week
            // never moves as the month opens — only what sits under the
            // number changes. Positioned children are bounded, so a cell too
            // short for its content drops it rather than overflowing.
            const numberTop = 2.0;
            const numberHeight = 20.0;
            const contentTop = numberTop + numberHeight + 2;
            final markerOpacity = (1 - expansion * 2.2).clamp(0.0, 1.0);
            final titleOpacity = ((expansion - 0.3) * 2.4).clamp(0.0, 1.0);

            return Stack(
              children: [
                Positioned(
                  top: numberTop,
                  left: 0,
                  right: 0,
                  child: Center(child: number),
                ),
                if (box.maxHeight > contentTop + 2)
                  Positioned(
                    top: contentTop,
                    left: 0,
                    right: 0,
                    bottom: 2,
                    child: Stack(
                      children: [
                        if (markerOpacity > 0)
                          Align(
                            alignment: Alignment.topCenter,
                            child: Opacity(
                              opacity: markerOpacity,
                              child: _MarkerBars(
                                colors: [
                                  for (final _ in holidays) AppColors.holiday,
                                  for (final task in tasks) taskColor(task),
                                ],
                              ),
                            ),
                          ),
                        if (titleOpacity > 0)
                          Opacity(
                            opacity: titleOpacity,
                            child: _DayTitles(
                              entries: [
                                for (final holiday in holidays)
                                  (
                                    label: holiday.name,
                                    color: AppColors.holiday,
                                    done: false,
                                  ),
                                for (final task in tasks)
                                  (
                                    label: task.title,
                                    color: taskColor(task),
                                    done: task.done,
                                  ),
                              ],
                              muted: p.faint,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            );
          }),
        ),
      ),
    );
  }
}

/// The compact marker for a day's tasks: a line per task, the width of the
/// day, stacked under its number.
class _MarkerBars extends StatelessWidget {
  /// One colour per thing happening that day, holidays first.
  final List<Color> colors;

  const _MarkerBars({required this.colors});

  static const _barHeight = 3.0;
  static const _gap = 2.0;
  static const _max = 4;

  @override
  Widget build(BuildContext context) {
    if (colors.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, box) {
      // Only as many lines as the compact cell can hold.
      final fits = ((box.maxHeight + _gap) / (_barHeight + _gap))
          .floor()
          .clamp(0, _max);
      final shown = colors.length < fits ? colors.length : fits;
      if (shown == 0) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < shown; i++)
              Container(
                height: _barHeight,
                margin: EdgeInsets.only(bottom: i == shown - 1 ? 0 : _gap),
                decoration: BoxDecoration(
                  color: colors[i],
                  borderRadius: BorderRadius.circular(_barHeight / 2),
                ),
              ),
          ],
        ),
      );
    });
  }
}

/// What an opened day writes out: one line per holiday and task.
typedef DayEntry = ({String label, Color color, bool done});

/// A day's entries written out, as many as the opened cell has room for.
class _DayTitles extends StatelessWidget {
  final List<DayEntry> entries;
  final Color muted;

  const _DayTitles({required this.entries, required this.muted});

  static const _rowHeight = 15.0;
  static const _gap = 2.0;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, box) {
      // Whole rows only — a half-clipped title would read as a glitch.
      final room = (box.maxHeight / (_rowHeight + _gap)).floor().clamp(0, 5);
      if (room == 0) return const SizedBox.shrink();
      // With room for a single row, spend it on a title rather than on a
      // lone "+2" that names nothing — there is no room for both.
      final shown = entries.length <= room
          ? entries.length
          : (room == 1 ? 1 : room - 1);
      final hidden = room == 1 ? 0 : entries.length - shown;
      return _titles(shown, hidden);
    });
  }

  Widget _titles(int shown, int hidden) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in entries.take(shown))
          Container(
            height: _rowHeight,
            margin: const EdgeInsets.only(bottom: _gap),
            padding: const EdgeInsets.symmetric(horizontal: 3),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: entry.color.withValues(alpha: entry.done ? 0.35 : 0.9),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              entry.label,
              maxLines: 1,
              // Fades out rather than cutting a letter in half or spending
              // two of the few characters on an ellipsis.
              overflow: TextOverflow.fade,
              softWrap: false,
              style: TextStyle(
                fontSize: 8.5,
                height: 1.2,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                decoration: entry.done ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        if (hidden > 0)
          SizedBox(
            height: _rowHeight,
            child: Text(
              '+$hidden',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                color: muted,
              ),
            ),
          ),
      ],
    );
  }
}

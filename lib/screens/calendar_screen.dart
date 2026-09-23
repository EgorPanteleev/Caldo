import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/task.dart';
import '../models/task_list.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/gradient_icon_button.dart';
import '../widgets/screen_header.dart';
import '../widgets/task_row.dart';
import 'task_edit_screen.dart';

/// A month grid of the user's dated tasks, with the selected day's tasks
/// listed underneath. Swipe or use the arrows to move between months.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  /// Middle of the page range; page [_basePage] shows [_baseMonth].
  static const _basePage = 6000;

  late final DateTime _baseMonth;
  late final PageController _controller;

  DateTime _selected = dayOf(DateTime.now());

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _baseMonth = DateTime(now.year, now.month);
    _controller = PageController(initialPage: _basePage);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<TaskProvider>().loadMonth(_baseMonth);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  DateTime _monthOfPage(int page) =>
      DateTime(_baseMonth.year, _baseMonth.month + (page - _basePage));

  void _goToPage(int page) => _controller.animateToPage(
        page,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );

  void _jumpToToday() {
    final today = dayOf(DateTime.now());
    setState(() => _selected = today);
    final page = _basePage +
        (today.year - _baseMonth.year) * 12 +
        (today.month - _baseMonth.month);
    if (_controller.page?.round() == page) {
      context.read<TaskProvider>().loadMonth(DateTime(today.year, today.month));
    } else {
      _goToPage(page);
    }
  }

  Future<void> _openEditor([Task? task]) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TaskEditScreen(task: task, initialDate: _selected),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final provider = context.watch<TaskProvider>();
    final mondayFirst = context.watch<SettingsProvider>().weekStartsMonday;
    final page = _controller.hasClients
        ? (_controller.page?.round() ?? _basePage)
        : _basePage;
    final shownMonth = _monthOfPage(page);
    final dayTasks = provider.tasksForDay(_selected);

    return Scaffold(
      body: Column(
        children: [
          ScreenHeader(
            title: Dates.monthTitle(shownMonth),
            actions: [
              IconButton(
                icon: Icon(Icons.chevron_left, color: p.muted),
                tooltip: 'Previous month',
                onPressed: () => _goToPage(page - 1),
              ),
              IconButton(
                icon: Icon(Icons.today_outlined, color: p.muted),
                tooltip: 'Today',
                onPressed: _jumpToToday,
              ),
              IconButton(
                icon: Icon(Icons.chevron_right, color: p.muted),
                tooltip: 'Next month',
                onPressed: () => _goToPage(page + 1),
              ),
            ],
          ),
          _WeekdayRow(mondayFirst: mondayFirst),
          SizedBox(
            height: 300,
            child: PageView.builder(
              controller: _controller,
              onPageChanged: (i) {
                final month = _monthOfPage(i);
                context.read<TaskProvider>().loadMonth(month);
                // Keep the selection inside the month being looked at.
                setState(() {
                  final today = dayOf(DateTime.now());
                  _selected = (today.year == month.year &&
                          today.month == month.month)
                      ? today
                      : month;
                });
              },
              itemBuilder: (context, i) => _MonthGrid(
                month: _monthOfPage(i),
                selected: _selected,
                mondayFirst: mondayFirst,
                tasksByDay: provider.tasksByDay,
                lists: provider.lists,
                onSelect: (day) => setState(() => _selected = day),
              ),
            ),
          ),
          Divider(height: 1, color: p.border),
          _DayBar(
            date: _selected,
            count: dayTasks.where((t) => !t.done).length,
            onAdd: () => _openEditor(),
          ),
          Expanded(
            child: dayTasks.isEmpty
                ? EmptyState(
                    icon: Icons.event_available_outlined,
                    title: 'Nothing on this day',
                    message: 'Tap + to schedule something for '
                        '${Dates.day(_selected).toLowerCase()}.',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 90),
                    itemCount: dayTasks.length,
                    itemBuilder: (context, i) {
                      final task = dayTasks[i];
                      return TaskRow(
                        task: task,
                        list: provider.listById(task.listId),
                        showList: true,
                        hideDate: !task.hasTime,
                        onTap: () => _openEditor(task),
                        onLongPress: () => _openEditor(task),
                        onToggle: () => provider.toggleDone(task),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// The Mon…Sun (or Sun…Sat) column headings above the grid.
class _WeekdayRow extends StatelessWidget {
  final bool mondayFirst;
  const _WeekdayRow({required this.mondayFirst});

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

/// One month of day cells.
class _MonthGrid extends StatelessWidget {
  final DateTime month;
  final DateTime selected;
  final bool mondayFirst;
  final Map<DateTime, List<Task>> tasksByDay;
  final List<TaskList> lists;
  final ValueChanged<DateTime> onSelect;

  const _MonthGrid({
    required this.month,
    required this.selected,
    required this.mondayFirst,
    required this.tasksByDay,
    required this.lists,
    required this.onSelect,
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
                        return _DayCell(
                          day: day,
                          inMonth: day.month == month.month,
                          isToday: day == today,
                          isSelected: day == selected,
                          tasks: tasksByDay[day] ?? const [],
                          lists: lists,
                          onTap: () => onSelect(day),
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
  final List<Task> tasks;
  final List<TaskList> lists;
  final VoidCallback onTap;

  const _DayCell({
    required this.day,
    required this.inMonth,
    required this.isToday,
    required this.isSelected,
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

/// The bar between the grid and the day's task list.
class _DayBar extends StatelessWidget {
  final DateTime date;
  final int count;
  final VoidCallback onAdd;

  const _DayBar({
    required this.date,
    required this.count,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Container(
      color: p.sidebar,
      padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              Dates.longDay(date),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.text,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            count == 0 ? 'Free' : '$count open',
            style: TextStyle(color: p.muted, fontSize: 12.5),
          ),
          const SizedBox(width: 10),
          GradientIconButton(
            icon: Icons.add,
            size: 34,
            tooltip: 'Add on this day',
            onTap: onAdd,
          ),
        ],
      ),
    );
  }
}

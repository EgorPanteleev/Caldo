import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/task.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/gradient_icon_button.dart';
import '../widgets/month_grid.dart';
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
    // Give the grid a share of the screen rather than a fixed height, so the
    // day's tasks keep room on a short phone.
    final gridHeight =
        (MediaQuery.of(context).size.height * 0.36).clamp(230.0, 310.0);

    return Scaffold(
      body: Column(
        children: [
          _MonthBar(
            title: Dates.monthTitle(shownMonth),
            onPrevious: () => _goToPage(page - 1),
            onToday: _jumpToToday,
            onNext: () => _goToPage(page + 1),
          ),
          WeekdayRow(mondayFirst: mondayFirst),
          SizedBox(
            height: gridHeight,
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
              itemBuilder: (context, i) => MonthGrid(
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

/// Identifies the month name in the calendar header.
const monthTitleKey = Key('month-title');

/// The calendar's own header. The month name is laid out first and the three
/// controls are kept narrow, so a long name like "September" is never clipped.
class _MonthBar extends StatelessWidget {
  final String title;
  final VoidCallback onPrevious;
  final VoidCallback onToday;
  final VoidCallback onNext;

  const _MonthBar({
    required this.title,
    required this.onPrevious,
    required this.onToday,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 10, 8),
      child: Row(
        children: [
          // Expanded, not Flexible beside a Spacer: a Spacer would claim an
          // equal share of the leftover width and clip the month name.
          Expanded(
            child: Text(
              title,
              key: monthTitleKey,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          _StepButton(
            icon: Icons.chevron_left,
            tooltip: 'Previous month',
            onTap: onPrevious,
          ),
          _StepButton(
            icon: Icons.today_outlined,
            tooltip: 'Today',
            onTap: onToday,
          ),
          _StepButton(
            icon: Icons.chevron_right,
            tooltip: 'Next month',
            onTap: onNext,
          ),
        ],
      ),
    );
  }
}

/// A compact icon button — narrower than Material's 48dp default, to leave
/// the month name all the room it needs.
class _StepButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _StepButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(icon, size: 21, color: p.muted),
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

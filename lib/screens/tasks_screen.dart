import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/task.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/gradient_icon_button.dart';
import '../widgets/screen_header.dart';
import '../widgets/task_row.dart';
import 'lists_screen.dart';
import 'task_edit_screen.dart';

/// The landing screen: every task, day by day — what is overdue, what is due
/// today, what is coming up, and finally everything with no date on it.
class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<TaskProvider>().loadTasks();
    });
  }

  Future<void> _openEditor([Task? task, DateTime? date]) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TaskEditScreen(task: task, initialDate: date),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final provider = context.watch<TaskProvider>();
    final today = dayOf(DateTime.now());
    final overdue = provider.overdue;
    // The list a task belongs to is only worth naming when there is more than
    // one to tell apart; with a single list every row repeated the same word.
    final showList = provider.lists.length > 1;
    final byDay = provider.upcomingByDay;
    final days = byDay.keys.toList()..sort();
    final undated = provider.undated;

    final todays = byDay[today] ?? const <Task>[];
    final doneToday = todays.where((t) => t.done).length;
    final openToday = todays.length - doneToday;
    final hasAnything =
        overdue.isNotEmpty || days.isNotEmpty || undated.isNotEmpty;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: provider.loadTasks,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 90),
          children: [
            ScreenHeader(
              title: 'Tasks',
              actions: [
                IconButton(
                  icon: Icon(Icons.folder_outlined, color: p.muted),
                  tooltip: 'Lists',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ListsScreen()),
                  ),
                ),
                GradientIconButton(
                  icon: Icons.add,
                  tooltip: 'New task',
                  onTap: () => _openEditor(null, today),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 18),
              child: _TodayCard(
                date: today,
                open: openToday,
                done: doneToday,
                overdue: overdue.length,
              ),
            ),
            if (!hasAnything)
              Padding(
                padding: const EdgeInsets.only(top: 40),
                child: EmptyState(
                  icon: Icons.beach_access_outlined,
                  title: 'No tasks yet',
                  message: 'Tap + to add one. Anything with a due date is '
                      'listed here day by day.',
                ),
              ),
            if (overdue.isNotEmpty) ...[
              const _DayHeader(label: 'Overdue', color: AppColors.overdue),
              for (final task in overdue)
                TaskRow(
                  task: task,
                  list: provider.listById(task.listId),
                  showList: showList,
                  onTap: () => _openEditor(task),
                  onLongPress: () => _openEditor(task),
                  onToggle: () => provider.toggleDone(task),
                ),
            ],
            for (final day in days) ...[
              _DayHeader(
                label: Dates.day(day),
                color: day == today ? AppTheme.accentOf(context).color : null,
                trailing: '${byDay[day]!.where((t) => !t.done).length} open',
                onAdd: () => _openEditor(null, day),
              ),
              for (final task in byDay[day]!)
                TaskRow(
                  task: task,
                  list: provider.listById(task.listId),
                  showList: showList,
                  hideDate: !task.hasTime,
                  onTap: () => _openEditor(task),
                  onLongPress: () => _openEditor(task),
                  onToggle: () => provider.toggleDone(task),
                ),
            ],
            if (undated.isNotEmpty) ...[
              _DayHeader(
                label: 'No date',
                trailing: '${undated.where((t) => !t.done).length} open',
                onAdd: () => _openEditor(),
              ),
              for (final task in undated)
                TaskRow(
                  task: task,
                  list: provider.listById(task.listId),
                  showList: showList,
                  onTap: () => _openEditor(task),
                  onLongPress: () => _openEditor(task),
                  onToggle: () => provider.toggleDone(task),
                ),
            ],
            if (days.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                child: Text(
                  'Dated tasks are shown for the next '
                  '${TaskProvider.agendaDays} days.',
                  style: TextStyle(color: p.faint, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The hero card at the top of the Tasks screen: today's date and how it is
/// going.
class _TodayCard extends StatelessWidget {
  final DateTime date;
  final int open;
  final int done;
  final int overdue;

  const _TodayCard({
    required this.date,
    required this.open,
    required this.done,
    required this.overdue,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context);
    final total = open + done;
    final progress = total == 0 ? 0.0 : done / total;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          Dates.longDay(date),
          style: TextStyle(
            color: p.text,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 5),
        Row(
          children: [
            Flexible(
              child: Text(
                total == 0
                    ? 'No tasks due today'
                    : done == total
                        ? 'All $total done — nice.'
                        : '$open left of $total today',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.muted, fontSize: 13),
              ),
            ),
            if (overdue > 0) ...[
              Text(' · ', style: TextStyle(color: p.faint, fontSize: 13)),
              Text(
                '$overdue overdue',
                style: const TextStyle(
                  color: AppColors.overdue,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
        if (total > 0) ...[
          const SizedBox(height: 12),
          // The only colour left up here: a hairline of progress.
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              backgroundColor: p.panelHi,
              valueColor: AlwaysStoppedAnimation<Color>(accent.color),
            ),
          ),
        ],
      ],
    );
  }
}

/// A day separator, optionally with a count and an add button.
class _DayHeader extends StatelessWidget {
  final String label;
  final Color? color;
  final String? trailing;
  final VoidCallback? onAdd;

  const _DayHeader({
    required this.label,
    this.color,
    this.trailing,
    this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Container(
      color: p.sidebar,
      padding: EdgeInsets.fromLTRB(20, 10, onAdd == null ? 20 : 8, 10),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: color ?? p.muted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const Spacer(),
          if (trailing != null)
            Text(
              trailing!,
              style: TextStyle(color: p.faint, fontSize: 11.5),
            ),
          if (onAdd != null)
            IconButton(
              icon: Icon(Icons.add, size: 18, color: p.muted),
              tooltip: 'Add on this day',
              visualDensity: VisualDensity.compact,
              onPressed: onAdd,
            ),
        ],
      ),
    );
  }
}

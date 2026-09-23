import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/task.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/gradient_icon_button.dart';
import '../widgets/screen_header.dart';
import '../widgets/task_row.dart';
import 'task_edit_screen.dart';

/// The landing screen: what is overdue, what is due today, and what is coming
/// up over the next few weeks — every list mixed together, soonest first.
class AgendaScreen extends StatefulWidget {
  const AgendaScreen({super.key});

  @override
  State<AgendaScreen> createState() => _AgendaScreenState();
}

class _AgendaScreenState extends State<AgendaScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<TaskProvider>().loadAgenda();
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
    final byDay = provider.upcomingByDay;
    final days = byDay.keys.toList()..sort();

    final todays = byDay[today] ?? const <Task>[];
    final doneToday = todays.where((t) => t.done).length;
    final openToday = todays.length - doneToday;
    final hasAnything = overdue.isNotEmpty || days.isNotEmpty;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: provider.loadAgenda,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 90),
          children: [
            ScreenHeader(
              title: 'Today',
              actions: [
                GradientIconButton(
                  icon: Icons.add,
                  tooltip: 'New task',
                  onTap: () => _openEditor(null, today),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
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
                  title: 'Nothing scheduled',
                  message: 'Tasks with a due date show up here, '
                      'soonest first.',
                ),
              ),
            if (overdue.isNotEmpty) ...[
              const _DayHeader(label: 'Overdue', color: AppColors.overdue),
              for (final task in overdue)
                TaskRow(
                  task: task,
                  list: provider.listById(task.listId),
                  showList: true,
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
                  showList: true,
                  hideDate: !task.hasTime,
                  onTap: () => _openEditor(task),
                  onLongPress: () => _openEditor(task),
                  onToggle: () => provider.toggleDone(task),
                ),
            ],
            if (days.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                child: Text(
                  'Showing the next ${TaskProvider.agendaDays} days.',
                  style: TextStyle(color: p.faint, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The hero card at the top of the agenda: today's date and how it is going.
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
    final accent = AppTheme.accentOf(context);
    final total = open + done;
    final progress = total == 0 ? 0.0 : done / total;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        gradient: accent.gradient,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            Dates.longDay(date),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            total == 0
                ? 'No tasks due today'
                : done == total
                    ? 'All $total done — nice.'
                    : '$open left of $total today',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
          if (overdue > 0) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.white, size: 16),
                const SizedBox(width: 6),
                Text(
                  '$overdue overdue ${overdue == 1 ? "task" : "tasks"}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A day separator in the agenda, optionally with a count and an add button.
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

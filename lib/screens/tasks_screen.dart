import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/holidays.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/quick_add_bar.dart';
import '../widgets/screen_header.dart';
import '../widgets/task_card.dart';
import 'search_screen.dart';
import 'task_edit_screen.dart';

/// The landing screen: one run of days, each with what is on it. A day that
/// carries a time is a line in the running order; anything all-day is a card,
/// the same card the calendar puts under its grid.
class TasksScreen extends StatefulWidget {
  /// Opens the shell's menu; null when the screen is shown on its own.
  final VoidCallback? onMenu;

  const TasksScreen({super.key, this.onMenu});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  final _scroll = ScrollController();
  final _quickAdd = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<TaskProvider>().loadTasks();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _quickAdd.dispose();
    super.dispose();
  }

  Future<void> _openEditor([Task? task, DateTime? date]) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TaskEditScreen(task: task, initialDate: date),
      ),
    );
  }

  /// Files an all-day task on today straight from the field at the foot.
  Future<void> _addQuickTask() async {
    final title = _quickAdd.text;
    _quickAdd.clear();
    await quickAddTask(context, day: dayOf(DateTime.now()), title: title);
  }

  /// Today is the top of the run, so this is a scroll home.
  void _jumpToToday() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final provider = context.watch<TaskProvider>();
    final country = context.watch<SettingsProvider>().effectiveHolidayCountry;
    final today = dayOf(DateTime.now());
    final overdue = provider.overdue;
    final byDay = provider.upcomingByDay;
    final days = byDay.keys.toList()..sort();
    final undated = provider.undated;
    final hasAnything =
        overdue.isNotEmpty || days.isNotEmpty || undated.isNotEmpty;

    // Public holidays fall in among the days rather than in a list of their
    // own, the same way they do under the calendar.
    final holidays = Holidays.around(country, today);

    Widget entry(Task task) => task.hasTime
        ? _TimedRow(
            task: task,
            list: provider.listById(task.listId),
            onTap: () => _openEditor(task),
            onToggle: () => provider.toggleDone(task),
          )
        : TaskCard(
            task: task,
            list: provider.listById(task.listId),
            onTap: () => _openEditor(task),
            onLongPress: () => _openEditor(task),
            onToggle: () => provider.toggleDone(task),
          );

    return Scaffold(
      body: Column(
        children: [
          ScreenHeader(
            title: 'Schedule',
            onMenu: widget.onMenu,
            actions: [
              IconButton(
                icon: Icon(Icons.search, color: p.muted),
                tooltip: 'Search',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SearchScreen()),
                ),
              ),
              _TodayButton(onTap: _jumpToToday),
              const SizedBox(width: 6),
            ],
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: provider.loadTasks,
              child: _LazyList(
                controller: _scroll,
                children: [
                  if (!hasAnything)
                    () => const Padding(
                      padding: EdgeInsets.only(top: 40),
                      child: EmptyState(
                        icon: Icons.beach_access_outlined,
                        title: 'Nothing scheduled',
                        message: 'Add something below. Anything with a date on '
                            'it is listed here, day by day.',
                      ),
                    ),
                  if (overdue.isNotEmpty) ...[
                    () => const _DayHeader(
                      label: 'Overdue',
                      color: AppColors.overdue,
                    ),
                    for (final task in overdue) () => entry(task),
                  ],
                  for (final day in days) ...[
                    () => _DayHeader(label: Dates.day(day)),
                    for (final holiday in holidays[day] ?? const <Holiday>[])
                      () => HolidayCard(holiday: holiday),
                    for (final task in byDay[day]!) () => entry(task),
                  ],
                  if (undated.isNotEmpty) ...[
                    () => const _DayHeader(label: 'No date'),
                    for (final task in undated) () => entry(task),
                  ],
                  if (days.isNotEmpty)
                    () => Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                      child: Text(
                        'Dated tasks are shown for the next '
                        '${TaskProvider.agendaDays} days.',
                        style: TextStyle(color: p.faint, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ),
          QuickAddBar(
            date: today,
            controller: _quickAdd,
            onSubmit: _addQuickTask,
            onFullForm: () => _openEditor(null, today),
          ),
        ],
      ),
    );
  }
}

/// A task with a time on it: the tick, a bar in the list's colour, the title,
/// and the hour at the far end where a column of them can be read down. An
/// all-day task is a card instead — the difference is the point, since one of
/// them happens at a moment and the other does not.
class _TimedRow extends StatelessWidget {
  final Task task;
  final TaskList? list;
  final VoidCallback onTap;
  final VoidCallback onToggle;

  const _TimedRow({
    required this.task,
    required this.list,
    required this.onTap,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final color = colorOfTask(
      task,
      list,
      fallback: AppTheme.accentOf(context).color,
    );
    final due = task.due;
    final faded = task.done;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.border, width: 0.5)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 14, 20, 14),
          child: Row(
            children: [
              // The tick leads, the same as it does on a card; the hour goes
              // to the far end, where the eye can run down a column of them.
              _Tick(done: task.done, color: color, onTap: onToggle),
              const SizedBox(width: 14),
              Container(
                width: 3.5,
                height: 34,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: faded ? 0.35 : 1),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: faded ? p.faint : p.text,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                        decoration: faded ? TextDecoration.lineThrough : null,
                        decorationColor: p.faint,
                      ),
                    ),
                    if (task.repeat != Repeat.none || task.notes.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          [
                            if (task.repeat != Repeat.none) task.repeat.label,
                            if (task.notes.isNotEmpty) task.notes,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.muted, fontSize: 12.5),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                due == null ? '' : Dates.time(due),
                style: TextStyle(
                  color: task.isOverdue ? AppColors.overdue : p.muted,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The square tick box, matching the one on a card.
class _Tick extends StatelessWidget {
  final bool done;
  final Color color;
  final VoidCallback onTap;

  const _Tick({required this.done, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return InkResponse(
      onTap: onTap,
      radius: 22,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: done ? color : Colors.transparent,
          border: Border.all(color: done ? color : p.border, width: 1.6),
          borderRadius: BorderRadius.circular(7),
        ),
        child: done
            ? const Icon(Icons.check, size: 15, color: Colors.white)
            : null,
      ),
    );
  }
}

/// Back to today, drawn as today's date on a page.
class _TodayButton extends StatelessWidget {
  final VoidCallback onTap;

  const _TodayButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Tooltip(
      message: 'Today',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Container(
              width: 27,
              height: 27,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: p.muted, width: 1.6),
              ),
              child: Text(
                '${DateTime.now().day}',
                style: TextStyle(
                  color: p.text,
                  fontSize: 13,
                  height: 1,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The date a run of entries belongs to. Written out plainly — it is a date,
/// not a section, and the uppercase label with a count beside it made a
/// heading out of something the eye should pass straight over.
class _DayHeader extends StatelessWidget {
  final String label;
  final Color? color;

  const _DayHeader({required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 10),
      child: Text(
        label,
        style: TextStyle(
          color: color ?? p.text,
          fontSize: 14.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// A list whose rows are only built when they come into view.
///
/// `ListView(children: [...])` constructs every row on every build, and the
/// screen rebuilds on each frame of the keyboard sliding in — so opening the
/// keyboard rebuilt the whole agenda sixty times a second and juddered. The
/// rows are handed over as builders instead, which costs one closure each and
/// nothing at all for the ones off screen.
class _LazyList extends StatelessWidget {
  final ScrollController controller;
  final List<Widget Function()> children;

  const _LazyList({required this.controller, required this.children});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      itemCount: children.length,
      itemBuilder: (context, i) => children[i](),
    );
  }
}

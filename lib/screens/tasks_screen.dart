import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/holidays.dart';
import '../models/task.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/quick_add_bar.dart';
import '../widgets/screen_header.dart';
import '../widgets/task_card.dart';
import 'search_screen.dart';
import 'task_edit_screen.dart';

/// The landing screen: one run of days, each with what is on it — written out
/// as the same cards the calendar puts under its grid.
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

    // One card for everything on a day. A timed task was a bare row with a
    // lone colour bar on it and its hour stranded at the far edge, which read
    // as unfinished beside the filled cards it sat between — and the card
    // already writes the hour where an all-day one writes "All day", so the
    // row was drawing a distinction the card had covered.
    Widget entry(Task task) => TaskCard(
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
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const SearchScreen())),
              ),
              _TodayButton(onTap: _jumpToToday),
              const SizedBox(width: 6),
            ],
          ),
          Expanded(
            // The run of days fades into the ground the add field sits on
            // rather than being cut off square by it, the same way the day's
            // tasks do under the calendar.
            child: Stack(
              children: [
                RefreshIndicator(
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
                            message:
                                'Add something below. Anything with a date on '
                                'it is listed here, day by day.',
                          ),
                        ),
                      if (overdue.isNotEmpty) ...[
                        () => const _DayHeader(
                          word: 'Overdue',
                          color: AppColors.overdue,
                        ),
                        for (final task in overdue) () => entry(task),
                      ],
                      for (final day in days) ...[
                        () => _DayHeader(
                          word: Dates.dayWord(day),
                          label: Dates.dayDate(day),
                        ),
                        for (final holiday
                            in holidays[day] ?? const <Holiday>[])
                          () => HolidayCard(holiday: holiday),
                        for (final task in byDay[day]!) () => entry(task),
                      ],
                      if (undated.isNotEmpty) ...[
                        () => const _DayHeader(word: 'No date'),
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
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: GroundFade(ground: p.bg),
                ),
              ],
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
///
/// A day the reader has a word for — today, tomorrow, yesterday — wears it on
/// a badge, with the date itself written beside it. The word alone replaced
/// the date, so the one day most likely to be looked up was the one day not
/// written down.
class _DayHeader extends StatelessWidget {
  final String? word;
  final String? label;
  final Color? color;

  const _DayHeader({this.word, this.label, this.color})
    : assert(word != null || label != null);

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final style = TextStyle(
      color: color ?? p.text,
      fontSize: 14.5,
      fontWeight: FontWeight.w600,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 10),
      child: Row(
        children: [
          if (word != null)
            Container(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 5),
              decoration: BoxDecoration(
                color: color ?? p.text,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                word!,
                style: style.copyWith(
                  color: color == null ? p.bg : Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
            ),
          if (word != null && label != null) const SizedBox(width: 10),
          if (label != null) Text(label!, style: style),
        ],
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

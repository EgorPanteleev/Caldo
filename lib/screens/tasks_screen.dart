import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/holidays.dart';
import '../models/task.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/quick_add_bar.dart';
import '../widgets/reorderable_task_list.dart';
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
                  child: _RunOfDays(
                    controller: _scroll,
                    ground: p.bg,
                    onReorder: provider.reorder,
                    rows: [
                      if (!hasAnything)
                        _Row(
                          key: const ValueKey('empty'),
                          build: () => const Padding(
                            padding: EdgeInsets.only(top: 40),
                            child: EmptyState(
                              icon: Icons.beach_access_outlined,
                              title: 'Nothing scheduled',
                              message:
                                  'Add something below. Anything with a date '
                                  'on it is listed here, day by day.',
                            ),
                          ),
                        ),
                      // The backlog is a run like any other. It wants to be
                      // ordered by how late each thing is until somebody says
                      // otherwise, and dragging is them saying otherwise — on
                      // a screen where most of what there is to drag is often
                      // in here.
                      if (overdue.isNotEmpty) ...[
                        _Row(
                          key: const ValueKey('overdue'),
                          build: () => const _DayHeader(
                            word: 'Overdue',
                            color: AppColors.overdue,
                          ),
                        ),
                        for (final task in overdue)
                          _Row(
                            key: ValueKey('task-${task.id}'),
                            group: 'overdue',
                            task: task,
                            build: () => entry(task),
                          ),
                      ],
                      for (final day in days) ...[
                        _Row(
                          key: ValueKey('head-$day'),
                          build: () => _DayHeader(
                            word: Dates.dayWord(day),
                            label: Dates.dayDate(day),
                          ),
                        ),
                        for (final holiday
                            in holidays[day] ?? const <Holiday>[])
                          _Row(
                            key: ValueKey('holiday-$day-${holiday.name}'),
                            build: () => HolidayCard(holiday: holiday),
                          ),
                        for (final task in byDay[day]!)
                          _Row(
                            key: ValueKey('task-${task.id}'),
                            group: '$day',
                            task: task,
                            build: () => entry(task),
                          ),
                      ],
                      if (undated.isNotEmpty) ...[
                        _Row(
                          key: const ValueKey('undated'),
                          build: () => const _DayHeader(word: 'No date'),
                        ),
                        for (final task in undated)
                          _Row(
                            key: ValueKey('task-${task.id}'),
                            group: 'undated',
                            task: task,
                            build: () => entry(task),
                          ),
                      ],
                      if (days.isNotEmpty)
                        _Row(
                          key: const ValueKey('footnote'),
                          build: () => Padding(
                            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                            child: Text(
                              'Dated tasks are shown for the next '
                              '${TaskProvider.agendaDays} days.',
                              style: TextStyle(color: p.faint, fontSize: 12),
                            ),
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

/// One line of the run: a day's heading, a holiday, or a task.
///
/// A row carries a builder rather than a built widget. `ListView(children:
/// [...])` constructs every row on every build, and the screen rebuilds on
/// each frame of the keyboard sliding in — so opening the keyboard rebuilt the
/// whole agenda sixty times a second and juddered.
class _Row {
  final Key key;
  final Widget Function() build;

  /// Which run of tasks this row can be dragged around inside, or null for a
  /// row that cannot be picked up at all. A task only ever moves within its
  /// own day; dragging one into another day would be a change of date wearing
  /// the clothes of a change of order.
  final String? group;

  final Task? task;

  const _Row({required this.key, required this.build, this.group, this.task});
}

/// The run of days, with each day's tasks draggable into an order of their
/// own. A long press picks a card up — the gesture used to open the editor,
/// which a tap already does.
class _RunOfDays extends StatefulWidget {
  final ScrollController controller;
  final List<_Row> rows;
  final Color ground;
  final ValueChanged<List<Task>> onReorder;

  const _RunOfDays({
    required this.controller,
    required this.rows,
    required this.ground,
    required this.onReorder,
  });

  @override
  State<_RunOfDays> createState() => _RunOfDaysState();
}

class _RunOfDaysState extends State<_RunOfDays> {
  // A key for each row that cannot be dragged — the headings, the footnote.
  // They are what a card being carried is penned in by, and they are the only
  // rows that can do the job: a row that can be dragged is lifted clean out
  // of the list while it is carried, and takes its key with it. Kept by row
  // and reused, because a key that is rebuilt is a subtree that is rebuilt.
  final _anchors = <Key, GlobalKey>{};

  GlobalKey _anchorOf(Key row) => _anchors.putIfAbsent(row, GlobalKey.new);

  /// The row above the given run and the row below it, if either exists.
  (GlobalKey?, GlobalKey?) _pen(String group) {
    final first = rows.indexWhere((r) => r.group == group);
    final last = rows.lastIndexWhere((r) => r.group == group);
    if (first < 0) return (null, null);
    return (
      first > 0 ? _anchors[rows[first - 1].key] : null,
      last < rows.length - 1 ? _anchors[rows[last + 1].key] : null,
    );
  }

  List<_Row> get rows => widget.rows;

  void _reorder(int oldIndex, int newIndex) {
    final group = rows[oldIndex].group;
    if (group == null) return;
    // Where this group's tasks are in the run. They are contiguous: a day's
    // heading and its holidays come first, then every task of that day.
    final block = [
      for (var i = 0; i < rows.length; i++)
        if (rows[i].group == group) i,
    ];
    if (block.length < 2) return;

    // Flutter reports the slot the card would go into before the gap it left
    // behind is closed up. Held inside the group: a card let go over another
    // day lands at the near end of its own rather than changing its date.
    final to = (newIndex > oldIndex ? newIndex - 1 : newIndex).clamp(
      block.first,
      block.last,
    );
    final from = oldIndex;
    if (from == to) return;

    final ordered = [for (final i in block) rows[i].task!];
    ordered.insert(
      to - block.first,
      ordered.removeAt(from - block.first),
    );
    widget.onReorder(ordered);
  }

  @override
  Widget build(BuildContext context) {
    // The card being carried belongs to the run, not to the screen: without
    // this it could be lifted up over the header and the Overdue badge.
    // The builder is for a context below `DragWithin`, which is where
    // the card being carried finds the box it has to stay inside.
    return DragWithin(
      child: Builder(builder: (context) => _list(context)),
    );
  }

  Widget _list(BuildContext context) {
    return ReorderableListView.builder(
      scrollController: widget.controller,
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      // The card is the handle. A grip beside every row would be a column of
      // furniture down a list whose whole job is to be read.
      buildDefaultDragHandles: false,
      itemCount: rows.length,
      onReorder: _reorder,
      proxyDecorator: (child, index, animation) {
        final group = rows[index].group;
        final pen = group == null ? (null, null) : _pen(group);
        return liftedCard(
          context,
          widget.ground,
          child,
          animation,
          under: pen.$1,
          over: pen.$2,
        );
      },
      itemBuilder: (context, i) {
        final row = rows[i];
        if (row.group == null) {
          return KeyedSubtree(
            key: row.key,
            child: KeyedSubtree(key: _anchorOf(row.key), child: row.build()),
          );
        }
        return ReorderableDelayedDragStartListener(
          key: row.key,
          index: i,
          child: row.build(),
        );
      },
    );
  }
}

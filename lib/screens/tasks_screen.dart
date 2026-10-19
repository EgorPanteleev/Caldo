import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/holidays.dart';
import '../models/task.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/carry.dart';
import '../widgets/quick_add_bar.dart';
import '../widgets/reorderable_task_list.dart';
import '../widgets/screen_header.dart';
import '../widgets/slide_into_place.dart';
import '../widgets/task_card.dart';
import '../widgets/tick_off.dart';
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
    // A done task is not overdue, so ticking one in the backlog takes it out
    // of the run; ticked anywhere else it stays where it is, crossed out.
    final overdueIds = {for (final t in overdue) t.id};
    Widget entry(Task task) => SlideIntoPlace(
      scope: 'schedule',
      id: task.id ?? task,
      trigger: provider.rearranging,
      child: AsShown(
        task: task,
        builder: (context, shown) => TaskCard(
          task: shown,
          list: provider.listById(task.listId),
          onTap: () => _openEditor(task),
          onToggle: () => tickOff(context, shown),
          ticking: provider.isTicking(task),
          leaving: provider.isLeaving(
            task,
            fromOverdue: overdueIds.contains(task.id),
          ),
        ),
      ),
    );

    return Scaffold(
      // The run keeps the height it had and the field is carried up over it,
      // the same way the calendar does it — one mechanism, so the two screens
      // cannot disagree about how a field meets a keyboard. A resizing
      // `Scaffold` moved this one by relayout, which follows every lump
      // Android reports exactly and so jumped on the last of them; the run
      // gets the keys' height as room at its foot instead, so nothing at the
      // bottom of it is out of reach while the keyboard is up.
      resizeToAvoidBottomInset: false,
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
                    entry: entry,
                    onReorder: provider.reorder,
                    onMove: provider.moveToDay,
                    head: hasAnything
                        ? null
                        : const Padding(
                            padding: EdgeInsets.only(top: 40),
                            child: EmptyState(
                              icon: Icons.beach_access_outlined,
                              title: 'Nothing scheduled',
                              message:
                                  'Add something below. Anything with a date '
                                  'on it is listed here, day by day.',
                            ),
                          ),
                    foot: days.isEmpty
                        ? null
                        : Padding(
                            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                            child: Text(
                              'Dated tasks are shown for the next '
                              '${TaskProvider.agendaDays} days.',
                              style: TextStyle(color: p.faint, fontSize: 12),
                            ),
                          ),
                    runs: [
                      // The backlog is a run like any other. It wants to be
                      // ordered by how late each thing is until somebody says
                      // otherwise, and dragging is them saying otherwise — on
                      // a screen where most of what there is to drag is often
                      // in here.
                      if (overdue.isNotEmpty)
                        _Run(
                          id: 'overdue',
                          heading: () => const _DayHeader(
                            word: 'Overdue',
                            color: AppColors.overdue,
                          ),
                          tasks: overdue,
                          takesDrops: false,
                        ),
                      for (final day in days)
                        _Run(
                          id: '$day',
                          heading: () => _DayHeader(
                            word: Dates.dayWord(day),
                            label: Dates.dayDate(day),
                          ),
                          holidays: holidays[day] ?? const <Holiday>[],
                          tasks: byDay[day]!,
                          day: day,
                        ),
                      if (undated.isNotEmpty)
                        _Run(
                          id: 'undated',
                          heading: () => const _DayHeader(word: 'No date'),
                          tasks: undated,
                        ),
                    ],
                  ),
                ),
                // The fade goes up with the field it belongs to; left at the
                // foot of the screen it would be fading the run into a strip
                // behind the keyboard.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: KeyboardLift(child: GroundFade(ground: p.bg)),
                ),
              ],
            ),
          ),
          // Opaque, now that it rides up over the run rather than sitting in
          // a slot of its own below it.
          KeyboardLift(
            child: ColoredBox(
              color: p.bg,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const KeyboardNumbers(),
                  QuickAddBar(
                    date: today,
                    controller: _quickAdd,
                    onSubmit: _addQuickTask,
                    onFullForm: () => _openEditor(null, today),
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

/// One run in the schedule: a heading, the holidays that fall on it, and the
/// tasks that can be dragged around inside it.
class _Run {
  final String id;
  final Widget Function() heading;
  final List<Holiday> holidays;
  final List<Task> tasks;

  /// The day a card dropped into this run moves to — null for No date.
  final DateTime? day;

  /// Whether a card from another run can be dropped into this one. Not the
  /// backlog: it holds many dates, so there is no one date to give a card.
  final bool takesDrops;

  const _Run({
    required this.id,
    required this.heading,
    required this.tasks,
    this.holidays = const [],
    this.day,
    this.takesDrops = true,
  });
}

/// Where in which run a carried card would be put down.
typedef _Slot = ({String run, int index});

/// The run of days: a heading and a reorderable list per run, not one list
/// with headings scattered through it.
///
/// That distinction is the whole of this widget. One list cannot tell a
/// heading from a task, so the gap it opens for the card being carried could
/// land at the very top — above the Overdue badge — and the screen appeared
/// to jump. A list per run can only open a gap inside its own run. It also
/// means the drop needs no clamping: a run holds nothing but its own tasks,
/// so there is nowhere else for one to land.
///
/// They are slivers rather than nested lists so the whole thing is still one
/// scroll, still lazy, and still auto-scrolls while a card is being carried
/// near the edge.
class _RunOfDays extends StatefulWidget {
  final ScrollController controller;
  final List<_Run> runs;
  final Color ground;
  final Widget Function(Task) entry;
  final ValueChanged<List<Task>> onReorder;

  /// Moves a task carried out of its run into another — to that run's day,
  /// in the order the run would then read.
  final Future<void> Function(Task task, DateTime? day, {List<Task>? among})
  onMove;
  final Widget? head;
  final Widget? foot;

  const _RunOfDays({
    required this.controller,
    required this.runs,
    required this.ground,
    required this.entry,
    required this.onReorder,
    required this.onMove,
    this.head,
    this.foot,
  });

  @override
  State<_RunOfDays> createState() => _RunOfDaysState();
}

class _RunOfDaysState extends State<_RunOfDays> {
  // A key on each heading, and on the footnote. They are how a card being
  // carried finds which run it is over, and they are the only rows that can
  // do the job: a row that can be dragged is lifted clean out of the list
  // while it is carried, and takes its key with it. Kept by run and reused,
  // because a key that is rebuilt is a subtree that is rebuilt.
  final _anchors = <String, GlobalKey>{};

  GlobalKey _anchorOf(String id) => _anchors.putIfAbsent(id, GlobalKey.new);

  // Each run's list, so a card carried out of it can be taken back off it.
  final _lists = <String, GlobalKey<SliverReorderableListState>>{};

  GlobalKey<SliverReorderableListState> _listOf(String id) =>
      _lists.putIfAbsent(id, GlobalKey<SliverReorderableListState>.new);

  late final _carry = Carry<_Slot>(resolve: _slotAt);

  @override
  void dispose() {
    _carry.dispose();
    super.dispose();
  }

  static double? _topOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero).dy;
  }

  static RenderBox? _cardOf(Task task) =>
      task.id == null ? null : SlideIntoPlace.boxOf('schedule', task.id!);

  /// The run a point on the screen is in, by the headings: each run runs
  /// from its own heading down to the next one.
  _Run? _runAt(double y) {
    _Run? found;
    for (final run in widget.runs) {
      final top = _topOf(_anchorOf(run.id));
      if (top == null) continue;
      if (top > y) break;
      found = run;
    }
    return found;
  }

  /// Where a card let go at [global] would go, if into a run other than its
  /// own: the run, and how many of its cards would be above it. Cards that
  /// are not built are scrolled off one end or the other, and which end is
  /// told by whether a built one has been passed yet.
  _Slot? _slotAt(Task task, Offset global) {
    final run = _runAt(global.dy);
    if (run == null || !run.takesDrops) return null;
    if (run.tasks.any((t) => t.id == task.id)) return null;
    var index = 0;
    var seen = false;
    for (var i = 0; i < run.tasks.length; i++) {
      final box = _cardOf(run.tasks[i]);
      if (box == null) {
        if (seen) break;
        index = i + 1;
        continue;
      }
      seen = true;
      final middle = box.localToGlobal(box.size.center(Offset.zero)).dy;
      if (middle >= global.dy) break;
      index = i + 1;
    }
    return (run: run.id, index: index);
  }

  /// The rule drawn where a card would be put down: along the top of the card
  /// it would go above, or the foot of the last one.
  Rect? _markOf(_Slot slot) {
    final run = widget.runs.where((r) => r.id == slot.run).firstOrNull;
    if (run == null || run.tasks.isEmpty) return null;
    final below = slot.index < run.tasks.length
        ? _cardOf(run.tasks[slot.index])
        : null;
    final box = below ?? _cardOf(run.tasks.last);
    if (box == null) return null;
    final card = TaskCard.margin.deflateRect(
      box.localToGlobal(Offset.zero) & box.size,
    );
    final y = below != null
        ? card.top - TaskCard.margin.top
        : card.bottom + TaskCard.margin.bottom;
    return Rect.fromLTRB(card.left + 8, y, card.right - 8, y);
  }

  void _drop(Task task, _Slot slot) {
    final run = widget.runs.where((r) => r.id == slot.run).firstOrNull;
    if (run == null) return;
    final among = [...run.tasks]
      ..insert(slot.index.clamp(0, run.tasks.length), task);
    widget.onMove(task, run.day, among: among);
  }

  void _move(_Run run, int oldIndex, int newIndex) {
    final ordered = [...run.tasks];
    // Flutter reports the slot the card would go into before the gap it left
    // behind is closed up.
    final to = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (to == oldIndex) return;
    ordered.insert(to, ordered.removeAt(oldIndex));
    widget.onReorder(ordered);
  }

  @override
  Widget build(BuildContext context) {
    // The builder is for a context below `DragWithin`, which is where the
    // card being carried finds the box it has to stay inside.
    return CarryArea<_Slot>(
      carry: _carry,
      onDrop: _drop,
      child: CarryMark<_Slot>(
        carry: _carry,
        mark: _markOf,
        line: true,
        child: DragWithin(child: Builder(builder: _build)),
      ),
    );
  }

  Widget _build(BuildContext context) {
    final slivers = <Widget>[
      const SliverToBoxAdapter(child: SizedBox(height: 4)),
      if (widget.head != null) SliverToBoxAdapter(child: widget.head),
    ];

    for (var i = 0; i < widget.runs.length; i++) {
      final run = widget.runs[i];
      slivers.add(
        SliverToBoxAdapter(
          child: KeyedSubtree(key: _anchorOf(run.id), child: run.heading()),
        ),
      );
      if (run.holidays.isNotEmpty) {
        slivers.add(
          SliverList.builder(
            itemCount: run.holidays.length,
            itemBuilder: (context, h) => HolidayCard(holiday: run.holidays[h]),
          ),
        );
      }
      slivers.add(
        SliverReorderableList(
          key: _listOf(run.id),
          itemCount: run.tasks.length,
          onReorder: (from, to) => _move(run, from, to),
          onReorderStart: (t) => _carry.begin(
            run.tasks[t],
            () => _listOf(run.id).currentState?.cancelReorder(),
          ),
          onReorderEnd: (_) => _carry.end(),
          // Held inside the schedule rather than inside its own run: every
          // other day on it is somewhere the card can be put down.
          proxyDecorator: (child, _, animation) => liftedCard(
            context,
            widget.ground,
            child,
            animation,
            carry: _carry,
          ),
          itemBuilder: (context, t) {
            final task = run.tasks[t];
            return ReorderableDelayedDragStartListener(
              key: ValueKey('task-${task.id}'),
              index: t,
              child: widget.entry(task),
            );
          },
        ),
      );
    }

    slivers.add(
      SliverToBoxAdapter(
        child: KeyedSubtree(
          key: _anchorOf('foot'),
          child: widget.foot ?? const SizedBox(height: 16),
        ),
      ),
    );
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 16)));
    // The keyboard's own height at the foot, so the end of the run can still
    // be scrolled clear of the keys on a screen that is not shortened for
    // them.
    slivers.add(const SliverToBoxAdapter(child: KeyboardRoom()));

    return CustomScrollView(controller: widget.controller, slivers: slivers);
  }
}

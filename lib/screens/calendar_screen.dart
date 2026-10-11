import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:provider/provider.dart';

import '../data/holidays.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/day_sheet.dart';
import '../widgets/menu_button.dart';
import '../widgets/month_grid.dart';
import '../widgets/screen_header.dart';
import '../widgets/quick_add_bar.dart';
import '../widgets/task_card.dart';
import 'search_screen.dart';
import 'task_edit_screen.dart';

/// A month grid of the user's dated tasks, with the selected day's tasks
/// listed underneath. Swipe or use the arrows to move between months, and
/// drag the grid down to open it up until every day spells out its tasks.
class CalendarScreen extends StatefulWidget {
  /// Opens the shell's menu; null when the screen is shown on its own.
  final VoidCallback? onMenu;

  const CalendarScreen({super.key, this.onMenu});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen>
    with SingleTickerProviderStateMixin {
  /// Middle of the page range; page [_basePage] shows [_baseMonth].
  static const _basePage = 6000;

  /// Height of the strip carrying the drag handle. Wide enough to be hit
  /// reliably with a thumb — at 16 the week view left almost nothing to aim
  /// at between the grid and the list.
  static const _handleHeight = 24.0;

  late final DateTime _baseMonth;
  late final PageController _controller;

  /// The day page range works the same way: page [_baseDayPage] is [_baseDay].
  static const _baseDayPage = 6000;

  late final DateTime _baseDay;
  late final PageController _dayController;

  /// Where the grid sits between its three states: -1 is the selected day's
  /// week alone, 0 the compact month with the day's tasks below it, and 1 the
  /// month opened to the full screen with each day's tasks written out.
  late final AnimationController _expansion;

  /// Pixels the grid grows or shrinks by between the states; set during
  /// layout and used to turn a drag into movement.
  double _rangeUp = 1;
  double _rangeDown = 1;

  DateTime _selected = dayOf(DateTime.now());

  /// The one-line "add a task on this day" field under the list.
  final _quickAdd = TextEditingController();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _baseMonth = DateTime(now.year, now.month);
    _controller = PageController(initialPage: _basePage);
    _baseDay = dayOf(now);
    _dayController = PageController(initialPage: _baseDayPage);
    _expansion = AnimationController(
      vsync: this,
      lowerBound: -1,
      upperBound: 1,
      value: 0,
      duration: const Duration(milliseconds: 280),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<TaskProvider>().loadMonth(_baseMonth);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _dayController.dispose();
    _expansion.dispose();
    _quickAdd.dispose();
    super.dispose();
  }

  /// Creates an all-day task on the selected day straight from the field.
  Future<void> _addQuickTask() async {
    final title = _quickAdd.text;
    _quickAdd.clear();
    await quickAddTask(context, day: _selected, title: title);
  }

  /// Where the grid stood when the current drag began; a drag is measured
  /// against it rather than against the nearest state, so a short pull still
  /// commits to the next one.
  double _dragFrom = 0;

  /// How far above the add field the content fades out into its ground.
  static const _fadeHeight = 48.0;

  /// The fade's shape. A straight ramp from clear to solid has a visible edge
  /// at each end — the point where it starts and the point where it finishes
  /// both read as lines. These follow a smoothstep instead, so it eases in and
  /// out of the two grounds and no edge is anywhere to be found.
  static const _fadeStops = [0.0, 0.2, 0.4, 0.5, 0.6, 0.8, 1.0];
  static const _fadeAlphas = [0.0, 0.104, 0.352, 0.5, 0.648, 0.896, 1.0];

  /// The ground the add field sits on, and the colour whatever is above it
  /// fades into: the calendar's own once the month is opened out, the app
  /// background while the day's tasks still have the lower half of the screen.
  Color _groundUnderField(AppPalette p) =>
      Color.lerp(p.bg, p.calendar, math.max(0.0, _expansion.value))!;

  /// Set while a pick is being carried to the two pagers, so the pages their
  /// animations pass through are not mistaken for picks of their own.
  bool _driving = false;

  /// Which way a tap steps through the states. It turns around at either end,
  /// so tapping repeatedly walks the grid open and back down again.
  int _tapDirection = 1;

  /// Snapping between states runs on a critically damped spring rather than a
  /// fixed curve: it carries the speed the finger left behind and settles
  /// without the small stop a timed ease ends on.
  static final _snapSpring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 340,
  );

  void _onDragStart(DragStartDetails details) {
    _dragFrom = _expansion.value.roundToDouble();
  }

  /// The day panel pulling past one of its ends, in pixels. Positive means
  /// the finger is going down, which is the direction that opens the month —
  /// the same sign the grid's own drag uses.
  void _onPull(double delta) {
    final value = _expansion.value;
    final range = value > 0 || (value == 0 && delta > 0)
        ? _rangeUp
        : _rangeDown;
    _expansion.value += delta / range;
  }

  void _onPullStart() => _dragFrom = _expansion.value.roundToDouble();

  void _onPullEnd() => _onDragEnd(DragEndDetails());

  void _onDrag(DragUpdateDetails details) {
    // Pulling down opens the month out, pushing up squeezes it to a week;
    // the two directions cover different distances. Exactly at the compact
    // month it is the direction of travel that says which range applies —
    // reading the value alone made an upward drag from 0 move by the opened
    // month's range and jump.
    final value = _expansion.value;
    final delta = details.primaryDelta!;
    final range = value > 0 || (value == 0 && delta > 0)
        ? _rangeUp
        : _rangeDown;
    _expansion.value += delta / range;
  }

  /// How far into the next state a drag has to reach before it counts as
  /// meaning it — a fifth of the way. Dragging the grid the whole distance
  /// was never the point; a nudge in the right direction is.
  static const _commit = 0.2;

  /// Settles on a state when the finger leaves: the one the flick points at,
  /// the one the drag has reached, or the next one along when the drag was
  /// short but deliberate.
  void _onDragEnd(DragEndDetails details) {
    // The two directions cover different distances, so pixels a second only
    // become states a second once divided by the one in play.
    final range = _expansion.value >= 0 ? _rangeUp : _rangeDown;
    final velocity = (details.primaryVelocity ?? 0) / range;
    final moved = _expansion.value - _dragFrom;

    var target = _expansion.value.roundToDouble();
    if (velocity > 0.7) {
      target = math.max(target, _dragFrom + 1);
    } else if (velocity < -0.7) {
      target = math.min(target, _dragFrom - 1);
    } else if (target == _dragFrom && moved.abs() > _commit) {
      target = _dragFrom + (moved > 0 ? 1 : -1);
    }
    _settleTo(target, velocity: velocity);
  }

  /// Runs the grid to [target] on the snap spring, keeping whatever speed the
  /// gesture ended with so the hand-off is invisible.
  void _settleTo(double target, {double velocity = 0}) {
    final to = target.clamp(-1.0, 1.0);
    if (_expansion.value == to && velocity == 0) return;
    _expansion.animateWith(
      SpringSimulation(_snapSpring, _expansion.value, to, velocity),
    );
  }

  /// A tap steps one state along instead of asking for the whole pull: from
  /// the month to the opened month, back to the month, on down to the week.
  void _toggleExpansion() {
    final state = _expansion.value.round();
    if (state >= 1) _tapDirection = -1;
    if (state <= -1) _tapDirection = 1;
    _settleTo((state + _tapDirection).toDouble());
  }

  /// How many week rows the grid of [month] needs.
  int _rowsOf(DateTime month, bool mondayFirst) {
    final first = DateTime(month.year, month.month);
    final lead = mondayFirst ? first.weekday - 1 : first.weekday % 7;
    final days = DateTime(month.year, month.month + 1, 0).day;
    return ((lead + days) / 7).ceil();
  }

  /// Moves to [day], sliding the day below the grid across to it and taking
  /// the month with it when the day is in another one.
  void _selectDay(DateTime day, {bool openSheet = true}) {
    if (day != _selected) {
      setState(() => _selected = day);
      // Both pagers report every page their animation passes through, and a
      // jump of a week reports six days nobody chose. Each of those was taken
      // for a new pick and sent the other pager off after it, which is how
      // tapping Today moved the selection back but left the grid a month away.
      _driving = true;
      Future.wait([_goToDayPage(day), _goToMonthOf(day)]).whenComplete(() {
        if (mounted) _driving = false;
      });
    }
    // Picking a day when the grid fills the screen means wanting to see that
    // day. There is nowhere left on the screen to list it out, so it opens on
    // top of the month instead — and the month is still there underneath when
    // the card is dismissed.
    if (openSheet && _expansion.value > 0.5) showDaySheet(context, day);
  }

  DateTime _monthOfPage(int page) =>
      DateTime(_baseMonth.year, _baseMonth.month + (page - _basePage));

  DateTime _dayOfPage(int page) => DateTime(
    _baseDay.year,
    _baseDay.month,
    _baseDay.day + (page - _baseDayPage),
  );

  /// Whole days between two dates. Counted in UTC, so the hour a daylight
  /// saving change adds or drops cannot round a day away.
  static int _daysBetween(DateTime from, DateTime to) => DateTime.utc(
    to.year,
    to.month,
    to.day,
  ).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

  Future<void> _goToPage(int page) => _controller.animateToPage(
    page,
    duration: const Duration(milliseconds: 260),
    curve: Curves.easeOutCubic,
  );

  /// Slides the day panel to [day]. A neighbouring day slides across; a day
  /// weeks away is not worth watching every day in between scroll past, so it
  /// is cut to straight away.
  Future<void> _goToDayPage(DateTime day) async {
    if (!_dayController.hasClients) return;
    final page = _baseDayPage + _daysBetween(_baseDay, day);
    final current = _dayController.page?.round() ?? page;
    if (current == page) return;
    if ((current - page).abs() <= 10) {
      await _dayController.animateToPage(
        page,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    } else {
      _dayController.jumpToPage(page);
    }
  }

  /// Brings the grid round to the month [day] falls in, if it is not there.
  /// A couple of months slide past; a year is cut to, for the same reason.
  Future<void> _goToMonthOf(DateTime day) async {
    final page =
        _basePage +
        (day.year - _baseMonth.year) * 12 +
        (day.month - _baseMonth.month);
    if (!_controller.hasClients) return;
    final current = _controller.page?.round() ?? page;
    if (current == page) return;
    if ((current - page).abs() <= 3) {
      await _goToPage(page);
    } else {
      _controller.jumpToPage(page);
    }
  }

  /// A month arrives under the grid: load it, and move the selection into it
  /// unless it is already there — swiping the days across a month boundary
  /// brings the month with it, and must not have the month answer back.
  void _onMonthPageChanged(int i) {
    final month = _monthOfPage(i);
    context.read<TaskProvider>().loadMonth(month);
    // The header reads its month off the controller, so every page change
    // owes it a frame — including the ones we drove ourselves, which take no
    // other path back into build.
    setState(() {});
    if (_driving) return;
    if (_selected.year == month.year && _selected.month == month.month) return;
    final today = dayOf(DateTime.now());
    final day = (today.year == month.year && today.month == month.month)
        ? today
        : month;
    _selectDay(day, openSheet: false);
  }

  void _onDayPageChanged(int i) {
    if (_driving) return;
    final day = _dayOfPage(i);
    // Fired by our own animation towards the day already chosen.
    if (day == _selected) return;
    _selectDay(day, openSheet: false);
  }

  void _jumpToToday() {
    final today = dayOf(DateTime.now());
    if (today == _selected) {
      context.read<TaskProvider>().loadMonth(DateTime(today.year, today.month));
      return;
    }
    _selectDay(today, openSheet: false);
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
    final settings = context.watch<SettingsProvider>();
    final mondayFirst = settings.weekStartsMonday;
    final country = settings.effectiveHolidayCountry;
    final page = _controller.hasClients
        ? (_controller.page?.round() ?? _basePage)
        : _basePage;
    final shownMonth = _monthOfPage(page);

    return Scaffold(
      // The month keeps the height it had when the keyboard arrives; the add
      // field lifts over it instead of the body being shortened underneath.
      resizeToAvoidBottomInset: false,
      body: Column(
        children: [
          Container(
            color: p.calendar,
            child: Column(
              children: [
                _MonthBar(
                  title: Dates.monthTitle(shownMonth),
                  onMenu: widget.onMenu,
                  onToday: _jumpToToday,
                  onSearch: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SearchScreen()),
                  ),
                ),
                AnimatedBuilder(
                  animation: _expansion,
                  builder: (context, _) => WeekdayRow(
                    mondayFirst: mondayFirst,
                    expansion: math.max(0.0, _expansion.value),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                LayoutBuilder(
                  builder: (context, box) {
                    // Three heights: one week, the compact month, and the month
                    // opened to the whole area. Whatever the grid leaves goes to the
                    // selected day's tasks.
                    final available = box.maxHeight;
                    // Enough height that a day can show a couple of lines under its
                    // number, without taking the list's half of the screen.
                    final month = (available * 0.52).clamp(240.0, 340.0);
                    final rows = _rowsOf(shownMonth, mondayFirst);
                    final week = month / rows;
                    final opened = available - _handleHeight;
                    _rangeUp = (opened - month).clamp(1.0, double.infinity);
                    _rangeDown = (month - week).clamp(1.0, double.infinity);
                    final listHeight = available - month - _handleHeight;

                    return AnimatedBuilder(
                      animation: _expansion,
                      // Hoisted out of the rebuild: nothing inside the day
                      // pager depends on how far the month is open, only the
                      // box it is given. Left in the builder, every card of
                      // every day was being rebuilt on every frame of the drag.
                      child: PageView.builder(
                        controller: _dayController,
                        onPageChanged: _onDayPageChanged,
                        itemBuilder: (context, i) {
                          final day = _dayOfPage(i);
                          return _DayPanel(
                            date: day,
                            tasks: provider.tasksForDay(day),
                            holidays:
                                Holidays.around(country, day)[day] ??
                                const <Holiday>[],
                            lists: provider.lists,
                            onDragStart: _onDragStart,
                            onDrag: _onDrag,
                            onDragEnd: _onDragEnd,
                            onPull: _onPull,
                            onPullStart: _onPullStart,
                            onPullEnd: _onPullEnd,
                            onOpen: _openEditor,
                            onToggle: provider.toggleDone,
                          );
                        },
                      ),
                      builder: (context, pager) {
                        final t = _expansion.value;
                        final gridHeight = t >= 0
                            ? month + _rangeUp * t
                            : week + _rangeDown * (1 + t);
                        final weekCollapse = t < 0 ? -t : 0.0;
                        final panelVisible =
                            (available - gridHeight - _handleHeight).clamp(
                              0.0,
                              available,
                            );
                        final panelLayout = math.max(listHeight, panelVisible);
                        return Column(
                          children: [
                            // The grid and its grip share the calendar's own ground;
                            // the day's tasks below sit on the app background.
                            ColoredBox(
                              color: p.calendar,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    height: gridHeight,
                                    child: GestureDetector(
                                      // Vertical drags open the grid; the PageView keeps
                                      // the horizontal ones for changing month. Opaque,
                                      // so a drag that starts on the padding around a day
                                      // cell is caught too rather than falling through.
                                      behavior: HitTestBehavior.opaque,
                                      onVerticalDragStart: _onDragStart,
                                      onVerticalDragUpdate: _onDrag,
                                      onVerticalDragEnd: _onDragEnd,
                                      child: PageView.builder(
                                        controller: _controller,
                                        onPageChanged: _onMonthPageChanged,
                                        itemBuilder: (context, i) => MonthGrid(
                                          month: _monthOfPage(i),
                                          selected: _selected,
                                          mondayFirst: mondayFirst,
                                          tasksByDay: provider.tasksByDay,
                                          holidaysByDay: Holidays.around(
                                            country,
                                            _monthOfPage(i),
                                          ),
                                          lists: provider.lists,
                                          expansion: math.max(0.0, t),
                                          weekCollapse: weekCollapse,
                                          onSelect: _selectDay,
                                        ),
                                      ),
                                    ),
                                  ),
                                  _DragHandle(
                                    key: calendarHandleKey,
                                    height: _handleHeight,
                                    expansion: t.abs(),
                                    onDragStart: _onDragStart,
                                    onDrag: _onDrag,
                                    onDragEnd: _onDragEnd,
                                    onTap: _toggleExpansion,
                                  ),
                                ],
                              ),
                            ),
                            // Laid out at the larger of its compact and visible
                            // sizes, so it fills the extra room a week view leaves
                            // and clips away instead of overflowing as it shrinks.
                            SizedBox(
                              height: panelVisible,
                              child: ClipRect(
                                child: OverflowBox(
                                  alignment: Alignment.topCenter,
                                  minHeight: panelLayout,
                                  maxHeight: panelLayout,
                                  child: pager,
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
                // Whatever is above the field fades into it rather than being
                // sliced off square by it — the last card in a full day used
                // to end in a straight cut across the middle of a word.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: _fadeHeight,
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _expansion,
                      builder: (context, _) {
                        final ground = _groundUnderField(p);
                        return DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              stops: _fadeStops,
                              colors: [
                                for (final a in _fadeAlphas)
                                  ground.withValues(alpha: a),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          // The strip the field sits on belongs to whatever is above it: the
          // calendar's own ground once the month is opened out, the list's
          // background while the day's tasks are still on screen.
          KeyboardLift(
            child: AnimatedBuilder(
              animation: _expansion,
              builder: (context, child) =>
                  ColoredBox(color: _groundUnderField(p), child: child),
              child: QuickAddBar(
                date: _selected,
                controller: _quickAdd,
                onSubmit: _addQuickTask,
                onFullForm: () => _openEditor(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Identifies the calendar's expand/collapse grip.
const calendarHandleKey = Key('calendar-handle');

/// The strip between the grid and the day's tasks. It draws nothing — the
/// month is dragged by the grid itself — but it keeps a band of its own for
/// drags and taps, so neither lands on the list by mistake.
class _DragHandle extends StatelessWidget {
  final double height;
  final double expansion;
  final ValueChanged<DragStartDetails> onDragStart;
  final ValueChanged<DragUpdateDetails> onDrag;
  final ValueChanged<DragEndDetails> onDragEnd;
  final VoidCallback onTap;

  const _DragHandle({
    super.key,
    required this.height,
    required this.expansion,
    required this.onDragStart,
    required this.onDrag,
    required this.onDragEnd,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragStart: onDragStart,
      onVerticalDragUpdate: onDrag,
      onVerticalDragEnd: onDragEnd,
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Semantics(
        button: true,
        label: expansion > 0.5 ? 'Collapse the month' : 'Expand the month',
        child: SizedBox(height: height, width: double.infinity),
      ),
    );
  }
}

/// Identifies the month name in the calendar header.
const monthTitleKey = Key('month-title');

/// The calendar's own header, in two rows: the controls across the top, and
/// the month name alone on the row under them. Sharing one row meant the name
/// had to be kept clear of whatever sat beside it, and it lost width on a
/// narrow phone to buttons it was nowhere near.
class _MonthBar extends StatelessWidget {
  final String title;
  final VoidCallback? onMenu;
  final VoidCallback onToday;
  final VoidCallback onSearch;

  const _MonthBar({
    required this.title,
    required this.onMenu,
    required this.onToday,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Column(
      children: [
        SizedBox(
          height: 48,
          child: Row(
            children: [
              if (onMenu != null)
                MenuButton(onTap: onMenu!)
              else
                const SizedBox(width: 12),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.search, color: p.muted),
                tooltip: 'Search',
                onPressed: onSearch,
              ),
              _TodayButton(onTap: onToday),
              const SizedBox(width: 6),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
          child: Text(
            title,
            key: monthTitleKey,
            maxLines: 1,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ],
    );
  }
}

/// Back to today, drawn as today's date on a page — the same thing a desk
/// calendar's torn-off sheet says, and it names the day it will take you to.
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

/// One day under the grid: its bar and its tasks. The days sit side by side
/// in a pager, so changing the day slides the next one in from the edge
/// rather than swapping the list out where it stands — and the days can be
/// swiped through directly.
class _DayPanel extends StatelessWidget {
  final DateTime date;
  final List<Task> tasks;
  final List<Holiday> holidays;
  final List<TaskList> lists;
  final ValueChanged<DragStartDetails> onDragStart;
  final ValueChanged<DragUpdateDetails> onDrag;
  final ValueChanged<DragEndDetails> onDragEnd;

  /// Pulling the day's list past either of its ends drives the grid. The
  /// panel is most of the screen, and a swipe on it that had nowhere else to
  /// go should open or close the month rather than do nothing at all.
  final void Function(double delta) onPull;
  final VoidCallback onPullStart;
  final VoidCallback onPullEnd;
  final ValueChanged<Task> onOpen;
  final ValueChanged<Task> onToggle;

  const _DayPanel({
    required this.date,
    required this.tasks,
    required this.holidays,
    required this.lists,
    required this.onDragStart,
    required this.onDrag,
    required this.onDragEnd,
    required this.onPull,
    required this.onPullStart,
    required this.onPullEnd,
    required this.onOpen,
    required this.onToggle,
  });

  TaskList? _listOf(Task task) {
    for (final list in lists) {
      if (list.id == task.listId) return list;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // The bar takes vertical drags too: from the week view the grid is a
        // thin strip, and this is the obvious thing to pull on. The pager
        // around it keeps the horizontal ones for changing day.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: onDragStart,
          onVerticalDragUpdate: onDrag,
          onVerticalDragEnd: onDragEnd,
          child: _DayBar(date: date),
        ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification) onPullStart();
              if (notification is ScrollEndNotification) onPullEnd();
              // A short day's list cannot scroll at all, so every drag on it
              // arrives here as overscroll; a long one only once it has run
              // out of list to give.
              if (notification is OverscrollNotification &&
                  notification.dragDetails != null) {
                onPull(-notification.overscroll);
              }
              return false;
            },
            child: tasks.isEmpty && holidays.isEmpty
                ? const EmptyState(
                    icon: Icons.event_available_outlined,
                    title: 'Nothing on this day',
                    message: 'Add one in the field below.',
                  )
                : ListView(
                    padding: const EdgeInsets.only(top: 4, bottom: 8),
                    children: [
                      for (final holiday in holidays)
                        HolidayCard(holiday: holiday),
                      for (final task in tasks)
                        TaskCard(
                          task: task,
                          list: _listOf(task),
                          onTap: () => onOpen(task),
                          onLongPress: () => onOpen(task),
                          onToggle: () => onToggle(task),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// The bar between the grid and the day's task list: the day it is showing,
/// and nothing else. The count and the button beside it were noise on a bar
/// whose whole job is to say which day is below it.
///
/// It sits on the same ground as the day below it. A shade of its own made a
/// band across the screen and cut the day in two — the date and the things on
/// that date are one panel, and the bar is only the top of it.
class _DayBar extends StatelessWidget {
  final DateTime date;

  const _DayBar({required this.date});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Container(
      color: p.bg,
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            '${date.day}',
            style: TextStyle(
              color: p.text,
              fontSize: 26,
              height: 1,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            Dates.weekdayShort(date),
            style: TextStyle(
              color: p.muted,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/holidays.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/carry.dart';
import '../widgets/day_sheet.dart';
import '../widgets/menu_button.dart';
import '../widgets/month_grid.dart';
import '../widgets/screen_header.dart';
import '../widgets/tick_off.dart';
import '../widgets/quick_add_bar.dart';
import '../widgets/reorderable_task_list.dart';
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
    with TickerProviderStateMixin {
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

  /// The grid's box, for finding the day a carried card is held over.
  final _grid = GlobalKey();

  /// A card carried up out of the day's list, perhaps onto another day.
  late final _carry = Carry<DateTime>(resolve: _dayUnder, shrinkTo: _dayTile);

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
    _carry.addListener(_watchEdges);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<TaskProvider>().loadMonth(_baseMonth);
    });
  }

  @override
  void dispose() {
    _turning?.cancel();
    _hold.dispose();
    _edgeShown.dispose();
    _carry.dispose();
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

  /// How tall the day panel under the grid is drawn this frame. Kept from
  /// the layout so the add field can tell what it is standing over once the
  /// keyboard has lifted it out of its own slot.
  double _panelVisible = 0;

  /// How far the field has climbed past the day panel and over the grid, as
  /// a fraction of the fade above it: nothing while it is over the panel or
  /// in its own slot, all of it once the keyboard has carried it a fade's
  /// height onto the month.
  double _overGrid(double lift) =>
      ((lift - _panelVisible) / GroundFade.height).clamp(0.0, 1.0);

  /// The ground the add field sits on, and the colour whatever is above it
  /// fades into — which is whatever it is actually standing over. The
  /// calendar's black once the month is opened out, the panel's grey while
  /// the day's tasks have the lower half of the screen, and the black again
  /// when the keyboard has lifted the field up past the panel onto the grid:
  /// it used to keep the panel's grey wherever it went, and rode up over
  /// the month as a grey slab.
  Color _groundUnderField(AppPalette p, double lift) => Color.lerp(
    p.panel,
    p.calendar,
    math.max(math.max(0.0, _expansion.value), _overGrid(lift)),
  )!;

  /// How much of the fade to draw. It is for something running under the
  /// field: the day's tasks while they are on screen, and the grid itself
  /// once the keyboard has lifted the field over it. Opened out with the
  /// keyboard down, the grid ends above the field and there is nothing to
  /// soften — but with the keyboard up the field sits across the month, and
  /// without the fade it cut the week under it off square.
  double _fadeStrength(double lift) => math.max(
    1 - _expansion.value.clamp(0.0, 1.0),
    (lift / GroundFade.height).clamp(0.0, 1.0),
  );

  /// Set while a pick is being carried to the two pagers, so the pages their
  /// animations pass through are not mistaken for picks of their own.
  bool _driving = false;

  /// Which way a tap steps through the states. It turns around at either end,
  /// so tapping repeatedly walks the grid open and back down again.
  int _tapDirection = 1;

  /// How long a snap from one state to the next takes from a standstill. It
  /// was a spring, made softer twice on request ("a little bit slower"),
  /// and softer was worse: a soft spring crept the last few points for most
  /// of a second, and a flick carried it past the state and back, which at
  /// either end was cut off at the bound — reported as "not smooth". See
  /// [_Glide].
  static const _snap = Duration(milliseconds: 420);

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

  /// Runs the grid to [target], keeping whatever speed the gesture ended
  /// with so the hand-off is invisible.
  void _settleTo(double target, {double velocity = 0}) {
    final to = target.clamp(-1.0, 1.0);
    if (_expansion.value == to) return;
    _expansion.animateWith(
      _Glide(from: _expansion.value, to: to, velocity: velocity, full: _snap),
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
    final carried = _carry.task;
    context.read<TaskProvider>().loadMonth(month, keep: carried?.dueDay);
    // The header reads its month off the controller, so every page change
    // owes it a frame — including the ones we drove ourselves, which take no
    // other path back into build.
    setState(() {});
    // A task carried across months: the day it was picked up from is still
    // the day below the grid, holding its list, until the carry is over.
    if (_driving || carried != null) return;
    _followMonth(month);
  }

  /// Picks the day to show for a month the grid has been turned to: today
  /// if it is in it, its first otherwise.
  void _followMonth(DateTime month) {
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

  /// How long a carried card has to be held at the side of the grid before
  /// the month turns, and how long between turns after that. Held, not
  /// touched: the outer columns are days too, and a card passing through
  /// one on its way to be dropped there must not set the month going.
  static const _edgeHold = Duration(milliseconds: 600);
  static const _edgeRepeat = Duration(milliseconds: 900);

  /// How close to the side of the grid counts as at it — under half a day's
  /// width, so the outer days can still be aimed at.
  static const _edgeWidth = 24.0;

  /// Which way the month is about to turn while a card is held at a side.
  int _edge = 0;

  /// The same, for the hints drawn at the sides, which only need to hear
  /// when it changes.
  final _edgeShown = ValueNotifier<int>(0);

  /// How far into the hold before the next turn: the side being held fills
  /// over it, so the wait is something to watch rather than a pause that
  /// looks like nothing happening.
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: _edgeHold,
  );
  Timer? _turning;
  bool _carrying = false;

  /// Turns the month under a card held at either side of the grid, and puts
  /// the day below the grid back in step once the carry is over.
  void _watchEdges() {
    final active = _carry.active;
    if (_carrying && !active) {
      _carrying = false;
      _edge = 0;
      _edgeShown.value = 0;
      _hold.value = 0;
      _turning?.cancel();
      // Turned to another month and let go without a drop: show a day of
      // the month on show, as turning it would have without a card.
      final page = _controller.hasClients
          ? (_controller.page?.round() ?? _basePage)
          : _basePage;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_carry.active) _followMonth(_monthOfPage(page));
      });
      return;
    }
    _carrying = active;
    if (!active) return;

    var edge = 0;
    final pointer = _carry.pointer;
    final box = _grid.currentContext?.findRenderObject() as RenderBox?;
    if (pointer != null && box != null && box.attached && box.hasSize) {
      final local = box.globalToLocal(pointer);
      if (local.dy >= 0 && local.dy < box.size.height) {
        if (local.dx < _edgeWidth) edge = -1;
        if (local.dx > box.size.width - _edgeWidth) edge = 1;
      }
    }
    if (edge == _edge) return;
    _edge = edge;
    _edgeShown.value = edge;
    _turning?.cancel();
    if (edge != 0) {
      _turning = Timer(_edgeHold, _turn);
      _hold
        ..duration = _edgeHold
        ..forward(from: 0);
    } else {
      _hold.value = 0;
    }
  }

  void _turn() {
    if (!mounted || !_carry.active || _edge == 0 || !_controller.hasClients) {
      return;
    }
    final page = _controller.page?.round() ?? _basePage;
    _controller
        .animateToPage(
          page + _edge,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        )
        .then((_) => _carry.refresh());
    _turning = Timer(_edgeRepeat, _turn);
    _hold
      ..duration = _edgeRepeat
      ..forward(from: 0);
  }

  /// Where the days of the month on show fall in the grid's box, now — the
  /// grid may be anywhere between its week and its opened month.
  (MonthLayout, RenderBox)? _gridLayout() {
    final box = _grid.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    final page = _controller.hasClients
        ? (_controller.page?.round() ?? _basePage)
        : _basePage;
    final t = _expansion.value;
    final layout = MonthLayout(
      month: _monthOfPage(page),
      mondayFirst: context.read<SettingsProvider>().weekStartsMonday,
      selected: _selected,
      weekCollapse: t < 0 ? -t : 0,
      size: box.size,
    );
    return (layout, box);
  }

  /// The day a carried card is held over in the grid, unless it is the day
  /// the card already belongs to.
  DateTime? _dayUnder(Task task, Offset global) {
    final found = _gridLayout();
    if (found == null) return null;
    final (layout, box) = found;
    final day = layout.dayAt(box.globalToLocal(global));
    return day == null || day == task.dueDay ? null : day;
  }

  /// Over the grid, a carried card is drawn as a tile the size of a day,
  /// under the finger and moving with it. Not in the day: the day it would
  /// land on is the outline's to say, and a tile that jumped from cell to
  /// cell was asked to "move freely without sticking".
  Rect? _dayTile(Offset global) {
    final found = _gridLayout();
    if (found == null) return null;
    final (layout, box) = found;
    if (!(Offset.zero & box.size).contains(box.globalToLocal(global))) {
      return null;
    }
    // Held to a day's shape where the rows are tall — the week view's single
    // row is most of the grid.
    final cell = layout.cellSize;
    final tile = Rect.fromCenter(
      center: global,
      width: cell.width - 4,
      height: math.min(cell.height, cell.width) - 6,
    );
    // Kept on the grid: held at a side to turn the month, a tile centred on
    // the finger was half off the screen.
    final grid = box.localToGlobal(Offset.zero) & box.size;
    return tile.shift(
      Offset(
        tile.left < grid.left
            ? grid.left - tile.left
            : math.min(0, grid.right - tile.right),
        tile.top < grid.top
            ? grid.top - tile.top
            : math.min(0, grid.bottom - tile.bottom),
      ),
    );
  }

  /// The cell of the day a carried card would be put down on, on the screen.
  Rect? _cellOf(DateTime day) {
    final found = _gridLayout();
    if (found == null) return null;
    final (layout, box) = found;
    final cell = layout.rectOf(day);
    if (cell == null) return null;
    // Clipped to the grid: in the week view the rows above and below are
    // slid out of its window.
    final visible = cell.intersect(Offset.zero & box.size);
    if (visible.isEmpty) return null;
    return box.localToGlobal(visible.topLeft) & visible.size;
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
                // A card picked up in the day's list can be carried up onto
                // the month and let go on another day. The calendar is its
                // box rather than the list, and the day it would land on is
                // outlined over everything, the card included.
                CarryArea<DateTime>(
                  carry: _carry,
                  onDrop: (task, day) {
                    // Put down in another month, the day it went to is the
                    // one shown — the day it came from is a turn or more away
                    // and no longer loaded.
                    if (day.year != _selected.year ||
                        day.month != _selected.month) {
                      _selectDay(day, openSheet: false);
                    }
                    context.read<TaskProvider>().moveToDay(task, day);
                  },
                  child: CarryMark<DateTime>(
                    carry: _carry,
                    mark: _cellOf,
                    line: false,
                    child: DragWithin(
                      child: LayoutBuilder(
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
                          _rangeUp = (opened - month).clamp(
                            1.0,
                            double.infinity,
                          );
                          _rangeDown = (month - week).clamp(
                            1.0,
                            double.infinity,
                          );
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
                                  onToggle: (task) => tickOff(context, task),
                                  isLeaving: provider.isLeaving,
                                  isTicking: provider.isTicking,
                                  rearranging: provider.rearranging,
                                  onReorder: provider.reorder,
                                  carry: _carry,
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
                                  (available - gridHeight - _handleHeight)
                                      .clamp(0.0, available);
                              final panelLayout = math.max(
                                listHeight,
                                panelVisible,
                              );
                              _panelVisible = panelVisible;
                              return Column(
                                children: [
                                  // The grid and its grip share the calendar's own
                                  // ground; the day below sits on a grey of its own,
                                  // so the month and the day it is showing read as
                                  // two surfaces rather than one dark field.
                                  ColoredBox(
                                    color: p.calendar,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Stack(
                                          children: [
                                            SizedBox(
                                              key: _grid,
                                              height: gridHeight,
                                              child: GestureDetector(
                                                // Vertical drags open the grid; the PageView keeps
                                                // the horizontal ones for changing month. Opaque,
                                                // so a drag that starts on the padding around a day
                                                // cell is caught too rather than falling through.
                                                behavior:
                                                    HitTestBehavior.opaque,
                                                onVerticalDragStart:
                                                    _onDragStart,
                                                onVerticalDragUpdate: _onDrag,
                                                onVerticalDragEnd: _onDragEnd,
                                                child: PageView.builder(
                                                  controller: _controller,
                                                  onPageChanged:
                                                      _onMonthPageChanged,
                                                  itemBuilder: (context, i) =>
                                                      MonthGrid(
                                                        month: _monthOfPage(i),
                                                        selected: _selected,
                                                        mondayFirst:
                                                            mondayFirst,
                                                        tasksByDay:
                                                            provider.tasksByDay,
                                                        holidaysByDay:
                                                            Holidays.around(
                                                              country,
                                                              _monthOfPage(i),
                                                            ),
                                                        lists: provider.lists,
                                                        expansion: math.max(
                                                          0.0,
                                                          t,
                                                        ),
                                                        weekCollapse:
                                                            weekCollapse,
                                                        onSelect: _selectDay,
                                                      ),
                                                ),
                                              ),
                                            ),
                                            // Where holding a carried task turns the month.
                                            Positioned.fill(
                                              child: IgnorePointer(
                                                child: _EdgeHints(
                                                  carry: _carry,
                                                  edge: _edgeShown,
                                                  hold: _hold,
                                                ),
                                              ),
                                            ),
                                          ],
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
                                    child: ColoredBox(
                                      color: p.panel,
                                      child: ClipRect(
                                        child: OverflowBox(
                                          alignment: Alignment.topCenter,
                                          minHeight: panelLayout,
                                          maxHeight: panelLayout,
                                          child: pager,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                ),
                // Whatever is above the field fades into it rather than being
                // sliced off square by it — the last card in a full day used
                // to end in a straight cut across the middle of a word. The
                // fade belongs to the field, so it goes up with it: left at
                // the foot of the screen it would fade the day into a strip
                // the keyboard is sitting on, and the field, now halfway up
                // the panel, would be back to slicing cards in half.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: KeyboardLift(
                    child: AnimatedBuilder(
                      animation: Listenable.merge([
                        _expansion,
                        KeyboardGap.instance.covered,
                      ]),
                      builder: (context, _) {
                        final lift = KeyboardGap.of(context);
                        return GroundFade(
                          ground: _groundUnderField(p, lift),
                          strength: _fadeStrength(lift),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          // The strip the field sits on belongs to whatever it is over: see
          // _groundUnderField.
          KeyboardLift(
            child: AnimatedBuilder(
              animation: Listenable.merge([
                _expansion,
                KeyboardGap.instance.covered,
              ]),
              builder: (context, child) => ColoredBox(
                color: _groundUnderField(p, KeyboardGap.of(context)),
                child: child,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const KeyboardNumbers(),
                  QuickAddBar(
                    date: _selected,
                    controller: _quickAdd,
                    onSubmit: _addQuickTask,
                    onFullForm: () => _openEditor(),
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

/// Identifies the calendar's expand/collapse grip.
/// A snap from where the grid is to [to] that starts at the speed the finger
/// left it with and comes to rest exactly at [to], at a set time.
///
/// A cubic with the starting speed and a stop at the end: from a standstill
/// it is an ease in and out, from a flick an ease out. The starting speed is
/// capped at three times the average — the slope at which the curve only just
/// stays short of the target — and a flick faster than that shortens the
/// glide to match it instead, so nothing ever overshoots. A short distance is
/// covered in less time than a whole one, as a spring would.
class _Glide extends Simulation {
  final double from;
  final double to;
  late final double _seconds;
  late final double _slope;

  _Glide({
    required this.from,
    required this.to,
    required double velocity,
    required Duration full,
  }) {
    final distance = (to - from).abs();
    final towards = velocity * (to - from).sign;
    var seconds =
        full.inMicroseconds /
        Duration.microsecondsPerSecond *
        math.sqrt(distance);
    if (towards * seconds > 3 * distance) {
      seconds = math.max(0.2, 3 * distance / towards);
    }
    _seconds = seconds;
    _slope = (towards * seconds / distance).clamp(0.0, 3.0);
  }

  double _s(double time) => (time / _seconds).clamp(0.0, 1.0);

  @override
  double x(double time) {
    final s = _s(time);
    final eased =
        _slope * (s * s * s - 2 * s * s + s) + (3 * s * s - 2 * s * s * s);
    return from + (to - from) * eased;
  }

  @override
  double dx(double time) {
    final s = _s(time);
    final slope = _slope * (3 * s * s - 4 * s + 1) + (6 * s - 6 * s * s);
    return (to - from) * slope / _seconds;
  }

  @override
  bool isDone(double time) => time >= _seconds;
}

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
  final bool Function(Task) isLeaving;
  final bool Function(Task) isTicking;
  final Listenable rearranging;
  final ValueChanged<List<Task>> onReorder;
  final Carry<DateTime> carry;

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
    required this.isLeaving,
    required this.isTicking,
    required this.rearranging,
    required this.onReorder,
    required this.carry,
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
            // An empty day has no list to pull past its ends, so the whole
            // panel takes the drag itself, as the bar above it does. Before,
            // only the placeholder's own little scroll view answered — most
            // of the panel did nothing, and a drag on the words moved the
            // grid a few points and left it stuck between states.
            child: tasks.isEmpty && holidays.isEmpty
                ? GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragStart: onDragStart,
                    onVerticalDragUpdate: onDrag,
                    onVerticalDragEnd: onDragEnd,
                    child: const EmptyState(
                      icon: Icons.event_available_outlined,
                      title: 'Nothing on this day',
                      message: 'Add one in the field below.',
                      scrolls: false,
                    ),
                  )
                : ReorderableTaskList(
                    padding: const EdgeInsets.only(top: 4, bottom: 8),
                    ground: AppTheme.of(context).panel,
                    holidays: holidays,
                    tasks: tasks,
                    listOf: _listOf,
                    onOpen: onOpen,
                    onToggle: onToggle,
                    isLeaving: isLeaving,
                    isTicking: isTicking,
                    rearranging: rearranging,
                    scope: 'calendar',
                    onReorder: onReorder,
                    carry: carry,
                    // Held inside the calendar instead, grid and all: the
                    // month above is where it can be carried to.
                    penned: false,
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
      color: p.panel,
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
              // Digits are laid out in boxes of one width so columns of them
              // line up, which at this size leaves a hole between the ones of
              // an 11. Nothing here is in a column, so the space is pulled
              // back out.
              letterSpacing: -1.6,
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

/// What says a carried task can be taken to another month: a small tab at
/// the middle of each side of the grid, with a chevron in it.
///
/// Both show the moment a task is carried over the month — the turning is
/// otherwise invisible until it happens, and nobody holds a card against the
/// edge of the screen on the off chance. The side the finger is at widens a
/// little and fills from the bottom over the hold ([hold]), its chevron
/// brightening and nudging outwards, so waiting there reads as the month
/// being about to go. They are in the carried tile's own terms — the add
/// field's grey, a light rim, round corners — where the first try, a
/// gradient down the whole height of each side, read as a shadow fallen
/// across the days.
class _EdgeHints extends StatelessWidget {
  final Carry<DateTime> carry;
  final ValueListenable<int> edge;
  final Animation<double> hold;

  const _EdgeHints({
    required this.carry,
    required this.edge,
    required this.hold,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([carry, edge]),
      builder: (context, _) => AnimatedOpacity(
        // Only while the card is over the month, which is when it is a tile.
        opacity: carry.shrink == null ? 0 : 1,
        duration: const Duration(milliseconds: 160),
        child: AnimatedBuilder(
          animation: hold,
          builder: (context, _) => Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [_tab(p, -1), const Spacer(), _tab(p, 1)],
          ),
        ),
      ),
    );
  }

  Widget _tab(AppPalette p, int side) {
    final held = edge.value == side;
    final fill = held ? Curves.easeOut.transform(hold.value) : 0.0;
    const height = 58.0;
    final radius = BorderRadius.circular(12);
    return Padding(
      // Narrow and close to the edge, so it stays clear of the numbers of the
      // outer days even widened — held, it covered the 18 beside it.
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        width: held ? 24 : 20,
        height: height,
        decoration: BoxDecoration(
          color: p.field,
          borderRadius: radius,
          border: Border.all(
            color: Colors.white.withValues(alpha: held ? 0.4 : 0.16),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // The hold, filling from the bottom: full is the month turning.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: height * fill,
                child: ColoredBox(color: p.text.withValues(alpha: 0.18)),
              ),
              Transform.translate(
                // Out towards the month it will turn to, a little further the
                // longer it is held.
                offset: Offset(side * 2.5 * fill, 0),
                child: Icon(
                  side < 0
                      ? Icons.chevron_left_rounded
                      : Icons.chevron_right_rounded,
                  size: 20,
                  color: held ? p.text : p.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:provider/provider.dart';

import '../data/holidays.dart';
import '../models/task.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/gradient_icon_button.dart';
import '../widgets/month_grid.dart';
import '../widgets/screen_header.dart';
import '../widgets/task_card.dart';
import 'task_edit_screen.dart';

/// A month grid of the user's dated tasks, with the selected day's tasks
/// listed underneath. Swipe or use the arrows to move between months, and
/// drag the grid down to open it up until every day spells out its tasks.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

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
    _expansion.dispose();
    _quickAdd.dispose();
    super.dispose();
  }

  /// Creates an all-day task on the selected day straight from the field.
  Future<void> _addQuickTask() async {
    final title = _quickAdd.text.trim();
    if (title.isEmpty) return;
    final provider = context.read<TaskProvider>();
    final lists = provider.lists;
    _quickAdd.clear();
    await provider.add(
      Task(
        listId: lists.isNotEmpty ? lists.first.id! : 1,
        title: title,
        dueAt: _selected.millisecondsSinceEpoch,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// Where the grid stood when the current drag began; a drag is measured
  /// against it rather than against the nearest state, so a short pull still
  /// commits to the next one.
  double _dragFrom = 0;

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

  void _selectDay(DateTime day) {
    setState(() => _selected = day);
    // Picking a day when the grid fills the screen means wanting to see that
    // day, so make room for it.
    if (_expansion.value > 0.5) _settleTo(0);
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
    final page =
        _basePage +
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
    final settings = context.watch<SettingsProvider>();
    final mondayFirst = settings.weekStartsMonday;
    final country = settings.effectiveHolidayCountry;
    final dayHolidays =
        Holidays.around(country, _selected)[_selected] ?? const <Holiday>[];
    final page = _controller.hasClients
        ? (_controller.page?.round() ?? _basePage)
        : _basePage;
    final shownMonth = _monthOfPage(page);
    final dayTasks = provider.tasksForDay(_selected);

    return Scaffold(
      body: Column(
        children: [
          Container(
            color: p.calendar,
            child: Column(
              children: [
                _MonthBar(
                  title: Dates.monthTitle(shownMonth),
                  onPrevious: () => _goToPage(page - 1),
                  onToday: _jumpToToday,
                  onNext: () => _goToPage(page + 1),
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
                _rangeUp = (opened - month).clamp(1.0, double.infinity);
                _rangeDown = (month - week).clamp(1.0, double.infinity);
                final listHeight = available - month - _handleHeight;

                return AnimatedBuilder(
                  animation: _expansion,
                  builder: (context, _) {
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
                                    onPageChanged: (i) {
                                      final month = _monthOfPage(i);
                                      context.read<TaskProvider>().loadMonth(
                                        month,
                                      );
                                      // Keep the selection inside the month in view.
                                      setState(() {
                                        final today = dayOf(DateTime.now());
                                        _selected =
                                            (today.year == month.year &&
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
                              child: Column(
                                children: [
                                  // The bar takes drags too: from the week
                                  // view the grid is a thin strip, and this
                                  // is the obvious thing to pull on.
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onVerticalDragStart: _onDragStart,
                                    onVerticalDragUpdate: _onDrag,
                                    onVerticalDragEnd: _onDragEnd,
                                    child: _DayBar(
                                      date: _selected,
                                      count: dayTasks
                                          .where((t) => !t.done)
                                          .length,
                                      onAdd: () => _openEditor(),
                                    ),
                                  ),
                                  Expanded(
                                    child:
                                        dayTasks.isEmpty && dayHolidays.isEmpty
                                        ? EmptyState(
                                            icon:
                                                Icons.event_available_outlined,
                                            title: 'Nothing on this day',
                                            message:
                                                'Add one below, or tap + '
                                                'for the full form.',
                                          )
                                        : ListView(
                                            padding: const EdgeInsets.only(
                                              top: 4,
                                              bottom: 8,
                                            ),
                                            children: [
                                              for (final holiday in dayHolidays)
                                                _HolidayCard(holiday: holiday),
                                              for (final task in dayTasks)
                                                TaskCard(
                                                  task: task,
                                                  list: provider.listById(
                                                    task.listId,
                                                  ),
                                                  onTap: () =>
                                                      _openEditor(task),
                                                  onLongPress: () =>
                                                      _openEditor(task),
                                                  onToggle: () =>
                                                      provider.toggleDone(task),
                                                ),
                                            ],
                                          ),
                                  ),
                                ],
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
          _QuickAddBar(
            date: _selected,
            controller: _quickAdd,
            onSubmit: _addQuickTask,
          ),
        ],
      ),
    );
  }
}

/// A public holiday under the calendar: the same card as a task, in green
/// and with nothing to tick off.
class _HolidayCard extends StatelessWidget {
  final Holiday holiday;

  const _HolidayCard({required this.holiday});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: AppColors.holiday.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.holiday.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.celebration_outlined,
              color: AppColors.holiday,
              size: 22,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    holiday.name,
                    style: TextStyle(
                      color: p.text,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Public holiday',
                    style: TextStyle(color: p.muted, fontSize: 12.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The field under the list: type a title, tap +, and it lands on the day in
/// view without opening the full form.
class _QuickAddBar extends StatelessWidget {
  final DateTime date;
  final TextEditingController controller;
  final VoidCallback onSubmit;

  const _QuickAddBar({
    required this.date,
    required this.controller,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => onSubmit(),
              style: TextStyle(color: p.text, fontSize: 14.5),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Add task on ${Dates.shortDay(date)}',
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(26),
                  borderSide: BorderSide(color: p.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(26),
                  borderSide: BorderSide(color: p.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(26),
                  borderSide: BorderSide(
                    color: AppTheme.accentOf(context).color,
                    width: 1.5,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          GradientIconButton(
            icon: Icons.add,
            size: 48,
            circle: true,
            tooltip: 'Add task',
            onTap: onSubmit,
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

/// The calendar's own header: the month centred on the screen with its
/// controls floating at the right, so the name sits in the middle however
/// many buttons sit beside it.
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
      // Symmetric, so the centred month name lands on the screen's midline.
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
      child: SizedBox(
        height: 36,
        child: Stack(
          children: [
            Align(
              alignment: Alignment.center,
              // Kept clear of the controls on both sides so the name stays
              // centred on the screen, shrinking a hair rather than running
              // under a button on a narrow phone.
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 118),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
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
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
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
            ),
          ],
        ),
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

  const _DayBar({required this.date, required this.count, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Container(
      color: p.sidebar,
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
          const Spacer(),
          if (count > 0)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(
                '$count open',
                style: TextStyle(color: p.muted, fontSize: 12.5),
              ),
            ),
          GradientIconButton(
            icon: Icons.edit_calendar_outlined,
            size: 34,
            tooltip: 'Add with a full form',
            onTap: onAdd,
          ),
        ],
      ),
    );
  }
}

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

  /// Height of the strip carrying the drag handle.
  static const _handleHeight = 22.0;

  late final DateTime _baseMonth;
  late final PageController _controller;

  /// 0 = compact grid with the day's tasks below, 1 = grid opened to the full
  /// screen with each day's tasks written out.
  late final AnimationController _expansion;

  /// How many pixels the grid grows by between the two states; set during
  /// layout and used to turn a drag into expansion.
  double _range = 1;

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
    await provider.add(Task(
      listId: lists.isNotEmpty ? lists.first.id! : 1,
      title: title,
      dueAt: _selected.millisecondsSinceEpoch,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  void _onDrag(DragUpdateDetails details) {
    _expansion.value += details.primaryDelta! / _range;
  }

  /// Snaps open or shut, following the flick when there is one. The drag
  /// itself tracks the finger exactly; only the snap is eased.
  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final open = velocity.abs() > 240 ? velocity > 0 : _expansion.value > 0.5;
    _snapTo(open);
  }

  void _snapTo(bool open) {
    if (open) {
      _expansion.animateTo(1, curve: Curves.easeOutCubic);
    } else {
      _expansion.animateBack(0, curve: Curves.easeOutCubic);
    }
  }

  void _toggleExpansion() => _snapTo(_expansion.value <= 0.5);

  void _selectDay(DateTime day) {
    setState(() => _selected = day);
    // Picking a day when the grid fills the screen means wanting to see that
    // day, so make room for it.
    if (_expansion.value > 0.5) _snapTo(false);
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
    final provider = context.watch<TaskProvider>();
    final mondayFirst = context.watch<SettingsProvider>().weekStartsMonday;
    final page = _controller.hasClients
        ? (_controller.page?.round() ?? _basePage)
        : _basePage;
    final shownMonth = _monthOfPage(page);
    final dayTasks = provider.tasksForDay(_selected);

    return Scaffold(
      body: Column(
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
              expansion: _expansion.value,
            ),
          ),
          Expanded(
            child: LayoutBuilder(builder: (context, box) {
              // The grid runs from a compact six-row block to the whole area;
              // whatever it leaves goes to the selected day's tasks.
              final available = box.maxHeight;
              // Enough height that a day can show a couple of lines under its
              // number, without taking the list's half of the screen.
              final collapsed = (available * 0.52).clamp(240.0, 340.0);
              final opened = available - _handleHeight;
              _range = (opened - collapsed).clamp(1.0, double.infinity);
              final listHeight = available - collapsed - _handleHeight;

              return AnimatedBuilder(
                animation: _expansion,
                builder: (context, _) {
                  final t = _expansion.value;
                  final gridHeight = collapsed + _range * t;
                  return Column(
                    children: [
                      SizedBox(
                        height: gridHeight,
                        child: GestureDetector(
                          // Vertical drags open the grid; the PageView keeps
                          // the horizontal ones for changing month.
                          onVerticalDragUpdate: _onDrag,
                          onVerticalDragEnd: _onDragEnd,
                          child: PageView.builder(
                            controller: _controller,
                            onPageChanged: (i) {
                              final month = _monthOfPage(i);
                              context.read<TaskProvider>().loadMonth(month);
                              // Keep the selection inside the month in view.
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
                              expansion: t,
                              onSelect: _selectDay,
                            ),
                          ),
                        ),
                      ),
                      _DragHandle(
                        key: calendarHandleKey,
                        height: _handleHeight,
                        expansion: t,
                        onDrag: _onDrag,
                        onDragEnd: _onDragEnd,
                        onTap: _toggleExpansion,
                      ),
                      // Laid out at its open size and clipped, so the panel
                      // slides away instead of overflowing as it shrinks.
                      SizedBox(
                        height: (listHeight * (1 - t)).clamp(0.0, available),
                        child: ClipRect(
                          child: OverflowBox(
                            alignment: Alignment.topCenter,
                            minHeight: listHeight,
                            maxHeight: listHeight,
                            child: Column(
                              children: [
                                _DayBar(
                                  date: _selected,
                                  count:
                                      dayTasks.where((t) => !t.done).length,
                                  onAdd: () => _openEditor(),
                                ),
                                Expanded(
                                  child: dayTasks.isEmpty
                                      ? EmptyState(
                                          icon: Icons.event_available_outlined,
                                          title: 'Nothing on this day',
                                          message: 'Add one below, or tap + '
                                              'for the full form.',
                                        )
                                      : ListView.builder(
                                          padding: const EdgeInsets.only(
                                              top: 4, bottom: 8),
                                          itemCount: dayTasks.length,
                                          itemBuilder: (context, i) {
                                            final task = dayTasks[i];
                                            return TaskCard(
                                              task: task,
                                              list: provider
                                                  .listById(task.listId),
                                              onTap: () => _openEditor(task),
                                              onLongPress: () =>
                                                  _openEditor(task),
                                              onToggle: () =>
                                                  provider.toggleDone(task),
                                            );
                                          },
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
            }),
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
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
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

/// The grip between the grid and the day's tasks. Dragging it opens the month
/// out; a tap snaps it open or shut.
class _DragHandle extends StatelessWidget {
  final double height;
  final double expansion;
  final ValueChanged<DragUpdateDetails> onDrag;
  final ValueChanged<DragEndDetails> onDragEnd;
  final VoidCallback onTap;

  const _DragHandle({
    super.key,
    required this.height,
    required this.expansion,
    required this.onDrag,
    required this.onDragEnd,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context);
    return GestureDetector(
      onVerticalDragUpdate: onDrag,
      onVerticalDragEnd: onDragEnd,
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Semantics(
        button: true,
        label: expansion > 0.5 ? 'Collapse the month' : 'Expand the month',
        child: SizedBox(
          height: height,
          child: Center(
            child: Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: Color.lerp(p.border, accent.color, expansion),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
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

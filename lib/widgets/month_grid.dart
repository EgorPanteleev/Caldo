import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../data/holidays.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../providers/task_provider.dart' show dayOf;
import '../theme/app_theme.dart';
import '../utils/dates.dart';

/// How visible the rules between the weeks are: nothing until the grid is
/// nearly all the way open, so they arrive as the month finishes opening and
/// are gone the moment it starts closing.
double weekRuleAlpha(double expansion) =>
    ((expansion - 0.75) / 0.25).clamp(0.0, 1.0);

/// The Mon…Sun (or Sun…Sat) column headings that sit above a [MonthGrid].
class WeekdayRow extends StatelessWidget {
  final bool mondayFirst;

  /// How far the grid below is opened; the headings are underlined by the
  /// same rule that separates the weeks, so the two arrive together.
  final double expansion;

  const WeekdayRow({super.key, required this.mondayFirst, this.expansion = 0});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final labels = Dates.weekdayLabels(mondayFirst: mondayFirst);
    return Padding(
      // Inset to match the grid, so the rule lines up with the week rules.
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: p.border.withValues(alpha: weekRuleAlpha(expansion)),
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 6),
          child: Row(
            children: [
              for (var i = 0; i < labels.length; i++)
                Expanded(
                  child: Center(
                    child: Text(
                      labels[i],
                      style: TextStyle(
                        // Sunday sits last when the week starts on Monday
                        // and first when it starts on Sunday.
                        color: i == (mondayFirst ? 6 : 0)
                            ? AppColors.weekend.withValues(alpha: 0.75)
                            : p.faint,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Where the days of a [MonthGrid] fall inside it, for a grid of [size].
///
/// The grid lays itself out from this, and so does anything that has to find
/// a day in it from a point on the screen — a task card carried over the
/// month — so the two cannot come apart.
class MonthLayout {
  final DateTime month;
  final bool mondayFirst;
  final DateTime? selected;
  final double weekCollapse;
  final Size size;

  /// The grid's inset from its own edges, either side.
  static const inset = 8.0;

  MonthLayout({
    required this.month,
    required this.mondayFirst,
    required this.selected,
    required this.weekCollapse,
    required this.size,
  });

  late final DateTime first = DateTime(month.year, month.month);

  // Sunday is weekday 7 in Dart, so it needs folding back to column 0.
  late final int lead = mondayFirst ? first.weekday - 1 : first.weekday % 7;

  late final int rows =
      ((lead + DateTime(month.year, month.month + 1, 0).day) / 7).ceil();

  /// The row holding the selected day — the one that stays when the grid is
  /// squeezed down to a single week.
  late final int selectedRow = () {
    final index = selected == null
        ? -1
        : selected!.difference(first.subtract(Duration(days: lead))).inDays;
    return index >= 0 && index < rows * 7 ? index ~/ 7 : 0;
  }();

  // Squeezing the month down to a week slides the whole grid past a
  // shrinking window instead of squashing the rows, so the row height is
  // read back out of the window's: at rest that is a rows-th of it, and at
  // the end of the collapse the whole of it.
  late final double rowHeight =
      size.height / (rows - weekCollapse * (rows - 1));

  /// How far the rows have slid up past the top of the window.
  late final double travel = selectedRow * rowHeight * weekCollapse;

  double get _cellWidth => (size.width - 2 * inset) / 7;

  /// The size of one day's cell.
  Size get cellSize => Size(_cellWidth, rowHeight);

  DateTime dayOfCell(int row, int col) =>
      first.add(Duration(days: row * 7 + col - lead));

  /// The day under [local], a point in the grid's own box.
  DateTime? dayAt(Offset local) {
    if (local.dy < 0 || local.dy >= size.height) return null;
    final col = ((local.dx - inset) / _cellWidth).floor();
    final row = ((local.dy + travel) / rowHeight).floor();
    if (col < 0 || col > 6 || row < 0 || row >= rows) return null;
    return dayOfCell(row, col);
  }

  /// [day]'s cell, in the grid's own box.
  Rect? rectOf(DateTime day) {
    final index = dayOf(day).difference(dayOfCell(0, 0)).inDays;
    if (index < 0 || index >= rows * 7) return null;
    return Rect.fromLTWH(
      inset + (index % 7) * _cellWidth,
      (index ~/ 7) * rowHeight - travel,
      _cellWidth,
      rowHeight,
    );
  }
}

/// One month of day cells. Shared by the Calendar tab and the date picker, so
/// picking a date looks exactly like reading the calendar.
class MonthGrid extends StatefulWidget {
  final DateTime month;
  final DateTime? selected;
  final bool mondayFirst;

  /// Dated tasks keyed by day; each day shows up to three dots for them.
  final Map<DateTime, List<Task>> tasksByDay;

  /// Lists, used to colour a day's marks by the list each task belongs to.
  final List<TaskList> lists;

  /// Public holidays of the month, keyed by day.
  final Map<DateTime, List<Holiday>> holidaysByDay;

  final ValueChanged<DateTime> onSelect;

  /// How far the grid is pulled open, 0 (compact: a marker per task) to 1
  /// (full height: each task's title spelled out in its day).
  final double expansion;

  /// How far the grid is squeezed down to the selected day's week alone,
  /// 0 (the whole month) to 1 (that single row).
  final double weekCollapse;

  /// The calendar's own state, -1 (the week) through 0 (the month) to 1
  /// (opened), followed frame by frame in place of [expansion] and
  /// [weekCollapse]. Given this, the grid is never rebuilt or laid out again
  /// while it moves — see [_RenderRows].
  final Animation<double>? animation;

  /// With [animation]: the grid's height opened out, which every week row is
  /// laid out at, and its height as a compact month, which is the room a
  /// day's marks have.
  final double? openHeight;
  final double? compactHeight;

  /// Days outside this range are shown but cannot be picked.
  final DateTime? firstDate;
  final DateTime? lastDate;

  const MonthGrid({
    super.key,
    required this.month,
    required this.selected,
    required this.mondayFirst,
    required this.onSelect,
    this.tasksByDay = const {},
    this.lists = const [],
    this.holidaysByDay = const {},
    this.expansion = 0,
    this.weekCollapse = 0,
    this.animation,
    this.openHeight,
    this.compactHeight,
    this.firstDate,
    this.lastDate,
  }) : assert(
         animation == null || (openHeight != null && compactHeight != null),
       );

  @override
  State<MonthGrid> createState() => _MonthGridState();
}

/// How strongly a day's marks show at [state] (as [MonthGrid.animation]):
/// they are gone before the titles have properly arrived.
double _markerOpacity(double state) =>
    (1 - math.max(0.0, state) * 2.2).clamp(0.0, 1.0);

double _titleOpacity(double state) =>
    ((math.max(0.0, state) - 0.3) * 2.4).clamp(0.0, 1.0);

class _MonthGridState extends State<MonthGrid>
    with SingleTickerProviderStateMixin {
  /// The day the outline is leaving, while [_fade] carries it across.
  DateTime? _was;
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
    value: 1,
  );

  late bool _markers;
  late bool _titles;

  Animation<double> get _state =>
      widget.animation ??
      AlwaysStoppedAnimation(
        widget.weekCollapse > 0 ? -widget.weekCollapse : widget.expansion,
      );

  @override
  void initState() {
    super.initState();
    widget.animation?.addListener(_follow);
    _markers = _markerOpacity(_state.value) > 0;
    _titles = _titleOpacity(_state.value) > 0;
  }

  @override
  void didUpdateWidget(MonthGrid old) {
    super.didUpdateWidget(old);
    if (old.animation != widget.animation) {
      old.animation?.removeListener(_follow);
      widget.animation?.addListener(_follow);
    }
    _markers = _markerOpacity(_state.value) > 0;
    _titles = _titleOpacity(_state.value) > 0;
    if (old.selected != widget.selected) {
      _was = old.selected;
      _fade.forward(from: 0);
    }
  }

  @override
  void dispose() {
    widget.animation?.removeListener(_follow);
    _fade.dispose();
    super.dispose();
  }

  /// The only rebuilds the moving grid gets: when its marks or titles come
  /// into being or go. Built while invisible they would cost nothing to
  /// show, but they would be in the tree — titles read out, found by tests,
  /// and on every day of the month.
  void _follow() {
    final markers = _markerOpacity(_state.value) > 0;
    final titles = _titleOpacity(_state.value) > 0;
    if (markers != _markers || titles != _titles) {
      setState(() {
        _markers = markers;
        _titles = titles;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final today = dayOf(DateTime.now());
    final state = _state;
    final markers = _Mapped(state, _markerOpacity);
    final titles = _Mapped(state, _titleOpacity);
    final layout = MonthLayout(
      month: widget.month,
      mondayFirst: widget.mondayFirst,
      selected: widget.selected,
      weekCollapse: 0,
      size: Size.zero,
    );
    final rows = layout.rows;
    // The room under a day's number its marks may fill, which is the compact
    // cell's: a row laid out opened has far more, and marks stacked into it
    // would be cut through by the compact row's edge.
    final markerRoom = widget.compactHeight == null
        ? null
        : widget.compactHeight! / rows -
              2 * (_DayCell.padding + _DayCell.outline) -
              _DayCell.contentTop -
              2;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MonthLayout.inset),
      child: _Rows(
        month: widget.month,
        mondayFirst: widget.mondayFirst,
        selected: widget.selected,
        was: _was,
        state: state,
        fade: _fade,
        rowExtent: widget.openHeight == null ? null : widget.openHeight! / rows,
        rule: p.border,
        outline: p.muted,
        children: [
          // Each week painted once and kept: a frame of the calendar moving
          // only places and clips them again, without drawing a day.
          for (var row = 0; row < rows; row++)
            RepaintBoundary(
              child: Row(
                children: [
                  for (var col = 0; col < 7; col++)
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          final day = layout.dayOfCell(row, col);
                          final enabled =
                              (widget.firstDate == null ||
                                  !day.isBefore(widget.firstDate!)) &&
                              (widget.lastDate == null ||
                                  !day.isAfter(widget.lastDate!));
                          return _DayCell(
                            day: day,
                            inMonth: day.month == widget.month.month,
                            isToday: day == today,
                            enabled: enabled,
                            markers: _markers ? markers : null,
                            titles: _titles ? titles : null,
                            markerRoom: markerRoom,
                            tasks: widget.tasksByDay[day] ?? const [],
                            holidays: widget.holidaysByDay[day] ?? const [],
                            lists: widget.lists,
                            onTap: enabled ? () => widget.onSelect(day) : null,
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// [parent]'s value passed through [map] — a fade that follows the calendar
/// without anything being rebuilt to follow it.
class _Mapped extends Animation<double> with AnimationWithParentMixin<double> {
  @override
  final Animation<double> parent;
  final double Function(double) map;

  _Mapped(this.parent, this.map);

  @override
  double get value => map(parent.value);
}

/// The weeks of a month, each laid out once and then only moved and clipped
/// as the calendar changes state.
///
/// The grid used to be rebuilt and laid out afresh on every frame of opening
/// and closing — every day, its number, marks and titles, forty-two times
/// over — because a day's cell was as tall as the row it sat in. Measured on
/// the emulator that was most of a frame's work, and a phone at 120Hz has
/// eight milliseconds for all of it: "laggy". Laid out at the opened height
/// instead and clipped to the row's height now, a cell never changes size,
/// so a frame is a few clips and translations. What did depend on the
/// height is drawn here instead: the selected day's outline, which has to
/// be the cell's height now, and the rules between the weeks.
class _Rows extends MultiChildRenderObjectWidget {
  final DateTime month;
  final bool mondayFirst;
  final DateTime? selected;
  final DateTime? was;
  final Animation<double> state;
  final Animation<double> fade;

  /// The height every row is laid out at, or null for the height it is shown
  /// at — a grid that never moves.
  final double? rowExtent;
  final Color rule;
  final Color outline;

  const _Rows({
    required this.month,
    required this.mondayFirst,
    required this.selected,
    required this.was,
    required this.state,
    required this.fade,
    required this.rowExtent,
    required this.rule,
    required this.outline,
    required super.children,
  });

  @override
  _RenderRows createRenderObject(BuildContext context) => _RenderRows(this);

  @override
  void updateRenderObject(BuildContext context, _RenderRows render) {
    render.widget = this;
  }
}

class _RowData extends ContainerBoxParentData<RenderBox> {
  int row = 0;
}

class _RenderRows extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _RowData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _RowData> {
  _RenderRows(this._widget);

  _Rows _widget;
  set widget(_Rows value) {
    final old = _widget;
    _widget = value;
    if (attached) {
      if (old.state != value.state) {
        old.state.removeListener(markNeedsPaint);
        value.state.addListener(markNeedsPaint);
      }
      if (old.fade != value.fade) {
        old.fade.removeListener(markNeedsPaint);
        value.fade.addListener(markNeedsPaint);
      }
    }
    if (old.rowExtent != value.rowExtent ||
        old.month != value.month ||
        old.mondayFirst != value.mondayFirst ||
        old.selected != value.selected) {
      markNeedsLayout();
    } else {
      markNeedsPaint();
    }
  }

  final _clips = <LayerHandle<ClipRectLayer>>[];

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _widget.state.addListener(markNeedsPaint);
    _widget.fade.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _widget.state.removeListener(markNeedsPaint);
    _widget.fade.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void dispose() {
    for (final clip in _clips) {
      clip.layer = null;
    }
    super.dispose();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _RowData) child.parentData = _RowData();
  }

  /// Where the days fall now, in the same terms the calendar's carry finds
  /// them in.
  MonthLayout _layout() {
    final state = _widget.state.value;
    return MonthLayout(
      month: _widget.month,
      mondayFirst: _widget.mondayFirst,
      selected: _widget.selected,
      weekCollapse: state < 0 ? -state : 0,
      size: Size(size.width + 2 * MonthLayout.inset, size.height),
    );
  }

  double _top(MonthLayout layout, int row) =>
      row * layout.rowHeight - layout.travel;

  @override
  void performLayout() {
    size = constraints.biggest;
    final extent = _widget.rowExtent ?? _layout().rowHeight;
    var child = firstChild;
    var row = 0;
    while (child != null) {
      final data = child.parentData! as _RowData;
      data.row = row++;
      child.layout(BoxConstraints.tightFor(width: size.width, height: extent));
      child = data.nextSibling;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final layout = _layout();
    final bounds = Offset.zero & size;
    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as _RowData;
      while (_clips.length <= data.row) {
        _clips.add(LayerHandle<ClipRectLayer>());
      }
      final top = _top(layout, data.row);
      final clip = Rect.fromLTWH(
        0,
        top,
        size.width,
        layout.rowHeight,
      ).intersect(bounds);
      final handle = _clips[data.row];
      if (clip.width > 0 && clip.height > 0) {
        final painted = child;
        handle.layer = context.pushClipRect(
          needsCompositing,
          offset,
          clip,
          (context, offset) =>
              context.paintChild(painted, offset + Offset(0, top)),
          oldLayer: handle.layer,
        );
      } else {
        handle.layer = null;
      }
      child = data.nextSibling;
    }

    final canvas = context.canvas;
    canvas.save();
    canvas.clipRect(bounds.shift(offset));

    // The rules between the weeks, arriving as the month finishes opening.
    final alpha = weekRuleAlpha(math.max(0.0, _widget.state.value));
    if (alpha > 0) {
      final paint = Paint()..color = _widget.rule.withValues(alpha: alpha);
      for (var row = 1; row < layout.rows; row++) {
        canvas.drawRect(
          Rect.fromLTWH(0, _top(layout, row), size.width, 1).shift(offset),
          paint,
        );
      }
    }

    // The selected day's outline, the height its row is now, crossing from
    // the day it was on over a short fade.
    final fade = Curves.easeOut.transform(_widget.fade.value);
    void outline(DateTime? day, double strength) {
      if (day == null || strength <= 0) return;
      final cell = layout.rectOf(day);
      if (cell == null) return;
      final outer = RRect.fromRectAndRadius(
        cell
            .shift(Offset(-MonthLayout.inset, 0))
            .deflate(_DayCell.padding)
            .shift(offset),
        const Radius.circular(7),
      );
      canvas.drawDRRect(
        outer,
        outer.deflate(_DayCell.outline),
        Paint()..color = _widget.outline.withValues(alpha: strength),
      );
    }

    if (_widget.was != _widget.selected) outline(_widget.was, 1 - fade);
    outline(_widget.selected, fade);
    canvas.restore();
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final row = (child.parentData! as _RowData).row;
    transform.translateByDouble(0, _top(_layout(), row), 0, 1);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final layout = _layout();
    var child = lastChild;
    while (child != null) {
      final data = child.parentData! as _RowData;
      final top = _top(layout, data.row);
      if (position.dy >= top && position.dy < top + layout.rowHeight) {
        final hit = child;
        if (result.addWithPaintOffset(
          offset: Offset(0, top),
          position: position,
          hitTest: (result, position) =>
              hit.hitTest(result, position: position),
        )) {
          return true;
        }
      }
      child = data.previousSibling;
    }
    return false;
  }
}

/// A single day: its number, a filled badge when it is today, and its tasks
/// — shown as lines under the number when the grid is compact and as titles
/// once it is pulled open. The selected day's outline is the grid's to draw.
class _DayCell extends StatelessWidget {
  final DateTime day;
  final bool inMonth;
  final bool isToday;
  final bool enabled;

  /// How strongly the marks and the titles show, or null for not at all.
  final Animation<double>? markers;
  final Animation<double>? titles;

  /// The height the marks may take, or null for whatever the cell has.
  final double? markerRoom;
  final List<Task> tasks;
  final List<Holiday> holidays;
  final List<TaskList> lists;
  final VoidCallback? onTap;

  const _DayCell({
    required this.day,
    required this.inMonth,
    required this.isToday,
    required this.enabled,
    required this.markers,
    required this.titles,
    required this.markerRoom,
    required this.tasks,
    required this.holidays,
    required this.lists,
    required this.onTap,
  });

  /// Air around the cell, inside which the selected day's outline is drawn.
  static const padding = 2.0;

  /// The outline's width, which the cell's contents stand inside whether it
  /// is drawn or not — as they did when the outline was the cell's own
  /// border, and a border insets what it surrounds.
  static const outline = 1.4;

  // Everything is positioned from the top of the cell: the number keeps its
  // place whatever the grid height, so the first week never moves as the
  // month opens — only what sits under the number changes. Centring it in a
  // compact cell was tried, and slid to the top as the month opened; it was
  // asked for and then asked back.
  static const numberTop = 5.0;
  static const numberHeight = 16.0;
  static const contentTop = numberTop + numberHeight + 2;

  TaskList? _listOf(Task task) {
    for (final list in lists) {
      if (list.id == task.listId) return list;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context);
    final open = tasks.where((t) => !t.done).toList();
    final allDone = tasks.isNotEmpty && open.isEmpty;

    // Only Sundays are red; a holiday says so with its green mark instead.
    final isRed = Dates.isSunday(day);

    // Today's badge is the colour the day's own number would have been: red
    // on a Sunday, the plain light badge on every other day. A light badge on
    // a red date was the one place the red stopped halfway.
    final badge = isRed ? AppColors.weekend : p.text;

    final Color numberColor;
    if (isToday) {
      // Black on the red badge, and on the light one the ground itself —
      // white in dark mode, near-black in light.
      numberColor = isRed ? Colors.black : p.bg;
    } else if (!enabled) {
      numberColor = p.faint.withValues(alpha: 0.4);
    } else if (!inMonth) {
      numberColor = (isRed ? AppColors.weekend : p.faint).withValues(
        alpha: isRed ? 0.45 : 0.6,
      );
    } else if (isRed) {
      numberColor = AppColors.weekend;
    } else {
      numberColor = p.text;
    }

    Color taskColor(Task task) => colorOfTask(
      task,
      _listOf(task),
      fallback: accent.color,
    ).withValues(alpha: task.done ? 0.35 : (allDone ? 0.55 : 1));

    // Today wears a badge and the selected day a thin neutral outline: the
    // accent on both was far too loud for a grid of numbers.
    final number = Container(
      // Near enough square and tight around the digits. Measured off the
      // screenshot this is matched to, the badge there is a square a fifth
      // wider than the number inside it; ours was half again as wide as that,
      // a slab with the date floating in the middle of it.
      width: 17,
      height: 16,
      // Centred on the digits rather than on the line box they are laid out
      // in. A line box carries room for descenders under the baseline and
      // none of these numbers has one, so centring the box drops the date
      // towards the bottom of the badge — which with a badge this tight was
      // the date all but resting on its edge.
      alignment: const Alignment(0, 0.2),
      decoration: BoxDecoration(
        color: isToday ? badge : Colors.transparent,
        borderRadius: BorderRadius.circular(5.5),
      ),
      child: Text(
        '${day.day}',
        style: TextStyle(
          color: numberColor,
          // Measured against the same screenshot: a date there stands about
          // two percent of the screen's width tall, and at 13.5 ours stood
          // nearer two and a third.
          fontSize: 12,
          // One line's worth and no more, so what is centred is close to the
          // digits themselves.
          height: 1,
          // Every number carries the same weight: a grid of dates is read by
          // glancing at it, not by reading along it, and today and the
          // selected day being the only bold ones was a distinction the badge
          // and the outline were already making. Semibold rather than bold —
          // bold was heavier than the dates on any other calendar on the
          // phone, which is what this is read beside.
          fontWeight: FontWeight.w600,
          // Proportional figures, not the tabular ones a font hands out by
          // default. Tabular digits are each given a box of the same width so
          // columns of them line up, and a 1 is a narrow glyph in a wide box
          // — so an 11 comes out with a hole down the middle and its ink
          // sitting left of where the pair is centred, which is what made the
          // date look off-centre in its badge. Nothing here is in a column.
          fontFeatures: const [FontFeature.proportionalFigures()],
          // And still pulled in a little: proportional or not, the pair reads
          // as one number rather than two.
          letterSpacing: -0.3,
        ),
      ),
    );

    final markerColours = [
      for (final _ in holidays) AppColors.holiday,
      for (final task in tasks) taskColor(task),
    ];
    final markerBars = _MarkerBars(colors: markerColours);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(padding + outline),
        child: LayoutBuilder(
          builder: (context, box) {
            // Positioned children are bounded, so a cell too short for its
            // content drops it rather than overflowing.
            return Stack(
              children: [
                Positioned(
                  top: numberTop,
                  left: 0,
                  right: 0,
                  child: Center(child: number),
                ),
                if (box.maxHeight > contentTop + 2)
                  Positioned(
                    top: contentTop,
                    left: 0,
                    right: 0,
                    bottom: 2,
                    child: Stack(
                      children: [
                        if (markers != null && markerColours.isNotEmpty)
                          Align(
                            alignment: Alignment.topCenter,
                            child: FadeTransition(
                              opacity: markers!,
                              child: markerRoom == null
                                  ? markerBars
                                  : SizedBox(
                                      height: math.max(0.0, markerRoom!),
                                      child: Align(
                                        alignment: Alignment.topCenter,
                                        child: markerBars,
                                      ),
                                    ),
                            ),
                          ),
                        if (titles != null)
                          FadeTransition(
                            opacity: titles!,
                            child: _DayTitles(
                              entries: [
                                for (final holiday in holidays)
                                  (
                                    label: holiday.name,
                                    color: AppColors.holiday,
                                    done: false,
                                  ),
                                for (final task in tasks)
                                  (
                                    label: task.title,
                                    color: taskColor(task),
                                    done: task.done,
                                  ),
                              ],
                              muted: p.faint,
                              text: p.text,
                              ground: p.calendar,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The compact marker for a day's tasks: a line per task, the width of the
/// day, stacked under its number.
class _MarkerBars extends StatelessWidget {
  /// One colour per thing happening that day, holidays first.
  final List<Color> colors;

  const _MarkerBars({required this.colors});

  static const _barHeight = 3.0;
  static const _gap = 2.0;
  static const _max = 4;

  @override
  Widget build(BuildContext context) {
    if (colors.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, box) {
        // Only as many lines as the compact cell can hold.
        final fits = ((box.maxHeight + _gap) / (_barHeight + _gap))
            .floor()
            .clamp(0, _max);
        final shown = colors.length < fits ? colors.length : fits;
        if (shown == 0) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < shown; i++)
                Container(
                  height: _barHeight,
                  margin: EdgeInsets.only(bottom: i == shown - 1 ? 0 : _gap),
                  decoration: BoxDecoration(
                    color: colors[i],
                    borderRadius: BorderRadius.circular(_barHeight / 2),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// What an opened day writes out: one line per holiday and task.
typedef DayEntry = ({String label, Color color, bool done});

/// The fill of a chip in an opened day: [colour] mixed into the calendar's
/// own [ground] rather than laid over it, the same way a task card is inked.
///
/// At full strength these were the only saturated blocks left in the app. Six
/// of them in a cell shouted over the day number they belonged to, and a month
/// with anything on it read as a sheet of violet bricks.
///
/// Out here rather than buried in the widget so a test can say "this chip is
/// wearing the task's own colour" without also pinning how deep the ink is.
Color dayChipColour(Color colour, Color ground, {bool done = false}) =>
    Color.alphaBlend(colour.withValues(alpha: done ? 0.14 : 0.42), ground);

/// A day's entries written out, as many as the opened cell has room for.
class _DayTitles extends StatelessWidget {
  final List<DayEntry> entries;
  final Color muted;

  /// The colour a title is written in, and the ground the chip is mixed into.
  final Color text;
  final Color ground;

  const _DayTitles({
    required this.entries,
    required this.muted,
    required this.text,
    required this.ground,
  });

  static const _fontSize = 7.5;
  static const _lineSpacing = 1.2;

  /// Room above and below the text inside a chip, and between two chips, and
  /// at either end of the title. All kept tight: the chip is the width of a
  /// day, so every point spent on padding is a character lost off the title.
  /// Kept as tight as it was: a point of air per chip reads as calmer right
  /// up until it costs the day a whole task, and a day showing two of its
  /// four with "+2 more" under them hides more than the air was worth.
  static const _inset = 1.5;
  static const _gap = 1.5;
  static const _sideInset = 3.0;

  /// A title may wrap onto a second line — a day is a few characters wide —
  /// but no further.
  static const _maxLines = 2;

  /// Enough to read as a chip rather than a brick, and not so much that the
  /// corners start eating the first letter of the title.
  static const _radius = 3.0;

  static const _style = TextStyle(
    fontSize: _fontSize,
    height: _lineSpacing,
    fontWeight: FontWeight.w600,
  );

  /// What [label] needs at [width]: the height the engine actually lays the
  /// title out at, rounded up, rather than one worked out from the font
  /// size — a box computed to the pixel is a box the text can overflow by a
  /// fraction of one — and whether the title ran past the lines it is
  /// allowed, which decides how the end of it is drawn.
  ///
  /// Kept once measured. A day cell is rebuilt on every frame the month is
  /// being dragged open, and laying out a painter per title per cell per frame
  /// was the most expensive thing happening during that drag. None of the
  /// inputs change while it runs, so the answer cannot either.
  static final _measured = <String, ({double height, bool overran})>{};

  static ({double height, bool overran}) _measure(
    String label,
    double width,
    TextStyle style,
    TextScaler scaler,
    TextDirection direction,
  ) {
    if (width <= 0) {
      return (height: _lineHeight + _inset * 2, overran: false);
    }
    final key =
        '$label|$width|${style.fontSize}|${style.fontFamily}'
        '|${scaler.scale(10)}|${direction.index}';
    return _measured.putIfAbsent(key, () {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: _maxLines,
      )..layout(maxWidth: width);
      final height = painter.height;
      final overran = painter.didExceedMaxLines;
      painter.dispose();
      return (height: height.ceilToDouble() + _inset * 2, overran: overran);
    });
  }

  /// One line's worth, for the "+N" that stands for what did not fit.
  static double get _lineHeight => (_fontSize * _lineSpacing).ceilToDouble();

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, box) {
        // Merged with the ambient style, so the measurement is made in the
        // font the chip will actually be drawn in.
        final style = DefaultTextStyle.of(context).style.merge(_style);
        final scaler = MediaQuery.textScalerOf(context);
        final direction = Directionality.of(context);
        final width = box.maxWidth - _sideInset * 2;
        final sizes = [
          for (final entry in entries)
            _measure(entry.label, width, style, scaler, direction),
        ];
        final heights = [for (final size in sizes) size.height];

        // Whole chips only — a half-clipped title would read as a glitch.
        var used = 0.0;
        var fits = 0;
        for (var i = 0; i < entries.length; i++) {
          final step = (fits == 0 ? 0.0 : _gap) + heights[i];
          if (used + step > box.maxHeight) break;
          used += step;
          fits++;
        }
        if (fits == 0) return const SizedBox.shrink();
        if (fits == entries.length) return _titles(fits, 0, sizes);

        // The rest are counted in a "+N", which needs room of its own, taken
        // from the last titles that fit. With space for only one thing, spend
        // it on a title: a lone "+3" names nothing.
        final plus = _lineHeight + _inset * 2;
        var shown = fits;
        while (shown > 1 && used + _gap + plus > box.maxHeight) {
          used -= heights[--shown] + _gap;
        }
        if (used + _gap + plus > box.maxHeight) {
          return _titles(shown, 0, sizes);
        }
        return _titles(shown, entries.length - shown, sizes);
      },
    );
  }

  Widget _titles(
    int shown,
    int hidden,
    List<({double height, bool overran})> sizes,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < shown; i++)
          Container(
            height: sizes[i].height,
            // A gap only where something follows, so the column never runs
            // two pixels past the height it was measured against.
            margin: EdgeInsets.only(
              bottom: i == shown - 1 && hidden == 0 ? 0 : _gap,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: _sideInset,
              vertical: _inset,
            ),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: dayChipColour(
                entries[i].color,
                ground,
                done: entries[i].done,
              ),
              borderRadius: BorderRadius.circular(_radius),
            ),
            child: Text(
              entries[i].label,
              maxLines: _maxLines,
              // A title too long for the chip's *width* fades out at the end
              // of its line, which is what a fade is good at: no letter cut
              // in half, no ellipsis eating two of the few characters there
              // are. A title too long for its *height* is a different thing
              // — there Flutter fades the bottom half of the last line it
              // drew, so every letter on it is sliced through the middle and
              // the chip reads as a rendering fault. That one is cut at the
              // line instead, which is a whole line of whole letters; the
              // rest of the title is a tap away in the day card.
              overflow: sizes[i].overran
                  ? TextOverflow.clip
                  : TextOverflow.fade,
              style: _style.copyWith(
                color: entries[i].done ? muted : text,
                decoration: entries[i].done ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        if (hidden > 0)
          SizedBox(
            height: _lineHeight + _inset * 2,
            child: Padding(
              // Lined up with the titles it stands for rather than centred
              // under them — centred, it read as a caption on the day.
              padding: const EdgeInsets.only(left: _sideInset),
              child: Text(
                '+$hidden more',
                style: TextStyle(
                  fontSize: _fontSize,
                  height: _lineSpacing,
                  fontWeight: FontWeight.w600,
                  color: muted,
                ),
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
              ),
            ),
          ),
      ],
    );
  }
}

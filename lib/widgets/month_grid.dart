import 'package:flutter/material.dart';

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

/// One month of day cells. Shared by the Calendar tab and the date picker, so
/// picking a date looks exactly like reading the calendar.
class MonthGrid extends StatelessWidget {
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
    this.firstDate,
    this.lastDate,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final first = DateTime(month.year, month.month);
    // Sunday is weekday 7 in Dart, so it needs folding back to column 0.
    final lead = mondayFirst ? first.weekday - 1 : first.weekday % 7;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final rows = ((lead + daysInMonth) / 7).ceil();
    final today = dayOf(DateTime.now());

    // Which row holds the selected day — the one that stays when the grid is
    // squeezed down to a single week.
    final gridStart = first.subtract(Duration(days: lead));
    final selectedIndex = selected == null
        ? -1
        : selected!.difference(gridStart).inDays;
    final selectedRow = (selectedIndex >= 0 && selectedIndex < rows * 7)
        ? selectedIndex ~/ 7
        : 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: LayoutBuilder(
        builder: (context, box) {
          // Squeezing the month down to a week slides the whole grid past a
          // shrinking window instead of squashing the rows: every week keeps
          // the height it has in the full month, so the numbers travel
          // together the way a list does, and the selected week is the one
          // the window is left sitting on. Shrinking the rows themselves made
          // the numbers close in on each other and read as a glitch.
          //
          // Only the window's height is known here, so the row height is read
          // back out of it: at rest that is a rows-th of it, and at the end of
          // the collapse the whole of it.
          final rowHeight = box.maxHeight / (rows - weekCollapse * (rows - 1));
          final travel = selectedRow * rowHeight * weekCollapse;

          return ClipRect(
            child: OverflowBox(
              alignment: Alignment.topCenter,
              minHeight: rowHeight * rows,
              maxHeight: rowHeight * rows,
              child: Transform.translate(
                offset: Offset(0, -travel),
                child: Column(
                  children: [
                    for (var row = 0; row < rows; row++)
                      SizedBox(
                        height: rowHeight,
                        child: ClipRect(
                          // Rules between the weeks, drawn in as the month opens.
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: row == 0
                                  ? null
                                  : Border(
                                      top: BorderSide(
                                        color: p.border.withValues(
                                          alpha: weekRuleAlpha(expansion),
                                        ),
                                      ),
                                    ),
                            ),
                            child: Row(
                              children: [
                                for (var col = 0; col < 7; col++)
                                  Expanded(
                                    child: Builder(
                                      builder: (context) {
                                        final day = first.add(
                                          Duration(days: row * 7 + col - lead),
                                        );
                                        final enabled =
                                            (firstDate == null ||
                                                !day.isBefore(firstDate!)) &&
                                            (lastDate == null ||
                                                !day.isAfter(lastDate!));
                                        return _DayCell(
                                          day: day,
                                          inMonth: day.month == month.month,
                                          isToday: day == today,
                                          isSelected: day == selected,
                                          enabled: enabled,
                                          expansion: expansion,
                                          tasks: tasksByDay[day] ?? const [],
                                          holidays:
                                              holidaysByDay[day] ?? const [],
                                          lists: lists,
                                          onTap: enabled
                                              ? () => onSelect(day)
                                              : null,
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
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A single day: its number, a filled badge when it is today, an outline when
/// it is the selected day, and its tasks — shown as lines under the number
/// when the grid is compact and as titles once it is pulled open.
class _DayCell extends StatelessWidget {
  final DateTime day;
  final bool inMonth;
  final bool isToday;
  final bool isSelected;
  final bool enabled;
  final double expansion;
  final List<Task> tasks;
  final List<Holiday> holidays;
  final List<TaskList> lists;
  final VoidCallback? onTap;

  const _DayCell({
    required this.day,
    required this.inMonth,
    required this.isToday,
    required this.isSelected,
    required this.enabled,
    required this.expansion,
    required this.tasks,
    required this.holidays,
    required this.lists,
    required this.onTap,
  });

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

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: isSelected ? p.muted : Colors.transparent,
              width: 1.4,
            ),
          ),
          child: LayoutBuilder(
            builder: (context, box) {
              // Everything is positioned from the top of the cell: the number
              // keeps its place whatever the grid height, so the first week
              // never moves as the month opens — only what sits under the
              // number changes. Centring it in a compact cell was tried, and
              // slid to the top as the month opened; it was asked for and then
              // asked back. Positioned children are bounded, so a cell too
              // short for its content drops it rather than overflowing.
              const numberTop = 5.0;
              const numberHeight = 16.0;
              const contentTop = numberTop + numberHeight + 2;
              final markerOpacity = (1 - expansion * 2.2).clamp(0.0, 1.0);
              final titleOpacity = ((expansion - 0.3) * 2.4).clamp(0.0, 1.0);

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
                          if (markerOpacity > 0)
                            Align(
                              alignment: Alignment.topCenter,
                              child: Opacity(
                                opacity: markerOpacity,
                                child: _MarkerBars(
                                  colors: [
                                    for (final _ in holidays) AppColors.holiday,
                                    for (final task in tasks) taskColor(task),
                                  ],
                                ),
                              ),
                            ),
                          if (titleOpacity > 0)
                            Opacity(
                              opacity: titleOpacity,
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

  /// The height a chip needs for [label] at [width] — the height the engine
  /// actually lays the title out at, rounded up, rather than one worked out
  /// from the font size. A box computed to the pixel is a box the text can
  /// overflow by a fraction of one, and an overflowing [TextOverflow.fade]
  /// fades away the bottom half of every letter.
  ///
  /// Kept once measured. A day cell is rebuilt on every frame the month is
  /// being dragged open, and laying out a painter per title per cell per frame
  /// was the most expensive thing happening during that drag. None of the
  /// inputs change while it runs, so the answer cannot either.
  static final _heights = <String, double>{};

  static double _heightOf(
    String label,
    double width,
    TextStyle style,
    TextScaler scaler,
    TextDirection direction,
  ) {
    if (width <= 0) return _lineHeight + _inset * 2;
    final key = '$label|$width|${style.fontSize}|${style.fontFamily}'
        '|${scaler.scale(10)}|${direction.index}';
    return _heights.putIfAbsent(key, () {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: _maxLines,
      )..layout(maxWidth: width);
      final height = painter.height;
      painter.dispose();
      return height.ceilToDouble() + _inset * 2;
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
        final heights = [
          for (final entry in entries)
            _heightOf(entry.label, width, style, scaler, direction),
        ];

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
        if (fits == entries.length) return _titles(fits, 0, heights);

        // The rest are counted in a "+N", which needs room of its own, taken
        // from the last titles that fit. With space for only one thing, spend
        // it on a title: a lone "+3" names nothing.
        final plus = _lineHeight + _inset * 2;
        var shown = fits;
        while (shown > 1 && used + _gap + plus > box.maxHeight) {
          used -= heights[--shown] + _gap;
        }
        if (used + _gap + plus > box.maxHeight) {
          return _titles(shown, 0, heights);
        }
        return _titles(shown, entries.length - shown, heights);
      },
    );
  }

  Widget _titles(int shown, int hidden, List<double> heights) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < shown; i++)
          Container(
            height: heights[i],
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
              // Fades out rather than cutting a letter in half or spending
              // two of the few characters on an ellipsis.
              overflow: TextOverflow.fade,
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

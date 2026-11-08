import 'package:flutter/material.dart';

import '../data/holidays.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../providers/task_provider.dart' show dayOf;
import '../services/device_calendars.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import 'task_card.dart';

/// A day as hours: what has no time across the top, as dense cards, and
/// under it the day from midnight to midnight with each timed task and
/// event a block from its start to its end. The calendar's day panel shows
/// this in place of the list when its bar is switched to hours.
///
/// A task with no end is drawn half an hour long, which is enough for its
/// title; things that overlap share the width between them, side by side.
/// It opens a little above the first thing on the day — or, on today, above
/// now or what began shortly before it, with a line across at the time.
///
/// Unlike the list, it scrolls whatever state the grid is in: held still
/// above the week, as the list is, it would show nothing past five in the
/// morning. A drag past either end still reaches the grid, as the list's
/// does, through the panel's listener.
class DayHours extends StatefulWidget {
  final DateTime date;
  final List<Task> tasks;
  final List<Holiday> holidays;
  final List<CalendarEvent> events;
  final List<TaskList> lists;
  final ValueChanged<Task> onOpen;
  final ValueChanged<Task> onToggle;
  final bool Function(Task) isTicking;
  final bool Function(Task) isLeaving;

  const DayHours({
    super.key,
    required this.date,
    required this.tasks,
    required this.holidays,
    required this.events,
    required this.lists,
    required this.onOpen,
    required this.onToggle,
    required this.isTicking,
    required this.isLeaving,
  });

  /// How tall an hour is drawn.
  static const hour = 56.0;

  /// The width of the column the hours are written in.
  static const _labels = 56.0;

  /// What a task with no end is drawn as lasting.
  static const _shortest = 30;

  @override
  State<DayHours> createState() => _DayHoursState();
}

class _DayHoursState extends State<DayHours> {
  final _scroll = ScrollController();

  /// The timeline's top within the scroll, measured once laid out.
  final _timeline = GlobalKey();

  /// Whether a finger has moved the hours. Until then they are placed
  /// again whenever what is on the day changes: the phone's events arrive
  /// after the tasks, and an all-day one landing above the timeline pushed
  /// it down by a card from where it had been placed.
  bool _touched = false;

  @override
  void initState() {
    super.initState();
    // Where the timeline starts depends on how much has no time above it,
    // which is only known once it is laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) => _toFirst());
  }

  @override
  void didUpdateWidget(DayHours old) {
    super.didUpdateWidget(old);
    if (_touched) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _toFirst());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _toFirst() {
    if (!mounted || !_scroll.hasClients) return;
    final box = _timeline.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final now = DateTime.now();
    final blocks = _blocks();
    // On today, now — or what started in the two hours before it, which is
    // most likely what is being looked for. On any other day, the first
    // thing on it, or eight in the morning on an empty one.
    final nowMinute = now.hour * 60 + now.minute;
    final int minute;
    if (dayOf(now) == widget.date) {
      final recent = blocks
          .where((b) => b.start >= nowMinute - 120 && b.start <= nowMinute)
          .firstOrNull;
      minute = recent?.start ?? nowMinute;
    } else if (blocks.isNotEmpty) {
      minute = blocks.first.start;
    } else {
      minute = 8 * 60;
    }
    final top =
        box.localToGlobal(Offset.zero).dy -
        (context.findRenderObject() as RenderBox)
            .localToGlobal(Offset.zero)
            .dy +
        _scroll.offset;
    // Half an hour above it, so it does not sit on the edge.
    final target = top + (minute - 30) / 60 * DayHours.hour;
    _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
  }

  /// Every timed thing on the day, as minutes from its midnight, in order.
  List<_Block> _blocks() {
    final day = widget.date;
    final next = day.add(const Duration(days: 1));
    int minutes(DateTime t) => t.isBefore(day)
        ? 0
        : (t.isBefore(next) ? t.hour * 60 + t.minute : 24 * 60);
    final blocks = <_Block>[
      for (final task in widget.tasks)
        if (task.hasTime && task.due != null)
          _Block(
            start: minutes(task.due!),
            end: task.end == null
                ? minutes(task.due!) + DayHours._shortest
                : minutes(task.end!),
            task: task,
          ),
      for (final event in widget.events)
        if (_timed(event))
          _Block(
            start: minutes(event.start),
            end: minutes(event.end),
            event: event,
          ),
    ];
    // Nothing shorter than half an hour, or its title would not fit.
    for (final b in blocks) {
      if (b.end < b.start + DayHours._shortest) {
        b.end = b.start + DayHours._shortest;
      }
    }
    blocks.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : b.end.compareTo(a.end);
    });
    _arrange(blocks);
    return blocks;
  }

  /// Whether [event] goes on the timeline rather than across the top: one
  /// with a time that starts or ends on this day. One that runs through the
  /// whole of it is drawn as an all-day one, as its card would say.
  bool _timed(CalendarEvent event) {
    if (event.allDay) return false;
    return dayOf(event.start) == widget.date || dayOf(event.end) == widget.date;
  }

  /// Gives each block a column, and each run of overlapping blocks the
  /// number of columns it needs, so they share the width side by side.
  static void _arrange(List<_Block> blocks) {
    var cluster = <_Block>[];
    var columns = <int>[];
    var clusterEnd = -1;
    void close() {
      for (final b in cluster) {
        b.of = columns.length;
      }
      cluster = [];
      columns = [];
    }

    for (final b in blocks) {
      if (b.start >= clusterEnd) close();
      var column = columns.indexWhere((end) => end <= b.start);
      if (column < 0) {
        column = columns.length;
        columns.add(b.end);
      } else {
        columns[column] = b.end;
      }
      b.column = column;
      cluster.add(b);
      clusterEnd = clusterEnd > b.end ? clusterEnd : b.end;
    }
    close();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final h24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final untimed = [
      for (final task in widget.tasks)
        if (!task.hasTime) task,
    ];
    final allDayEvents = [
      for (final event in widget.events)
        if (!_timed(event)) event,
    ];
    final blocks = _blocks();
    final now = DateTime.now();
    final today = dayOf(now) == widget.date;

    return NotificationListener<ScrollStartNotification>(
      onNotification: (n) {
        if (n.dragDetails != null) _touched = true;
        return false;
      },
      child: SingleChildScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 4, bottom: 72),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final holiday in widget.holidays)
              HolidayCard(holiday: holiday, dense: true),
            for (final event in allDayEvents)
              EventCard(event: event, day: widget.date, dense: true),
            for (final task in untimed)
              TaskCard(
                task: task,
                list: _listOf(task),
                dense: true,
                onTap: () => widget.onOpen(task),
                onToggle: () => widget.onToggle(task),
                ticking: widget.isTicking(task),
                leaving: widget.isLeaving(task),
              ),
            SizedBox(
              key: _timeline,
              height: DayHours.hour * 24 + 8,
              child: LayoutBuilder(
                builder: (context, box) {
                  final left = DayHours._labels;
                  final width = box.maxWidth - left - 16;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (var h = 0; h < 24; h++) ...[
                        Positioned(
                          top: h * DayHours.hour + 4,
                          left: left,
                          right: 16,
                          child: Container(height: 1, color: p.border),
                        ),
                        Positioned(
                          top: h * DayHours.hour - 3,
                          left: 0,
                          width: left - 8,
                          child: Text(
                            Dates.time(
                              DateTime(2000, 1, 1, h),
                              h24: h24,
                            ).replaceAll(':00', ''),
                            textAlign: TextAlign.right,
                            style: TextStyle(color: p.faint, fontSize: 11),
                          ),
                        ),
                      ],
                      for (final b in blocks)
                        Positioned(
                          top: b.start / 60 * DayHours.hour + 5,
                          height: (b.end - b.start) / 60 * DayHours.hour - 2,
                          left: left + 4 + width * b.column / b.of,
                          width: width / b.of - 4,
                          child: _BlockView(
                            block: b,
                            colour: b.task != null
                                ? colorOfTask(
                                    b.task!,
                                    _listOf(b.task!),
                                    fallback: AppColors.accent,
                                  )
                                : b.event!.color,
                            h24: h24,
                            onTap: b.task != null
                                ? () => widget.onOpen(b.task!)
                                : () => DeviceCalendars.open(b.event!),
                          ),
                        ),
                      if (today)
                        Positioned(
                          top:
                              (now.hour * 60 + now.minute) /
                                  60 *
                                  DayHours.hour +
                              3,
                          left: left - 4,
                          right: 16,
                          child: Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: AppColors.overdue,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              Expanded(
                                child: Container(
                                  height: 2,
                                  color: AppColors.overdue,
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
          ],
        ),
      ),
    );
  }

  TaskList? _listOf(Task task) {
    for (final l in widget.lists) {
      if (l.id == task.listId) return l;
    }
    return null;
  }
}

/// A timed thing on the day: its span in minutes from midnight, and where
/// it stands among those it overlaps.
class _Block {
  final int start;
  int end;
  final Task? task;
  final CalendarEvent? event;
  int column = 0;
  int of = 1;

  _Block({required this.start, required this.end, this.task, this.event});
}

/// One block on the timeline, inked in its colour as a card is, with a
/// stripe of the colour itself down its leading edge: the title, and under
/// it the times if there is room.
class _BlockView extends StatelessWidget {
  final _Block block;
  final Color colour;
  final bool h24;
  final VoidCallback onTap;

  const _BlockView({
    required this.block,
    required this.colour,
    required this.h24,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final done = block.task?.done ?? false;
    final title = block.task?.title ?? block.event!.title;
    final from = block.task?.due ?? block.event!.start;
    final to = block.task?.end ?? (block.event?.end);
    final times = to == null
        ? Dates.time(from, h24: h24)
        : '${Dates.time(from, h24: h24)} – ${Dates.time(to, h24: h24)}';
    final tall = (block.end - block.start) >= 45;
    return Material(
      color: colour.withValues(alpha: done ? 0.05 : 0.25),
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 3,
              color: colour.withValues(alpha: done ? 0.4 : 1),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 3, 6, 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: tall ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: done ? p.faint : p.text,
                        fontSize: 13,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                        decoration: done ? TextDecoration.lineThrough : null,
                        decorationColor: p.faint,
                      ),
                    ),
                    if (tall)
                      Text(
                        times,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        softWrap: false,
                        style: TextStyle(color: p.muted, fontSize: 11.5),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

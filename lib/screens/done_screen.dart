import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../db/database.dart';
import '../models/completion.dart';
import '../models/task_list.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/screen_header.dart';
import '../widgets/task_card.dart' show CheckMark, TaskCard;
import 'task_edit_screen.dart';

/// How far back the log reads. A year is a few hundred rows at most, and
/// it is what a streak can be counted over.
const _logDays = 366;

/// What has been ticked off, day by day, latest first, under a few figures:
/// today, this week, the days in a row, and the last seven days as bars.
///
/// Read from the log of ticks (`Completion`) rather than from the tasks, so
/// a repeating task counts every time round and a task cleared away or
/// deleted is still there.
class DoneScreen extends StatefulWidget {
  /// Whether this is the screen on show. The shell builds every screen at
  /// once, and a log nobody is looking at has no business being read on
  /// every change to every task. Null when shown on its own.
  final ValueListenable<bool>? shown;

  const DoneScreen({super.key, this.shown});

  @override
  State<DoneScreen> createState() => _DoneScreenState();
}

class _DoneScreenState extends State<DoneScreen> {
  List<Completion> _log = const [];
  late final TaskProvider _tasks = context.read<TaskProvider>();

  bool _listening = false;

  @override
  void initState() {
    super.initState();
    widget.shown?.addListener(_follow);
    _follow();
  }

  @override
  void dispose() {
    widget.shown?.removeListener(_follow);
    if (_listening) _tasks.removeListener(_load);
    super.dispose();
  }

  /// Reads the log as the screen comes on show, and again on every change
  /// while it is there — every change to a task ends in the provider
  /// re-reading its lists, a tick among them.
  void _follow() {
    final shown = widget.shown?.value ?? true;
    if (shown == _listening) return;
    _listening = shown;
    if (shown) {
      _tasks.addListener(_load);
      _load();
    } else {
      _tasks.removeListener(_load);
    }
  }

  Future<void> _load() async {
    final since = dayOf(
      DateTime.now(),
    ).subtract(const Duration(days: _logDays));
    final log = await AppDatabase.instance.getCompletions(
      since.millisecondsSinceEpoch,
    );
    if (mounted) setState(() => _log = log);
  }

  Future<void> _open(Completion done) async {
    final id = done.taskId;
    final task = id == null ? null : await AppDatabase.instance.getTask(id);
    if (task == null || !mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => TaskEditScreen(task: task)));
  }

  @override
  Widget build(BuildContext context) {
    final mondayFirst = context.select<SettingsProvider, bool>(
      (s) => s.weekStartsMonday,
    );
    final stats = DoneStats.of(_log, DateTime.now(), mondayFirst: mondayFirst);
    // The log arrives latest first, so each day's run does too.
    final days = <DateTime, List<Completion>>{};
    for (final done in _log) {
      days.putIfAbsent(dayOf(done.at), () => []).add(done);
    }
    final rows = <Widget>[
      _Summary(stats: stats),
      for (final MapEntry(key: day, value: ticks) in days.entries) ...[
        DayHeader(word: Dates.dayWord(day), label: Dates.dayDate(day)),
        for (final done in ticks)
          _DoneRow(done: done, onTap: () => _open(done)),
      ],
      const SizedBox(height: 24),
    ];

    return Scaffold(
      body: Column(
        children: [
          ScreenHeader(title: S.of(context).done),
          Expanded(
            child: _log.isEmpty
                ? EmptyState(
                    icon: Icons.task_alt,
                    title: S.of(context).nothingDoneYet,
                    message: S.of(context).doneHint,
                  )
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, i) => rows[i],
                  ),
          ),
        ],
      ),
    );
  }
}

/// The figures over the log. Worked out apart from any widget so a test
/// can say what a run of ticks comes to.
class DoneStats {
  /// Ticks made today.
  final int today;

  /// Ticks made since the week began, on the day Settings starts it.
  final int week;

  /// Days in a row with at least one tick, up to today — or up to
  /// yesterday while today has none yet, since a day that is not over has
  /// not broken anything.
  final int streak;

  /// Ticks on each of the last seven days, oldest first, today last.
  final List<int> lastSeven;

  const DoneStats({
    required this.today,
    required this.week,
    required this.streak,
    required this.lastSeven,
  });

  factory DoneStats.of(
    List<Completion> log,
    DateTime now, {
    bool mondayFirst = true,
  }) {
    final today = dayOf(now);
    final perDay = <DateTime, int>{};
    for (final done in log) {
      final day = dayOf(done.at);
      perDay[day] = (perDay[day] ?? 0) + 1;
    }
    int on(DateTime day) => perDay[day] ?? 0;

    final firstDay = mondayFirst ? DateTime.monday : DateTime.sunday;
    final weekStart = DateTime(
      today.year,
      today.month,
      today.day - (today.weekday - firstDay) % 7,
    );
    var week = 0;
    for (var d = weekStart; !d.isAfter(today); d = _next(d)) {
      week += on(d);
    }

    var streak = 0;
    var d = on(today) > 0 ? today : _previous(today);
    while (on(d) > 0) {
      streak++;
      d = _previous(d);
    }

    return DoneStats(
      today: on(today),
      week: week,
      streak: streak,
      lastSeven: [
        for (var i = 6; i >= 0; i--)
          on(DateTime(today.year, today.month, today.day - i)),
      ],
    );
  }

  // By the calendar rather than by 24 hours, so a change of the clocks
  // cannot land two steps on one day.
  static DateTime _next(DateTime d) => DateTime(d.year, d.month, d.day + 1);
  static DateTime _previous(DateTime d) => DateTime(d.year, d.month, d.day - 1);
}

/// Three figures and a week of bars, on a panel at the head of the log.
/// Neutral throughout: a tally is not one of the rare things the accent is
/// kept for, and the colour of what was done is in the rows below it.
class _Summary extends StatelessWidget {
  final DoneStats stats;

  const _Summary({required this.stats});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final most = stats.lastSeven.fold<int>(1, (a, b) => a > b ? a : b);
    final today = dayOf(DateTime.now());
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(TaskCard.radius),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _Figure(value: stats.today, label: s.figureToday),
              _Figure(value: stats.week, label: s.figureWeek),
              _Figure(value: stats.streak, label: s.daysInARow(stats.streak)),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: _Bar(
                    count: stats.lastSeven[i],
                    share: stats.lastSeven[i] / most,
                    day: DateTime(today.year, today.month, today.day - 6 + i),
                    isToday: i == 6,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  final int value;
  final String label;

  const _Figure({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$value',
            style: TextStyle(
              color: p.text,
              fontSize: 26,
              fontWeight: FontWeight.w700,
              height: 1.1,
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: p.faint, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

/// One day of the last seven: its count over a bar, its weekday under it.
/// A day with nothing keeps a stub, so the week reads as seven days rather
/// than as bars with holes between them.
class _Bar extends StatelessWidget {
  final int count;
  final double share;
  final DateTime day;
  final bool isToday;

  const _Bar({
    required this.count,
    required this.share,
    required this.day,
    required this.isToday,
  });

  static const _tallest = 36.0;

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    // The count rides on top of its bar inside a fixed height, so the bars
    // share one baseline whatever the counts are.
    return Column(
      children: [
        SizedBox(
          height: _tallest + 18,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (count > 0)
                Text(
                  '$count',
                  style: TextStyle(color: p.faint, fontSize: 11, height: 1),
                ),
              const SizedBox(height: 4),
              Container(
                width: 18,
                height: count == 0 ? 3 : 6 + (_tallest - 6) * share,
                decoration: BoxDecoration(
                  color: count == 0 ? p.border : (isToday ? p.text : p.muted),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          Dates.weekdayNarrow(day),
          style: TextStyle(
            color: isToday ? p.text : p.faint,
            fontSize: 11.5,
            fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

/// A tick in the log: a card inked in the task's colour, as the task's own
/// card is, with its square filled — but not crossed out. Everything here
/// is done; striking through the lot would only make it harder to read.
class _DoneRow extends StatelessWidget {
  final Completion done;
  final VoidCallback onTap;

  const _DoneRow({required this.done, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final list = context.select<TaskProvider, TaskList?>(
      (t) => t.listById(done.listId),
    );
    final color = colorOfStyle(
      done.styleId,
      list,
      fallback: AppTheme.accentOf(context).color,
    );
    return Padding(
      padding: TaskCard.margin,
      child: Material(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(TaskCard.radius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(TaskCard.radius),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: const CustomPaint(painter: CheckMark(progress: 1)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    done.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.text,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  Dates.time(
                    done.at,
                    h24: MediaQuery.alwaysUse24HourFormatOf(context),
                  ),
                  style: TextStyle(color: p.muted, fontSize: 12.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

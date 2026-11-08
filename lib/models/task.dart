import 'dart:convert';

import 'package:flutter/foundation.dart';

/// The unit a rule repeats by.
enum RepeatUnit { none, day, week, month, year }

/// How often a task comes back after it is completed: every [every]
/// [unit]s, on chosen [weekdays] when it is weekly, on the month's last day
/// when [monthEnd], and until a date or for a number of rounds.
///
/// The five rules there were before this could say more are kept as
/// constants and stored under their old names (`daily`, `weekly`…), so no
/// row written before needed touching and a plain rule still reads plainly
/// in the database. Anything richer is stored as a short RRULE-like string.
@immutable
class Repeat {
  final RepeatUnit unit;
  final int every;

  /// `DateTime.weekday` values (1 Monday … 7 Sunday) a weekly rule falls
  /// on. Empty means the weekday the task is due on, as it always was.
  final Set<int> weekdays;

  /// Whether a monthly rule falls on the last day of each month rather than
  /// on the due date's day.
  final bool monthEnd;

  /// The last day a round may fall on, or null for no end.
  final DateTime? until;

  /// How many rounds are left, this one included, or null for no count.
  final int? left;

  const Repeat({
    this.unit = RepeatUnit.none,
    this.every = 1,
    this.weekdays = const {},
    this.monthEnd = false,
    this.until,
    this.left,
  });

  static const none = Repeat();
  static const daily = Repeat(unit: RepeatUnit.day);
  static const weekly = Repeat(unit: RepeatUnit.week);
  static const monthly = Repeat(unit: RepeatUnit.month);
  static const yearly = Repeat(unit: RepeatUnit.year);
  static const weekdaysOnly = Repeat(
    unit: RepeatUnit.week,
    weekdays: {1, 2, 3, 4, 5},
  );

  bool get isNone => unit == RepeatUnit.none;

  /// Whether this is one of the five plain rules, which are stored by name.
  bool get _plain =>
      every == 1 &&
      weekdays.isEmpty &&
      !monthEnd &&
      until == null &&
      left == null;

  static const _names = {
    'none': RepeatUnit.none,
    'daily': RepeatUnit.day,
    'weekly': RepeatUnit.week,
    'monthly': RepeatUnit.month,
    'yearly': RepeatUnit.year,
  };

  static const _freq = {
    RepeatUnit.day: 'DAILY',
    RepeatUnit.week: 'WEEKLY',
    RepeatUnit.month: 'MONTHLY',
    RepeatUnit.year: 'YEARLY',
  };

  /// What is written to the `repeat_rule` column.
  String toRule() {
    if (isNone) return 'none';
    if (_plain) {
      return _names.entries.firstWhere((e) => e.value == unit).key;
    }
    final u = until;
    return [
      'FREQ=${_freq[unit]}',
      if (every != 1) 'INTERVAL=$every',
      if (weekdays.isNotEmpty) 'BYDAY=${(weekdays.toList()..sort()).join(',')}',
      if (monthEnd) 'BYMONTHDAY=-1',
      if (u != null)
        'UNTIL=${u.year.toString().padLeft(4, '0')}'
            '${u.month.toString().padLeft(2, '0')}'
            '${u.day.toString().padLeft(2, '0')}',
      if (left != null) 'COUNT=$left',
    ].join(';');
  }

  /// Reads back what [toRule] wrote. Anything unreadable does not repeat:
  /// a task is worth more than a rule that will not parse.
  static Repeat fromRule(String? rule) {
    if (rule == null) return none;
    final plain = _names[rule];
    if (plain != null) return Repeat(unit: plain);
    final parts = {
      for (final part in rule.split(';'))
        if (part.split('=') case [final key, final value]) key: value,
    };
    final unit = _freq.entries
        .where((e) => e.value == parts['FREQ'])
        .firstOrNull
        ?.key;
    if (unit == null) return none;
    final untilText = parts['UNTIL'];
    return Repeat(
      unit: unit,
      every: int.tryParse(parts['INTERVAL'] ?? '')?.clamp(1, 999) ?? 1,
      weekdays: (parts['BYDAY'] ?? '')
          .split(',')
          .map(int.tryParse)
          .whereType<int>()
          .where((n) => n >= 1 && n <= 7)
          .toSet(),
      monthEnd: parts['BYMONTHDAY'] == '-1',
      until: untilText != null && untilText.length == 8
          ? DateTime.tryParse(untilText)
          : null,
      left: int.tryParse(parts['COUNT'] ?? ''),
    );
  }

  Repeat copyWith({
    RepeatUnit? unit,
    int? every,
    Set<int>? weekdays,
    bool? monthEnd,
    DateTime? until,
    bool clearUntil = false,
    int? left,
    bool clearLeft = false,
  }) => Repeat(
    unit: unit ?? this.unit,
    every: every ?? this.every,
    weekdays: weekdays ?? this.weekdays,
    monthEnd: monthEnd ?? this.monthEnd,
    until: clearUntil ? null : (until ?? this.until),
    left: clearLeft ? null : (left ?? this.left),
  );

  /// The rule as it stands for the round after this one: a count of rounds
  /// goes down by the one just done.
  Repeat rolled() => left == null ? this : copyWith(left: left! - 1);

  /// The next due date after [from], or null when there is none — the task
  /// does not repeat, its end date has passed, or this was its last round.
  DateTime? next(DateTime from) {
    if (isNone || (left != null && left! <= 1)) return null;
    final DateTime next = switch (unit) {
      RepeatUnit.none => from,
      RepeatUnit.day => _onDay(from, from.day + every),
      RepeatUnit.week when weekdays.isEmpty => _onDay(
        from,
        from.day + 7 * every,
      ),
      RepeatUnit.week => _nextWeekday(from),
      RepeatUnit.month =>
        monthEnd ? _monthEnd(from, every) : _shiftMonths(from, every),
      RepeatUnit.year => _shiftMonths(from, 12 * every),
    };
    final end = until;
    if (end != null &&
        DateTime(
          next.year,
          next.month,
          next.day,
        ).isAfter(DateTime(end.year, end.month, end.day))) {
      return null;
    }
    return next;
  }

  /// [from]'s time of day on day [day] of its month, which may run past
  /// the month's end and on into the next — as `DateTime` allows.
  static DateTime _onDay(DateTime from, int day) =>
      DateTime(from.year, from.month, day, from.hour, from.minute);

  /// The next chosen weekday after [from]: later in its own week if one is
  /// left there, otherwise the first in the week [every] weeks on. Weeks
  /// are counted from Monday.
  DateTime _nextWeekday(DateTime from) {
    for (var d = from.weekday + 1; d <= 7; d++) {
      if (weekdays.contains(d)) {
        return _onDay(from, from.day + d - from.weekday);
      }
    }
    final monday = from.day - (from.weekday - 1) + 7 * every;
    final first = weekdays.reduce((a, b) => a < b ? a : b);
    return _onDay(from, monday + first - 1);
  }

  static DateTime _monthEnd(DateTime from, int months) {
    final last = DateTime(from.year, from.month + months + 1, 0);
    return DateTime(last.year, last.month, last.day, from.hour, from.minute);
  }

  // Clamps to the last day of the target month (31 Jan -> 28/29 Feb).
  static DateTime _shiftMonths(DateTime from, int months) {
    final total = from.month - 1 + months;
    final year = from.year + total ~/ 12;
    final month = total % 12 + 1;
    final lastDay = DateTime(year, month + 1, 0).day;
    return DateTime(
      year,
      month,
      from.day.clamp(1, lastDay),
      from.hour,
      from.minute,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Repeat &&
      other.unit == unit &&
      other.every == every &&
      setEquals(other.weekdays, weekdays) &&
      other.monthEnd == monthEnd &&
      other.until == until &&
      other.left == left;

  @override
  int get hashCode => Object.hash(
    unit,
    every,
    Object.hashAllUnordered(weekdays),
    monthEnd,
    until,
    left,
  );

  @override
  String toString() => 'Repeat(${toRule()})';
}

/// Task importance. Shown as a coloured flag on the task row.
enum Priority {
  none('None'),
  low('Low'),
  medium('Medium'),
  high('High');

  const Priority(this.label);

  final String label;

  static Priority byIndex(int? index) =>
      index == null || index < 0 || index >= Priority.values.length
      ? Priority.none
      : Priority.values[index];
}

/// Where a task stands on the board: not begun, under way, or finished.
/// Only the middle one is stored ([Task.startedAt]); the other two are
/// whether the task is done.
enum Stage { notStarted, inProgress, done }

/// One step of a task's checklist. Kept with the task rather than in a table
/// of its own: a task is written back whole — by Undo, and by a repeating
/// task rolling on — and its checklist has to go with it every time.
class Subtask {
  final String title;
  final bool done;

  const Subtask(this.title, {this.done = false});

  Subtask copyWith({String? title, bool? done}) =>
      Subtask(title ?? this.title, done: done ?? this.done);

  Map<String, Object?> toJson() => {'title': title, 'done': done};

  static Subtask? fromJson(Object? json) {
    if (json is! Map) return null;
    final title = json['title'];
    if (title is! String) return null;
    return Subtask(title, done: json['done'] == true);
  }

  @override
  bool operator ==(Object other) =>
      other is Subtask && other.title == title && other.done == done;

  @override
  int get hashCode => Object.hash(title, done);
}

/// A single to-do item: a title, optional notes, an optional due date (with or
/// without a time of day) and a repeat rule.
class Task {
  final int? id;

  /// The list this task belongs to.
  final int listId;

  final String title;
  final String notes;

  /// Epoch millis the task is due, or null for a task with no date. A dated
  /// task shows up on the calendar; an undated one only in its list.
  final int? dueAt;

  /// Whether [dueAt] carries a meaningful time of day. When false the task is
  /// an all-day item on its date.
  final bool hasTime;

  final bool done;
  final Priority priority;
  final Repeat repeat;

  /// Id of a [ListStyle] overriding the colour this task inherits from its
  /// list, or null to follow the list.
  final String? styleId;

  /// Epoch millis of creation, used for sorting.
  final int createdAt;

  /// Epoch millis the task was last completed, or null while it is open.
  final int? completedAt;

  /// Where the user has dragged this task within its day, or null if its day
  /// has never been reordered. Null means "wherever the ordinary rules put
  /// it", which is why it is nullable rather than defaulted to zero: a column
  /// of zeros would claim every task had been placed by hand.
  final int? sortOrder;

  /// The task's checklist, in the order it was written.
  final List<Subtask> subtasks;

  /// How many minutes ahead of its time the task is announced, or null to
  /// follow Settings. [silent] for a task that is never announced. An all-day
  /// task counts only whole days of it: it is announced at the hour Settings
  /// names, on its day or on one before.
  final int? remindBefore;

  /// Epoch millis a snoozed reminder comes back at, or null. While set, it
  /// is the one time the task is announced — the snooze answers "not now",
  /// and the time worked out from the due date has already gone by.
  final int? snoozedUntil;

  /// Epoch millis the task was put in progress on the board, or null while
  /// it has not been. A tick ends it: a repeating task's next round has not
  /// been started, and a done one is past being in progress.
  final int? startedAt;

  /// How many minutes a timed task lasts, or null for one that only has a
  /// start. Kept as a length rather than an end, so moving the task, rolling
  /// it on or changing its start carries the end along with nothing to
  /// remember.
  final int? duration;

  /// [remindBefore] for a task that is never announced.
  static const silent = -1;

  const Task({
    this.id,
    required this.listId,
    required this.title,
    this.notes = '',
    this.dueAt,
    this.hasTime = false,
    this.done = false,
    this.priority = Priority.none,
    this.repeat = Repeat.none,
    this.styleId,
    required this.createdAt,
    this.completedAt,
    this.sortOrder,
    this.subtasks = const [],
    this.remindBefore,
    this.snoozedUntil,
    this.startedAt,
    this.duration,
  });

  /// When a timed task with a length ends, or null.
  DateTime? get end {
    final d = due;
    final minutes = duration;
    if (!hasTime || d == null || minutes == null) return null;
    return d.add(Duration(minutes: minutes));
  }

  /// Whether ticking this task off rolls it on to its next date rather than
  /// closing it.
  bool get rollsOn => !done && dueAt != null && repeat.next(due!) != null;

  /// This task as it is written back once ticked off at [now]: on its next
  /// date with its checklist cleared, if it repeats, and done otherwise.
  /// Either way a snooze is over — what it was put off for has been done.
  ///
  /// The one definition of a tick, shared by the cards, a reminder's Done and
  /// the home-screen widget, which must not come to disagree about what a
  /// repeating task does.
  Task completed(int now) {
    if (rollsOn) {
      return copyWith(
        dueAt: repeat.next(due!)!.millisecondsSinceEpoch,
        repeat: repeat.rolled(),
        completedAt: now,
        clearSnoozedUntil: true,
        clearStartedAt: true,
        // Its next time round starts with nothing on the checklist done.
        subtasks: [for (final s in subtasks) s.copyWith(done: false)],
      );
    }
    return copyWith(
      done: true,
      completedAt: now,
      clearSnoozedUntil: true,
      clearStartedAt: true,
    );
  }

  /// This task with its tick taken back.
  Task reopened() => copyWith(done: false, clearCompletedAt: true);

  /// This task as it is written back once moved on the board to [stage] at
  /// [now]. Into Done is [completed], so a repeating task rolls on to a
  /// round not yet started; out of it, the tick is taken back.
  Task toStage(Stage stage, int now) => switch (stage) {
    Stage.done => completed(now),
    Stage.inProgress => reopened().copyWith(startedAt: now),
    Stage.notStarted => reopened().copyWith(clearStartedAt: true),
  };

  /// Which of the board's columns this task is in.
  Stage get stage => done
      ? Stage.done
      : startedAt != null
      ? Stage.inProgress
      : Stage.notStarted;

  /// How many of the checklist's steps are ticked.
  int get subtasksDone => subtasks.where((s) => s.done).length;

  /// The due moment, or null for an undated task.
  DateTime? get due =>
      dueAt == null ? null : DateTime.fromMillisecondsSinceEpoch(dueAt!);

  /// The due date with the time stripped — the calendar day this task sits on.
  DateTime? get dueDay {
    final d = due;
    return d == null ? null : DateTime(d.year, d.month, d.day);
  }

  /// True when an open task's due moment is already in the past. All-day tasks
  /// only count as overdue once their whole day has passed.
  bool get isOverdue {
    final d = due;
    if (done || d == null) return false;
    final now = DateTime.now();
    if (!hasTime) {
      return DateTime(
        d.year,
        d.month,
        d.day,
      ).isBefore(DateTime(now.year, now.month, now.day));
    }
    return d.isBefore(now);
  }

  Task copyWith({
    int? id,
    int? listId,
    String? title,
    String? notes,
    int? dueAt,
    bool clearDueAt = false,
    bool? hasTime,
    bool? done,
    Priority? priority,
    Repeat? repeat,
    String? styleId,
    bool clearStyleId = false,
    int? createdAt,
    int? completedAt,
    bool clearCompletedAt = false,
    int? sortOrder,
    bool clearSortOrder = false,
    List<Subtask>? subtasks,
    int? remindBefore,
    bool clearRemindBefore = false,
    int? snoozedUntil,
    bool clearSnoozedUntil = false,
    int? startedAt,
    bool clearStartedAt = false,
    int? duration,
    bool clearDuration = false,
  }) {
    return Task(
      id: id ?? this.id,
      listId: listId ?? this.listId,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      dueAt: clearDueAt ? null : (dueAt ?? this.dueAt),
      hasTime: hasTime ?? this.hasTime,
      done: done ?? this.done,
      priority: priority ?? this.priority,
      repeat: repeat ?? this.repeat,
      styleId: clearStyleId ? null : (styleId ?? this.styleId),
      createdAt: createdAt ?? this.createdAt,
      completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
      sortOrder: clearSortOrder ? null : (sortOrder ?? this.sortOrder),
      subtasks: subtasks ?? this.subtasks,
      remindBefore: clearRemindBefore
          ? null
          : (remindBefore ?? this.remindBefore),
      snoozedUntil: clearSnoozedUntil
          ? null
          : (snoozedUntil ?? this.snoozedUntil),
      startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
      duration: clearDuration ? null : (duration ?? this.duration),
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'list_id': listId,
      'title': title,
      'notes': notes,
      'due_at': dueAt,
      'has_time': hasTime ? 1 : 0,
      'done': done ? 1 : 0,
      'priority': priority.index,
      'repeat_rule': repeat.toRule(),
      'style_id': styleId,
      'created_at': createdAt,
      'completed_at': completedAt,
      'sort_order': sortOrder,
      'subtasks': jsonEncode([for (final s in subtasks) s.toJson()]),
      'remind_before': remindBefore,
      'snoozed_until': snoozedUntil,
      'started_at': startedAt,
      'duration': duration,
    };
  }

  factory Task.fromMap(Map<String, Object?> map) {
    return Task(
      id: map['id'] as int?,
      listId: map['list_id'] as int? ?? 1,
      title: map['title'] as String? ?? '',
      notes: map['notes'] as String? ?? '',
      dueAt: map['due_at'] as int?,
      hasTime: (map['has_time'] as int? ?? 0) == 1,
      done: (map['done'] as int? ?? 0) == 1,
      priority: Priority.byIndex(map['priority'] as int?),
      repeat: Repeat.fromRule(map['repeat_rule'] as String?),
      styleId: map['style_id'] as String?,
      createdAt: map['created_at'] as int? ?? 0,
      completedAt: map['completed_at'] as int?,
      sortOrder: map['sort_order'] as int?,
      subtasks: _subtasksFrom(map['subtasks'] as String?),
      remindBefore: map['remind_before'] as int?,
      snoozedUntil: map['snoozed_until'] as int?,
      startedAt: map['started_at'] as int?,
      duration: map['duration'] as int?,
    );
  }

  /// The stored checklist, or none if there is none or it cannot be read — a
  /// task is worth more than a checklist that will not parse.
  static List<Subtask> _subtasksFrom(String? text) {
    if (text == null || text.isEmpty) return const [];
    try {
      final decoded = jsonDecode(text);
      if (decoded is! List) return const [];
      return [for (final item in decoded) ?Subtask.fromJson(item)];
    } on FormatException {
      return const [];
    }
  }
}

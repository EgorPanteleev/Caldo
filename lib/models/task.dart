/// How often a task comes back after it is completed.
enum Repeat {
  none('Never'),
  daily('Every day'),
  weekly('Every week'),
  monthly('Every month'),
  yearly('Every year');

  const Repeat(this.label);

  final String label;

  static Repeat byName(String? name) =>
      Repeat.values.firstWhere((r) => r.name == name, orElse: () => Repeat.none);

  /// The next due date after [from], or null when the task does not repeat.
  DateTime? next(DateTime from) {
    return switch (this) {
      Repeat.none => null,
      Repeat.daily => from.add(const Duration(days: 1)),
      Repeat.weekly => from.add(const Duration(days: 7)),
      // Clamps to the last day of the target month (31 Jan -> 28/29 Feb).
      Repeat.monthly => _shiftMonths(from, 1),
      Repeat.yearly => _shiftMonths(from, 12),
    };
  }

  static DateTime _shiftMonths(DateTime from, int months) {
    final total = from.month - 1 + months;
    final year = from.year + total ~/ 12;
    final month = total % 12 + 1;
    final lastDay = DateTime(year, month + 1, 0).day;
    return DateTime(year, month, from.day.clamp(1, lastDay), from.hour,
        from.minute);
  }
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

  /// Epoch millis of creation, used for sorting.
  final int createdAt;

  /// Epoch millis the task was last completed, or null while it is open.
  final int? completedAt;

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
    required this.createdAt,
    this.completedAt,
  });

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
      return DateTime(d.year, d.month, d.day)
          .isBefore(DateTime(now.year, now.month, now.day));
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
    int? createdAt,
    int? completedAt,
    bool clearCompletedAt = false,
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
      createdAt: createdAt ?? this.createdAt,
      completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
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
      'repeat_rule': repeat.name,
      'created_at': createdAt,
      'completed_at': completedAt,
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
      repeat: Repeat.byName(map['repeat_rule'] as String?),
      createdAt: map['created_at'] as int? ?? 0,
      completedAt: map['completed_at'] as int?,
    );
  }
}

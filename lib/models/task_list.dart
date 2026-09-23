import 'package:flutter/material.dart';

import 'task.dart';

/// A colour + icon identity a list can be tagged with, so lists stay
/// recognisable at a glance in the calendar and in the lists grid.
class ListStyle {
  final String id;
  final String label;
  final Color color;
  final IconData icon;

  const ListStyle({
    required this.id,
    required this.label,
    required this.color,
    required this.icon,
  });

  static const presets = <ListStyle>[
    ListStyle(
      id: 'violet',
      label: 'Violet',
      color: Color(0xFF8B5CF6),
      icon: Icons.checklist_rounded,
    ),
    ListStyle(
      id: 'blue',
      label: 'Blue',
      color: Color(0xFF3B82F6),
      icon: Icons.work_outline,
    ),
    ListStyle(
      id: 'teal',
      label: 'Teal',
      color: Color(0xFF14B8A6),
      icon: Icons.self_improvement,
    ),
    ListStyle(
      id: 'green',
      label: 'Green',
      color: Color(0xFF22C55E),
      icon: Icons.shopping_cart_outlined,
    ),
    ListStyle(
      id: 'amber',
      label: 'Amber',
      color: Color(0xFFF59E0B),
      icon: Icons.lightbulb_outline,
    ),
    ListStyle(
      id: 'pink',
      label: 'Pink',
      color: Color(0xFFEC4899),
      icon: Icons.favorite_outline,
    ),
    ListStyle(
      id: 'cyan',
      label: 'Cyan',
      color: Color(0xFF06B6D4),
      icon: Icons.school_outlined,
    ),
    ListStyle(
      id: 'orange',
      label: 'Orange',
      color: Color(0xFFF97316),
      icon: Icons.home_outlined,
    ),
  ];

  static ListStyle byId(String? id) =>
      presets.firstWhere((s) => s.id == id, orElse: () => presets.first);
}

/// A named collection of tasks, e.g. "Work" or "Groceries".
class TaskList {
  final int? id;
  final String name;

  /// Id of the [ListStyle] giving the list its colour and icon.
  final String styleId;

  /// Epoch millis of creation, used for sorting.
  final int createdAt;

  /// Number of tasks in the list (filled in by queries, not stored).
  final int taskCount;

  /// Number of tasks in the list that are not done yet (not stored).
  final int openCount;

  const TaskList({
    this.id,
    required this.name,
    this.styleId = 'violet',
    required this.createdAt,
    this.taskCount = 0,
    this.openCount = 0,
  });

  ListStyle get style => ListStyle.byId(styleId);

  TaskList copyWith({
    int? id,
    String? name,
    String? styleId,
    int? createdAt,
    int? taskCount,
    int? openCount,
  }) {
    return TaskList(
      id: id ?? this.id,
      name: name ?? this.name,
      styleId: styleId ?? this.styleId,
      createdAt: createdAt ?? this.createdAt,
      taskCount: taskCount ?? this.taskCount,
      openCount: openCount ?? this.openCount,
    );
  }

  /// Only the stored columns; `task_count`/`open_count` are query results.
  Map<String, Object?> toMap() {
    return {
      'id': id,
      'name': name,
      'style_id': styleId,
      'created_at': createdAt,
    };
  }

  factory TaskList.fromMap(Map<String, Object?> map) {
    return TaskList(
      id: map['id'] as int?,
      name: map['name'] as String? ?? '',
      styleId: map['style_id'] as String? ?? 'violet',
      createdAt: map['created_at'] as int? ?? 0,
      taskCount: map['task_count'] as int? ?? 0,
      openCount: map['open_count'] as int? ?? 0,
    );
  }
}

/// The colour a task is drawn in: its own when it has been given one, its
/// list's otherwise, and [fallback] when it has neither.
Color colorOfTask(Task task, TaskList? list, {required Color fallback}) {
  if (task.styleId != null) return ListStyle.byId(task.styleId).color;
  return list?.style.color ?? fallback;
}

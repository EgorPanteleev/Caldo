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

  /// The palette, in the order it is laid out: round the colour wheel from
  /// red, then the two that are on no wheel. Eight of them were all there
  /// was, and four of those eight were blue or green; the ids of those eight
  /// are unchanged, so what was chosen then is still its own colour. Every
  /// one is a middle tone, since a card shows a quarter of it over black:
  /// darker comes out as a black card, paler as a grey one.
  static const presets = <ListStyle>[
    ListStyle(
      id: 'red',
      label: 'Red',
      color: Color(0xFFD9473F),
      icon: Icons.local_fire_department_outlined,
    ),
    ListStyle(
      id: 'orange',
      label: 'Orange',
      color: Color(0xFFDB7A33),
      icon: Icons.home_outlined,
    ),
    ListStyle(
      id: 'amber',
      label: 'Amber',
      color: Color(0xFFD99A2B),
      icon: Icons.lightbulb_outline,
    ),
    ListStyle(
      id: 'yellow',
      label: 'Yellow',
      color: Color(0xFFCCB529),
      icon: Icons.wb_sunny_outlined,
    ),
    ListStyle(
      id: 'lime',
      label: 'Lime',
      color: Color(0xFF86AD34),
      icon: Icons.eco_outlined,
    ),
    ListStyle(
      id: 'green',
      label: 'Green',
      color: Color(0xFF35A06A),
      icon: Icons.shopping_cart_outlined,
    ),
    ListStyle(
      id: 'teal',
      label: 'Teal',
      color: Color(0xFF16A394),
      icon: Icons.self_improvement,
    ),
    ListStyle(
      id: 'cyan',
      label: 'Cyan',
      color: Color(0xFF1E94B0),
      icon: Icons.school_outlined,
    ),
    ListStyle(
      id: 'blue',
      label: 'Blue',
      color: Color(0xFF3B7DD8),
      icon: Icons.work_outline,
    ),
    ListStyle(
      id: 'indigo',
      label: 'Indigo',
      color: Color(0xFF5560D6),
      icon: Icons.nightlight_outlined,
    ),
    ListStyle(
      id: 'violet',
      label: 'Violet',
      color: Color(0xFF7B61E8),
      icon: Icons.checklist_rounded,
    ),
    ListStyle(
      id: 'purple',
      label: 'Purple',
      color: Color(0xFFA057D9),
      icon: Icons.auto_awesome_outlined,
    ),
    ListStyle(
      id: 'magenta',
      label: 'Magenta',
      color: Color(0xFFC451B5),
      icon: Icons.palette_outlined,
    ),
    ListStyle(
      id: 'pink',
      label: 'Pink',
      color: Color(0xFFD9528A),
      icon: Icons.favorite_outline,
    ),
    ListStyle(
      id: 'brown',
      label: 'Brown',
      color: Color(0xFFA06E4E),
      icon: Icons.coffee_outlined,
    ),
    ListStyle(
      id: 'graphite',
      label: 'Graphite',
      color: Color(0xFF7F858D),
      icon: Icons.circle_outlined,
    ),
  ];

  /// The order a new group is offered colours in, while there is one no
  /// group has: the eight the palette used to be first, in the order they
  /// were offered then, and after them the rest, picked to stay far apart.
  static const _forNewGroups = [
    'violet',
    'blue',
    'teal',
    'green',
    'amber',
    'pink',
    'cyan',
    'orange',
    'red',
    'lime',
    'purple',
    'yellow',
    'indigo',
    'magenta',
    'brown',
    'graphite',
  ];

  /// The colour a new group starts in: one no group in [taken] has yet, so
  /// two groups made one after another can be told apart unasked.
  static String freeFor(Set<String> taken) => _forNewGroups.firstWhere(
    (id) => !taken.contains(id),
    orElse: () => 'violet',
  );

  /// Whether [id] is a colour picked on the custom sheet rather than one of
  /// the [presets]: those are stored as `#RRGGBB` in the same column.
  static bool isCustom(String? id) => id != null && id.startsWith('#');

  /// How a colour picked on the custom sheet is stored.
  static String idOf(Color color) =>
      '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  // Asked for on every card of every build; parsed once each.
  static final _custom = <String, ListStyle>{};

  static ListStyle byId(String? id) {
    if (isCustom(id)) {
      final custom = _custom[id!];
      if (custom != null) return custom;
      final rgb = id.length == 7
          ? int.tryParse(id.substring(1), radix: 16)
          : null;
      if (rgb != null) {
        return _custom[id] = ListStyle(
          id: id,
          label: id,
          color: Color(0xFF000000 | rgb),
          icon: Icons.palette_outlined,
        );
      }
    }
    return presets.firstWhere(
      (s) => s.id == id,
      orElse: () => presets.firstWhere((s) => s.id == 'violet'),
    );
  }
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

  /// The group a task goes into when nothing says otherwise: the oldest,
  /// "Personal" unless it was renamed. Not the first in [lists], since the
  /// groups can be dragged into any order.
  static TaskList oldest(List<TaskList> lists) => lists.reduce(
    (a, b) =>
        a.createdAt < b.createdAt ||
            (a.createdAt == b.createdAt && (a.id ?? 0) <= (b.id ?? 0))
        ? a
        : b,
  );

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
Color colorOfTask(Task task, TaskList? list, {required Color fallback}) =>
    colorOfStyle(task.styleId, list, fallback: fallback);

/// [colorOfTask] for something that only carries a task's colour, not the
/// task — a tick in the Done log.
Color colorOfStyle(String? styleId, TaskList? list, {required Color fallback}) {
  if (styleId != null) return ListStyle.byId(styleId).color;
  return list?.style.color ?? fallback;
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/task.dart';
import '../models/task_list.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import 'selection_bar.dart';

/// One task in a list: a tick circle, the title, and a meta line carrying the
/// due date, the repeat rule, the notes hint and the owning list.
class TaskRow extends StatelessWidget {
  final Task task;

  /// The list the task belongs to; its colour tints the row's accents. When
  /// [showList] is true its name is shown in the meta line too.
  final TaskList? list;
  final bool showList;

  /// Hides the due date — used on the calendar, where the day is the context.
  final bool hideDate;

  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggle;

  const TaskRow({
    super.key,
    required this.task,
    this.list,
    this.showList = false,
    this.hideDate = false,
    this.selected = false,
    required this.onTap,
    required this.onLongPress,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context);
    final color = colorOfTask(task, list, fallback: accent.color);
    final overdue = task.isOverdue;
    final meta = <Widget>[];

    if (!hideDate && task.dueAt != null) {
      meta.add(
        _MetaChip(
          icon: task.hasTime ? Icons.schedule : Icons.event_outlined,
          label: Dates.due(
            task,
            h24: MediaQuery.alwaysUse24HourFormatOf(context),
          ),
          color: overdue ? AppColors.overdue : p.muted,
        ),
      );
    }
    if (task.repeat != Repeat.none) {
      meta.add(
        _MetaChip(icon: Icons.repeat, label: task.repeat.label, color: p.faint),
      );
    }
    if (task.notes.trim().isNotEmpty) {
      meta.add(
        _MetaChip(
          icon: Icons.notes,
          label: task.notes.trim().split('\n').first,
          color: p.faint,
        ),
      );
    }
    if (showList && list != null) {
      meta.add(
        _MetaChip(
          icon: Icons.circle,
          iconSize: 8,
          label: list!.name,
          color: color,
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          decoration: BoxDecoration(
            color: selected ? accent.color.withValues(alpha: 0.14) : null,
            border: Border(bottom: BorderSide(color: p.border)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  _CheckCircle(done: task.done, color: color, onTap: onToggle),
                  if (selected)
                    const Positioned(
                      right: -6,
                      bottom: -6,
                      child: SelectionCheck(),
                    ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      style: TextStyle(
                        color: task.done ? p.faint : p.text,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                        decoration: task.done
                            ? TextDecoration.lineThrough
                            : null,
                        decorationColor: p.faint,
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      // Wraps onto a second line rather than clipping when a
                      // task carries a date, a repeat rule, notes and a list.
                      Wrap(spacing: 12, runSpacing: 4, children: meta),
                    ],
                  ],
                ),
              ),
              if (task.priority != Priority.none) ...[
                const SizedBox(width: 10),
                PriorityFlag(priority: task.priority),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Identifies the tick circle inside a task row.
const checkKey = Key('task-check');

/// The tappable tick circle at the head of a task row.
class _CheckCircle extends StatelessWidget {
  final bool done;
  final Color color;
  final VoidCallback onTap;

  const _CheckCircle({
    required this.done,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return GestureDetector(
      key: checkKey,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        // A comfortable tap target around a deliberately small circle.
        padding: const EdgeInsets.all(3),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: done ? color : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: done ? color : p.faint, width: 1.8),
          ),
          child: done
              ? const Icon(Icons.check, color: Colors.white, size: 15)
              : null,
        ),
      ),
    );
  }
}

/// One item of a task row's meta line: a small icon and its label.
class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final double iconSize;

  const _MetaChip({
    required this.icon,
    required this.label,
    required this.color,
    this.iconSize = 13,
  });

  /// Long labels (notes, a long list name) ellipsise instead of pushing the
  /// other chips off the row.
  static const _maxLabelWidth = 170.0;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: iconSize, color: color),
        const SizedBox(width: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxLabelWidth),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

/// A small coloured flag standing for a task's priority.
class PriorityFlag extends StatelessWidget {
  final Priority priority;
  const PriorityFlag({super.key, required this.priority});

  static const _colors = {
    Priority.low: Color(0xFF60A5FA),
    Priority.medium: Color(0xFFF59E0B),
    Priority.high: Color(0xFFEF4444),
  };

  static Color colorOf(Priority priority) =>
      _colors[priority] ?? const Color(0xFF9394A1);

  @override
  Widget build(BuildContext context) {
    final color = colorOf(priority);
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Icon(Icons.flag, size: 14, color: color),
    );
  }
}

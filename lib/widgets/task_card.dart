import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/holidays.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';

/// A task as it appears under the calendar: a card inked with its list's
/// colour, carrying a tick, the title and when it is due.
///
/// The ink is mixed into the ground rather than laid over it, which is what
/// keeps it a deep, flat colour instead of a haze: a quarter of the list's
/// colour against true black comes out as the near-navy the cards wear. There
/// is no border — the fill is the shape, and an outline a shade brighter than
/// it only blurred the edge.
class TaskCard extends StatelessWidget {
  final Task task;
  final TaskList? list;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggle;

  const TaskCard({
    super.key,
    required this.task,
    this.list,
    required this.onTap,
    required this.onLongPress,
    required this.onToggle,
  });

  /// "All day", or the time it is due, and the repeat rule if it has one. Not
  /// the list it belongs to: the tick already wears that list's colour, and
  /// under the calendar a day's tasks are usually all from the same one, so
  /// the name was the same word under every card.
  String _subtitle() {
    final due = task.due;
    final when = due == null
        ? 'No date'
        : (task.hasTime ? Dates.time(due) : 'All day');
    final parts = [
      when,
      if (task.repeat != Repeat.none) task.repeat.label,
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final color = colorOfTask(task, list,
        fallback: AppTheme.accentOf(context).color);
    final faded = task.done;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              // A done task sinks most of the way back into the ground rather
              // than keeping its place in the run.
              color: Color.alphaBlend(
                color.withValues(alpha: faded ? 0.07 : 0.24),
                p.bg,
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _Tick(done: task.done, color: color, onTap: onToggle),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: faded ? p.faint : p.text,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w500,
                          decoration:
                              faded ? TextDecoration.lineThrough : null,
                          decorationColor: p.faint,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _subtitle(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: task.isOverdue ? AppColors.overdue : p.muted,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                if (task.priority != Priority.none) ...[
                  const SizedBox(width: 10),
                  Icon(Icons.flag,
                      size: 16, color: _priorityColor(task.priority)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Color _priorityColor(Priority priority) => switch (priority) {
        Priority.high => const Color(0xFFEF4444),
        Priority.medium => const Color(0xFFF59E0B),
        Priority.low => const Color(0xFF60A5FA),
        Priority.none => const Color(0xFF9394A1),
      };
}

/// The tappable tick circle on a card.
class _Tick extends StatelessWidget {
  final bool done;
  final Color color;
  final VoidCallback onTap;

  const _Tick({required this.done, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: taskCardTickKey,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: done ? color : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          // Outlined in the task's own colour rather than a neutral grey:
          // with the card itself plain, this is the only place the colour a
          // task was given is still said, and an empty square is a small
          // enough mark to say it without tinting the whole run.
          border: Border.all(color: color, width: 1.8),
        ),
        child: done
            ? const Icon(Icons.check, color: Colors.white, size: 15)
            : null,
      ),
    );
  }
}

/// Identifies the tick circle on a task card.
const taskCardTickKey = Key('task-card-tick');

/// A public holiday beside a day's tasks: the same card as a [TaskCard], with
/// a green mark where the tick would be and nothing to tick off.
class HolidayCard extends StatelessWidget {
  final Holiday holiday;

  const HolidayCard({super.key, required this.holiday});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: Color.alphaBlend(
            AppColors.holiday.withValues(alpha: 0.22),
            p.bg,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.celebration_outlined,
              color: AppColors.holiday,
              size: 22,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    holiday.name,
                    style: TextStyle(
                      color: p.text,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Public holiday',
                    style: TextStyle(color: p.muted, fontSize: 12.5),
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

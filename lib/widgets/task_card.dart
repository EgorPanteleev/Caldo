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
/// The ink is a quarter of the list's colour over whatever the card is
/// standing on, which against true black comes out as the near-navy the cards
/// wear. Left translucent rather than mixed into one named colour, so a card
/// is inked by the ground it actually sits on — the calendar's day panel is a
/// grey, the agenda and the day card are black, and a card worked out against
/// the wrong one of those is a card darker than the sheet under it. There is
/// no border: the fill is the shape, and an outline a shade brighter than it
/// only blurred the edge.
class TaskCard extends StatelessWidget {
  /// The room a card leaves around itself, and the corners it is cut to.
  /// Out here because a card being carried is backed in its own shape, and
  /// two places guessing at the same rectangle would drift.
  static const margin = EdgeInsets.fromLTRB(16, 0, 16, 8);
  static const radius = 14.0;

  final Task task;
  final TaskList? list;
  final VoidCallback onTap;

  /// Null where a long press belongs to something else — a list that can be
  /// dragged into a new order takes it to start the drag.
  final VoidCallback? onLongPress;
  final VoidCallback onToggle;

  const TaskCard({
    super.key,
    required this.task,
    this.list,
    required this.onTap,
    this.onLongPress,
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
    final parts = [when, if (task.repeat != Repeat.none) task.repeat.label];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final color = colorOfTask(
      task,
      list,
      fallback: AppTheme.accentOf(context).color,
    );
    final faded = task.done;

    return Padding(
      padding: TaskCard.margin,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(TaskCard.radius),
          child: AnimatedContainer(
            // Ticked off, a card sinks over a moment rather than between two
            // frames: the point of the gesture is seeing it happen.
            duration: _settle,
            curve: Curves.easeOut,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              // A done task sinks most of the way back into the ground rather
              // than keeping its place in the run.
              color: color.withValues(alpha: faded ? 0.07 : 0.24),
              borderRadius: BorderRadius.circular(TaskCard.radius),
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
                      AnimatedDefaultTextStyle(
                        duration: _settle,
                        curve: Curves.easeOut,
                        style: TextStyle(
                          color: faded ? p.faint : p.text,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w500,
                          decoration: faded ? TextDecoration.lineThrough : null,
                          decorationColor: p.faint,
                        ),
                        child: Text(
                          task.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
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
                  Icon(
                    Icons.flag,
                    size: 16,
                    color: _priorityColor(task.priority),
                  ),
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

/// How long a card takes to settle into its new state once it is ticked —
/// long enough to be seen as something happening, short enough that the run
/// it sits in is not left waiting on it. The list holds its reordering for
/// the same stretch, so the card is still under the finger that ticked it
/// while the tick is being drawn (`TaskProvider.toggleDone`).
const _settle = Duration(milliseconds: 240);

/// The tappable tick on a card.
///
/// Ticking something off is the one gesture in this app worth watching
/// happen, so the mark is drawn rather than switched on: the square fills
/// and the stroke runs through it, over [_settle]. It used to appear whole
/// between two frames, which — with the card leaving for the done end of
/// the run in the same instant — meant the gesture had no moment at all.
///
/// Coming off, it goes in half the time and without the drawing: undoing is
/// a correction, and a correction should not be a flourish.
class _Tick extends StatefulWidget {
  final bool done;
  final Color color;
  final VoidCallback onTap;

  const _Tick({required this.done, required this.color, required this.onTap});

  @override
  State<_Tick> createState() => _TickState();
}

class _TickState extends State<_Tick> with SingleTickerProviderStateMixin {
  late final AnimationController _draw = AnimationController(
    vsync: this,
    duration: _settle,
    reverseDuration: const Duration(milliseconds: 110),
    value: widget.done ? 1 : 0,
  );

  @override
  void didUpdateWidget(_Tick old) {
    super.didUpdateWidget(old);
    if (widget.done != old.done) {
      widget.done ? _draw.forward() : _draw.reverse();
    }
  }

  @override
  void dispose() {
    _draw.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: taskCardTickKey,
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: _draw,
        builder: (context, _) {
          // The square fills first and the stroke follows it in, so the two
          // read as one movement rather than a fill with a mark dropped on
          // top of it.
          final fill = Curves.easeOut.transform(_draw.value);
          final mark = Curves.easeOutCubic.transform(
            ((_draw.value - 0.25) / 0.75).clamp(0.0, 1.0),
          );
          return Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: fill),
              borderRadius: BorderRadius.circular(7),
              // Outlined in the task's own colour rather than a neutral grey:
              // with the card itself plain, this is the only place the colour
              // a task was given is still said, and an empty square is a
              // small enough mark to say it without tinting the whole run.
              border: Border.all(color: widget.color, width: 1.8),
            ),
            child: CustomPaint(
              key: taskCardMarkKey,
              painter: CheckMark(progress: mark),
            ),
          );
        },
      ),
    );
  }
}

/// The tick's stroke, drawn as far as [progress].
///
/// Public, and holding the progress where a test can read it, for the same
/// reason `dayChipColour` is: the thing worth pinning is that the mark is
/// drawn over a moment rather than switched on, and nothing about how it is
/// painted should have to be pinned with it.
class CheckMark extends CustomPainter {
  final double progress;
  final Color color;

  const CheckMark({required this.progress, this.color = Colors.white});

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.26, h * 0.52)
      ..lineTo(w * 0.44, h * 0.70)
      ..lineTo(w * 0.76, h * 0.32);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (progress >= 1) {
      canvas.drawPath(path, paint);
      return;
    }
    // Drawn to the same fraction of the whole stroke rather than of each
    // leg, so the short leg does not take as long as the long one.
    final total = [
      for (final metric in path.computeMetrics()) metric.length,
    ].fold<double>(0, (a, b) => a + b);
    var left = total * progress;
    final drawn = Path();
    for (final metric in path.computeMetrics()) {
      if (left <= 0) break;
      drawn.addPath(
        metric.extractPath(0, left.clamp(0, metric.length)),
        Offset.zero,
      );
      left -= metric.length;
    }
    canvas.drawPath(drawn, paint);
  }

  @override
  bool shouldRepaint(CheckMark old) =>
      old.progress != progress || old.color != color;
}

/// Identifies the tick circle on a task card, and the mark inside it.
const taskCardTickKey = Key('task-card-tick');
const taskCardMarkKey = Key('task-card-mark');

/// A public holiday beside a day's tasks: the same card as a [TaskCard], with
/// a green mark where the tick would be and nothing to tick off.
class HolidayCard extends StatelessWidget {
  final Holiday holiday;

  const HolidayCard({super.key, required this.holiday});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: TaskCard.margin,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: AppColors.holiday.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(TaskCard.radius),
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

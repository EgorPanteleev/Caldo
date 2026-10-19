import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/task.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import 'task_card.dart';

/// Ticks [task] off, or takes its tick back, from a card — and when it was
/// ticked off, offers a moment to take that back.
///
/// The bar stays four seconds. Undo puts the task back exactly as it was
/// before the tap (`TaskProvider.restore`): not done, and on its own date if
/// it was a repeating task that had rolled on — ticking it again would only
/// have rolled it a second time. Taking a tick back by tapping the tick needs
/// no bar: it is already an undo.
void tickOff(BuildContext context, Task task) {
  final provider = context.read<TaskProvider>();
  final messenger = ScaffoldMessenger.of(context);
  final completing = !task.done;
  provider.toggleDone(task);
  if (!completing) return;

  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        // The bar draws itself; the snack bar only carries it in and out.
        backgroundColor: Colors.transparent,
        elevation: 0,
        padding: EdgeInsets.zero,
        duration: _undoFor,
        // A bar with an action otherwise stays until it is dismissed, and an
        // offer to take a tick back is only worth making for a moment.
        persist: false,
        // Over the add field rather than on it: the field is the next thing
        // most often reached for, and a bar sitting on it for four seconds
        // would be in the way of exactly that.
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 78),
        content: _UndoBar(
          task: task,
          onUndo: () {
            messenger.hideCurrentSnackBar();
            provider.restore(task);
          },
        ),
      ),
    );
}

const _undoFor = Duration(seconds: 4);

/// What a tick off leaves on screen for a moment: the task, wearing the same
/// filled tick its card now does, and a way to take it back.
///
/// It is in the add field's grey and lifted off the cards with a shadow,
/// rather than the flat slab a snack bar is by default, which sat on a list of
/// cards like one more of them. Along its foot a line runs down over the four
/// seconds it stays, so the offer says how long it is open.
class _UndoBar extends StatelessWidget {
  final Task task;
  final VoidCallback onUndo;

  const _UndoBar({required this.task, required this.onUndo});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context).color;
    final radius = BorderRadius.circular(16);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Material(
          color: p.field,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                child: Row(
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const CustomPaint(painter: CheckMark(progress: 1)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        task.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: onUndo,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CustomPaint(
                                painter: _UndoArrow(color: accent),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Undo',
                              style: TextStyle(
                                color: accent,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 1, end: 0),
                  duration: _undoFor,
                  builder: (context, left, _) => Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: left,
                      child: Container(
                        height: 2.5,
                        color: accent.withValues(alpha: 0.8),
                      ),
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

/// Builds a task's card from [task] as it is shown right now
/// (`TaskProvider.shown`), and again whenever a tick moves on.
///
/// The card listens to the tick rather than to the provider, so drawing a
/// tick or crossing a card out rebuilds that card and nothing around it.
class AsShown extends StatelessWidget {
  final Task task;
  final Widget Function(BuildContext context, Task task) builder;

  const AsShown({super.key, required this.task, required this.builder});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<TaskProvider>();
    return ListenableBuilder(
      listenable: provider.ticked,
      builder: (context, _) => builder(context, provider.shown(task)),
    );
  }
}

/// The arrow beside Undo, drawn in the same round-ended stroke as the tick on
/// the other end of the bar: a head pointing back, and a line that runs out
/// and curls round under it. The stock icon was a filled hook of a different
/// weight from everything else on the bar.
class _UndoArrow extends CustomPainter {
  final Color color;

  const _UndoArrow({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    // Laid out on a 24-point square and scaled to whatever it is given.
    final k = size.width / 24;
    Offset at(double x, double y) => Offset(x * k, y * k);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4 * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final head = Path()
      ..moveTo(at(9, 14).dx, at(9, 14).dy)
      ..lineTo(at(4, 9).dx, at(4, 9).dy)
      ..lineTo(at(9, 4).dx, at(9, 4).dy);
    final radius = Radius.circular(5.5 * k);
    final tail = Path()
      ..moveTo(at(4, 9).dx, at(4, 9).dy)
      ..lineTo(at(14.5, 9).dx, at(14.5, 9).dy)
      ..arcToPoint(at(14.5, 20), radius: radius)
      ..lineTo(at(11, 20).dx, at(11, 20).dy);
    canvas
      ..drawPath(head, paint)
      ..drawPath(tail, paint);
  }

  @override
  bool shouldRepaint(_UndoArrow old) => old.color != color;
}

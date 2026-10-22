import 'package:flutter/material.dart';

import '../models/task.dart';
import '../theme/app_theme.dart';

/// A task card picked up in one of the reorderable lists, followed for as long
/// as it is carried, and handed to another day if it is let go over one.
///
/// The lists stay what they were — a card picked up and put down inside its
/// own run is still a change of order, done by the list. What this adds is
/// everywhere else the finger can go: [resolve] says what a card let go at a
/// point would land on, if anything other than its own run, and a card let
/// go there is taken off the list (`cancelReorder`, so it does not first
/// glide back to its old place) and handed to [CarryArea.onDrop].
class Carry<T extends Object> extends ChangeNotifier {
  /// What a card let go at a point on the screen would land on, or null for
  /// nowhere new — its own run, or somewhere it cannot go.
  final T? Function(Task task, Offset global) resolve;

  /// Where on the screen the carried card is drawn, shrunk, over a point
  /// where it should not be a card — over the month it is the day under the
  /// finger, so it reads as something going into that day. Null elsewhere,
  /// and null throughout for a screen that never shrinks it.
  final Rect? Function(Offset global)? shrinkTo;

  Carry({required this.resolve, this.shrinkTo});

  Task? _task;
  VoidCallback? _cancel;
  Offset? _pointer;
  T? _target;
  Rect? _shrink;

  /// The task being carried, or null when nothing is.
  Task? get task => _task;

  /// Where the finger is, on the screen.
  Offset? get pointer => _pointer;

  /// What the card would land on if it were let go now.
  T? get target => _target;

  /// Where the carried card should be drawn shrunk now (see [shrinkTo]).
  Rect? get shrink => _shrink;

  bool get active => _task != null;

  /// Called by a list when one of its cards is picked up; [cancel] takes the
  /// card back off it without the drop it would otherwise animate.
  void begin(Task task, VoidCallback cancel) {
    _task = task;
    _cancel = cancel;
    _aim();
  }

  /// Called by a list when its card has been put down in it.
  void end() {
    if (_task == null) return;
    _task = null;
    _cancel = null;
    _target = null;
    _shrink = null;
    notifyListeners();
  }

  void _move(Offset global) {
    _pointer = global;
    if (active) _aim();
  }

  void _aim() {
    final at = _pointer;
    _target = at == null ? null : resolve(_task!, at);
    _shrink = at == null ? null : shrinkTo?.call(at);
    // Every move, not only every change of target: what is drawn to show
    // where the card will land follows the finger within a target too.
    notifyListeners();
  }

  /// Let go: hands the task over if it is over somewhere new, and otherwise
  /// leaves the list to put it down.
  void _release(void Function(Task task, T target) onDrop) {
    final task = _task;
    final target = _target;
    if (task != null && target != null) {
      _cancel?.call();
      end();
      onDrop(task, target);
    } else {
      end();
    }
  }
}

/// The part of the screen a card can be carried over.
///
/// It listens to the pointer rather than taking part in the gesture: the
/// list's own drag goes on exactly as before, and this only watches where it
/// goes. A pointer's events go to whatever it first came down on, so a card
/// picked up inside this area is followed wherever it is taken. And they
/// arrive here before the list's drag hears of them, which is what lets a
/// release over another day take the card off the list before the list
/// starts putting it back.
class CarryArea<T extends Object> extends StatelessWidget {
  final Carry<T> carry;
  final void Function(Task task, T target) onDrop;
  final Widget child;

  const CarryArea({
    super.key,
    required this.carry,
    required this.onDrop,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) => carry._move(event.position),
      onPointerMove: (event) => carry._move(event.position),
      onPointerUp: (event) => carry._release(onDrop),
      onPointerCancel: (event) => carry.end(),
      child: child,
    );
  }
}

/// Draws where a carried card would land — over everything in [child],
/// the carried card included, which is the one thing most likely to be on top
/// of the spot it is being carried to.
///
/// [mark] gives the place, on the screen, for a target; [line] says whether
/// that is a slot between two cards, drawn as a rule, or a whole day, drawn
/// as an outline.
class CarryMark<T extends Object> extends StatefulWidget {
  final Carry<T> carry;
  final Rect? Function(T target) mark;
  final bool line;
  final Widget child;

  const CarryMark({
    super.key,
    required this.carry,
    required this.mark,
    required this.line,
    required this.child,
  });

  @override
  State<CarryMark<T>> createState() => _CarryMarkState<T>();
}

class _CarryMarkState<T extends Object> extends State<CarryMark<T>> {
  final _box = GlobalKey();

  @override
  Widget build(BuildContext context) {
    // The neutral, like every other mark of where something is.
    final accent = AppTheme.of(context).text;
    return CustomPaint(
      key: _box,
      foregroundPainter: _MarkPainter<T>(
        carry: widget.carry,
        mark: widget.mark,
        line: widget.line,
        colour: accent,
        box: _box,
      ),
      child: widget.child,
    );
  }
}

class _MarkPainter<T extends Object> extends CustomPainter {
  final Carry<T> carry;
  final Rect? Function(T target) mark;
  final bool line;
  final Color colour;
  final GlobalKey box;

  _MarkPainter({
    required this.carry,
    required this.mark,
    required this.line,
    required this.colour,
    required this.box,
  }) : super(repaint: carry);

  @override
  void paint(Canvas canvas, Size size) {
    final target = carry.target;
    final render = box.currentContext?.findRenderObject() as RenderBox?;
    if (target == null || render == null || !render.attached) return;
    final global = mark(target);
    if (global == null) return;
    final rect = Rect.fromPoints(
      render.globalToLocal(global.topLeft),
      render.globalToLocal(global.bottomRight),
    );
    if (line) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: rect.center, width: rect.width, height: 3),
          const Radius.circular(1.5),
        ),
        Paint()..color = colour,
      );
    } else {
      final cell = RRect.fromRectAndRadius(
        rect.deflate(2),
        const Radius.circular(8),
      );
      canvas.drawRRect(cell, Paint()..color = colour.withValues(alpha: 0.18));
      canvas.drawRRect(
        cell,
        Paint()
          ..color = colour
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_MarkPainter<T> old) => true;
}

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import 'task_card.dart';

/// Ticks [task] off, or takes its tick back, from a card — and when it was
/// ticked off, offers a moment to take that back.
///
/// The bar stays four seconds, or longer while a finger is on it, and can be
/// brushed off sooner. Undo puts the task back exactly as it was before the
/// tap (`TaskProvider.restore`): not done, and on its own date if it was a
/// repeating task that had rolled on — ticking it again would only have
/// rolled it a second time. Taking a tick back by tapping the tick needs no
/// bar: it is already an undo.
void tickOff(BuildContext context, Task task) {
  final provider = context.read<TaskProvider>();
  final messenger = ScaffoldMessenger.of(context);
  final completing = !task.done;
  provider.toggleDone(task);
  if (!completing) return;

  // A bar on its way out can still finish its countdown or be let go of, and
  // closing "the current one" then would close the bar that replaced it.
  final offer = ++_offers;
  bool current() => offer == _offers;

  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        // The bar draws itself; the snack bar only carries it in and out.
        backgroundColor: Colors.transparent,
        elevation: 0,
        padding: EdgeInsets.zero,
        // Unclipped, or the bar's shadow is cut off at its own edge and a
        // drag cuts the bar off at the snack bar's.
        clipBehavior: Clip.none,
        // The bar does its own dismissing: it follows the finger either way
        // and keeps its own time, which stops while it is held.
        dismissDirection: DismissDirection.none,
        persist: true,
        // As wide as what it says, so the cards either side of it can still
        // be tapped: the snack bar's box takes every tap inside it. Over the
        // add field rather than on it: the field is the next thing most often
        // reached for, and a bar sitting on it for four seconds would be in
        // the way of exactly that.
        margin: _UndoBar.marginFor(context, task.title),
        content: _UndoBar(
          task: task,
          onUndo: () {
            if (current()) messenger.hideCurrentSnackBar();
            provider.restore(task);
          },
          onTimeout: () {
            if (current()) {
              messenger.hideCurrentSnackBar(
                reason: SnackBarClosedReason.timeout,
              );
            }
          },
          // Already faded out where it was thrown, so it goes at once rather
          // than fading a second time.
          onBrushedOff: () {
            if (current()) {
              messenger.removeCurrentSnackBar(
                reason: SnackBarClosedReason.swipe,
              );
            }
          },
        ),
      ),
    );
}

int _offers = 0;

const _undoFor = Duration(seconds: 4);

/// What a tick off leaves on screen for a moment: the task, ticked, and a way
/// to take it back.
///
/// A pill as wide as its words, in a grey a step above the add field's, with
/// a hairline rim and a shadow to lift it off the cards. Full width it had
/// the cards' own width and corners, and sat on the list like one more of
/// them. Around the tick a ring runs down over the four seconds the offer is
/// open — it was a line along the bar's foot, whose ends the bar's rounded
/// corners sheared off.
///
/// Undo is the only thing on it in the accent. The tick was a filled accent
/// square and the line an accent rule as well, and with the button that made
/// three purple things on one small bar — "too many accent colours".
///
/// It can be brushed off to either side or down: it follows the finger,
/// fading as it goes, and either carries on out of a throw or settles back.
/// A finger resting on it holds the countdown, since someone holding the
/// offer is still deciding.
class _UndoBar extends StatefulWidget {
  final Task task;
  final VoidCallback onUndo;
  final VoidCallback onTimeout;
  final VoidCallback onBrushedOff;

  const _UndoBar({
    required this.task,
    required this.onUndo,
    required this.onTimeout,
    required this.onBrushedOff,
  });

  static const _ring = 26.0;
  static const _arrow = 18.0;

  // Everything on the bar but its two words, left to right.
  static const _around = 12 + _ring + 10 + 10 + 14 + _arrow + 6 + 14 + 4;

  static TextStyle _titleStyle(AppPalette p) =>
      TextStyle(color: p.text, fontSize: 15, fontWeight: FontWeight.w600);

  static TextStyle _undoStyle(Color accent) =>
      TextStyle(color: accent, fontSize: 15, fontWeight: FontWeight.w700);

  /// The snack bar's margin for a bar about [title]: as much either side as
  /// the bar does not need. A long title is held 16 points off the edges and
  /// ends in an ellipsis.
  static EdgeInsets marginFor(BuildContext context, String title) {
    final p = AppTheme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    double measure(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final words =
        measure(title, _titleStyle(p)) +
        measure(S.of(context).undo, _undoStyle(Colors.white));
    // A few points spare: laid out in the bar, each of the two words comes
    // out a point or so wider than the painter here says, and a title one
    // point short of its room loses its last letter to an ellipsis.
    final screen = MediaQuery.sizeOf(context).width;
    final width = (_around + words + 6).ceilToDouble();
    final side = math.max(16.0, (screen - width) / 2);
    return EdgeInsets.fromLTRB(side, 0, side, 78);
  }

  @override
  State<_UndoBar> createState() => _UndoBarState();
}

class _UndoBarState extends State<_UndoBar> with TickerProviderStateMixin {
  /// The offer left, from 1 down to 0.
  late final _left = AnimationController(
    vsync: this,
    duration: _undoFor,
    value: 1,
  )..addStatusListener(_onLeft);

  late final _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  )..forward();

  /// Carries the bar from where the finger left it, back home or away.
  late final _fling = AnimationController(vsync: this)..addListener(_onFling);

  var _drag = Offset.zero;
  var _from = Offset.zero;
  var _to = Offset.zero;
  var _gone = false;

  var _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _run();
  }

  void _run() {
    // With a screen reader the offer stays until it is answered, as a snack
    // bar's own timer would have it.
    if (MediaQuery.accessibleNavigationOf(context)) return;
    if (!_gone) _left.reverse();
  }

  void _onLeft(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !_gone) {
      _gone = true;
      widget.onTimeout();
    }
  }

  void _onFling() {
    setState(() {
      _drag = Offset.lerp(
        _from,
        _to,
        Curves.easeOutCubic.transform(_fling.value),
      )!;
    });
  }

  double get _width => MediaQuery.sizeOf(context).width;

  // Upwards there is nowhere to throw it, so it only gives a little.
  Offset get _shown => Offset(_drag.dx, _drag.dy > 0 ? _drag.dy : _drag.dy / 4);

  // Solid for the first part of a pull: faded from the start, the card under
  // it showed through the words on the bar before it had gone anywhere.
  double get _opacity {
    final s = _shown;
    final away = math.max(
      (s.dx.abs() - _width * 0.15) / (_width * 0.45),
      (s.dy - 24) / 70,
    );
    return 1 - away.clamp(0.0, 1.0);
  }

  void _hold(DragDownDetails _) {
    if (_gone) return;
    _left.stop();
    _fling.stop();
  }

  void _move(DragUpdateDetails details) {
    if (_gone) return;
    setState(() => _drag += details.delta);
  }

  void _let(DragEndDetails details) {
    if (_gone) return;
    final v = details.velocity.pixelsPerSecond;
    final s = _shown;
    final sideways = s.dx.abs() >= s.dy || v.dx.abs() > v.dy.abs();
    final thrown = sideways
        ? s.dx.abs() > _width * 0.25 ||
              (v.dx.abs() > 700 && v.dx.sign == s.dx.sign)
        : s.dy > 36 || v.dy > 700;
    if (!thrown) {
      _settle(const Duration(milliseconds: 240), Offset.zero);
      _run();
      return;
    }
    _gone = true;
    _left.stop();
    final to = sideways
        ? Offset(s.dx.sign * _width, _drag.dy)
        : Offset(_drag.dx, _drag.dy + 120);
    _settle(const Duration(milliseconds: 180), to).whenComplete(() {
      if (mounted) widget.onBrushedOff();
    });
  }

  void _cancel() {
    if (_gone) return;
    _settle(const Duration(milliseconds: 240), Offset.zero);
    _run();
  }

  TickerFuture _settle(Duration duration, Offset to) {
    _from = _drag;
    _to = to;
    _fling.duration = duration;
    return _fling.forward(from: 0);
  }

  @override
  void dispose() {
    _left.dispose();
    _enter.dispose();
    _fling.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context).color;
    final ground = Color.alphaBlend(p.text.withValues(alpha: 0.06), p.field);
    final bar = DecoratedBox(
      decoration: ShapeDecoration(
        color: ground,
        shape: StadiumBorder(
          side: BorderSide(color: p.text.withValues(alpha: 0.08)),
        ),
        shadows: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              SizedBox.square(
                dimension: _UndoBar._ring,
                child: CustomPaint(
                  painter: _Countdown(left: _left, color: p.muted),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.task.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _UndoBar._titleStyle(p),
                ),
              ),
              const SizedBox(width: 10),
              InkWell(
                onTap: _gone ? null : widget.onUndo,
                customBorder: const StadiumBorder(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox.square(
                        dimension: _UndoBar._arrow,
                        child: CustomPaint(painter: _UndoArrow(color: accent)),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        S.of(context).undo,
                        style: _UndoBar._undoStyle(accent),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return GestureDetector(
      onPanDown: _hold,
      onPanUpdate: _move,
      onPanEnd: _let,
      onPanCancel: _cancel,
      child: AnimatedBuilder(
        animation: _enter,
        builder: (context, child) {
          // Rises a little into place as the snack bar fades it in.
          final t = Curves.easeOutCubic.transform(_enter.value);
          return Transform.translate(
            offset: _shown + Offset(0, 14 * (1 - t)),
            child: Transform.scale(
              scale: 0.94 + 0.06 * t,
              child: Opacity(opacity: _opacity, child: child),
            ),
          );
        },
        child: bar,
      ),
    );
  }
}

/// The tick, in a ring that runs down over the time the offer is open —
/// clockwise from the top, the way a clock's hand would take it.
class _Countdown extends CustomPainter {
  final Animation<double> left;
  final Color color;

  _Countdown({required this.left, required this.color}) : super(repaint: left);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(1.2);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawOval(rect, stroke..color = color.withValues(alpha: 0.18));
    final sweep = 2 * math.pi * left.value;
    // Drawn from where the hand has got to round to the top, so what is left
    // is what is drawn.
    canvas.drawArc(
      rect,
      -math.pi / 2 + (2 * math.pi - sweep),
      sweep,
      false,
      stroke..color = color,
    );
    CheckMark(progress: 1, color: color).paint(canvas, size);
  }

  @override
  bool shouldRepaint(_Countdown old) => old.color != color;
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

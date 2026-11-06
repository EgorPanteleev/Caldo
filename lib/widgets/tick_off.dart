import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

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
///
/// The bar is an overlay entry of its own, not a snack bar. A snack bar
/// fades itself in and out, and a blur inside a fade has nothing behind it
/// to blur — the glass went clear and sharp for every fade. It also takes
/// every tap across the width it is given, so a bar narrower than the
/// screen had to be measured beforehand to keep it off the cards beside it.
void tickOff(BuildContext context, Task task) {
  final provider = context.read<TaskProvider>();
  final completing = !task.done;
  provider.toggleDone(task);
  if (!completing) return;

  // One offer at a time: the new bar rises in the old one's place.
  _offer?.remove();
  late final OverlayEntry entry;
  void close() {
    if (_offer != entry) return;
    entry.remove();
    _offer = null;
  }

  entry = OverlayEntry(
    builder: (context) => _UndoBar(
      task: task,
      onUndo: () => provider.restore(task),
      onGone: close,
    ),
  );
  _offer = entry;
  // The app's own overlay, the whole screen: the nearest one can be a pen a
  // carried card is kept inside (`DragWithin`), which on the calendar ends
  // above the add field and put the bar half a card too high.
  Overlay.of(context, rootOverlay: true).insert(entry);
}

OverlayEntry? _offer;

const _undoFor = Duration(seconds: 4);

/// What a tick off leaves on screen for a moment: the task, ticked, and a way
/// to take it back.
///
/// A pill of frosted glass — what is behind it blurred under a grey a step
/// lighter than the add field, with a hairline rim — holding a plain tick,
/// the task's name, and Undo. It floats over the add field, nine tenths of
/// the screen wide at least: full width, with the cards' own width and
/// corners, it read as one more card; sized to a short title alone it was a
/// lozenge ("make it wider"); and at four fifths its round end stopped just
/// short of the tick on the card under it, which stuck out beside the bar
/// as half a purple square.
///
/// Undo is the only thing on it in the accent. The tick was a filled accent
/// square and the countdown an accent rule as well, and with the button that
/// made three purple things on one small bar — "too many accent colours".
///
/// It can be brushed off to either side or down: it follows the finger,
/// fading as it goes, and either carries on out of a throw or settles back.
/// A finger resting on it holds the countdown, since someone holding the
/// offer is still deciding.
class _UndoBar extends StatefulWidget {
  final Task task;
  final VoidCallback onUndo;

  /// Called once the bar has finished leaving, however it left.
  final VoidCallback onGone;

  const _UndoBar({
    required this.task,
    required this.onUndo,
    required this.onGone,
  });

  static const _tick = 20.0;
  static const _arrow = 18.0;

  static TextStyle _titleStyle(AppPalette p) =>
      TextStyle(color: p.text, fontSize: 15, fontWeight: FontWeight.w600);

  static TextStyle _undoStyle(Color accent) => TextStyle(
    color: accent,
    fontSize: 15,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.2,
  );

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

  /// In on the way up, out on the way down — rising and growing a little as
  /// it comes, sinking a little as it goes.
  late final _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    reverseDuration: const Duration(milliseconds: 200),
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
    if (status == AnimationStatus.dismissed) _leave();
  }

  void _leave() {
    if (_gone) return;
    _gone = true;
    _left.stop();
    _enter.reverse().whenComplete(() {
      if (mounted) widget.onGone();
    });
  }

  void _undo() {
    if (_gone) return;
    widget.onUndo();
    _leave();
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
    // Faded out by the time it gets there, so it goes at once rather than
    // fading a second time.
    _settle(const Duration(milliseconds: 180), to).whenComplete(() {
      if (mounted) widget.onGone();
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Lifted towards white on the dark glass: the accent itself is a deep
    // violet, and on grey it was the dimmest thing on the bar rather than
    // the one to press.
    final base = AppTheme.accentOf(context).color;
    final accent = dark ? Color.lerp(base, Colors.white, 0.3)! : base;
    final content = Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 4, 4),
        child: Row(
          children: [
            SizedBox.square(
              dimension: _UndoBar._tick,
              child: CustomPaint(
                painter: CheckMark(progress: 1, color: p.muted),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                widget.task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _UndoBar._titleStyle(p),
              ),
            ),
            const SizedBox(width: 8),
            _UndoButton(
              accent: accent,
              onTap: _undo,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: _UndoBar._arrow,
                    child: CustomPaint(painter: _UndoArrow(color: accent)),
                  ),
                  const SizedBox(width: 6),
                  Text(S.of(context).undo, style: _UndoBar._undoStyle(accent)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    // Over the add field rather than on it: the field is the next thing most
    // often reached for, and a bar sitting on it for four seconds would be in
    // the way of exactly that.
    return Positioned(
      left: 16,
      right: 16,
      bottom: 78 + MediaQuery.viewPaddingOf(context).bottom,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: _width * 0.9),
          // As wide as its words when they need more than that, so a title
          // only gives up letters to an ellipsis at the margins.
          child: IntrinsicWidth(
            child: GestureDetector(
              onPanDown: _hold,
              onPanUpdate: _move,
              onPanEnd: _let,
              onPanCancel: _cancel,
              child: AnimatedBuilder(
                animation: _enter,
                builder: (context, content) {
                  final t = Curves.easeOutCubic.transform(_enter.value);
                  return Transform.translate(
                    offset: _shown + Offset(0, 14 * (1 - t)),
                    child: Transform.scale(
                      scale: 0.94 + 0.06 * t,
                      child: _Glass(
                        shown: t * _opacity,
                        dark: dark,
                        child: content!,
                      ),
                    ),
                  );
                },
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A pill of frosted glass over [child], at [shown] of its full strength.
///
/// The blur is not faded with the rest. A blur inside a fading layer only
/// sees that layer, which is empty, so faded together the glass turned clear
/// and sharp the moment it began to go. Here the blur sits beside the fading
/// layers rather than inside one, and thins out as they do.
class _Glass extends StatelessWidget {
  final double shown;
  final bool dark;
  final Widget child;

  const _Glass({required this.shown, required this.dark, required this.child});

  static const _shape = StadiumBorder();

  @override
  Widget build(BuildContext context) {
    // Most of the way to opaque. A thin veil of white was tried first, and
    // over these dark cards it came out a muddy grey that took on whatever
    // card it crossed — "bad looking". Here the glass is one even grey,
    // lighter than the field below it so the two never merge, and what is
    // behind only tints it.
    final veil = dark
        ? const [Color(0xE0404046), Color(0xE036363B)]
        : [
            Colors.white.withValues(alpha: 0.92),
            Colors.white.withValues(alpha: 0.86),
          ];
    final sigma = 24 * shown;
    return Stack(
      children: [
        Positioned.fill(
          child: Opacity(
            opacity: shown,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: _shape,
                shadows: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 28,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (sigma > 0.5)
          Positioned.fill(
            child: ClipPath(
              clipper: const ShapeBorderClipper(shape: _shape),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        Opacity(
          opacity: shown,
          child: ClipPath(
            clipper: const ShapeBorderClipper(shape: _shape),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: veil,
                ),
              ),
              child: CustomPaint(
                foregroundPainter: _Rim(
                  color: dark ? Colors.white : Colors.black,
                ),
                child: child,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The glass's edge: a hairline, a little brighter along the top. Bright
/// enough to be seen, it drew a grey outline round the whole bar.
class _Rim extends CustomPainter {
  final Color color;

  const _Rim({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(0.5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.12),
            color.withValues(alpha: 0.04),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_Rim old) => old.color != color;
}

/// Undo, in the accent and on nothing — the one thing on the bar to press,
/// and the one thing in colour. It sat on a chip of the accent's tint, and
/// violet words on a violet chip on grey glass were a pill inside a pill
/// with nothing in it standing out.
///
/// The bar's four seconds are not drawn. They were a ring around the tick,
/// which made it a round checkbox ("i dont like this rounded checkbox"),
/// then a line along the foot, then the tint draining out of the chip,
/// which read as a smudge on it. The offer still holds while it is touched.
class _UndoButton extends StatelessWidget {
  final Color accent;
  final VoidCallback? onTap;
  final Widget child;

  const _UndoButton({
    required this.accent,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        splashColor: accent.withValues(alpha: 0.16),
        highlightColor: accent.withValues(alpha: 0.10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 16, 13),
          child: child,
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

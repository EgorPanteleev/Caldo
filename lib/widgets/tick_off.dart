import 'dart:math' as math;
import 'dart:ui' as ui;

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
/// The offer stands in the quick-add row of the screen the tick was made on
/// ([UndoScope], [UndoSlot]): for four seconds, or longer while a finger is
/// on it, the field and its button give way to it. Undo puts the task back
/// exactly as it was before the tap (`TaskProvider.restore`): not done, and
/// on its own date if it was a repeating task that had rolled on — ticking
/// it again would only have rolled it a second time. Taking a tick back by
/// tapping the tick needs no offer: it is already an undo.
void tickOff(BuildContext context, Task task) {
  final provider = context.read<TaskProvider>();
  final completing = !task.done;
  provider.toggleDone(task);
  if (!completing) return;
  offerUndo(context, task, onUndo: () => provider.restore(task));
}

/// Offers [onUndo] for a change just made to [task], in the same place and
/// for the same four seconds a tick's offer stands — a card put off to
/// another day is offered back this way. [icon] stands where a tick's
/// check mark does, to say what is being undone.
void offerUndo(
  BuildContext context,
  Task task, {
  required VoidCallback onUndo,
  IconData? icon,
}) {
  final spot = context.getInheritedWidgetOfExactType<_UndoSpot>()?.offer;
  if (spot == null) return;
  // One offer at a time, whichever screen it stands on: the new one takes
  // the old one's place.
  _offered?.value = null;
  spot.value = _Offer(task: task, onUndo: onUndo, icon: icon);
  _offered = spot;
}

/// Where the offer standing now was made.
ValueNotifier<_Offer?>? _offered;

/// Takes back whatever offer is standing — for the tab bar, which is the
/// way off a screen, and leaves nothing of that screen's in its place.
void withdrawUndo() => _offered?.value = null;

const _undoFor = Duration(seconds: 4);

class _Offer {
  final Task task;
  final VoidCallback onUndo;
  final IconData? icon;

  const _Offer({required this.task, required this.onUndo, this.icon});
}

/// The reach of a tick's offer: a tick made on a card under it is offered
/// back in the [UndoSlot] under it, and nowhere else. Each screen with a
/// quick-add field is one, and so is the day card, which is a dialog of its
/// own over the calendar.
class UndoScope extends StatefulWidget {
  final Widget child;

  const UndoScope({super.key, required this.child});

  /// Where the scope over [context] makes its offers, if there is one.
  static UndoPlace? placeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_UndoSpot>()?.place;

  @override
  State<UndoScope> createState() => _UndoScopeState();
}

/// Where a scope's offers are made, for an [UndoSlot] that is not under
/// it: the shell's tab bar, which a screen's offers stand in the place of.
class UndoPlace {
  final ValueNotifier<_Offer?> _offer;

  const UndoPlace._(this._offer);
}

class _UndoScopeState extends State<UndoScope> {
  final _offer = ValueNotifier<_Offer?>(null);
  late final place = UndoPlace._(_offer);

  @override
  void dispose() {
    if (_offered == _offer) _offered = null;
    _offer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _UndoSpot(offer: _offer, place: place, child: widget.child);
}

class _UndoSpot extends InheritedWidget {
  final ValueNotifier<_Offer?> offer;
  final UndoPlace place;

  const _UndoSpot({
    required this.offer,
    required this.place,
    required super.child,
  });

  @override
  bool updateShouldNotify(_UndoSpot old) => old.offer != offer;
}

/// The quick-add row, which gives its place to the offer for as long as it
/// stands, and gets it back after.
///
/// In the row's place rather than above it: floated over the field, as it
/// was, the bar was a second grey pill of the same height stacked on the
/// first, which read as two fields, and it cut across whatever card was
/// under it. Here there is only ever one thing at the foot of the screen.
/// What that costs is the field, for four seconds — so a tap anywhere on the
/// bar but Undo puts it away and opens the field ([onField]).
class UndoSlot extends StatefulWidget {
  final Widget child;
  final VoidCallback onField;

  /// The scope whose offers stand here, for a slot that is not under it;
  /// otherwise the one over the slot.
  final UndoPlace? place;

  const UndoSlot({
    super.key,
    required this.onField,
    this.place,
    required this.child,
  });

  @override
  State<UndoSlot> createState() => _UndoSlotState();
}

class _UndoSlotState extends State<UndoSlot>
    with SingleTickerProviderStateMixin {
  ValueNotifier<_Offer?>? _spot;

  /// The offer on show — kept after it has been withdrawn, for as long as
  /// it takes to fade.
  _Offer? _shown;

  late final _swap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    reverseDuration: const Duration(milliseconds: 200),
  )..addStatusListener(_onSwap);

  late final _eased = CurvedAnimation(
    parent: _swap,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  /// How far the bar has been pulled towards being brushed off, from 0 at
  /// rest to 1 at the point where letting go throws it.
  final _away = ValueNotifier<double>(0);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _follow();
  }

  @override
  void didUpdateWidget(UndoSlot old) {
    super.didUpdateWidget(old);
    if (old.place != widget.place) _follow();
  }

  void _follow() {
    final spot =
        widget.place?._offer ??
        context.getInheritedWidgetOfExactType<_UndoSpot>()?.offer;
    if (spot == _spot) return;
    _spot?.removeListener(_changed);
    _spot = spot?..addListener(_changed);
    // Another screen's slot, in the shell: whatever it has standing is
    // shown at once, and nothing is shown for one that has none.
    _shown = spot?.value;
    _away.value = 0;
    _swap.value = _shown == null ? 0 : 1;
  }

  void _changed() {
    final offer = _spot?.value;
    setState(() => _shown = offer ?? _shown);
    if (offer == null) {
      _swap.reverse();
    } else {
      _away.value = 0;
      _swap.forward();
    }
  }

  void _onSwap(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _spot?.value == null) {
      setState(() => _shown = null);
    }
  }

  void _withdraw(_Offer offer) {
    if (_spot?.value == offer) _spot!.value = null;
  }

  @override
  void dispose() {
    _spot?.removeListener(_changed);
    _away.dispose();
    _eased.dispose();
    _swap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final standing = _spot?.value != null;
    return Stack(
      children: [
        // Always first and always wrapped the same way, so the field keeps
        // its state — what is typed, and its hold on the keyboard — while
        // the offer stands over it.
        //
        // It comes back as the bar is pulled away, all of it by the point
        // where letting go would throw the bar: pulled off a blank strip, the
        // bar read as taking the field with it ("i dont see add task under
        // it when im moving undo bar").
        IgnorePointer(
          ignoring: standing,
          child: AnimatedBuilder(
            animation: Listenable.merge([_eased, _away]),
            builder: (context, child) => Opacity(
              opacity: 1 - _eased.value * (1 - _away.value),
              child: child,
            ),
            child: widget.child,
          ),
        ),
        if (shown != null)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: _spot?.value != shown,
              child: FadeTransition(
                opacity: _eased,
                child: SlideTransition(
                  position: Tween(
                    begin: const Offset(0, 0.18),
                    end: Offset.zero,
                  ).animate(_eased),
                  child: _UndoBar(
                    key: ObjectKey(shown),
                    task: shown.task,
                    onUndo: shown.onUndo,
                    icon: shown.icon,
                    away: _away,
                    onGone: () => _withdraw(shown),
                    onField: () {
                      _withdraw(shown);
                      widget.onField();
                    },
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// What a tick off leaves on screen for a moment: the task, ticked, and a way
/// to take it back.
///
/// The field's own pill, at the field's own size, holding a plain tick, the
/// task's name, and Undo — the only thing on it in the accent. The tick was
/// a filled accent square and the countdown an accent rule as well, and with
/// the button that made three purple things on one small bar — "too many
/// accent colours".
///
/// The four seconds are drawn across the whole of it ([_Countdown]), asked
/// for as "the timer like gradient in all panel".
///
/// It can be brushed off to either side or down: it follows the finger,
/// fading as it goes, and either carries on out of a throw or settles back.
/// A finger resting on it holds the countdown, since someone holding the
/// offer is still deciding.
class _UndoBar extends StatefulWidget {
  final Task task;
  final VoidCallback onUndo;

  /// Drawn in the tick's place, for an offer that is not a tick's.
  final IconData? icon;

  /// Called once, however it left.
  final VoidCallback onGone;

  /// A tap on the bar away from Undo: the field is wanted back.
  final VoidCallback onField;

  /// Where the bar tells the row how far it has been pulled away.
  final ValueNotifier<double> away;

  const _UndoBar({
    super.key,
    required this.task,
    required this.onUndo,
    this.icon,
    required this.onGone,
    required this.onField,
    required this.away,
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
    widget.onGone();
  }

  void _undo() {
    if (_gone) return;
    widget.onUndo();
    _leave();
  }

  void _field() {
    if (_gone) return;
    _gone = true;
    _left.stop();
    widget.onField();
  }

  void _onFling() {
    setState(() {
      _drag = Offset.lerp(
        _from,
        _to,
        Curves.easeOutCubic.transform(_fling.value),
      )!;
    });
    _report();
  }

  /// Tells the row how near the bar is to being thrown, measured against
  /// the same distances [_let] decides by.
  void _report() {
    final s = _shown;
    final away = math.max(s.dx.abs() / (_width * 0.25), s.dy / 36);
    widget.away.value = away.clamp(0.0, 1.0);
  }

  double get _width => MediaQuery.sizeOf(context).width;

  // Upwards there is nowhere to throw it, so it only gives a little.
  Offset get _shown => Offset(_drag.dx, _drag.dy > 0 ? _drag.dy : _drag.dy / 4);

  // Solid for the first part of a pull: faded from the start, what is under
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
    _report();
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
    _fling.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Lifted towards white on the dark grey: the accent itself is a deep
    // violet, and on grey it was the dimmest thing on the bar rather than
    // the one to press.
    final base = AppTheme.accentOf(context).color;
    final accent = dark ? Color.lerp(base, Colors.white, 0.3)! : base;
    final content = Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 0, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: SizedBox.square(
                dimension: _UndoBar._tick,
                child: widget.icon == null
                    ? CustomPaint(
                        painter: CheckMark(progress: 1, color: p.muted),
                      )
                    : Icon(widget.icon, size: _UndoBar._tick, color: p.muted),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  widget.task.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _UndoBar._titleStyle(p),
                ),
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _field,
      onPanDown: _hold,
      onPanUpdate: _move,
      onPanEnd: _let,
      onPanCancel: _cancel,
      child: Transform.translate(
        offset: _shown,
        child: Opacity(
          opacity: _opacity,
          child: CustomPaint(
            painter: _Countdown(
              left: _left,
              ground: p.field,
              tint: Color.lerp(p.field, base, dark ? 0.26 : 0.2)!,
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}

/// The bar's pill, with the time left drawn across all of it: the tint
/// covers the bar at first and draws back towards the start as the four
/// seconds run out, its leading edge a long soft ramp into the field's grey
/// rather than a line, so it reads as the bar draining rather than as a
/// progress bar laid on it. A finger holding the bar holds it still.
///
/// Drawn before, and taken out: a ring around the tick, which made it a
/// round checkbox; a line along the foot; and the tint draining out of the
/// Undo chip alone, which read as a smudge on it. This one was asked for.
class _Countdown extends CustomPainter {
  final Animation<double> left;
  final Color ground;
  final Color tint;

  _Countdown({required this.left, required this.ground, required this.tint})
    : super(repaint: left);

  /// How much of the bar's width the soft edge takes.
  static const _soft = 0.4;

  @override
  void paint(Canvas canvas, Size size) {
    final pill = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.height / 2),
    );
    // Solid up to [from], the field's grey from [to]: whole at the start,
    // with the ramp past the far end, and gone by the end, with the ramp
    // before the near one.
    final reach = left.value * (1 + _soft);
    final from = (reach - _soft) * size.width;
    final to = reach * size.width;
    canvas.drawRRect(
      pill,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(from, 0),
          Offset(math.max(to, from + 1), 0),
          [tint, ground],
        ),
    );
  }

  @override
  bool shouldRepaint(_Countdown old) =>
      old.left != left || old.ground != ground || old.tint != tint;
}

/// Undo, in the accent and on nothing — the one thing on the bar to press,
/// and the one thing in colour. It sat on a chip of the accent's tint, and
/// violet words on a violet chip on grey were a pill inside a pill with
/// nothing in it standing out.
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
          padding: const EdgeInsets.fromLTRB(14, 0, 20, 0),
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

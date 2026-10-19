import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Slides [child] from where it stood to where it now stands whenever the list
/// it is in is put in a new order.
///
/// When [trigger] fires — just before the lists are read back in a new order —
/// every card notes where it is. Once the new order has been laid out, each one
/// that has moved is drawn back at its old place and slides to its new one. A
/// finished task drifts to the end of its day and the cards below it rise into
/// the gap, where before one vanished and turned up somewhere else.
///
/// Where a card stands is measured inside its list's own scrolling space, so a
/// list being scrolled is never taken for one being rearranged. And it is noted
/// by task rather than by card: a list is free to hand a card's state to a
/// different task when it reorders, but a task is the same task wherever it
/// lands.
class SlideIntoPlace extends StatefulWidget {
  /// Which list this is, so the same task on two screens at once — the
  /// schedule and the calendar are both alive under the menu — is two cards
  /// with two places, not one.
  final String scope;

  /// The task the card shows.
  final Object id;

  final Listenable trigger;
  final Widget child;

  const SlideIntoPlace({
    super.key,
    required this.scope,
    required this.id,
    required this.trigger,
    required this.child,
  });

  /// How long a card takes to slide into its new place.
  static const duration = Duration(milliseconds: 260);

  @override
  State<SlideIntoPlace> createState() => _SlideIntoPlaceState();
}

class _SlideIntoPlaceState extends State<SlideIntoPlace>
    with SingleTickerProviderStateMixin {
  /// Where each card stood when it was last told a new order was coming, and
  /// when — a note that has not been used within [_stale] belongs to a reorder
  /// that never moved its card, and is dropped rather than replayed later.
  static final Map<(String, Object), ({double y, DateTime at})> _stood = {};
  static const _stale = Duration(milliseconds: 900);

  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: SlideIntoPlace.duration,
  );

  /// How far below its new place the card started, in points.
  double _from = 0;

  /// Found to have moved, and drawn at its old place, but not yet sliding:
  /// the slide is started after the frame that found it.
  bool _starting = false;

  ScrollableState? _scrollable;

  (String, Object) get _key => (widget.scope, widget.id);

  @override
  void initState() {
    super.initState();
    widget.trigger.addListener(_note);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scrollable = Scrollable.maybeOf(context);
  }

  @override
  void didUpdateWidget(SlideIntoPlace old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger) {
      old.trigger.removeListener(_note);
      widget.trigger.addListener(_note);
    }
  }

  @override
  void dispose() {
    widget.trigger.removeListener(_note);
    _slide.dispose();
    super.dispose();
  }

  /// How far the card is drawn from where it is laid out, right now.
  double get _shift {
    if (_starting) return _from;
    if (!_slide.isAnimating) return 0;
    return _from * (1 - Curves.easeInOutCubic.transform(_slide.value));
  }

  void _note() {
    final box = context.findRenderObject() as RenderBox?;
    final y = box == null ? null : _y(box);
    // Where it is seen, which mid-slide is not where it is laid out.
    if (y != null) _stood[_key] = (y: y + _shift, at: DateTime.now());
  }

  /// Where [box] stands within its list's scrolling content.
  double? _y(RenderBox box) {
    if (!mounted || !box.attached || !box.hasSize) return null;
    final scrollable = _scrollable;
    final ground = scrollable?.context.findRenderObject() as RenderBox?;
    if (scrollable == null || ground == null || !ground.attached) {
      return box.localToGlobal(Offset.zero).dy;
    }
    return box.localToGlobal(Offset.zero, ancestor: ground).dy +
        scrollable.position.pixels;
  }

  /// Asked while the card is being painted, once the new order has been laid
  /// out — not after the frame, as it was: by then that frame had already
  /// gone to the screen with every card at its new place, and the next one
  /// put them all back to slide from the old. One frame of the finished
  /// arrangement, then the slide to it, was a stutter at the start of every
  /// one.
  double _paintShift(RenderBox box) {
    final stood = _stood[_key];
    if (stood != null) {
      if (DateTime.now().difference(stood.at) > _stale) {
        _stood.remove(_key);
      } else {
        final y = _y(box);
        // Not moved yet: the lists are read back in more than one step, and
        // this card's may be the later one. The note is kept for that frame.
        if (y != null && (stood.y - y).abs() >= 1) {
          _stood.remove(_key);
          _from = stood.y - y;
          _starting = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _starting = false;
            _slide.forward(from: 0);
          });
        }
      }
    }
    return _shift;
  }

  @override
  Widget build(BuildContext context) =>
      _Slide(state: this, animation: _slide, child: widget.child);
}

class _Slide extends SingleChildRenderObjectWidget {
  final _SlideIntoPlaceState state;
  final Animation<double> animation;

  const _Slide({
    required this.state,
    required this.animation,
    required Widget super.child,
  });

  @override
  _RenderSlide createRenderObject(BuildContext context) =>
      _RenderSlide(state, animation);

  @override
  void updateRenderObject(BuildContext context, _RenderSlide render) {
    render
      ..state = state
      ..animation = animation
      // Rebuilt is when it may have been moved, and a card that has only
      // moved is not painted again on its own — the list just shifts it.
      ..markNeedsPaint();
  }
}

class _RenderSlide extends RenderProxyBox {
  _RenderSlide(this.state, this._animation);

  _SlideIntoPlaceState state;
  double _painted = 0;

  Animation<double> _animation;
  set animation(Animation<double> value) {
    if (value == _animation) return;
    if (attached) _animation.removeListener(markNeedsPaint);
    _animation = value;
    if (attached) _animation.addListener(markNeedsPaint);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _animation.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _painted = state._paintShift(this);
    super.paint(context, offset.translate(0, _painted));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return result.addWithPaintOffset(
      offset: Offset(0, _painted),
      position: position,
      hitTest: (result, position) =>
          super.hitTestChildren(result, position: position),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(0, _painted, 0, 1);
  }
}

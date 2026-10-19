import 'package:flutter/material.dart';

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
  static const duration = Duration(milliseconds: 320);

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

  (String, Object) get _key => (widget.scope, widget.id);

  @override
  void initState() {
    super.initState();
    widget.trigger.addListener(_note);
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

  void _note() {
    final y = _y();
    if (y != null) _stood[_key] = (y: y, at: DateTime.now());
  }

  /// Where the card stands within its list's scrolling content.
  double? _y() {
    if (!mounted) return null;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    final scrollable = Scrollable.maybeOf(context);
    final ground = scrollable?.context.findRenderObject() as RenderBox?;
    if (scrollable == null || ground == null) {
      return box.localToGlobal(Offset.zero).dy;
    }
    return box.localToGlobal(Offset.zero, ancestor: ground).dy +
        scrollable.position.pixels;
  }

  void _landed(Duration _) {
    final stood = _stood[_key];
    if (stood == null) return;
    if (DateTime.now().difference(stood.at) > _stale) {
      _stood.remove(_key);
      return;
    }
    final y = _y();
    if (y == null) return;
    final moved = stood.y - y;
    // Not moved yet: the lists are read back in more than one step, and this
    // card's may be the later one. The note is kept for the frame it lands.
    if (moved.abs() < 1) return;
    _stood.remove(_key);
    _from = moved;
    _slide.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback(_landed);
    return AnimatedBuilder(
      animation: _slide,
      builder: (context, child) {
        final left = 1 - Curves.easeInOutCubic.transform(_slide.value);
        return Transform.translate(
          offset: Offset(0, _slide.isAnimating ? _from * left : 0),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../data/holidays.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../theme/app_theme.dart';
import 'carry.dart';
import 'slide_into_place.dart';
import 'task_card.dart';
import 'tick_off.dart';

/// One day's holidays and tasks, with the tasks draggable into an order of
/// the user's own.
///
/// A long press starts the drag. That gesture used to open the editor, which
/// a tap already does — so nothing was lost by giving it to the drag, and a
/// card is the obvious thing to pick up.
///
/// The holidays are in the same list rather than above it, so one scroll runs
/// through the whole day. They have no drag listener and cannot be picked up,
/// and a task dropped among them is pushed back below them: a public holiday
/// is not something the user placed, so it has no place in the order.
/// Keeps a card being carried inside the list it came from.
///
/// A reorderable list puts the card it is dragging into an `Overlay`, and the
/// nearest one is the app's — the whole screen. So a card could be carried up
/// over the calendar's grid, or above Schedule's first heading, somewhere it
/// could never be dropped. Giving the list an overlay of its own puts the
/// card in a box the size of the list, and clips it to it.
class DragWithin extends StatefulWidget {
  final Widget child;

  const DragWithin({super.key, required this.child});

  @override
  State<DragWithin> createState() => _DragWithinState();
}

class _DragWithinState extends State<DragWithin> {
  final GlobalKey _bounds = GlobalKey();

  // An overlay reads `initialEntries` once, so the entry has to be told when
  // what it shows has changed — which, for a list of tasks, is every time one
  // of them does.
  late final OverlayEntry _entry = OverlayEntry(builder: (_) => widget.child);

  @override
  void didUpdateWidget(covariant DragWithin old) {
    super.didUpdateWidget(old);
    _entry.markNeedsBuild();
  }

  @override
  Widget build(BuildContext context) {
    return _DragBounds(
      bounds: _bounds,
      child: SizedBox(
        key: _bounds,
        child: Overlay(initialEntries: [_entry]),
      ),
    );
  }
}

/// Where the list is on the screen, for the card being carried over it.
class _DragBounds extends InheritedWidget {
  final GlobalKey bounds;

  const _DragBounds({required this.bounds, required super.child});

  static GlobalKey? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DragBounds>()?.bounds;

  @override
  bool updateShouldNotify(_DragBounds old) => old.bounds != bounds;
}

/// Holds whatever it is given inside [bounds] while it is painted.
///
/// The card being carried follows the finger, and a finger can go anywhere.
/// Clipping it to the list was worse than letting it wander: it vanished a
/// sliver at a time into the top of the screen. It is held against the edge
/// instead, which is where it would be dropped anyway — the drop is clamped
/// to the run the card came from.
class _KeepInside extends SingleChildRenderObjectWidget {
  final GlobalKey bounds;

  /// The rows the run is penned in by: the card is kept below [under] and
  /// above [over].
  ///
  /// Both are rows that cannot themselves be dragged — a heading, a holiday —
  /// because a row that can be dragged is lifted clean out of the list while
  /// it is carried, taking its key with it. Anchoring to the ends of the run
  /// meant that dragging the first card of one left nothing to measure
  /// against, which is the card most likely to be dragged somewhere it should
  /// not go.
  final GlobalKey? under;
  final GlobalKey? over;

  /// While this says the card is shrunk to a day, it is not held: the tile
  /// is under the finger and inside the month, and holding the full card's
  /// box against an edge would pull the tile off the finger with it.
  final Carry<Object>? carry;

  const _KeepInside({
    required this.bounds,
    required Widget super.child,
    this.under,
    this.over,
    this.carry,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderKeepInside(bounds, under, over, carry);

  @override
  void updateRenderObject(BuildContext context, _RenderKeepInside render) {
    render
      ..bounds = bounds
      ..under = under
      ..over = over
      ..carry = carry;
  }
}

class _RenderKeepInside extends RenderProxyBox {
  _RenderKeepInside(this.bounds, this.under, this.over, this.carry);

  GlobalKey bounds;
  GlobalKey? under;
  GlobalKey? over;
  Carry<Object>? carry;

  static RenderBox? _boxOf(GlobalKey? key) {
    final render = key?.currentContext?.findRenderObject();
    return render is RenderBox && render.hasSize ? render : null;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final whole = _boxOf(bounds);
    if (whole == null || !hasSize || carry?.shrink != null) {
      return super.paint(context, offset);
    }

    // A row scrolled out of the list has nothing to measure, so the list
    // itself stands in for whichever end of the pen is missing.
    final above = _boxOf(under);
    final below = _boxOf(over);
    final listTop = whole.localToGlobal(Offset.zero).dy;
    final top = above == null
        ? listTop
        : above.localToGlobal(Offset.zero).dy + above.size.height;
    final bottom = below == null
        ? listTop + whole.size.height
        : below.localToGlobal(Offset.zero).dy;

    final lowest = math.max(top, bottom - size.height);
    final mine = localToGlobal(Offset.zero).dy;
    super.paint(context, offset.translate(0, mine.clamp(top, lowest) - mine));
  }
}

/// What a card looks like while it is being carried: the card, and nothing
/// else — no slab behind it and no square corners anywhere.
///
/// Left to itself a reorderable list wraps the card in a `Material` of the
/// theme's canvas colour, which here is the true black the app is grounded on,
/// so a card picked up off the calendar's grey day panel dragged a black box
/// around with it. Painting the ground instead fixed the colour but kept the
/// box. What is painted now is the card's own rectangle, in its own corners,
/// in the colour it is standing on — which is to say nothing you can see. The
/// ink in a task card is translucent and has to land on something, or it
/// turns muddy over whatever it is passing across; this gives it the same
/// something it has at rest.
Widget liftedCard(
  BuildContext context,
  Color ground,
  Widget child,
  Animation<double> animation, {
  GlobalKey? under,
  GlobalKey? over,
  Carry<Object>? carry,
  ({String title, Color colour})? chip,
}) {
  final whole = AnimatedBuilder(
    animation: animation,
    builder: (context, inner) => Transform.scale(
      scale: 1 + 0.02 * Curves.easeOut.transform(animation.value),
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: TaskCard.margin,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: ground,
                    borderRadius: BorderRadius.circular(TaskCard.radius),
                  ),
                ),
              ),
            ),
            inner!,
          ],
        ),
      ),
    ),
    child: child,
  );
  final card = carry == null || chip == null
      ? whole
      : _ShrinkingCard(
          carry: carry,
          title: chip.title,
          colour: chip.colour,
          ground: ground,
          child: whole,
        );
  // Held over another day, the card thins out: it is on top of the very spot
  // it is being carried to, and the mark that says where it will land has to
  // be seen through it. Not once it has shrunk to a day's size — then the
  // mark shows round it.
  final lifted = carry == null
      ? card
      : ListenableBuilder(
          listenable: carry,
          builder: (context, child) => AnimatedOpacity(
            opacity: carry.target == null || carry.shrink != null ? 1 : 0.45,
            duration: const Duration(milliseconds: 120),
            child: child,
          ),
          child: card,
        );
  final bounds = _DragBounds.of(context);
  return bounds == null
      ? lifted
      : _KeepInside(
          bounds: bounds,
          under: under,
          over: over,
          carry: carry,
          child: lifted,
        );
}

/// A carried card that turns into a tile the size of a day while it is over
/// the month, and back into the card when it leaves it.
///
/// A full-width card held over a grid of days covers a week of them and
/// says nothing about which one it is going to; a tile the size of one, under
/// the finger, reads as something being put into a day. It is the task's
/// title on the task's colour mixed the way an opened month's chips are, so
/// what is carried in looks like what will be there once it is let go. The
/// card fades out over the first part of the change while the tile draws in
/// from the card's own outline to the finger, and then goes wherever the
/// finger does — the day it would land on is marked by its outline, not by
/// where the tile sits.
class _ShrinkingCard extends StatefulWidget {
  final Carry<Object> carry;
  final String title;
  final Color colour;

  /// What the card is standing on, which its ink is mixed into.
  final Color ground;
  final Widget child;

  const _ShrinkingCard({
    required this.carry,
    required this.title,
    required this.colour,
    required this.ground,
    required this.child,
  });

  @override
  State<_ShrinkingCard> createState() => _ShrinkingCardState();
}

class _ShrinkingCardState extends State<_ShrinkingCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  /// Where it last shrank to, on the screen, kept for the way back.
  Rect _tile = Rect.zero;

  @override
  void initState() {
    super.initState();
    widget.carry.addListener(_follow);
  }

  @override
  void dispose() {
    widget.carry.removeListener(_follow);
    _morph.dispose();
    super.dispose();
  }

  void _follow() {
    final shrink = widget.carry.shrink;
    if (shrink != null) {
      if (shrink != _tile) setState(() => _tile = shrink);
      if (_morph.status != AnimationStatus.forward &&
          _morph.status != AnimationStatus.completed) {
        _morph.forward();
      }
    } else if (_morph.status != AnimationStatus.reverse &&
        _morph.status != AnimationStatus.dismissed) {
      _morph.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final cardInk = Color.alphaBlend(
      widget.colour.withValues(alpha: 0.25),
      widget.ground,
    );
    // Clearer than a card's ink or a chip's: the tile is small, lifted, and
    // the one thing moving on the screen, so it carries its colour rather
    // than a hint of it.
    final tileInk = Color.alphaBlend(
      widget.colour.withValues(alpha: 0.55),
      p.field,
    );
    final rim = Color.alphaBlend(Colors.white.withValues(alpha: 0.18), tileInk);
    return AnimatedBuilder(
      animation: _morph,
      child: widget.child,
      builder: (context, card) {
        final t = Curves.easeOutCubic.transform(_morph.value);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Opacity(opacity: (1 - t * 2.5).clamp(0.0, 1.0), child: card),
            if (t > 0)
              Positioned.fill(
                child: _AtFinger(
                  carry: widget.carry,
                  tile: _tile,
                  t: t,
                  child: Opacity(
                    opacity: (t * 3).clamp(0.0, 1.0),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Color.lerp(cardInk, tileInk, t),
                        borderRadius: BorderRadius.circular(
                          lerpDouble(TaskCard.radius, 10, t)!,
                        ),
                        border: Border.all(
                          color: Color.lerp(cardInk, rim, t)!,
                          width: 1,
                        ),
                        // Lifted off the month: it is being carried over the
                        // days, not lying in one of them.
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.45 * t),
                            blurRadius: 14,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 4,
                        ),
                        child: Center(
                          child: Opacity(
                            opacity: t,
                            // Two lines, ended with an ellipsis: three in a
                            // box this size ran off the bottom and cut the
                            // last one through the middle of its letters.
                            child: Text(
                              widget.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: p.text,
                                fontSize: 10.5,
                                height: 1.2,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Lays the tile out at its size and paints it where it is told, under the
/// finger.
///
/// Placed on the screen rather than relative to the card, and while
/// painting, when this frame's positions are known. A reorderable list moves
/// the card it carries along its own axis only, so a finger moving sideways
/// across the month left the card — and a tile placed relative to it —
/// behind, over the days already passed. The tile starts out over the card's
/// own outline and moves into [tile], a place on the screen, as it shrinks
/// ([t]). It once snapped into the cell under the finger instead; that was
/// asked back — the tile is to move freely, and the outline to say the day.
///
/// The card's outline is read from this box's own size, which is the card's
/// once laid out. A `LayoutBuilder` round it was handed the proxy's open
/// height instead — infinite — and the tile worked out from that was NaN,
/// which Flutter drew pinned to the left edge whatever the finger did.
class _AtFinger extends SingleChildRenderObjectWidget {
  final Carry<Object> carry;
  final Rect tile;
  final double t;

  const _AtFinger({
    required this.carry,
    required this.tile,
    required this.t,
    required Widget super.child,
  });

  @override
  _RenderAtFinger createRenderObject(BuildContext context) =>
      _RenderAtFinger(carry, tile, t);

  @override
  void updateRenderObject(BuildContext context, _RenderAtFinger render) {
    render
      ..carry = carry
      ..tile = tile
      ..t = t
      ..markNeedsLayout();
  }
}

class _RenderAtFinger extends RenderProxyBox {
  _RenderAtFinger(this._carry, this.tile, this.t);

  Carry<Object> _carry;
  set carry(Carry<Object> value) {
    if (value == _carry) return;
    if (attached) _carry.removeListener(markNeedsPaint);
    _carry = value;
    if (attached) _carry.addListener(markNeedsPaint);
  }

  Rect tile;
  double t;

  Rect get _from => TaskCard.margin.deflateRect(Offset.zero & size);

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _carry.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _carry.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    child?.layout(BoxConstraints.tight(Size.lerp(_from.size, tile.size, t)!));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final from = _from;
    _at = Offset.lerp(from.topLeft, globalToLocal(tile.topLeft), t)!;
    context.paintChild(child, offset + _at);
  }

  /// Where the tile was last painted, so anything asking where it is on the
  /// screen is told where it was drawn rather than where it was laid out.
  Offset _at = Offset.zero;

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(_at.dx, _at.dy, 0, 1);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      false;
}

class ReorderableTaskList extends StatefulWidget {
  final List<Holiday> holidays;
  final List<Task> tasks;

  /// What the list is standing on, painted behind a card while it is carried.
  final Color ground;

  final EdgeInsets padding;
  final ScrollController? controller;
  final bool shrinkWrap;
  final TaskList? Function(Task) listOf;
  final ValueChanged<Task> onOpen;
  final ValueChanged<Task> onToggle;

  /// Whether a ticked task's card is fading out of the list
  /// (`TaskProvider.isLeaving`).
  final bool Function(Task)? isLeaving;

  /// Whether a ticked task's tick is drawn but its card not yet crossed out
  /// (`TaskProvider.isTicking`).
  final bool Function(Task)? isTicking;

  /// Fires just before the list is read back in a new order, so its cards
  /// can slide to their new places (`TaskProvider.rearranging`).
  final Listenable? rearranging;

  /// Which list this is, for [SlideIntoPlace].
  final String scope;

  /// Follows a card carried out of this list, which may be let go over
  /// another day (`CarryArea`).
  final Carry<Object>? carry;

  /// Whether a carried card is kept inside this list. A list whose cards can
  /// be carried elsewhere is put in a box by whoever is around it instead.
  final bool penned;

  /// Hands back the day's tasks in the order they were dragged into.
  final ValueChanged<List<Task>> onReorder;

  const ReorderableTaskList({
    super.key,
    required this.holidays,
    required this.tasks,
    required this.ground,
    required this.listOf,
    required this.onOpen,
    required this.onToggle,
    this.isLeaving,
    this.isTicking,
    this.rearranging,
    this.scope = 'tasks',
    this.carry,
    this.penned = true,
    required this.onReorder,
    this.padding = EdgeInsets.zero,
    this.controller,
    this.shrinkWrap = false,
  });

  @override
  State<ReorderableTaskList> createState() => _ReorderableTaskListState();
}

class _ReorderableTaskListState extends State<ReorderableTaskList> {
  // The ends of the run, so a card can be held between them while it is
  // carried. One pair per list rather than one for the class: the day pager
  // has several of these alive at once, and a key may only be in the tree in
  // one place.
  final _lastHoliday = GlobalKey();
  final _list = GlobalKey<SliverReorderableListState>();

  ReorderableTaskList get w => widget;

  void _reorder(int oldIndex, int newIndex) {
    // Flutter reports the slot the card would go into before the gap it left
    // behind is closed up. No clamping: the reorderable sliver holds the
    // day's tasks and nothing else, so there is nowhere else to land.
    final to = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (to == oldIndex) return;
    final ordered = [...w.tasks];
    ordered.insert(to, ordered.removeAt(oldIndex));
    w.onReorder(ordered);
  }

  @override
  Widget build(BuildContext context) {
    // The builder is for a context below `DragWithin`, which is where
    // the card being carried finds the box it has to stay inside.
    if (!w.penned) return _build(context);
    return DragWithin(child: Builder(builder: (context) => _build(context)));
  }

  /// Holidays in a sliver of their own and the tasks in a reorderable one,
  /// rather than both in a single list. A list cannot tell a holiday from a
  /// task, so the gap it opens for the card being carried could land above
  /// the holidays, where the card could never be dropped.
  Widget _build(BuildContext context) {
    return CustomScrollView(
      controller: w.controller,
      shrinkWrap: w.shrinkWrap,
      physics: w.shrinkWrap ? const ClampingScrollPhysics() : null,
      slivers: [
        SliverToBoxAdapter(child: SizedBox(height: w.padding.top)),
        SliverList.builder(
          itemCount: w.holidays.length,
          itemBuilder: (context, i) => KeyedSubtree(
            key: i == w.holidays.length - 1 ? _lastHoliday : null,
            child: HolidayCard(holiday: w.holidays[i]),
          ),
        ),
        SliverReorderableList(
          key: _list,
          itemCount: w.tasks.length,
          onReorder: _reorder,
          onReorderStart: (i) => w.carry?.begin(
            w.tasks[i],
            () => _list.currentState?.cancelReorder(),
          ),
          onReorderEnd: (_) => w.carry?.end(),
          proxyDecorator: (child, index, animation) => liftedCard(
            context,
            w.ground,
            child,
            animation,
            // A card that can leave the list is not held below its
            // holidays: up past them is the way to the month.
            under: w.holidays.isEmpty || !w.penned ? null : _lastHoliday,
            carry: w.carry,
            chip: (
              title: w.tasks[index].title,
              colour: colorOfTask(
                w.tasks[index],
                w.listOf(w.tasks[index]),
                fallback: AppTheme.accentOf(context).color,
              ),
            ),
          ),
          itemBuilder: (context, i) {
            final task = w.tasks[i];
            return ReorderableDelayedDragStartListener(
              key: ValueKey('task-${task.id}'),
              index: i,
              child: SlideIntoPlace(
                scope: w.scope,
                id: task.id ?? task,
                trigger: w.rearranging ?? const _Never(),
                child: AsShown(
                  task: task,
                  builder: (context, shown) => TaskCard(
                    task: shown,
                    list: w.listOf(task),
                    onTap: () => w.onOpen(task),
                    onToggle: () => w.onToggle(shown),
                    ticking: w.isTicking?.call(task) ?? false,
                    leaving: w.isLeaving?.call(task) ?? false,
                  ),
                ),
              ),
            );
          },
        ),
        SliverToBoxAdapter(child: SizedBox(height: w.padding.bottom)),
      ],
    );
  }
}

/// A listenable that never fires, for a list nobody rearranges.
class _Never implements Listenable {
  const _Never();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

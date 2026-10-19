import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../data/holidays.dart';
import '../models/task.dart';
import '../models/task_list.dart';
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

  const _KeepInside({
    required this.bounds,
    required Widget super.child,
    this.under,
    this.over,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderKeepInside(bounds, under, over);

  @override
  void updateRenderObject(BuildContext context, _RenderKeepInside render) {
    render
      ..bounds = bounds
      ..under = under
      ..over = over;
  }
}

class _RenderKeepInside extends RenderProxyBox {
  _RenderKeepInside(this.bounds, this.under, this.over);

  GlobalKey bounds;
  GlobalKey? under;
  GlobalKey? over;

  static RenderBox? _boxOf(GlobalKey? key) {
    final render = key?.currentContext?.findRenderObject();
    return render is RenderBox && render.hasSize ? render : null;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final whole = _boxOf(bounds);
    if (whole == null || !hasSize) return super.paint(context, offset);

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
}) {
  final lifted = AnimatedBuilder(
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
  final bounds = _DragBounds.of(context);
  return bounds == null
      ? lifted
      : _KeepInside(bounds: bounds, under: under, over: over, child: lifted);
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
    return DragWithin(child: Builder(builder: (context) => _list(context)));
  }

  /// Holidays in a sliver of their own and the tasks in a reorderable one,
  /// rather than both in a single list. A list cannot tell a holiday from a
  /// task, so the gap it opens for the card being carried could land above
  /// the holidays, where the card could never be dropped.
  Widget _list(BuildContext context) {
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
          itemCount: w.tasks.length,
          onReorder: _reorder,
          proxyDecorator: (child, _, animation) => liftedCard(
            context,
            w.ground,
            child,
            animation,
            under: w.holidays.isEmpty ? null : _lastHoliday,
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

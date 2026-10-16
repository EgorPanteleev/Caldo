import 'package:flutter/material.dart';

import '../data/holidays.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import 'task_card.dart';

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
Widget liftedCard(Color ground, Widget child, Animation<double> animation) {
  return AnimatedBuilder(
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
}

class ReorderableTaskList extends StatelessWidget {
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
    required this.onReorder,
    this.padding = EdgeInsets.zero,
    this.controller,
    this.shrinkWrap = false,
  });

  void _reorder(int oldIndex, int newIndex) {
    final first = holidays.length;
    // Flutter reports the slot the card would go into before the gap it left
    // behind is closed up.
    var to = (newIndex > oldIndex ? newIndex - 1 : newIndex).clamp(
      first,
      first + tasks.length - 1,
    );
    final from = oldIndex - first;
    if (from < 0 || from == to - first) return;
    final ordered = [...tasks];
    ordered.insert(to - first, ordered.removeAt(from));
    onReorder(ordered);
  }

  @override
  Widget build(BuildContext context) {
    return ReorderableListView.builder(
      scrollController: controller,
      padding: padding,
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const ClampingScrollPhysics() : null,
      // The card is the handle; a grip beside every row would be a column of
      // furniture down a list whose whole job is to be read.
      buildDefaultDragHandles: false,
      itemCount: holidays.length + tasks.length,
      onReorder: _reorder,
      proxyDecorator: (child, _, animation) =>
          liftedCard(ground, child, animation),
      itemBuilder: (context, i) {
        if (i < holidays.length) {
          final holiday = holidays[i];
          return HolidayCard(
            key: ValueKey('holiday-${holiday.name}-$i'),
            holiday: holiday,
          );
        }
        final task = tasks[i - holidays.length];
        return ReorderableDelayedDragStartListener(
          key: ValueKey('task-${task.id}'),
          index: i,
          child: TaskCard(
            task: task,
            list: listOf(task),
            onTap: () => onOpen(task),
            onToggle: () => onToggle(task),
          ),
        );
      },
    );
  }
}

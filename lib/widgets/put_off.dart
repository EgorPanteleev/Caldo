import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import 'date_time_pickers.dart';
import 'selection.dart';
import 'task_card.dart';
import 'tick_off.dart';

/// A card on Schedule that can be swiped left to put its task off.
///
/// Pulled part of the way it stays open on two actions — the next day and a
/// day picked from the calendar sheet — and pulled most of the way across,
/// or thrown, it does the first of them at once. Either way the card goes
/// back to rest and then slides to its new day as the run is read back, and
/// the add row offers the move back for four seconds, as it does a tick.
///
/// Schedule only: under the calendar a sideways swipe turns the day, and
/// the board's cards are carried between lanes.
class PutOff extends StatefulWidget {
  final Task task;
  final Widget child;

  const PutOff({super.key, required this.task, required this.child});

  /// The day "the next day" means for [task]: tomorrow for anything due by
  /// today, or with no date; the day after its own for anything later,
  /// which tomorrow would have brought forward rather than put off.
  static DateTime nextDay(Task task, DateTime now) {
    final today = dayOf(now);
    final due = task.dueDay;
    final from = due == null || !due.isAfter(today) ? today : due;
    return DateTime(from.year, from.month, from.day + 1);
  }

  @override
  State<PutOff> createState() => _PutOffState();
}

class _PutOffState extends State<PutOff> with SingleTickerProviderStateMixin {
  /// How far the card is pulled, in points, leftwards and so negative.
  late final _offset = AnimationController.unbounded(vsync: this);

  /// The one card standing open, so opening another closes it.
  static _PutOffState? _open;

  /// The width the two actions take behind the card, and the gap between
  /// the card and their strip.
  static const _actions = 168.0;
  static const _gap = 8.0;

  /// The part of the card's width past which letting go puts it off.
  static const _through = 0.55;

  double _width = 1;

  @override
  void didUpdateWidget(PutOff old) {
    super.didUpdateWidget(old);
    // Moved, by this or anything else: it is a card on another day now.
    if (old.task.dueAt != widget.task.dueAt) _settle(0);
  }

  @override
  void dispose() {
    if (_open == this) _open = null;
    _offset.dispose();
    super.dispose();
  }

  /// Whether the drag now under way is one this card answers. A done task
  /// has nothing to put off, and while tasks are picked out a card is for
  /// picking. Asked when the drag starts rather than at build, so the card
  /// is the same widgets either way and its tick plays out undisturbed.
  bool _live = false;

  void _settle(double to, {double velocity = 0}) {
    if (to == 0 && _open == this) _open = null;
    _offset.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 500, damping: 40),
        _offset.value,
        to,
        velocity,
      ),
    );
  }

  void _onStart(DragStartDetails _) {
    _live = !widget.task.done && !(Selection.maybeOf(context)?.active ?? false);
    if (!_live) return;
    if (_open != null && _open != this) _open!._settle(0);
    _offset.stop();
  }

  void _onUpdate(DragUpdateDetails d) {
    if (!_live) return;
    // Only leftwards; a pull the other way gives a little and no more.
    final next = _offset.value + d.primaryDelta!;
    _offset.value = next > 0 ? next * 0.15 : math.max(next, -_width);
  }

  void _onEnd(DragEndDetails d) {
    if (!_live) return;
    final v = d.primaryVelocity ?? 0;
    final pulled = -_offset.value;
    if (pulled > _width * _through || (v < -1200 && pulled > _actions / 2)) {
      _settle(0, velocity: v);
      _nextDay();
    } else if (pulled > _actions / 2 && v < 600) {
      _open = this;
      _settle(-_actions - _gap, velocity: v);
    } else {
      _settle(0, velocity: v);
    }
  }

  Future<void> _move(DateTime day, IconData icon) async {
    final original = widget.task;
    final provider = context.read<TaskProvider>();
    offerUndo(
      context,
      original,
      icon: icon,
      onUndo: () => provider.putBack(original),
    );
    await provider.moveToDay(original, day);
  }

  void _nextDay() {
    _settle(0);
    _move(PutOff.nextDay(widget.task, DateTime.now()), Icons.redo_rounded);
  }

  Future<void> _pickDay() async {
    _settle(0);
    final picked = await showAppDatePicker(
      context: context,
      initial: widget.task.dueDay ?? dayOf(DateTime.now()),
    );
    if (picked == null || !mounted) return;
    if (picked == widget.task.dueDay) return;
    await _move(picked, Icons.event_outlined);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final later = widget.task.dueDay?.isAfter(dayOf(DateTime.now())) ?? false;
    return LayoutBuilder(
      builder: (context, box) {
        _width = box.maxWidth;
        return GestureDetector(
          onHorizontalDragStart: _onStart,
          onHorizontalDragUpdate: _onUpdate,
          onHorizontalDragEnd: _onEnd,
          child: Stack(
            children: [
              // The actions, in a strip of the card's shape exactly as wide
              // as the gap the card leaves — never under the card itself,
              // whose ink is translucent and would take the strip's grey.
              ValueListenableBuilder<double>(
                valueListenable: _offset,
                builder: (context, offset, actions) {
                  final gap = -offset - _gap;
                  if (gap <= 0) return const SizedBox.shrink();
                  return Positioned(
                    top: TaskCard.margin.top,
                    bottom: TaskCard.margin.bottom,
                    right: TaskCard.margin.right,
                    width: gap,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(TaskCard.radius),
                      child: ColoredBox(color: p.field, child: actions),
                    ),
                  );
                },
                // Held against the strip's far end, and cut off at its near
                // one while it is narrower than they are.
                child: OverflowBox(
                  alignment: Alignment.centerRight,
                  minWidth: 0,
                  maxWidth: double.infinity,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _Action(
                        icon: Icons.redo_rounded,
                        label: later ? s.putOffDay : s.tomorrow,
                        onTap: _nextDay,
                      ),
                      _Action(
                        icon: Icons.event_outlined,
                        label: s.pickDay,
                        onTap: _pickDay,
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
              ),
              AnimatedBuilder(
                animation: _offset,
                builder: (context, card) => Transform.translate(
                  offset: Offset(_offset.value, 0),
                  child: card,
                ),
                child: widget.child,
              ),
              // Open, a tap on the card closes it rather than opening the
              // task: the tap was most likely meant for that.
              ValueListenableBuilder<double>(
                valueListenable: _offset,
                builder: (context, offset, _) => offset < -1
                    ? Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        right: -offset,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _settle(0),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One of the actions behind a card: an icon over a word, neutral.
class _Action extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _Action({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return SizedBox(
      width: 80,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: p.text),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: TextStyle(
                color: p.text,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

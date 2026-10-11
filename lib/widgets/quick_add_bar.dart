import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:provider/provider.dart';

import '../models/task.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';

/// Identifies the button beside the quick-add field.
const quickAddButtonKey = Key('quick-add-button');

/// The field under a day's tasks: type a title, confirm, and it lands on the
/// day in view without opening the full form. Used by the calendar and by the
/// day card that opens over it.
class QuickAddBar extends StatefulWidget {
  final DateTime date;
  final TextEditingController controller;
  final VoidCallback onSubmit;

  /// Opens the full form. The button is a plus until the field is opened, and
  /// a plus has to lead somewhere — pressing it on an empty field used to do
  /// nothing at all.
  final VoidCallback onFullForm;

  /// Room around the row; the day card sets its own, tighter than the
  /// calendar's.
  final EdgeInsets padding;

  const QuickAddBar({
    super.key,
    required this.date,
    required this.controller,
    required this.onSubmit,
    required this.onFullForm,
    this.padding = const EdgeInsets.fromLTRB(16, 6, 16, 10),
  });

  @override
  State<QuickAddBar> createState() => _QuickAddBarState();
}

class _QuickAddBarState extends State<QuickAddBar> {
  late final FocusNode _focus = FocusNode()
    ..addListener(() {
      if (mounted) setState(() {});
    });

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// Hands the title over and closes the field. The task is filed at that
  /// point, so leaving the keyboard up over a day whose list has just changed
  /// hides the very thing the tap was meant to produce.
  void _submit() {
    widget.onSubmit();
    _focus.unfocus();
  }

  /// A plus opens the form; a tick files what has been typed.
  void _press() => _focus.hasFocus ? _submit() : widget.onFullForm();

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    // Opening the field is the moment the button's job changes: from here on
    // it finishes the task being typed, so it says so. Waiting for the first
    // character left it a plus over an active field.
    final writing = _focus.hasFocus;
    // A filled grey rather than an outline: on true black an outlined pill
    // read as a hole cut in the screen, and the field and the button beside
    // it are the one thing down there to press.
    const border = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(26)),
      borderSide: BorderSide.none,
    );

    return Padding(
      padding: widget.padding,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              style: TextStyle(color: p.text, fontSize: 14.5),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: p.field,
                hintText: 'Add task on ${Dates.shortDay(widget.date)}',
                hintStyle: TextStyle(color: p.muted, fontSize: 14.5),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
                // Nothing marks the focus but the cursor. An accent ring
                // around half the screen was the loudest thing on it, and a
                // neutral one on a grey field is a line nobody reads.
                border: border,
                enabledBorder: border,
                focusedBorder: border,
              ),
            ),
          ),
          const SizedBox(width: 10),
          _ConfirmButton(
            key: quickAddButtonKey,
            icon: writing ? Icons.check_rounded : Icons.add,
            tooltip: writing ? 'Add task' : 'New task',
            onTap: _press,
          ),
        ],
      ),
    );
  }
}

/// The round button beside the field. Plain rather than the accent gradient
/// the screen headers wear: it sits next to the field the eye is already on,
/// and a bright disc there pulled attention off what was being typed.
class _ConfirmButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _ConfirmButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: p.field,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(icon, color: p.text, size: 26),
          ),
        ),
      ),
    );
  }
}

/// Files an all-day task on [day] from a one-line title, in the colour new
/// tasks are set to start in.
Future<void> quickAddTask(
  BuildContext context, {
  required DateTime day,
  required String title,
}) async {
  final trimmed = title.trim();
  if (trimmed.isEmpty) return;
  final provider = context.read<TaskProvider>();
  final styleId = context.read<SettingsProvider>().defaultTaskStyleId;
  final lists = provider.lists;
  await provider.add(
    Task(
      listId: lists.isNotEmpty ? lists.first.id! : 1,
      title: trimmed,
      dueAt: dayOf(day).millisecondsSinceEpoch,
      styleId: styleId,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ),
  );
}

/// Floats [child] above the keyboard without the layout knowing about it.
///
/// A `Scaffold` that resizes for the keyboard takes the room out of whatever
/// is above the field — which on the calendar means squeezing the month the
/// user is looking at. Translating costs no layout, so the grid keeps the
/// height it had and the keyboard simply arrives over it.
///
/// The inset is read here and nowhere else on purpose: it changes on every
/// frame of the keyboard sliding in, and whoever reads it is rebuilt that
/// often. Keeping that to one small widget, with the bar handed in as a
/// child, is what stops the rest of the screen rebuilding with it.
class KeyboardLift extends StatefulWidget {
  final Widget child;

  const KeyboardLift({super.key, required this.child});

  @override
  State<KeyboardLift> createState() => _KeyboardLiftState();
}

class _KeyboardLiftState extends State<KeyboardLift>
    with SingleTickerProviderStateMixin {
  /// Holds the lift itself, in points, rather than a 0..1 progress: the thing
  /// being animated is a distance whose target moves mid-flight.
  late final AnimationController _lift;

  double _inset = 0;

  /// Critically damped, so the bar never passes the place it is going to, and
  /// quick enough to keep up with the keyboard's own slide: most of the way
  /// in a tenth of a second, at rest by a fifth. Stiffer than this and a
  /// lumpy report shows through as a jump again; softer and the field visibly
  /// lags the keys it is supposed to be riding on.
  static const _stiffness = 900.0;
  static final _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: _stiffness,
  );

  @override
  void initState() {
    super.initState();
    _lift = AnimationController.unbounded(vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset == _inset) return;
    _inset = inset;

    // The bar is never put anywhere — it is always sent there, in both
    // directions. Android does not promise to report a keyboard's slide frame
    // by frame; it reports it in however many lumps it feels like, and a bar
    // moved straight to one of those has teleported whether or not the number
    // it was handed was honest. Following the inset exactly was tried on the
    // way up, for the sake of staying glued to the keys — on a phone that
    // reports the rise in two steps, that is two jumps.
    //
    // The spring carries whatever speed it already has, so a change of target
    // mid-flight stays continuous, and from a standstill it starts from a
    // standstill. Reported smoothly it trails the keyboard by about a frame,
    // which is the price of never jumping.
    // Critically damped only promises not to overshoot from a standstill. Given
    // a speed of its own it can be thrown past the target and have to come
    // back — which, on the way down, is the bar dipping below the place it
    // lives and climbing back into it. The carried speed is held to what the
    // spring can shed over the distance that is left.
    final from = _lift.value;
    final away = from - inset;
    final bound = -math.sqrt(_stiffness) * away;
    final speed = away >= 0
        ? math.max(_lift.velocity, bound)
        : math.min(_lift.velocity, bound);

    _lift.animateWith(
      SpringSimulation(
        _spring,
        from,
        inset,
        speed,
        tolerance: const Tolerance(distance: 0.1, velocity: 1),
      ),
    );
  }

  @override
  void dispose() {
    _lift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _lift,
      builder: (context, child) =>
          Transform.translate(offset: Offset(0, -_lift.value), child: child),
      child: widget.child,
    );
  }
}

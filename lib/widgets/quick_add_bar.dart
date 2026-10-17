import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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

/// The keyboard's height, turned from what Android reports into something
/// that can be moved to.
///
/// Android does not promise to report the slide frame by frame; it reports it
/// in however many lumps it feels like. A bar moved straight to each report
/// is therefore glued to the keys on a phone that reports every frame and
/// teleports on one that reports three times — and the last lump, arriving
/// when the keys have already stopped, is the one the eye is resting on.
///
/// What is reported is a position and never a speed, so the only question
/// worth asking of a report is how far the bar would have to move in a single
/// rendered frame to honour it. Under what the keyboard itself covers in a
/// frame, it goes straight there: that is being glued to the keys, with no
/// lag at all, and it is what a report arriving every frame deserves. Over
/// it, the same distance is covered at that same speed instead — a movement
/// of its own, taking the frames it needs — easing out at the end so the bar
/// settles onto the keys rather than halting on them.
///
/// Both screens hang their field off this one value, and Schedule's list
/// takes its room at the foot from it as well, so the two of them move as one
/// thing. Doing it by resizing a `Scaffold` instead, as Schedule used to,
/// hands the job to the layout — which follows every lump exactly, teleports
/// and all, and squeezes whatever is above the field while it is at it.
class KeyboardInset extends StatefulWidget {
  final Widget child;

  const KeyboardInset({super.key, required this.child});

  /// The height to move by, or to leave room for. A listenable rather than a
  /// value on purpose: it changes on every frame the keyboard is moving, and
  /// only the handful of widgets that move with it should be rebuilding that
  /// often. [KeyboardLift] and [KeyboardRoom] are the two that do.
  static ValueListenable<double> of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_KeyboardInsetScope>();
    assert(scope != null, 'KeyboardInset.of() called with none above it.');
    return scope?.lift ?? _still;
  }

  /// Stands in where there is none above — a sheet of a screen pulled out on
  /// its own, and the keyboard is somebody else's problem there anyway.
  static final _still = ValueNotifier<double>(0);

  @override
  State<KeyboardInset> createState() => _KeyboardInsetState();
}

class _KeyboardInsetState extends State<KeyboardInset>
    with SingleTickerProviderStateMixin {
  /// How fast the bar may travel, in points a second. A keyboard covers its
  /// own height in something like a quarter of a second, so the rise is held
  /// a little above the fastest the keys themselves go: fast enough that a
  /// frame-by-frame report is always inside one frame's worth and followed
  /// exactly, slow enough that a lump is a movement rather than a jump.
  ///
  /// Down is gentler. There is nothing to keep up with — Android cuts the
  /// rest of the slide off and reports the floor in one go — so the whole
  /// distance is ours to cover and nothing is gained by throwing the bar at
  /// it.
  static const _riseSpeed = 2200.0;
  static const _fallSpeed = 1600.0;

  /// The tail. The speed limit above is what the bar spends most of a lump
  /// doing; inside the last of the distance this critically damped spring is
  /// the slower of the two and brings it down to nothing. Stiffer going up,
  /// where the keys are already in place and waiting.
  static const _riseStiffness = 3600.0;
  static const _fallStiffness = 1600.0;

  final _lift = ValueNotifier<double>(0);
  late final Ticker _ticker;

  /// Where the keyboard last said it was, and how fast the bar is travelling
  /// towards it.
  double _target = 0;
  double _velocity = 0;
  Duration _ticked = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
  }

  /// One frame of the panel this is running on. The whole rule is "how far
  /// would this have to move in a single frame", and the app asks Android for
  /// the fastest mode the display has, so 60Hz cannot be assumed.
  double get _frame {
    final rate = View.of(context).display.refreshRate;
    return rate > 1 ? 1 / rate : 1 / 60;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset == _target) return;
    _target = inset;

    if (_ticker.isActive) return;
    // How far the bar may go in the frame this report is being read in. How
    // long ago the last report was does not come into it: those frames are
    // spent, and the only question left is whether this one can be honoured
    // without the eye being shown a jump.
    final distance = _target - _lift.value;
    final frame = _frame;
    final speed = distance > 0 ? _riseSpeed : _fallSpeed;
    if (distance.abs() <= speed * frame) {
      // One frame's worth: go there, and keep the speed that implies. The
      // first lump of a slide usually arrives after a run of these, and the
      // movement it starts should carry on from what the keys were already
      // doing rather than from a standstill.
      _velocity = distance / frame;
      _lift.value = _target;
      return;
    }
    _ticked = Duration.zero;
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    final dt = ((elapsed - _ticked).inMicroseconds / 1e6).clamp(0.0, 1 / 30);
    _ticked = elapsed;
    if (dt == 0) return;

    final rising = _target > _lift.value;
    final stiffness = rising ? _riseStiffness : _fallStiffness;
    final speed = rising ? _riseSpeed : _fallSpeed;

    // The spring is stepped by its own closed form rather than by adding up
    // accelerations. A frame is a long time next to a spring this stiff —
    // stiffness 3600 over a 60Hz frame is a radian of its own period — and
    // integrating it a frame at a time has it overshoot and come back, which
    // is a bar that slows down, speeds up and lands twice.
    final w = math.sqrt(stiffness);
    final offset = _lift.value - _target;
    // Critical damping only promises not to pass the target when it starts
    // from a standstill; thrown at it with a speed of its own it sails past
    // and comes back, which is the bar dipping below the place it lives and
    // climbing into it. The speed it carries in is held to what the spring
    // can shed over the distance that is left, which is also what eases the
    // last of a glide: the limit falls with the distance.
    final bound = w * offset.abs();
    final from = _velocity.clamp(-bound, bound);
    final decay = math.exp(-w * dt);
    final reach = offset + (from + w * offset) * dt;
    var next = _target + reach * decay;
    var velocity = (from - w * reach) * decay;

    // Critically damped, it would cover most of a lump in the first frame.
    // Held to the speed limit, the first frames of one are a glide at that
    // speed and the spring only takes over for the last of the distance,
    // where it is the slower of the two — which is the bar settling onto the
    // keys rather than halting on them.
    final step = next - _lift.value;
    final cap = speed * dt;
    if (step.abs() > cap) {
      next = _lift.value + cap * step.sign;
      velocity = speed * step.sign;
    }

    if ((_target - next).abs() < 0.5) {
      _lift.value = _target;
      _velocity = 0;
      _ticker.stop();
      return;
    }
    _lift.value = next;
    _velocity = velocity;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _lift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _KeyboardInsetScope(lift: _lift, child: widget.child);
  }
}

class _KeyboardInsetScope extends InheritedWidget {
  final ValueListenable<double> lift;

  const _KeyboardInsetScope({required this.lift, required super.child});

  @override
  bool updateShouldNotify(_KeyboardInsetScope old) => lift != old.lift;
}

/// Floats [child] above the keyboard without the layout knowing about it.
///
/// A `Scaffold` that resizes for the keyboard takes the room out of whatever
/// is above the field — which on the calendar means squeezing the month the
/// user is looking at, and on Schedule means the field moving by relayout,
/// exactly as reported, lumps included. Translating costs no layout, so what
/// is above keeps the height it had and the keyboard simply arrives over it.
class KeyboardLift extends StatelessWidget {
  final Widget child;

  const KeyboardLift({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final lift = KeyboardInset.of(context);
    return AnimatedBuilder(
      animation: lift,
      builder: (context, child) =>
          Transform.translate(offset: Offset(0, -lift.value), child: child),
      child: child,
    );
  }
}

/// Room at the foot of a list for the keyboard that is over it, so the last
/// thing in the list can still be scrolled clear of the keys. The screen is
/// not shortened — see [KeyboardLift] — so without this the bottom of the run
/// is simply behind them with no way to reach it.
class KeyboardRoom extends StatelessWidget {
  const KeyboardRoom({super.key});

  @override
  Widget build(BuildContext context) {
    final lift = KeyboardInset.of(context);
    return AnimatedBuilder(
      animation: lift,
      builder: (context, _) => SizedBox(height: lift.value),
    );
  }
}

/// The fade that carries whatever is above the quick-add field down into the
/// ground the field sits on, instead of letting the field slice it off square
/// — the last card in a full day used to end in a straight cut across the
/// middle of a word.
///
/// [ground] is what the field is standing on, which is not always the same
/// colour: on the calendar it follows the month opening out.
class GroundFade extends StatelessWidget {
  final Color ground;

  const GroundFade({super.key, required this.ground});

  /// How far above the field the fade reaches.
  static const height = 48.0;

  /// Its shape. A straight ramp from clear to solid has a visible edge at
  /// each end — the point where it starts and the point where it finishes
  /// both read as lines. These follow a smoothstep instead, so it eases in
  /// and out of the two grounds and no edge is anywhere to be found.
  static const _stops = [0.0, 0.2, 0.4, 0.5, 0.6, 0.8, 1.0];
  static const _alphas = [0.0, 0.104, 0.352, 0.5, 0.648, 0.896, 1.0];

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: _stops,
              colors: [for (final a in _alphas) ground.withValues(alpha: a)],
            ),
          ),
        ),
      ),
    );
  }
}

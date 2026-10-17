import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Where the keyboard is, as Android measures it, kept beside what
/// `MediaQuery` says and used whenever it is the larger of the two.
///
/// `viewInsets.bottom` is not one measurement. On a window drawn edge to
/// edge it leaves the system bar strip at the foot of the screen out of a
/// slide's animated values and puts it back at the end — and *which* slides
/// leave it out varies: opening the field, closing it and opening it again
/// quickly produced one of each. Measured off a phone recording, the field
/// sat 17px from the keys on the first opening and 62px on the second.
///
/// Correcting a number whose meaning changes needs something saying which
/// meaning is in force, and that was tried: the activity reported what was
/// missing while an animation was running. It is a race — the flag comes
/// down one channel and the number down another — and it showed as the bar
/// sitting a strip too high for the whole of every other opening, but only
/// when the field was opened and closed quickly, which is exactly when two
/// slides overlap.
///
/// So the activity reports where the keyboard is instead (`MainActivity`),
/// which cannot disagree with itself, and the two are reconciled by taking
/// whichever says the keys reach further. That way neither a platform
/// message that arrives a frame late nor an inset that is a strip short can
/// put the bar over the keyboard; the worst either can do is hold it where
/// the keys were a frame ago.
class KeyboardGap {
  KeyboardGap._();

  static final instance = KeyboardGap._();

  static const _channel = EventChannel('caldo/ime');

  /// How far the keys reach into the window, in logical pixels, as Android
  /// last reported it. Zero while the keyboard is away, and zero always on
  /// a platform that never reports — an Android older than 11, or a test —
  /// where `MediaQuery` is left to say it alone, as it did before any of
  /// this.
  final ValueNotifier<double> covered = ValueNotifier<double>(0);

  /// What Android reported it from, for the numbers on screen: the raw IME
  /// inset, the navigation bar, and how much of the display it takes this
  /// window to sit above.
  final ValueNotifier<String> raw = ValueNotifier<String>('');

  StreamSubscription<dynamic>? _sub;

  void listen() {
    if (_sub != null) return;
    _sub = _channel.receiveBroadcastStream().listen(
      (value) {
        if (value is num) {
          covered.value = value.toDouble();
        } else if (value is Map) {
          covered.value = (value['reach'] as num).toDouble();
          raw.value =
              'ime ${(value['ime'] as num).toStringAsFixed(1)} '
              'nav ${(value['nav'] as num).toStringAsFixed(1)} '
              'below ${(value['below'] as num).toStringAsFixed(1)}';
        }
      },
      // Nothing to do but carry on with Flutter's number, which is what the
      // app ran on before and is right wherever this cannot be reported.
      onError: (_) => covered.value = 0,
    );
  }

  /// How far to lift whatever is glued to the keyboard.
  static double of(BuildContext context) {
    final covered = math.max(
      MediaQuery.viewInsetsOf(context).bottom,
      instance.covered.value,
    );
    if (covered <= 0) return 0;
    // Less the strip at the foot of the window the layout never had: the
    // screens sit in a `SafeArea` that keeps the gesture bar reserved
    // whether or not the keys are over it, so the bar starts that much above
    // the window's edge and has that much less to climb. Read from the view,
    // since the SafeArea has taken it out of the `MediaQuery` handed down —
    // that is what it is for.
    final reserved = MediaQueryData.fromView(
      View.of(context),
    ).viewPadding.bottom;
    return math.max(0.0, covered - reserved);
  }

  /// Whether to draw the numbers above the bar. Off, and not stored: it is
  /// turned on by a long press on the Settings title when something about
  /// the keyboard looks wrong on a device that cannot be plugged into a
  /// machine, and it has taken four attempts at one such bug to decide that
  /// is worth having. What it shows is every number the lift is made of, so
  /// a recording of the fault says which of them is lying.
  static final showNumbers = ValueNotifier<bool>(false);

  /// Forgets what the platform last said, so one test cannot set the stage
  /// for the next.
  @visibleForTesting
  void forget() => covered.value = 0;
}

/// The numbers behind the lift, drawn above the bar while [showNumbers] is
/// on and the keyboard is up.
class KeyboardNumbers extends StatelessWidget {
  const KeyboardNumbers({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: KeyboardGap.showNumbers,
      builder: (context, on, _) {
        if (!on) return const SizedBox.shrink();
        return ValueListenableBuilder<double>(
          valueListenable: KeyboardGap.instance.covered,
          builder: (context, platform, _) {
            final inset = MediaQuery.viewInsetsOf(context).bottom;
            if (inset <= 0 && platform <= 0) return const SizedBox.shrink();
            final reserved = MediaQueryData.fromView(
              View.of(context),
            ).viewPadding.bottom;
            final line =
                'inset ${inset.toStringAsFixed(1)}  '
                'android ${platform.toStringAsFixed(1)}  '
                'strip ${reserved.toStringAsFixed(1)}  '
                'lift ${KeyboardGap.of(context).toStringAsFixed(1)}\n'
                '${KeyboardGap.instance.raw.value}';
            return IgnorePointer(
              child: Container(
                width: double.infinity,
                color: const Color(0xCC000000),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Text(
                  line,
                  textAlign: TextAlign.right,
                  maxLines: 2,
                  style: const TextStyle(
                    color: Color(0xFF7CFF9B),
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Floats [child] above the keyboard: its bottom edge is the keyboard's top
/// edge, at every moment of the slide and wherever the slide stops.
///
/// There is no animation here and there must not be one. Android reports
/// where the keyboard is; the bar goes there, in the same frame, every time.
/// Anything laid over that — a spring, a speed limit, a rule about which
/// reports to believe — is the bar deciding to be somewhere the keyboard is
/// not, which is the one thing it may never do. Three of those were tried
/// and all three were wrong the same way: smoothing a report that was honest
/// put the bar behind the keys, and no amount of tuning turns a lag into an
/// attachment. If a keyboard jumps, the bar jumps with it — that is what
/// being attached to it means.
///
/// The height is read here and in [KeyboardRoom] and nowhere else, so a
/// change that arrives on every frame of a slide rebuilds two small widgets
/// rather than a screen. The screens' `Scaffold`s do not resize for it: that
/// would take the room out of whatever is above the field, which on an
/// opened month is the grid being looked at.
class KeyboardLift extends StatelessWidget {
  final Widget child;

  const KeyboardLift({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: KeyboardGap.instance.covered,
      builder: (context, _, child) => Transform.translate(
        offset: Offset(0, -KeyboardGap.of(context)),
        child: child,
      ),
      child: child,
    );
  }
}

/// Room at the foot of a list for the keyboard that is over it, so the last
/// thing in the list can still be scrolled clear of the keys. The screen is
/// not shortened — see [KeyboardLift] — so without this the bottom of the
/// run is simply behind them with no way to reach it.
class KeyboardRoom extends StatelessWidget {
  const KeyboardRoom({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: KeyboardGap.instance.covered,
      builder: (context, _, _) => SizedBox(height: KeyboardGap.of(context)),
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

  /// How much of it to draw, from all of it down to none.
  ///
  /// The fade is for a list that runs under the field. The calendar has one
  /// only while the day's tasks are on screen: opened out, what sits above
  /// the field is the month itself, which is a fixed grid that ends above
  /// the field and has nothing to soften — so the fade there only dimmed
  /// the last week of the month. Measured on the opened month, the outline
  /// around the selected day went from 155 down to 112 over its last sixty
  /// pixels, and a day with enough tasks had their chips washed out the
  /// same way.
  final double strength;

  const GroundFade({super.key, required this.ground, this.strength = 1});

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
              colors: [
                for (final a in _alphas)
                  ground.withValues(alpha: a * strength.clamp(0.0, 1.0)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

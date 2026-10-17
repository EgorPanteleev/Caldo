import 'package:flutter/material.dart';
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

/// Floats [child] above the keyboard: its bottom edge is the keyboard's top
/// edge, at every moment of the slide and wherever the slide stops.
///
/// There is no animation here and there must not be one. Android reports
/// where the keyboard is; the bar goes there, in the same frame, every time.
/// Anything laid over that — a spring, a speed limit, a rule about which
/// reports to believe — is the bar deciding to be somewhere the keyboard is
/// not, which is the one thing it may never do. Three of those were tried
/// and all three were wrong in the same way: smoothing a report that was
/// honest put the bar behind the keys, and no amount of tuning turns a lag
/// into an attachment. If a keyboard jumps, the bar jumps with it — that is
/// what being attached to it means.
///
/// The inset is read here and in [KeyboardRoom] and nowhere else, so a
/// change that arrives on every frame of a slide rebuilds two small widgets
/// rather than a screen. The screens' `Scaffold`s do not resize for it: that
/// would take the room out of whatever is above the field, which on an
/// opened month is the grid being looked at.
class KeyboardLift extends StatelessWidget {
  final Widget child;

  const KeyboardLift({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: Offset(0, -MediaQuery.viewInsetsOf(context).bottom),
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
    return SizedBox(height: MediaQuery.viewInsetsOf(context).bottom);
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

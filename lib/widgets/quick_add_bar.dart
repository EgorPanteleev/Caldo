import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import 'groups.dart';
import 'selection.dart';
import 'tick_off.dart';

/// Identifies the button beside the quick-add field.
const quickAddButtonKey = Key('quick-add-button');

/// Identifies the row of groups above the open field.
const quickAddGroupsKey = Key('quick-add-groups');

/// The field under a day's tasks: type a title, confirm, and it lands on the
/// day in view without opening the full form. Used by the calendar and by the
/// day card that opens over it.
class QuickAddBar extends StatefulWidget {
  final DateTime date;
  final TextEditingController controller;

  /// Files what has been typed, into the group picked above the field — or,
  /// with null, the one a task made on this screen goes into anyway.
  final ValueChanged<int?> onSubmit;

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
  late final FocusNode _focus = FocusNode()..addListener(_focused);

  bool _open = false;

  /// The group picked above the field for the task being typed; null for
  /// the default. Back to the default each time the field opens, so a pick
  /// made for one task does not quietly file the next.
  int? _group;

  void _focused() {
    if (!mounted) return;
    setState(() {
      if (_focus.hasFocus && !_open) _group = null;
      _open = _focus.hasFocus;
    });
  }

  /// The shell's tab bar this field sits in the room of, if it has one.
  BarFoot? _foot;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final foot = BarRoom.footOf(context);
    if (foot != _foot) _foot?.detach(this);
    _foot = foot
      ?..attach(
        this,
        open: _openField,
        form: () => widget.onFullForm(),
        undo: UndoScope.placeOf(context),
        selection: Selection.maybeOf(context),
      );
  }

  /// Brings the field up on the keyboard. A field that still has the focus
  /// — the keyboard put away by Back, or by an empty tick — only needs the
  /// keyboard back: asking for the focus it already has does nothing at all.
  void _openField() {
    if (_focus.hasFocus) {
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    } else {
      _focus.requestFocus();
    }
  }

  @override
  void dispose() {
    _foot?.detach(this);
    _focus.dispose();
    super.dispose();
  }

  /// Hands the title over and closes the field. The task is filed at that
  /// point, so leaving the keyboard up over a day whose list has just changed
  /// hides the very thing the tap was meant to produce.
  ///
  /// With nothing typed there is nothing to file, and the tick does exactly
  /// what cancelling does: the keyboard goes, and the field keeps hold of
  /// it. On a phone, the opening after a tick on an empty field came up with
  /// the field a strip above the keys, every time, and the opening after a
  /// cancel never did. Telling the keyboard to go first (1.3.12) changed
  /// nothing, so the hiding was not the difference. Letting go of the field
  /// was: it closes the field's connection to the keyboard, the next tap opens
  /// a new one, and Android brings the keyboard up from scratch — the only
  /// opening that ever went wrong. Back leaves the connection open, and so
  /// now does an empty tick.
  void _submit() {
    final filing = widget.controller.text.trim().isNotEmpty;
    // A group deleted while the field was open is no place to file into.
    final lists = context.read<TaskProvider>().lists;
    widget.onSubmit(lists.any((l) => l.id == _group) ? _group : null);
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    if (filing) _focus.unfocus();
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
    // A filled grey with the tab bar's rim. Outlined on true black and
    // left unfilled, the pill read as a hole cut in the screen; filled and
    // unrimmed, it was a grey smudge beside the bar's crisp edge.
    final border = OutlineInputBorder(
      borderRadius: const BorderRadius.all(Radius.circular(26)),
      borderSide: BorderSide(color: BarRoom.rim(p), width: BarRoom.rimWidth),
    );

    // With every group on show there is no telling which one a new task
    // belongs in, so the groups are offered above the open field; one group
    // on show is where it goes, and a single group is no choice at all.
    final picking = context.select<TaskProvider, bool>(
      (t) => writing && t.group == null && t.lists.length > 1,
    );

    final row = Row(
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
              hintText: S.of(context).addTaskOn(Dates.shortDay(widget.date)),
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
          tooltip: writing ? S.of(context).addTask : S.of(context).newTask,
          onTap: _press,
        ),
      ],
    );

    // In the tab bar's room the field is only there while it is being
    // written in, and Undo and the selection stand in the bar's place
    // instead of the field's — the shell draws those.
    final bar = _foot != null
        ? Padding(
            padding: const EdgeInsets.fromLTRB(
              BarRoom.side,
              BarRoom.above,
              BarRoom.side,
              BarRoom.below,
            ),
            child: SizedBox(
              height: BarRoom.pill,
              child: _WhileWriting(open: _open, child: row),
            ),
          )
        : Padding(
            padding: widget.padding,
            // Undo under the selection: a tick offered back while cards are
            // being picked out waits beneath the bar for them.
            child: SelectionSlot(
              child: UndoSlot(onField: _openField, child: row),
            ),
          );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (picking)
          _WhileKeyboardUp(
            child: _GroupPick(
              picked: _group,
              padding: EdgeInsets.only(
                left: _foot != null ? BarRoom.side : widget.padding.left,
                right: _foot != null ? BarRoom.side : widget.padding.right,
                top: 6,
              ),
              onPick: (id) => setState(() => _group = id),
            ),
          ),
        bar,
      ],
    );
  }
}

/// Draws [child] only while the keyboard is up. Open is not the same as
/// focused: Back puts the keyboard away and the field keeps hold of it (see
/// [_QuickAddBarState._submit]), and the groups left standing over a closed
/// field read as part of the screen, offered before anything was being
/// added. Reads the lift, so it is rebuilt on every frame of a slide — it
/// is the smallest widget that can, and what it holds is a row of chips.
class _WhileKeyboardUp extends StatelessWidget {
  final Widget child;

  const _WhileKeyboardUp({required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: KeyboardGap.instance.covered,
      // Grown into rather than popped in, as the keyboard comes up under
      // it; the field below keeps its place on the keys either way.
      builder: (context, _, child) => AnimatedSize(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        alignment: Alignment.bottomCenter,
        child: KeyboardGap.of(context) > 0
            ? child
            : const SizedBox(width: double.infinity),
      ),
      child: child,
    );
  }
}

/// Draws the field in the tab bar's room only while it is being written in
/// with the keyboard up, which is when the bar is out of the way: the shell
/// puts the bar away while the keys are up, and the field takes its place
/// and rides them. With the keyboard down the bar is back over it, and a
/// field left focused by Back is not drawn round its edges.
class _WhileWriting extends StatelessWidget {
  final bool open;
  final Widget child;

  const _WhileWriting({required this.open, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: KeyboardGap.instance.covered,
      builder: (context, _, child) {
        final shown = open && KeyboardGap.of(context) > 0;
        // Kept in the tree either way, so it keeps what is typed and its
        // hold on the keyboard.
        return IgnorePointer(
          ignoring: !shown,
          child: Opacity(opacity: shown ? 1 : 0, child: child),
        );
      },
      child: child,
    );
  }
}

/// The groups as chips across the top of the open field, the one the task
/// will go into lit: the default until another is tapped. The header's row
/// picks what a screen shows; this one picks where a task goes, and it is
/// one tap with the keyboard still up — the form's Group row was the only
/// way before, and that meant leaving the field for the whole form.
class _GroupPick extends StatelessWidget {
  final int? picked;
  final EdgeInsets padding;
  final ValueChanged<int?> onPick;

  const _GroupPick({
    required this.picked,
    required this.padding,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final lists = context.select<TaskProvider, List<TaskList>>((t) => t.lists);
    final fallback = context.read<TaskProvider>().defaultGroup;
    final chosen = lists.any((l) => l.id == picked) ? picked! : fallback;
    final height = math.max(
      32.0,
      MediaQuery.textScalerOf(context).scale(14) * 1.3 + 12,
    );
    // Part of the field as far as a tap is concerned, so picking a group
    // never lets go of the keyboard.
    return TextFieldTapRegion(
      child: Padding(
        padding: EdgeInsets.only(top: padding.top),
        child: SizedBox(
          key: quickAddGroupsKey,
          height: height,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.only(left: padding.left, right: padding.right),
            children: [
              for (final list in lists)
                Padding(
                  padding: EdgeInsets.only(left: list == lists.first ? 0 : 8),
                  child: Center(
                    child: GroupChip(
                      label: groupLabel(context, list),
                      color: list.style.color,
                      selected: list.id == chosen,
                      onTap: () => onPick(list.id == fallback ? null : list.id),
                    ),
                  ),
                ),
            ],
          ),
        ),
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
        shape: CircleBorder(
          side: BorderSide(color: BarRoom.rim(p), width: BarRoom.rimWidth),
        ),
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

/// Files an all-day task on [day] from a one-line title, into [group] if
/// one was picked above the field, and otherwise into the group on show —
/// added to a screen showing one group, a task anywhere else would vanish as
/// it was filed — in that group's colour.
Future<void> quickAddTask(
  BuildContext context, {
  required DateTime day,
  required String title,
  int? group,
}) async {
  final trimmed = title.trim();
  if (trimmed.isEmpty) return;
  final provider = context.read<TaskProvider>();
  await provider.add(
    Task(
      listId: group ?? provider.groupForNew,
      title: trimmed,
      dueAt: dayOf(day).millisecondsSinceEpoch,
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
    // Nothing is taken off for the shell's tab bar: with the bar, the field
    // rests in the bar's own room, so it starts from the foot as well.
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

/// How much of the foot of a screen the shell's tab bar floats over, and
/// the way between the bar and the screen's field.
///
/// The two screens with a field run their ground on under the bar, so the
/// day panel's grey does not stop at a band of black, and their field rests
/// in the bar's room rather than above it: it is drawn only while it is
/// being written in, brought up by the plus beside the bar ([foot]). The
/// field and the bar stacked one over the other at the foot of the screen
/// were two grey pills fighting over one place — "badly fit". Nothing above
/// the shell provides one — the form and the sheets are pushed over the bar
/// — so there it is nothing.
class BarRoom extends InheritedWidget {
  final double height;

  /// Where a screen with a field hands the bar what its plus opens, and
  /// what stands in the bar's place for a moment; null on the screens with
  /// no field, and with the menu.
  final BarFoot? foot;

  const BarRoom({
    super.key,
    required this.height,
    this.foot,
    required super.child,
  });

  /// The bar's pill, and the room around it.
  static const pill = 62.0;
  static const above = 4.0;
  static const below = 8.0;
  static const side = 12.0;

  /// The tabs stand further in than the field that takes their place:
  /// measured off another app's bar the user pointed at, a pill about
  /// nine tenths of the phone's width reads as a thing set on the screen,
  /// where one 12 points from either edge read as a band across it.
  static const tabsSide = 23.0;

  /// The rim round the tab bar, its plus, and the add field and its button.
  /// In the field's grey it was a step off the bar's own fill and all but
  /// gone on a phone; measured off another app's bar the user pointed at,
  /// the edge there is two and a half times as bright as the fill inside
  /// it, and about a point and a half wide.
  static Color rim(AppPalette p) => Color.lerp(p.field, p.muted, 0.26)!;

  static const rimWidth = 1.4;

  /// The height the bar takes at the foot of a screen, gaps included.
  static const room = above + pill + below;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BarRoom>()?.height ?? 0;

  static BarFoot? footOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BarRoom>()?.foot;

  @override
  bool updateShouldNotify(BarRoom oldWidget) =>
      oldWidget.height != height || oldWidget.foot != foot;
}

/// What a screen's field lends the tab bar: how to open the field and the
/// full form, which the plus does on a tap and a long press, and where the
/// screen's Undo and selection are offered, which then stand in the bar's
/// place as they stood in the field's.
class BarFoot extends ChangeNotifier {
  Object? _owner;
  VoidCallback? open;
  VoidCallback? form;
  UndoPlace? undo;
  Selection? selection;

  void attach(
    Object owner, {
    required VoidCallback open,
    required VoidCallback form,
    required UndoPlace? undo,
    required Selection? selection,
  }) {
    final changed =
        owner != _owner || undo != this.undo || selection != this.selection;
    _owner = owner;
    this.open = open;
    this.form = form;
    this.undo = undo;
    this.selection = selection;
    if (changed) _tell();
  }

  void detach(Object owner) {
    if (owner != _owner) return;
    _owner = null;
    open = null;
    form = null;
    undo = null;
    selection = null;
    _tell();
  }

  bool _disposed = false;

  /// After the frame: the field attaches while the screens are being built,
  /// and the bar is built beside them, not under them.
  void _tell() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!_disposed) notifyListeners();
  });

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
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

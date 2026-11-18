import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../providers/task_provider.dart';
import '../services/attachments.dart';
import '../theme/app_theme.dart';
import '../theme/tweaks.dart';
import '../utils/dates.dart';
import '../utils/platform.dart';
import 'attachments_field.dart';
import 'groups.dart';
import 'selection.dart';
import 'tick_off.dart';

/// Identifies the button beside the quick-add field.
const quickAddButtonKey = Key('quick-add-button');

/// Identifies the group the open field files into, under the title.
const quickAddGroupsKey = Key('quick-add-groups');

/// Identifies the plus that attaches a photo or a file to the task typed.
const quickAddAttachKey = Key('quick-add-attach');

/// The field under a day's tasks: type a title, confirm, and it lands on the
/// day in view without opening the full form. Used by the calendar and by the
/// day card that opens over it.
///
/// Opened, it is two rows: the title on top, and under it a plus that
/// attaches photos and files, the group the task goes into, and the tick
/// that files it.
class QuickAddBar extends StatefulWidget {
  final DateTime date;
  final TextEditingController controller;

  /// Files what has been typed, into the group picked under the field — or,
  /// with null, the one a task made on this screen goes into anyway — with
  /// whatever was attached to it.
  final void Function(int? group, List<Attachment> attached) onSubmit;

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

  /// The group picked under the field for the task being typed; null for
  /// the default. Back to the default each time the field opens, so a pick
  /// made for one task does not quietly file the next.
  int? _group;

  /// What has been attached to the task being typed; let go of on the same
  /// terms as [_group]. A copy dropped here is swept up on a later start
  /// (`Attachments.sweep`), as the form's are.
  final List<Attachment> _attached = [];

  void _focused() {
    if (!mounted) return;
    setState(() {
      if (_focus.hasFocus && !_open) {
        _group = null;
        _attached.clear();
      }
      _open = _focus.hasFocus;
    });
    if (onDesktop) KeyboardGap.instance.write(this, _focus.hasFocus);
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
    KeyboardGap.instance.write(this, false);
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
  ///
  /// A desktop has no keyboard to put away with the field still held: there
  /// the focus is all that "open" is, so Enter on an empty field lets go of
  /// it, and so does Escape.
  void _submit() {
    final filing = widget.controller.text.trim().isNotEmpty;
    // A group deleted while the field was open is no place to file into.
    final lists = context.read<TaskProvider>().lists;
    widget.onSubmit(
      lists.any((l) => l.id == _group) ? _group : null,
      List.of(_attached),
    );
    // Kept with nothing typed: nothing was filed to take them.
    if (filing) setState(_attached.clear);
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    if (filing || onDesktop) _focus.unfocus();
  }

  /// A plus opens the form; a tick files what has been typed.
  void _press() => _focus.hasFocus ? _submit() : widget.onFullForm();

  /// Has the user pick what to attach, and keeps whatever comes back for the
  /// task being typed.
  Future<void> _attach(AttachFrom from) async {
    final picked = await Attachments.instance.pick(from);
    if (!mounted) return;
    if (picked.attached.isNotEmpty) {
      setState(() => _attached.addAll(picked.attached));
    }
    if (picked.tooBig.isNotEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(S.of(context).tooBigToAttach(picked.tooBig.join(', '))),
        ),
      );
    }
    // The pickers are other apps' screens, and the keyboard goes while one
    // is up; back on a field still being written in, it is wanted again.
    if (onDesktop) return;
    await _whenInFront();
    if (mounted && _focus.hasFocus) _openField();
  }

  /// Waits for Caldo to be in front again. What a picker picked arrives
  /// before the activity is resumed, and the window gets its focus a little
  /// after that; Android drops a call for the keyboard made before then —
  /// asked for at once, it never came.
  Future<void> _whenInFront() async {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      final back = Completer<void>();
      final listener = AppLifecycleListener(onResume: back.complete);
      await back.future;
      listener.dispose();
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    // Opening the field is the moment the button's job changes: from here on
    // it finishes the task being typed, so it says so. Waiting for the first
    // character left it a plus over an active field.
    final writing = _focus.hasFocus;

    // With every group on show there is no telling which one a new task
    // belongs in, so the group is offered under the open field; one group
    // on show is where it goes, and a single group is no choice at all.
    final picking = context.select<TaskProvider, bool>(
      (t) => writing && t.group == null && t.lists.length > 1,
    );

    // Escape closes the field, as Back does on a phone.
    final field = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _focus.unfocus,
      },
      child: TextField(
        controller: widget.controller,
        focusNode: _focus,
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        style: TextStyle(color: p.text, fontSize: 14.5),
        // Nothing marks the focus but the cursor. An accent ring around half
        // the screen was the loudest thing on it, and a neutral one on a grey
        // field is a line nobody reads. The fill and the rim are the panel's
        // round it, which grows a second row under the title.
        decoration: InputDecoration(
          isDense: true,
          hintText: s.addTaskOn(Dates.shortDay(widget.date)),
          hintStyle: TextStyle(color: p.muted, fontSize: 14.5),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 14,
          ),
          // The theme's own outline and fill, off: the panel is both.
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
    );

    // Part of the field as far as a tap is concerned, so nothing on the row
    // lets go of the keyboard.
    final tools = TextFieldTapRegion(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Row(
          children: [
            _AttachButton(key: quickAddAttachKey, onPick: _attach),
            if (_attached.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: AttachmentMark(count: _attached.length, color: p.muted),
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: picking
                    ? _GroupButton(
                        key: quickAddGroupsKey,
                        picked: _group,
                        onPick: (id) => setState(() => _group = id),
                      )
                    : null,
              ),
            ),
            const SizedBox(width: 8),
            _ConfirmButton(
              key: quickAddButtonKey,
              icon: Icons.check_rounded,
              tooltip: s.addTask,
              onTap: _submit,
              size: 38,
              fill: BarRoom.rim(p),
              rimmed: false,
            ),
          ],
        ),
      ),
    );

    final button = _ConfirmButton(
      key: quickAddButtonKey,
      icon: writing ? Icons.check_rounded : Icons.add,
      tooltip: writing ? s.addTask : s.newTask,
      onTap: _press,
    );

    // The second row is there only while the keyboard is up. Open is not
    // the same as focused: Back puts the keyboard away and the field keeps
    // hold of it (see [_submit]), and a row of tools left standing over it
    // read as part of the screen — the field folds back to one row, its
    // button beside it. Rebuilt on every frame of a slide; the field and the
    // rows are made outside, so only the frame round them is.
    final row = ListenableBuilder(
      listenable: KeyboardGap.instance.changes,
      builder: (context, _) {
        final opened = writing && KeyboardGap.up(context);
        return Row(
          children: [
            Expanded(
              // A filled grey with the tab bar's rim. Outlined on true black
              // and left unfilled, the pill read as a hole cut in the
              // screen; filled and unrimmed, it was a grey smudge beside the
              // bar's crisp edge.
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.field,
                  borderRadius: BorderRadius.circular(opened ? 22 : 26),
                  border: Border.all(
                    color: BarRoom.rim(p),
                    width: BarRoom.rimWidth,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    field,
                    // Grown into rather than popped in, as the keyboard
                    // comes up under it; the title keeps its place.
                    AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      alignment: Alignment.topCenter,
                      child: opened
                          ? tools
                          : const SizedBox(width: double.infinity),
                    ),
                  ],
                ),
              ),
            ),
            if (!opened) ...[const SizedBox(width: 10), button],
          ],
        );
      },
    );

    // In the tab bar's room the field is only there while it is being
    // written in, and Undo and the selection stand in the bar's place
    // instead of the field's — the shell draws those. A foot with no room
    // is the wide layout's: it wants to know what the plus opens, for the
    // sidebar's button, and has no bar for the field to rest in.
    final inBar = _foot != null && BarRoom.of(context) > 0;
    return inBar
        ? Padding(
            padding: const EdgeInsets.fromLTRB(
              BarRoom.side,
              BarRoom.above,
              BarRoom.side,
              BarRoom.below,
            ),
            // The bar's height at the least, the field in its middle; opened,
            // it grows up from the bar's foot.
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: BarRoom.pill),
              child: Align(
                heightFactor: 1,
                child: _WhileWriting(open: _open, child: row),
              ),
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
  }
}

/// A screen's add field resting in the tab bar's room, laid over the foot
/// of a screen that runs on under the bar — Schedule's and the calendar's,
/// one widget so the two cannot come to differ. Its ground, and the fade
/// into it of whatever is above, are only there while the field is out on
/// the keys: left in place they made a slab of the bar's room, and there
/// was nothing under the bar for its frosting to show.
///
/// [ground] is what the field stands on at a lift, and [fade] how much of
/// the fade to draw there; [also] is anything else they follow. Rebuilt on
/// every frame of a slide, so it is kept small.
class FieldInBarRoom extends StatelessWidget {
  final Color Function(double lift) ground;
  final double Function(double lift)? fade;
  final Listenable? also;
  final Widget child;

  const FieldInBarRoom({
    super.key,
    required this.ground,
    this.fade,
    this.also,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return KeyboardLift(
      child: ListenableBuilder(
        listenable: Listenable.merge([KeyboardGap.instance.changes, ?also]),
        builder: (context, child) {
          final up = KeyboardGap.up(context);
          final lift = KeyboardGap.of(context);
          final under = ground(lift);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GroundFade(
                ground: under,
                strength: up ? (fade?.call(lift) ?? 1) : 0,
              ),
              // Not a ColoredBox: that takes taps meant for what is beside
              // the bar.
              DecoratedBox(
                decoration: BoxDecoration(color: up ? under : null),
                child: child,
              ),
            ],
          );
        },
        child: child,
      ),
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
    return ListenableBuilder(
      listenable: KeyboardGap.instance.changes,
      builder: (context, child) {
        final shown = open && KeyboardGap.up(context);
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

/// The group a task typed with every group on show will go into, as a chip
/// under the title: its colour and its name, the default until another is
/// picked from the list it opens. The header's row picks what a screen
/// shows; this picks where a task goes, with the keyboard still up — the
/// form's Group row was the only way before, and that meant leaving the
/// field for the whole form. One chip rather than all of them in a row
/// leaves the row room for the plus and the tick.
class _GroupButton extends StatelessWidget {
  final int? picked;
  final ValueChanged<int?> onPick;

  const _GroupButton({super.key, required this.picked, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final lists = context.select<TaskProvider, List<TaskList>>((t) => t.lists);
    final fallback = context.read<TaskProvider>().defaultGroup;
    final chosen = lists.any((l) => l.id == picked) ? picked! : fallback;
    final list = lists.firstWhere(
      (l) => l.id == chosen,
      orElse: () => lists.first,
    );
    return _Popup(
      anchor: (toggle) => Material(
        type: MaterialType.transparency,
        shape: StadiumBorder(
          side: BorderSide(color: BarRoom.rim(p), width: BarRoom.rimWidth),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            toggle();
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(11, 8, 8, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Dot(color: list.style.color),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    groupLabel(context, list),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.text, fontSize: 13.5),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(Icons.expand_less_rounded, size: 18, color: p.muted),
              ],
            ),
          ),
        ),
      ),
      menu: (close) => _Menu(
        children: [
          for (final l in lists)
            _MenuItem(
              leading: _Dot(color: l.style.color),
              label: groupLabel(context, l),
              chosen: l.id == chosen,
              onTap: () {
                close();
                onPick(l.id == fallback ? null : l.id);
              },
            ),
        ],
      ),
    );
  }
}

/// The plus under the title, which attaches a photo or a file to the task
/// as the form's Attachments do.
class _AttachButton extends StatelessWidget {
  final ValueChanged<AttachFrom> onPick;

  const _AttachButton({super.key, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    _MenuItem item(
      IconData icon,
      String label,
      AttachFrom from,
      VoidCallback close,
    ) => _MenuItem(
      leading: Icon(icon, size: 19, color: p.muted),
      label: label,
      onTap: () {
        close();
        onPick(from);
      },
    );
    return _Popup(
      anchor: (toggle) => _ConfirmButton(
        icon: Icons.add,
        tooltip: s.sectionAttachments,
        onTap: toggle,
        size: 38,
        fill: Colors.transparent,
      ),
      menu: (close) => _Menu(
        children: [
          item(Icons.photo_outlined, s.attachPhoto, AttachFrom.photos, close),
          // A desktop has no camera app to hand a file to.
          if (!onDesktop)
            item(
              Icons.photo_camera_outlined,
              s.attachCamera,
              AttachFrom.camera,
              close,
            ),
          item(Icons.attach_file, s.attachFile, AttachFrom.files, close),
        ],
      ),
    );
  }
}

/// A group's colour, as a dot.
class _Dot extends StatelessWidget {
  final Color color;

  const _Dot({required this.color});

  @override
  Widget build(BuildContext context) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// A small list opened above [anchor], over whatever is above the field.
///
/// Laid in the overlay rather than pushed as a route: a route takes the
/// focus, the field lets go of the keyboard, and the field, the row and the
/// list all go with it. The list counts as part of the field for taps, so
/// picking from it keeps the keyboard up; a tap anywhere else closes it.
class _Popup extends StatefulWidget {
  final Widget Function(VoidCallback toggle) anchor;
  final Widget Function(VoidCallback close) menu;

  const _Popup({required this.anchor, required this.menu});

  @override
  State<_Popup> createState() => _PopupState();
}

class _PopupState extends State<_Popup> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();

  void _toggle() => setState(_portal.isShowing ? _portal.hide : _portal.show);

  void _close() {
    if (_portal.isShowing) setState(_portal.hide);
  }

  @override
  Widget build(BuildContext context) {
    return TapRegion(
      groupId: this,
      onTapOutside: (_) => _close(),
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (context) => Positioned(
            left: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topLeft,
              followerAnchor: Alignment.bottomLeft,
              offset: const Offset(0, -10),
              child: TapRegion(
                groupId: this,
                child: TextFieldTapRegion(child: widget.menu(_close)),
              ),
            ),
          ),
          child: widget.anchor(_toggle),
        ),
      ),
    );
  }
}

/// The surface of a [_Popup]: the field's grey and rim, raised off what it
/// stands over.
class _Menu extends StatelessWidget {
  final List<Widget> children;

  const _Menu({required this.children});

  static const width = 220.0;

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Material(
      color: p.field,
      elevation: 8,
      shadowColor: Colors.black,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: BarRoom.rim(p), width: BarRoom.rimWidth),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 300),
        child: SizedBox(
          width: width,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final Widget leading;
  final String label;
  final bool chosen;
  final VoidCallback onTap;

  const _MenuItem({
    required this.leading,
    required this.label,
    this.chosen = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 42,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              SizedBox(width: 20, child: Center(child: leading)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.text, fontSize: 14),
                ),
              ),
              if (chosen) Icon(Icons.check_rounded, size: 18, color: p.text),
            ],
          ),
        ),
      ),
    );
  }
}

/// The round button beside the field, and the ones on its second row. Plain
/// rather than the accent gradient the screen headers wear: it sits next to
/// the field the eye is already on, and a bright disc there pulled attention
/// off what was being typed.
class _ConfirmButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;

  /// The field's grey unless said otherwise.
  final Color? fill;
  final bool rimmed;

  const _ConfirmButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 48,
    this.fill,
    this.rimmed = true,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: fill ?? p.field,
        shape: CircleBorder(
          side: rimmed
              ? BorderSide(color: BarRoom.rim(p), width: BarRoom.rimWidth)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, color: p.text, size: size * 0.54),
          ),
        ),
      ),
    );
  }
}

/// Files an all-day task on [day] from a one-line title, into [group] if
/// one was picked under the field, and otherwise into the group on show —
/// added to a screen showing one group, a task anywhere else would vanish as
/// it was filed — in that group's colour, with whatever was [attachments].
Future<void> quickAddTask(
  BuildContext context, {
  required DateTime day,
  required String title,
  int? group,
  List<Attachment> attachments = const [],
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
      attachments: attachments,
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
///
/// Except in a slide, where `viewInsets` is a frame behind and taking the
/// further of the two held the field over the keys on every closing. There
/// Android's report is followed alone ([sliding]) — and not as it lands,
/// but read off the slide's own clock at each frame's vsync ([_Slide]).
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

  /// Whether [covered] is from the middle of a slide. Then it is followed
  /// alone: `viewInsets` is where the keys were, and taking the further of
  /// the two held the field over them on every closing.
  bool sliding = false;

  /// The slide [covered] is read off at each frame, while one runs and
  /// Android could describe it.
  _Slide? _slide;

  /// The curves of slides lately told, by their number: each is sent once,
  /// with its slide's first report.
  final _curves = <int, List<double>>{};

  /// Whether a frame is booked to read [_slide].
  bool _booked = false;

  /// How [covered] came by its number, for the recordings: 'clock' off a
  /// slide's own clock, 'reported' as a message last said.
  String how = 'reported';

  StreamSubscription<dynamic>? _sub;

  void listen() {
    if (_sub != null) return;
    _sub = _channel.receiveBroadcastStream().listen(
      take,
      // Nothing to do but carry on with Flutter's number, which is what the
      // app ran on before and is right wherever this cannot be reported.
      onError: (_) => covered.value = 0,
    );
  }

  /// One report from Android.
  @visibleForTesting
  void take(Object? value) {
    if (value is num) {
      _slide = null;
      sliding = false;
      how = 'reported';
      covered.value = value.toDouble();
    } else if (value is Map) {
      raw.value =
          'ime ${(value['ime'] as num).toStringAsFixed(1)} '
          'nav ${(value['nav'] as num).toStringAsFixed(1)} '
          'below ${(value['below'] as num).toStringAsFixed(1)}';
      // Before the number, so whoever it wakes reads the two together.
      sliding = value['sliding'] == true;
      final slide = sliding ? _Slide.read(value, _curves) : null;
      _slide = slide;
      if (slide == null) {
        how = 'reported';
        covered.value = (value['reach'] as num).toDouble();
      } else {
        // The frame this report belongs to has already begun, most
        // likely, and was placed off the clock as it then stood; from
        // the next on, it is read as this report sets it.
        how = 'clock';
        _book();
      }
    }
  }

  void _book() {
    if (_booked) return;
    _booked = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _booked = false;
      final slide = _slide;
      if (slide == null) return;
      // The vsync this frame is being made for, on the clock Android
      // stamped the slide with — not the timestamp handed to frame
      // callbacks, which starts from the first frame and can be dilated.
      final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
      final lead = slide.opening ? Tweaks.keysLeadOpen : Tweaks.keysLeadClose;
      final (reach, done) = slide.at(
        now.inMicroseconds + (lead * 1000).round(),
      );
      covered.value = reach;
      // Past its end it holds there until the slide's own end is
      // reported, which puts the window's insets in its place.
      if (!done) _book();
    });
  }

  /// The add fields being written in, on a desktop, and whether any is.
  ///
  /// A desktop has no keyboard to come up, and "the keys are up" is what
  /// the tab bar, the field in its room and the groups above it all go by:
  /// the bar is put away and the field drawn in its place while they are.
  /// What stands for it there is the field holding the focus — the plus
  /// gives it that, and Enter, Escape or a click anywhere else takes it
  /// away. Nothing sets this on a phone, where the keys speak for
  /// themselves.
  final ValueNotifier<bool> writing = ValueNotifier<bool>(false);
  final Set<Object> _writers = {};

  void write(Object field, bool on) {
    if (!(on ? _writers.add(field) : _writers.remove(field))) return;
    // A field taken out of the tree lets go while the tree is locked, and
    // those who listen rebuild.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback(
        (_) => writing.value = _writers.isNotEmpty,
      );
    } else {
      writing.value = _writers.isNotEmpty;
    }
  }

  /// What changes when [up] does.
  late final Listenable changes = Listenable.merge([covered, writing]);

  /// Whether the keyboard is up — or, with none to come up, whether an add
  /// field is being written in.
  static bool up(BuildContext context) =>
      instance.writing.value || of(context) > 0;

  /// How far to lift whatever is glued to the keyboard.
  static double of(BuildContext context) {
    // Subscribes either way, so the end of a slide is seen.
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final covered = instance.sliding
        ? instance.covered.value
        : math.max(inset, instance.covered.value);
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
  void forget() {
    _slide = null;
    _curves.clear();
    how = 'reported';
    sliding = false;
    covered.value = 0;
    _writers.clear();
    writing.value = false;
  }
}

/// One slide of the keyboard as Android described it in a report: where it
/// was at which vsync, how long it runs and its curve (`MainActivity
/// .clockOf`). Read at the vsync of each frame Flutter draws, it says where
/// the keys are in the frame of Android's that reaches the screen with it.
///
/// The report itself is no good for that: made in Android's frame, it lands
/// after Flutter has begun its own for the same vsync, and a field drawn to
/// it is a frame behind the keys — the whole of what 2.11.28 showed — or,
/// read ahead by a fixed time (2.11.23–2.11.27), off by however late each
/// message happened to land.
class _Slide {
  final int id;

  /// The vsync the report was made at, in microseconds of the monotonic
  /// clock both sides keep.
  final int stamp;

  /// How far through the slide that was, in time.
  final double fraction;

  /// How long the whole slide runs, in microseconds.
  final double length;

  /// The IME inset it runs from and to, and how much of that is below the
  /// window, in logical pixels.
  final double from, to, below;
  final List<double> curve;

  _Slide._(
    this.id,
    this.stamp,
    this.fraction,
    this.length,
    this.from,
    this.to,
    this.below,
    this.curve,
  );

  bool get opening => to > from;

  /// The slide [report] describes, or null if it describes none.
  static _Slide? read(
    Map<dynamic, dynamic> report,
    Map<int, List<double>> curves,
  ) {
    final id = report['slide'];
    if (id is! int) return null;
    final sent = report['curve'];
    if (sent is List) {
      curves[id] = [for (final y in sent) (y as num).toDouble()];
      // A few kept, for a report that lands after the next slide's first.
      curves.removeWhere((k, _) => k < id - 4);
    }
    final curve = curves[id];
    if (curve == null || curve.length < 2) return null;
    return _Slide._(
      id,
      (report['at'] as num).toInt(),
      (report['fraction'] as num).toDouble(),
      (report['length'] as num).toDouble() * 1000,
      (report['from'] as num).toDouble(),
      (report['to'] as num).toDouble(),
      (report['below'] as num).toDouble(),
      curve,
    );
  }

  /// How far the keys reach into the window at [micros], and whether the
  /// slide is over by then.
  (double, bool) at(int micros) {
    final f = (fraction + (micros - stamp) / length).clamp(0.0, 1.0);
    final x = f * (curve.length - 1);
    final i = math.min(x.floor(), curve.length - 2);
    final y = curve[i] + (curve[i + 1] - curve[i]) * (x - i);
    final ime = from + (to - from) * y;
    return (math.max(0.0, ime - below), f >= 1);
  }
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
                '${KeyboardGap.instance.raw.value}  '
                '${KeyboardGap.instance.how}';
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

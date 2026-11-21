import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../data/holidays.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../providers/task_provider.dart';
import '../services/device_calendars.dart';
import '../theme/app_theme.dart';
import '../theme/tweaks.dart';
import '../utils/dates.dart';
import '../utils/platform.dart';
import 'attachments_field.dart' show AttachmentMark;
import 'selection.dart';
import 'special_days.dart';
import 'task_menu.dart';

/// A task as it appears under the calendar: a card inked with its list's
/// colour, carrying a tick, the title and when it is due.
///
/// The card is a pane of tinted, frosted glass: a little over a fifth of the
/// list's colour, a rim of the colour itself, and over the fill a faint
/// white veil with a fine grain in it, the frost. Picked from mock-ups over a deeper ink, which read as a slab of
/// muddy navy once a day held several cards of one group. Left translucent
/// rather than mixed into one named colour, so a card is inked by the
/// ground it actually sits on — the calendar's day panel is a grey, the
/// agenda and the day card are black, and a card worked out against the
/// wrong one of those is a card darker than the sheet under it.
class TaskCard extends StatelessWidget {
  /// The room a card leaves around itself, and the corners it is cut to.
  /// Out here because a card being carried is backed in its own shape, and
  /// two places guessing at the same rectangle would drift.
  static const margin = EdgeInsets.fromLTRB(16, 0, 16, 8);
  static const radius = 14.0;

  /// How much of a card's colour is laid over the ground: 30%, with the
  /// frost no more than the grain's own 3.4% white. Picked from pictures
  /// ("richer") over 22% under an 8% veil, which read as greyish.
  static const ink = 0.30;

  /// What is left of the ink once a task is done: 9.45%, a sinking most
  /// of the way back into the ground. Raised from 7% from the Debug
  /// sliders (1.35×).
  static const doneInk = 0.0945;

  /// The grain (`tool/make_grain.py`): white, its alpha around half.
  static const grain = AssetImage('assets/grain.png');

  /// Laid at this, the grain is a white of about 3.4% varying by 1.5%:
  /// the whole of the frost. Picked from pictures over none, then raised
  /// from 1.25%; a grain twice as large and softened read as noise
  /// (2.11.38).
  static const _grainDepth = 0.0682;

  /// How deep the grain is laid on a card [frost] of the way frosted:
  /// the alpha [CardPane] paints it at.
  static double frostOf(double frost) =>
      (_grainDepth * Tweaks.cardFrost * frost).clamp(0, 1);

  /// The rim round a card of [colour]: the colour itself, faint once done.
  /// 56% (18% done), taken down from 70% from the Debug sliders (0.8×).
  static Color rimOf(Color colour, {bool faded = false}) => colour.withValues(
    alpha: ((faded ? 0.176 : 0.56) * Tweaks.cardRim).clamp(0, 1),
  );

  /// Fill, grain and rim for a card that is not a task's (a holiday, a
  /// phone event), so it stands among them as one of them.
  static CardPane paneOf(Color colour) => CardPane(
    ink: colour.withValues(alpha: ink * Tweaks.cardInk),
    frost: frostOf(1),
  );
  static BoxDecoration rimDecoration(Color colour) => BoxDecoration(
    border: Border.all(color: rimOf(colour), width: 1.5),
    borderRadius: BorderRadius.circular(radius),
  );

  final Task task;
  final TaskList? list;
  final VoidCallback onTap;

  /// Null where a long press belongs to something else — a list that can be
  /// dragged into a new order takes it to start the drag.
  final VoidCallback? onLongPress;
  final VoidCallback onToggle;

  /// Set while the card's tick has been drawn but the card is not yet
  /// crossed out: the tick answers the tap at once, and being crossed out
  /// follows a beat later (`TaskProvider.linger`).
  final bool ticking;

  /// Set when the card's task is leaving the run it is in — a done task out
  /// of the overdue backlog, a repeating one on to its next date: it fades,
  /// and the gap it leaves closes, before the run is read back
  /// (`TaskProvider.toggleDone`).
  final bool leaving;

  /// One line instead of two: the title, and when it is due at the far end
  /// of it. For the day card over the opened month, which has half a screen
  /// to say a day in, and at two lines a card a day of six tasks filled all
  /// of it.
  final bool dense;

  const TaskCard({
    super.key,
    required this.task,
    this.list,
    required this.onTap,
    this.onLongPress,
    required this.onToggle,
    this.ticking = false,
    this.leaving = false,
    this.dense = false,
  });

  /// The padding inside a card, and a dense one's.
  static const _inside = EdgeInsets.fromLTRB(14, 12, 14, 12);
  static const _insideDense = EdgeInsets.fromLTRB(14, 9, 14, 9);

  /// "All day", or the time it is due, and the repeat rule if it has one. Not
  /// the list it belongs to: the tick already wears that list's colour, and
  /// under the calendar a day's tasks are usually all from the same one, so
  /// the name was the same word under every card.
  String _subtitle(S s, bool h24) {
    final parts = [
      _when(s, h24),
      if (task.repeat != Repeat.none) s.repeatName(task.repeat),
    ];
    return parts.join(' · ');
  }

  String _when(S s, bool h24) {
    final due = task.due;
    if (due == null) return s.noDate;
    if (!task.hasTime) return s.allDay;
    final end = task.end;
    final from = Dates.time(due, h24: h24);
    return end == null ? from : '$from – ${Dates.time(end, h24: h24)}';
  }

  @override
  Widget build(BuildContext context) {
    final selection = Selection.maybeOf(context);
    if (selection == null) return _build(context, null);
    return ListenableBuilder(
      listenable: selection,
      builder: (context, _) => _build(context, selection),
    );
  }

  /// While anything is picked out ([selection] active), a tap anywhere on
  /// the card — its tick included — picks it out or puts it back, and what
  /// is picked out is lit in its colour: ticking a card off or opening it by mistake,
  /// halfway through gathering several, would be the wrong thing to have
  /// happen.
  Widget _build(BuildContext context, Selection? selection) {
    final p = AppTheme.of(context);
    final selecting = selection?.active ?? false;
    final picked = selection?.has(task) ?? false;
    // At a keyboard, Ctrl and a click picks a card out, as it does a file:
    // the long press that does it on a phone is the mouse's drag.
    void open() =>
        selection != null &&
            onDesktop &&
            HardwareKeyboard.instance.isControlPressed
        ? selection.toggle(task)
        : this.onTap();
    final onTap = selecting ? () => selection!.toggle(task) : open;
    final onToggle = selecting ? onTap : this.onToggle;
    final color = colorOfTask(
      task,
      list,
      fallback: AppTheme.accentOf(context).color,
    );
    // Crossed out once the tick has been seen, not with it.
    final faded = task.done && !ticking;
    final title = AnimatedDefaultTextStyle(
      duration: _settle,
      curve: Curves.easeOut,
      style: TextStyle(
        color: faded ? p.faint : p.text,
        fontSize: dense ? 15 : 15.5,
        fontWeight: FontWeight.w500,
        decoration: faded ? TextDecoration.lineThrough : null,
        decorationColor: p.faint,
      ),
      child: Text(
        task.title,
        maxLines: dense ? 1 : 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
    final flag = task.priority == Priority.none
        ? null
        : Icon(Icons.flag, size: 16, color: priorityColor(task.priority));
    final started = task.stage == Stage.inProgress
        ? const InProgressBadge()
        : null;

    final card = Padding(
      padding: TaskCard.margin,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          // A right click opens what can be done with it. Not while cards
          // are being picked out: those are dealt with together.
          onSecondaryTapUp: onDesktop && !selecting
              ? (details) => showTaskMenu(context, details.globalPosition, task)
              : null,
          borderRadius: BorderRadius.circular(TaskCard.radius),
          child: AnimatedContainer(
            // Ticked off, a card sinks over a moment rather than between two
            // frames: the point of the gesture is seeing it happen.
            duration: _settle,
            curve: Curves.easeOut,
            padding: dense ? _insideDense : _inside,
            decoration: CardPane(
              // A done task sinks most of the way back into the ground rather
              // than keeping its place in the run.
              ink: color.withValues(
                alpha: faded
                    ? TaskCard.doneInk * Tweaks.doneInk
                    : (TaskCard.ink + (picked ? 0.1 : 0)) * Tweaks.cardInk,
              ),
              // Done, the grain goes to nothing with the ink rather than
              // between two frames.
              frost: TaskCard.frostOf(faded ? 0 : 1),
              // A picked-out card is lit in its own colour: a soft glow
              // round it, outside only — under the translucent ink a
              // shadow would cloud the card itself.
              glow: color.withValues(alpha: picked ? 0.5 : 0),
            ),
            // The rim is the task's colour, the edge of the pane; picked
            // out, it is lifted towards white rather than turned white: a
            // white box round a violet card read as a frame put on it,
            // where this reads as the card itself lit up. In front rather
            // than a border of the card's own, which would take its width
            // out of what is inside and shift the title.
            foregroundDecoration: BoxDecoration(
              border: Border.all(
                color: picked
                    ? Color.lerp(color, Colors.white, 0.4)!
                    : TaskCard.rimOf(color, faded: faded),
                width: 1.5,
              ),
              borderRadius: BorderRadius.circular(TaskCard.radius),
            ),
            child: _WithChecklist(
              // Keyed by task: a reorderable list hands a card's state to
              // another task when it reorders, and a checklist left open
              // belongs to the task it was opened on.
              key: ValueKey(('checklist', task.id)),
              task: task,
              color: color,
              onTick: onToggle,
              // While tasks are being picked out the tick picks this one
              // out, which leaves nothing for its steps to hold back.
              holdsBack: !selecting,
              head: (tick, count) => dense
                  ? Row(
                      children: [
                        tick,
                        const SizedBox(width: 14),
                        Expanded(child: title),
                        if (started != null) ...[
                          const SizedBox(width: 8),
                          started,
                        ],
                        if (count != null) ...[const SizedBox(width: 8), count],
                        const SizedBox(width: 10),
                        // The time alone: the repeat rule is a mark, not
                        // words, so a long rule cannot eat into the title.
                        if (task.repeat != Repeat.none) ...[
                          Icon(Icons.repeat, size: 14, color: p.faint),
                          const SizedBox(width: 4),
                        ],
                        if (task.attachments.isNotEmpty) ...[
                          AttachmentMark(
                            count: task.attachments.length,
                            color: p.faint,
                          ),
                          const SizedBox(width: 4),
                        ],
                        if (task.claude != null) ...[
                          Icon(Icons.auto_awesome, size: 14, color: p.faint),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          _when(
                            S.of(context),
                            MediaQuery.alwaysUse24HourFormatOf(context),
                          ),
                          maxLines: 1,
                          style: TextStyle(
                            color: task.isOverdue ? AppColors.overdue : p.muted,
                            fontSize: 12.5,
                          ),
                        ),
                        if (flag != null) ...[const SizedBox(width: 8), flag],
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        tick,
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              title,
                              const SizedBox(height: 3),
                              Row(
                                children: [
                                  if (started != null) ...[
                                    started,
                                    const SizedBox(width: 8),
                                  ],
                                  Flexible(
                                    child: Text(
                                      _subtitle(
                                        S.of(context),
                                        MediaQuery.alwaysUse24HourFormatOf(
                                          context,
                                        ),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: task.isOverdue
                                            ? AppColors.overdue
                                            : p.muted,
                                        fontSize: 12.5,
                                      ),
                                    ),
                                  ),
                                  if (task.attachments.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    AttachmentMark(
                                      count: task.attachments.length,
                                      color: p.muted,
                                    ),
                                  ],
                                  if (task.claude case final model?) ...[
                                    const SizedBox(width: 8),
                                    ClaudeMark(model: model, color: p.muted),
                                  ],
                                  if (count != null) ...[
                                    const SizedBox(width: 10),
                                    count,
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                        if (flag != null) ...[const SizedBox(width: 10), flag],
                      ],
                    ),
            ),
          ),
        ),
      ),
    );

    return TweenAnimationBuilder<double>(
      tween: Tween(end: leaving ? 0.0 : 1.0),
      duration: _leave,
      curve: Curves.easeInOutCubic,
      child: card,
      // The card goes first and the gap after it: faded out over the first
      // half, while its height only closes over the whole. Both at once
      // read as the card being squashed rather than taken away.
      builder: (context, t, card) => ClipRect(
        // Only while it is going: at rest the clip would cut a picked-out
        // card's glow off flat along its top, where it has no margin.
        clipBehavior: t < 1 ? Clip.hardEdge : Clip.none,
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: t,
          child: Opacity(opacity: (t * 2 - 1).clamp(0.0, 1.0), child: card),
        ),
      ),
    );
  }

  static Color priorityColor(Priority priority) => switch (priority) {
    Priority.high => const Color(0xFFEF4444),
    Priority.medium => const Color(0xFFF59E0B),
    Priority.low => const Color(0xFF60A5FA),
    Priority.none => const Color(0xFF9394A1),
  };
}

/// A card's checklist, when its task has one: how far through it is
/// ("2/5"), handed to [head] to put beside the line under the title, and the
/// list itself, opened under the title when the count is tapped — so a step
/// can be ticked without opening the task. Under the row rather than in it,
/// so the card's own tick stays beside the title instead of sinking to the
/// middle of a taller card.
///
/// The card's tick is made here too, because a checklist holds it back: a
/// task with steps still open is not ticked off by the first tap on it. The
/// tick shakes and the list opens, so what is left is in front of the reader,
/// and a tap while it is open ticks the task off anyway. A task was ticked
/// off with half its steps forgotten, and refusing outright would leave a
/// step that turned out not to matter standing in the way.
class _WithChecklist extends StatefulWidget {
  final Task task;
  final Color color;
  final VoidCallback onTick;

  /// Whether open steps hold the tick back at all.
  final bool holdsBack;
  final Widget Function(Widget tick, Widget? count) head;

  const _WithChecklist({
    super.key,
    required this.task,
    required this.color,
    required this.onTick,
    required this.holdsBack,
    required this.head,
  });

  @override
  State<_WithChecklist> createState() => _WithChecklistState();
}

class _WithChecklistState extends State<_WithChecklist> {
  bool _open = false;

  /// Counts the taps held back, so the tick shakes once for each.
  int _heldBack = 0;

  void _tick() {
    final task = widget.task;
    final left = task.subtasks.length - task.subtasksDone;
    if (widget.holdsBack && !task.done && left > 0 && !_open) {
      setState(() {
        _open = true;
        _heldBack++;
      });
      return;
    }
    widget.onTick();
  }

  void _toggle(int index) {
    HapticFeedback.selectionClick();
    final task = widget.task;
    final steps = [
      for (var i = 0; i < task.subtasks.length; i++)
        i == index
            ? task.subtasks[i].copyWith(done: !task.subtasks[i].done)
            : task.subtasks[i],
    ];
    context.read<TaskProvider>().update(task.copyWith(subtasks: steps));
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final steps = widget.task.subtasks;
    final tick = _Tick(
      done: widget.task.done,
      color: widget.color,
      shakes: _heldBack,
      onTap: _tick,
    );
    if (steps.isEmpty) return widget.head(tick, null);
    // A done card has sunk back into the ground, and its pill goes with it.
    final ink = widget.task.done ? p.muted : p.text;

    // A pill rather than a few muted characters: written the way the time
    // beside it is, the count read as one more fact about the task, and
    // nothing said it would open. Lifted out of the card in the text's own
    // colour so it reads as a control in light and dark alike, and lifted a
    // little further while the list is open.
    final count = GestureDetector(
      key: subtaskCountKey,
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _open = !_open);
      },
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: const EdgeInsets.fromLTRB(7, 2, 4, 2),
          decoration: BoxDecoration(
            color: ink.withValues(alpha: _open ? 0.16 : 0.09),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.checklist_rounded, size: 14, color: ink),
              const SizedBox(width: 4),
              Text(
                '${widget.task.subtasksDone}/${steps.length}',
                style: TextStyle(
                  color: ink,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 1),
              AnimatedRotation(
                turns: _open ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(Icons.expand_more, size: 16, color: ink),
              ),
            ],
          ),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.head(tick, count),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !_open
              ? const SizedBox(width: double.infinity)
              : Padding(
                  // Lined up with the title: past the tick and its gap.
                  padding: const EdgeInsets.only(left: 24 + 14, top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < steps.length; i++)
                        _Step(
                          step: steps[i],
                          color: widget.color,
                          onTap: () => _toggle(i),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// One line of a checklist opened in its card: a small tick in the task's
/// colour, the way the card's own tick is, and the step.
class _Step extends StatelessWidget {
  final Subtask step;
  final Color color;
  final VoidCallback onTap;

  const _Step({required this.step, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 17,
              height: 17,
              margin: const EdgeInsets.only(top: 1),
              decoration: BoxDecoration(
                color: step.done ? color : Colors.transparent,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: TaskCard.rimOf(color), width: 1.5),
              ),
              child: CustomPaint(
                painter: CheckMark(progress: step.done ? 1 : 0),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                step.title,
                style: TextStyle(
                  color: step.done ? p.faint : p.text,
                  fontSize: 14,
                  decoration: step.done ? TextDecoration.lineThrough : null,
                  decorationColor: p.faint,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The checklist count on a card, which opens and closes its list.
const subtaskCountKey = Key('subtask-count');

/// How long a card takes to settle into its new state once it is ticked —
/// long enough to be seen as something happening, short enough that the run
/// it sits in is not left waiting on it. The list holds its reordering for
/// the same stretch, so the card is still under the finger that ticked it
/// while the tick is being drawn (`TaskProvider.toggleDone`).
const _settle = Duration(milliseconds: 240);

/// How long a ticked card takes to fade and close up the gap it leaves.
/// Matched to `TaskProvider.leave`, which waits that long before the run is
/// read back.
const _leave = Duration(milliseconds: 280);

/// The tappable tick on a card.
///
/// Ticking something off is the one gesture in this app worth watching
/// happen, so the mark is drawn rather than switched on: the square fills
/// and the stroke runs through it, over [_settle]. It used to appear whole
/// between two frames, which — with the card leaving for the done end of
/// the run in the same instant — meant the gesture had no moment at all.
///
/// Coming off, it goes in half the time and without the drawing: undoing is
/// a correction, and a correction should not be a flourish.
/// Says a task has been put in progress on the board, where every other
/// screen would otherwise show it as one more open task. Jira's status
/// lozenge, in Jira's blue for it: small capitals on a tint of their own
/// colour, so it reads as a status rather than as the task's colour.
/// A card's word that the task is handed to Claude, and to which model.
class ClaudeMark extends StatelessWidget {
  final String model;
  final Color color;

  const ClaudeMark({super.key, required this.model, required this.color});

  @override
  Widget build(BuildContext context) => Row(
    key: claudeMarkKey,
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.auto_awesome, size: 13, color: color),
      const SizedBox(width: 3),
      Text(
        ClaudeModels.name(model),
        maxLines: 1,
        style: TextStyle(color: color, fontSize: 12.5),
      ),
    ],
  );
}

const claudeMarkKey = Key('claude-mark');

class InProgressBadge extends StatelessWidget {
  static const color = Color(0xFF579DFF);

  const InProgressBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        S.of(context).inProgress.toUpperCase(),
        maxLines: 1,
        style: const TextStyle(
          color: color,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          height: 1.3,
        ),
      ),
    );
  }
}

class _Tick extends StatefulWidget {
  final bool done;
  final Color color;

  /// Goes up by one each time a tap on the tick was held back, and the tick
  /// shakes its head once for each.
  final int shakes;
  final VoidCallback onTap;

  const _Tick({
    required this.done,
    required this.color,
    this.shakes = 0,
    required this.onTap,
  });

  @override
  State<_Tick> createState() => _TickState();
}

class _TickState extends State<_Tick> with TickerProviderStateMixin {
  late final AnimationController _draw = AnimationController(
    vsync: this,
    duration: _settle,
    reverseDuration: const Duration(milliseconds: 110),
    value: widget.done ? 1 : 0,
  );

  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  @override
  void didUpdateWidget(_Tick old) {
    super.didUpdateWidget(old);
    if (widget.done != old.done) {
      widget.done ? _draw.forward() : _draw.reverse();
    }
    if (widget.shakes != old.shakes) {
      HapticFeedback.mediumImpact();
      _shake.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _draw.dispose();
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: taskCardTickKey,
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      behavior: HitTestBehavior.opaque,
      // Under a mouse the pointer says the square is a thing to press, as
      // it does over the card around it.
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedBuilder(
          animation: Listenable.merge([_draw, _shake]),
          builder: (context, _) {
            // Three swings either way, dying out: a no, not a wobble.
            final t = _shake.value;
            final dx = 3.5 * math.sin(t * 6 * math.pi) * (1 - t);
            // The square fills first and the stroke follows it in, so the two
            // read as one movement rather than a fill with a mark dropped on
            // top of it.
            final fill = Curves.easeOut.transform(_draw.value);
            final mark = Curves.easeOutCubic.transform(
              ((_draw.value - 0.25) / 0.75).clamp(0.0, 1.0),
            );
            return Transform.translate(
              offset: Offset(dx, 0),
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: fill),
                  borderRadius: BorderRadius.circular(7),
                  // Outlined as the card is rimmed, so the square reads as
                  // drawn with the same pen as the card's edge rather than
                  // a brighter frame set on it.
                  border: Border.all(
                    color: TaskCard.rimOf(widget.color),
                    width: 1.5,
                  ),
                ),
                child: CustomPaint(
                  key: taskCardMarkKey,
                  painter: CheckMark(progress: mark),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The tick's stroke, drawn as far as [progress].
///
/// Public, and holding the progress where a test can read it, for the same
/// reason `dayChipColour` is: the thing worth pinning is that the mark is
/// drawn over a moment rather than switched on, and nothing about how it is
/// painted should have to be pinned with it.
class CheckMark extends CustomPainter {
  final double progress;
  final Color color;

  const CheckMark({required this.progress, this.color = Colors.white});

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.26, h * 0.52)
      ..lineTo(w * 0.44, h * 0.70)
      ..lineTo(w * 0.76, h * 0.32);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (progress >= 1) {
      canvas.drawPath(path, paint);
      return;
    }
    // Drawn to the same fraction of the whole stroke rather than of each
    // leg, so the short leg does not take as long as the long one.
    final total = [
      for (final metric in path.computeMetrics()) metric.length,
    ].fold<double>(0, (a, b) => a + b);
    var left = total * progress;
    final drawn = Path();
    for (final metric in path.computeMetrics()) {
      if (left <= 0) break;
      drawn.addPath(
        metric.extractPath(0, left.clamp(0, metric.length)),
        Offset.zero,
      );
      left -= metric.length;
    }
    canvas.drawPath(drawn, paint);
  }

  @override
  bool shouldRepaint(CheckMark old) =>
      old.progress != progress || old.color != color;
}

/// Identifies the tick circle on a task card, and the mark inside it.
const taskCardTickKey = Key('task-card-tick');
const taskCardMarkKey = Key('task-card-mark');

/// A public holiday beside a day's tasks: the same card as a [TaskCard], with
/// a green mark where the tick would be and nothing to tick off. One of the
/// user's special days is the same card again in its own colour and with
/// its own mark, and a tap opens it to be changed.
class HolidayCard extends StatelessWidget {
  final Holiday holiday;

  /// On one line, as [TaskCard.dense] is.
  final bool dense;

  const HolidayCard({super.key, required this.holiday, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final special = holiday.special;
    final color = holiday.color;
    final line = special == null
        ? s.publicHoliday
        : s.specialLine(special.kind, special.yearsIn(holiday.date.year));
    final body = Padding(
      padding: dense ? TaskCard._insideDense : TaskCard._inside,
      child: Row(
        children: [
          Icon(
            special?.icon ?? Icons.celebration_outlined,
            color: color,
            size: dense ? 20 : 22,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: dense
                // The mark says what it is; the words saying so are left to
                // the full card.
                ? Text(
                    holiday.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        holiday.name,
                        style: TextStyle(
                          color: p.text,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        line,
                        style: TextStyle(color: p.muted, fontSize: 12.5),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
    return Padding(
      padding: TaskCard.margin,
      child: Container(
        foregroundDecoration: TaskCard.rimDecoration(color),
        child: special == null
            ? DecoratedBox(decoration: TaskCard.paneOf(color), child: body)
            : Material(
                type: MaterialType.transparency,
                child: Ink(
                  decoration: TaskCard.paneOf(color),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(TaskCard.radius),
                    onTap: () => showSpecialDaySheet(context, day: special),
                    child: body,
                  ),
                ),
              ),
      ),
    );
  }
}

/// An event from the phone's own calendars beside a day's tasks: the same
/// card again, inked in the event's colour, with a calendar where the tick
/// would be. Nothing on it can be ticked or dragged — it belongs to the
/// calendar app, which a tap opens it in.
class EventCard extends StatelessWidget {
  final CalendarEvent event;

  /// The day it is shown on, which an event of several days needs to say
  /// which of them this is.
  final DateTime day;

  /// On one line, as [TaskCard.dense] is.
  final bool dense;

  const EventCard({
    super.key,
    required this.event,
    required this.day,
    this.dense = false,
  });

  String _when(S s, bool h24) {
    if (event.allDay) return s.allDay;
    final starts = dayOf(event.start) == day;
    final ends = dayOf(event.end) == day;
    final from = Dates.time(event.start, h24: h24);
    final to = Dates.time(event.end, h24: h24);
    if (starts && ends) return '$from – $to';
    if (starts) return s.eventFrom(from);
    if (ends) return s.eventUntil(to);
    return s.allDay;
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final when = _when(
      S.of(context),
      MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return Padding(
      padding: TaskCard.margin,
      child: Container(
        foregroundDecoration: TaskCard.rimDecoration(event.color),
        child: Material(
          type: MaterialType.transparency,
          child: Ink(
            decoration: TaskCard.paneOf(event.color),
            child: InkWell(
              borderRadius: BorderRadius.circular(TaskCard.radius),
              onTap: () => DeviceCalendars.open(event),
              child: Padding(
                padding: dense ? TaskCard._insideDense : TaskCard._inside,
                child: Row(
                  children: [
                    Icon(
                      Icons.event_outlined,
                      color: event.color,
                      size: dense ? 20 : 22,
                    ),
                    const SizedBox(width: 14),
                    if (dense) ...[
                      Expanded(
                        child: Text(
                          event.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: p.text,
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        when,
                        maxLines: 1,
                        style: TextStyle(color: p.muted, fontSize: 12.5),
                      ),
                    ] else
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              event.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: p.text,
                                fontSize: 15.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              event.calendarName.isEmpty
                                  ? when
                                  : '$when · ${event.calendarName}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: p.muted, fontSize: 12.5),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The read-only cards a day carries above its tasks: its holidays, then
/// the events from the phone's calendars.
List<Widget> fixedCards(
  DateTime day,
  List<Holiday> holidays,
  List<CalendarEvent> events, {
  bool dense = false,
}) => [
  for (final holiday in holidays) HolidayCard(holiday: holiday, dense: dense),
  for (final event in events) EventCard(event: event, day: day, dense: dense),
];

/// The pane a card is drawn on: its ink, the grain over it and, picked out,
/// a glow round it. A decoration of its own rather than a [BoxDecoration]
/// with the grain as its image: that clips each card to its corners and
/// tiles the grain into it a draw at a time, which every card on show paid
/// for again on every frame of a scroll. Here the grain is a shader the
/// pane's own shape is filled with, one draw and no clip.
class CardPane extends Decoration {
  /// The fill, the task's colour at its ink.
  final Color ink;

  /// The grain's alpha ([TaskCard.frostOf]); 0 lays none.
  final double frost;

  /// The glow round a picked-out card; transparent for none.
  final Color glow;

  const CardPane({
    required this.ink,
    required this.frost,
    this.glow = Colors.transparent,
  });

  static CardPane lerp(CardPane a, CardPane b, double t) => CardPane(
    ink: Color.lerp(a.ink, b.ink, t)!,
    frost: ui.lerpDouble(a.frost, b.frost, t)!,
    glow: Color.lerp(a.glow, b.glow, t)!,
  );

  @override
  Decoration? lerpFrom(Decoration? a, double t) =>
      a is CardPane ? lerp(a, this, t) : super.lerpFrom(a, t);

  @override
  Decoration? lerpTo(Decoration? b, double t) =>
      b is CardPane ? lerp(this, b, t) : super.lerpTo(b, t);

  RRect _shape(Rect rect) =>
      RRect.fromRectAndRadius(rect, const Radius.circular(TaskCard.radius));

  @override
  bool hitTest(Size size, Offset position, {TextDirection? textDirection}) =>
      _shape(Offset.zero & size).contains(position);

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _CardPanePainter(this, onChanged);

  @override
  bool operator ==(Object other) =>
      other is CardPane &&
      other.ink == ink &&
      other.frost == frost &&
      other.glow == glow;

  @override
  int get hashCode => Object.hash(ink, frost, glow);
}

class _CardPanePainter extends BoxPainter {
  final CardPane pane;

  _CardPanePainter(this.pane, super.onChanged);

  /// As a [BoxShadow] of blur radius 14 would have it.
  static final _glowSigma = Shadow.convertRadiusToSigma(14);

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final rect = offset & configuration.size!;
    final shape = pane._shape(rect);
    if (pane.glow.a > 0) {
      canvas.drawRRect(
        shape,
        Paint()
          ..color = pane.glow
          ..maskFilter = MaskFilter.blur(BlurStyle.outer, _glowSigma),
      );
    }
    canvas.drawRRect(shape, Paint()..color = pane.ink);
    if (pane.frost <= 0) return;
    final grain = _Grain.image;
    if (grain == null) {
      _Grain.wait(onChanged);
      return;
    }
    // One of the grain's pixels to each of the screen's, from the card's
    // corner, and unfiltered, so it stays as fine and sharp as it was
    // picked: scaled, the smoothing blurred it.
    final s = 1 / (configuration.devicePixelRatio ?? 1);
    final place = Float64List.fromList([
      s, 0, 0, 0, //
      0, s, 0, 0,
      0, 0, 1, 0,
      rect.left, rect.top, 0, 1,
    ]);
    canvas.drawRRect(
      shape,
      Paint()
        // With a shader, the colour gives only its alpha.
        ..color = Color.fromRGBO(255, 255, 255, pane.frost)
        ..shader = ImageShader(
          grain,
          TileMode.repeated,
          TileMode.repeated,
          place,
          filterQuality: FilterQuality.none,
        ),
    );
  }

  @override
  void dispose() {
    _Grain.forget(onChanged);
    super.dispose();
  }
}

/// [TaskCard.grain], decoded once for every card. A pane painted before it
/// is ready lays no grain and is painted again once it is.
abstract final class _Grain {
  static ui.Image? image;
  static ImageStream? _stream;
  static final _waiting = <VoidCallback>{};

  static void wait(VoidCallback? then) {
    if (then != null) _waiting.add(then);
    if (_stream != null) return;
    // Listened to for good, so the image is never let go of.
    _stream = TaskCard.grain.resolve(ImageConfiguration.empty)
      ..addListener(
        ImageStreamListener((info, _) {
          image = info.image;
          final waiting = [..._waiting];
          _waiting.clear();
          for (final then in waiting) {
            then();
          }
        }),
      );
  }

  static void forget(VoidCallback? then) => _waiting.remove(then);
}

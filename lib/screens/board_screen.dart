import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/database.dart';
import '../l10n/strings.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/groups.dart';
import '../widgets/screen_header.dart';
import '../widgets/task_card.dart' show TaskCard;
import 'task_edit_screen.dart';

/// Every task in one of three columns — not started, in progress, done — and
/// moved between them by carrying its card across.
///
/// A screen of its own rather than a way of drawing Schedule or the
/// calendar: those are about when, and this is about how far along. It reads
/// the tasks only while it is the screen on show, as Done does.
class BoardScreen extends StatefulWidget {
  /// Opens the shell's menu.
  final VoidCallback? onMenu;

  /// Whether this is the screen on show; null when shown on its own.
  final ValueListenable<bool>? shown;

  const BoardScreen({super.key, this.onMenu, this.shown});

  @override
  State<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends State<BoardScreen> {
  List<Task> _all = const [];
  late final TaskProvider _tasks = context.read<TaskProvider>();

  bool _listening = false;

  /// The lanes, a page each with the next one showing at the side.
  final _pages = PageController(viewportFraction: _Board.laneFraction);

  /// Whether a card is being carried, and the lane it was picked up from,
  /// which the drop bar keeps drawing while it goes away.
  bool _carrying = false;
  Stage _from = Stage.notStarted;

  /// Where the card being carried was held. One for the board, since one
  /// card is carried at a time and picking it up rebuilds its lane, which
  /// would otherwise hand the drag a different one from the card's.
  final _grab = _Grab();

  @override
  void initState() {
    super.initState();
    widget.shown?.addListener(_follow);
    _follow();
  }

  @override
  void dispose() {
    widget.shown?.removeListener(_follow);
    if (_listening) _tasks.removeListener(_load);
    _pages.dispose();
    _grab.finger.dispose();
    super.dispose();
  }

  /// Reads the tasks as the screen comes on show, and again on every change
  /// while it is there.
  void _follow() {
    final shown = widget.shown?.value ?? true;
    if (shown == _listening) return;
    _listening = shown;
    if (shown) {
      _tasks.addListener(_load);
      _load();
    } else {
      _tasks.removeListener(_load);
    }
  }

  Future<void> _load() async {
    final all = await AppDatabase.instance.getBoard();
    if (mounted) setState(() => _all = all);
  }

  /// Puts the card in its new column at once and writes it after. Waiting
  /// for the write, the card let go of went back to the column it came from
  /// for as long as the read took, and then jumped.
  void _move(Task task, Stage stage) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final moved = task.toStage(stage, now);
    setState(() {
      _all = [for (final t in _all) t.id == task.id ? moved : t];
    });
    _tasks.moveToStage(task, stage);
  }

  void _lift(Task task) => setState(() {
    _carrying = true;
    _from = task.stage;
  });

  void _putDown() => setState(() => _carrying = false);

  Future<void> _open([Task? task]) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => TaskEditScreen(task: task)));
  }

  /// Not started by when each is due, soonest first and undated last; the
  /// other two latest first, so a card just carried over is at the top of
  /// the column it was put in.
  static Map<Stage, List<Task>> _columns(List<Task> tasks) {
    final columns = {for (final stage in Stage.values) stage: <Task>[]};
    for (final task in tasks) {
      columns[task.stage]!.add(task);
    }
    columns[Stage.notStarted]!.sort((a, b) {
      if ((a.dueAt == null) != (b.dueAt == null)) {
        return a.dueAt == null ? 1 : -1;
      }
      final byDue = (a.dueAt ?? 0).compareTo(b.dueAt ?? 0);
      return byDue != 0 ? byDue : b.createdAt.compareTo(a.createdAt);
    });
    columns[Stage.inProgress]!.sort(
      (a, b) => (b.startedAt ?? 0).compareTo(a.startedAt ?? 0),
    );
    columns[Stage.done]!.sort(
      (a, b) => (b.completedAt ?? 0).compareTo(a.completedAt ?? 0),
    );
    return columns;
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final group = context.select<TaskProvider, int?>((t) => t.group);
    context.select<TaskProvider, List<TaskList>>((t) => t.lists);
    final shown = group == null
        ? _all
        : [
            for (final t in _all)
              if (t.listId == group) t,
          ];
    final columns = _columns(shown);

    return Scaffold(
      body: Column(
        children: [
          ScreenHeader(
            title: s.board,
            onMenu: widget.onMenu,
            actions: [
              IconButton(
                icon: Icon(Icons.add, color: p.muted),
                tooltip: s.newTask,
                onPressed: _open,
              ),
              const SizedBox(width: 6),
            ],
          ),
          // The same choice of group as Schedule and the calendar make.
          const SizedBox(width: double.infinity, child: GroupChips()),
          const SizedBox(height: 14),
          // Wide enough lanes for a card to be a Jira card, so a page each,
          // with the next lane at the side to say there is one and to be
          // carried onto. Three at once left a column a third of a phone
          // wide and a title a word a line.
          Expanded(
            child: Stack(
              children: [
                PageView(
                  controller: _pages,
                  padEnds: false,
                  children: [
                    for (final stage in Stage.values)
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          _Board.gap,
                          0,
                          stage == Stage.values.last ? _Board.gap : 0,
                          _Board.gap,
                        ),
                        child: _Column(
                          stage: stage,
                          tasks: columns[stage]!,
                          onTap: _open,
                          onDrop: (task) => _move(task, stage),
                          grab: _grab,
                          onLift: _lift,
                          onPutDown: _putDown,
                        ),
                      ),
                  ],
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _DropBar(shown: _carrying, from: _from, onDrop: _move),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One column, as a Jira board draws one: a grey lane with its name in
/// small capitals and how many are in it, over cards that scroll on their
/// own. A card carried over it rings it, as long as it would be a move.
class _Column extends StatelessWidget {
  final Stage stage;
  final List<Task> tasks;
  final ValueChanged<Task> onTap;
  final ValueChanged<Task> onDrop;

  /// Where the card being carried was held, the board's.
  final _Grab grab;

  /// A card in this lane has been picked up.
  final ValueChanged<Task> onLift;

  /// The card has been let go, wherever it was.
  final VoidCallback onPutDown;

  const _Column({
    required this.stage,
    required this.tasks,
    required this.onTap,
    required this.onDrop,
    required this.grab,
    required this.onLift,
    required this.onPutDown,
  });

  static String nameOf(S s, Stage stage) => switch (stage) {
    Stage.notStarted => s.notStarted,
    Stage.inProgress => s.inProgress,
    Stage.done => s.done,
  };

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final provider = context.read<TaskProvider>();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final header = TextStyle(
      color: p.muted,
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
      height: 1.25,
    );
    return DragTarget<Task>(
      onWillAcceptWithDetails: (d) => d.data.stage != stage,
      onAcceptWithDetails: (d) => onDrop(d.data),
      builder: (context, over, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: dark ? p.panel : p.sidebar,
          borderRadius: BorderRadius.circular(_Board.laneRadius),
          // Always there and only coloured in, so the ring coming and going
          // does not move the cards inside it.
          border: Border.all(
            color: over.isNotEmpty ? p.muted : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: LayoutBuilder(
          builder: (context, box) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The name stands over the titles, in line with them.
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  _Board.inset + BoardCard.padding,
                  16,
                  _Board.inset + BoardCard.padding,
                  14,
                ),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: nameOf(s, stage).toUpperCase()),
                      TextSpan(text: '   ${tasks.length}'),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: header,
                ),
              ),
              Expanded(
                child: _FadeFoot(
                  child: ListView.builder(
                    // Room to scroll the last card clear of the fade.
                    padding: const EdgeInsets.fromLTRB(
                      _Board.inset,
                      0,
                      _Board.inset,
                      28,
                    ),
                    itemCount: tasks.length,
                    itemBuilder: (context, i) {
                      final task = tasks[i];
                      final card = BoardCard(
                        task: task,
                        list: provider.listById(task.listId),
                        onTap: () => onTap(task),
                      );
                      return LongPressDraggable<Task>(
                        key: ValueKey(task.id),
                        data: task,
                        hapticFeedbackOnStart: true,
                        dragAnchorStrategy: grab.anchor,
                        onDragStarted: () => onLift(task),
                        onDragUpdate: (d) =>
                            grab.finger.value = d.globalPosition.dx,
                        onDragEnd: (_) => onPutDown(),
                        feedback: _Lifted(
                          width: box.maxWidth - 2 * _Board.inset,
                          grab: grab,
                          child: card,
                        ),
                        childWhenDragging: Opacity(opacity: 0.3, child: card),
                        child: card,
                      );
                    },
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

/// The board's measures.
abstract final class _Board {
  /// How much of the screen's width a lane takes; the rest shows the next.
  static const laneFraction = 0.84;

  /// Between the lanes, and round the board.
  static const gap = 10.0;

  /// From a lane's sides to its cards.
  static const inset = 6.0;

  /// Squarer than the rest of the app's corners, as Jira's are.
  static const laneRadius = 8.0;

  /// A carried card's size against the card it was, and how far above the
  /// finger it rides.
  static const carriedScale = 0.6;
  static const carriedLift = 18.0;

  /// The drop bar's targets.
  static const dropHeight = 60.0;
}

/// Fades a column's foot out rather than letting the last card be cut off
/// square by the edge, as everything that runs under the add field does
/// elsewhere. A mask rather than the ground painted over the cards, since
/// the lane's ground is not the screen's.
class _FadeFoot extends StatelessWidget {
  final Widget child;

  const _FadeFoot({required this.child});

  static const _height = 32.0;

  // The smoothstep `GroundFade` follows, for the reason it does: a straight
  // ramp shows a line at each end of it.
  static const _stops = [0.0, 0.2, 0.4, 0.5, 0.6, 0.8, 1.0];
  static const _alphas = [0.0, 0.104, 0.352, 0.5, 0.648, 0.896, 1.0];

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final from = (1 - _height / bounds.height).clamp(0.0, 1.0);
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0, for (final f in _stops) from + f * (1 - from)],
          colors: [
            Colors.white,
            for (final a in _alphas) Colors.white.withValues(alpha: 1 - a),
          ],
        ).createShader(bounds);
      },
      child: child,
    );
  }
}

/// Where a card was taken hold of, and how big it was, for the card that
/// is carried to shrink about. Filled in by the drag's anchor, which runs
/// before the carried card is first built.
class _Grab {
  Offset at = Offset.zero;
  Size size = Size.zero;

  /// Where the finger is on the screen, so the card can be kept on it.
  final finger = ValueNotifier<double>(0);

  Offset anchor(Draggable<Object> draggable, BuildContext context, Offset p) {
    final box = context.findRenderObject()! as RenderBox;
    size = box.size;
    finger.value = p.dx;
    return at = box.globalToLocal(p);
  }
}

/// A card as it is carried: it draws in from where it lay to a tile a little
/// over half its size, riding just above the finger. Carried at full size it
/// was as wide as a lane and covered the strip of the next one it was being
/// carried onto, and the finger covered the rest. Shadowed, so it is above
/// the board rather than in it, and held square — tipped a degree or two,
/// as Jira's are, it was asked to stop looking crooked.
class _Lifted extends StatefulWidget {
  final double width;
  final _Grab grab;
  final Widget child;

  const _Lifted({required this.width, required this.grab, required this.child});

  @override
  State<_Lifted> createState() => _LiftedState();
}

class _LiftedState extends State<_Lifted> with SingleTickerProviderStateMixin {
  late final _shrink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..forward();

  @override
  void dispose() {
    _shrink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final grab = widget.grab;
    final from = Offset.zero & grab.size;
    const s = _Board.carriedScale;
    final to = Rect.fromLTWH(
      grab.at.dx - grab.size.width * s / 2,
      grab.at.dy - _Board.carriedLift - grab.size.height * s,
      grab.size.width * s,
      grab.size.height * s,
    );
    final card = SizedBox(
      width: widget.width,
      child: Material(
        type: MaterialType.transparency,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(BoardCard.radius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: widget.child,
        ),
      ),
    );
    final screen = MediaQuery.sizeOf(context).width;
    return AnimatedBuilder(
      animation: Listenable.merge([_shrink, grab.finger]),
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_shrink.value);
        var r = Rect.lerp(from, to, t)!;
        // Kept on the screen at the sides, rather than centred on a finger
        // near the edge and half off it.
        final left = grab.finger.value - grab.at.dx + r.left;
        final kept = left.clamp(
          _Board.gap,
          math.max(_Board.gap, screen - _Board.gap - r.width),
        );
        r = r.translate(kept - left, 0);
        final scale = grab.size.width == 0 ? 1.0 : r.width / grab.size.width;
        return Transform(
          transform: Matrix4.translationValues(r.left, r.top, 0)
            ..scaleByDouble(scale, scale, 1, 1),
          child: child,
        );
      },
      child: card,
    );
  }
}

/// While a card is carried, a target for each lane along the foot of the
/// board, so a card can go to any lane from any other without the lane
/// being on screen. The strip of the next lane at the side was the only
/// place to drop a card, which made the lane before it out of reach but by
/// holding the card at the edge until the board turned under the finger.
/// The lane it came from is drawn faintly and takes nothing.
class _DropBar extends StatelessWidget {
  final bool shown;
  final Stage from;
  final void Function(Task task, Stage stage) onDrop;

  const _DropBar({
    required this.shown,
    required this.from,
    required this.onDrop,
  });

  static const _fade = 28.0;

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final ground = Theme.of(context).scaffoldBackgroundColor;
    return IgnorePointer(
      ignoring: !shown,
      child: AnimatedSlide(
        offset: shown ? Offset.zero : const Offset(0, 0.4),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: shown ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          child: DecoratedBox(
            // The lanes run on under it, so it stands on the screen's own
            // ground, faded in above, rather than on top of the cards.
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0, 0.3],
                colors: [ground.withValues(alpha: 0), ground],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                _Board.gap,
                _fade,
                _Board.gap,
                _Board.gap,
              ),
              child: Row(
                children: [
                  for (final stage in Stage.values) ...[
                    if (stage != Stage.values.first) const SizedBox(width: 8),
                    Expanded(
                      child: DragTarget<Task>(
                        onWillAcceptWithDetails: (d) => d.data.stage != stage,
                        onAcceptWithDetails: (d) => onDrop(d.data, stage),
                        builder: (context, over, _) {
                          final here = stage == from;
                          final lit = over.isNotEmpty;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 140),
                            curve: Curves.easeOut,
                            height: _Board.dropHeight,
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              color: here
                                  ? p.panel
                                  : lit
                                  ? p.field
                                  : p.panelHi,
                              borderRadius: BorderRadius.circular(
                                _Board.laneRadius,
                              ),
                              // Always there and only coloured in, as the
                              // lanes' is, so the label does not shift.
                              border: Border.all(
                                color: lit ? p.text : Colors.transparent,
                                width: 1.5,
                              ),
                            ),
                            child: Text(
                              _Column.nameOf(s, stage).toUpperCase(),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: here
                                    ? p.faint
                                    : lit
                                    ? p.text
                                    : p.muted,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                                height: 1.25,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A task on the board, drawn as a Jira card: a flat card a step lighter
/// than its lane with the title across the top; under it the group as
/// Jira labels an epic, a lozenge in its colour, and when it is due; and
/// along the foot the issue type's square in the task's colour, the key,
/// and the marks — repeat, checklist, priority as Jira's chevrons.
///
/// Neutral rather than inked like the cards elsewhere: three columns of
/// tinted cards in three tinted lanes were a wash of colour, and the square
/// says which colour the task is. A done card looks like any other but for
/// its key, struck through as Jira strikes a resolved issue's.
class BoardCard extends StatelessWidget {
  static const margin = EdgeInsets.only(bottom: 8);
  static const radius = 6.0;
  static const padding = 14.0;

  final Task task;
  final TaskList? list;
  final VoidCallback onTap;

  const BoardCard({
    super.key,
    required this.task,
    this.list,
    required this.onTap,
  });

  /// "Today", "Sep 23", with the time after it if it has one.
  String? _when(bool h24) {
    final due = task.due;
    if (due == null) return null;
    final day = Dates.dayWord(due) ?? Dates.shortDay(due);
    return task.hasTime ? '$day ${Dates.time(due, h24: h24)}' : day;
  }

  /// Jira's issue key: the project's first letters and the issue's number.
  /// Here the group stands for the project, so "PER-12" is in Personal.
  static String keyOf(String group, int? id) {
    final letters = RegExp(
      r'\p{L}',
      unicode: true,
    ).allMatches(group).map((m) => m[0]!).take(3).join().toUpperCase();
    return '${letters.isEmpty ? 'T' : letters}-${id ?? 0}';
  }

  /// Jira's: up for high, two bars for medium, down for low.
  static IconData _priorityIcon(Priority priority) => switch (priority) {
    Priority.high => Icons.keyboard_double_arrow_up_rounded,
    Priority.medium => Icons.drag_handle_rounded,
    _ => Icons.keyboard_double_arrow_down_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = colorOfTask(
      task,
      list,
      fallback: AppTheme.accentOf(context).color,
    );
    final group = list == null ? null : groupLabel(context, list!);
    final when = _when(MediaQuery.alwaysUse24HourFormatOf(context));
    final meta = TextStyle(
      color: p.muted,
      fontSize: 12.5,
      fontWeight: FontWeight.w500,
    );
    final chip = dark ? p.field : p.border;

    // The group's lozenge and the due date: Jira's labels row.
    final labels = <Widget>[
      if (group != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: list!.style.color,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            group.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              height: 1.3,
            ),
          ),
        ),
      if (when != null)
        _Due(when: when, overdue: task.isOverdue && !task.done, ground: chip),
    ];

    final foot = <Widget>[
      _TypeSquare(color: color, done: task.done),
      const SizedBox(width: 7),
      Text(
        keyOf(group ?? '', task.id),
        style: meta.copyWith(
          decoration: task.done ? TextDecoration.lineThrough : null,
          decorationColor: p.muted,
        ),
      ),
      const Spacer(),
      if (task.repeat != Repeat.none) ...[
        Icon(Icons.repeat_rounded, size: 16, color: p.muted),
        const SizedBox(width: 10),
      ],
      if (task.subtasks.isNotEmpty) ...[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
          decoration: BoxDecoration(
            color: chip,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '${task.subtasksDone}/${task.subtasks.length}',
            style: meta.copyWith(fontSize: 12),
          ),
        ),
        const SizedBox(width: 10),
      ],
      if (task.priority != Priority.none)
        Icon(
          _priorityIcon(task.priority),
          size: 20,
          color: TaskCard.priorityColor(task.priority),
        ),
    ];

    return Padding(
      padding: margin,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          child: Ink(
            padding: const EdgeInsets.fromLTRB(padding, 13, padding, 13),
            decoration: BoxDecoration(
              color: dark ? p.panelHi : p.panel,
              borderRadius: BorderRadius.circular(radius),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.6 : 0.14),
                  blurRadius: 2,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.title,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.text, fontSize: 15.5, height: 1.35),
                ),
                if (labels.isNotEmpty) ...[
                  const SizedBox(height: 9),
                  Wrap(spacing: 6, runSpacing: 6, children: labels),
                ],
                const SizedBox(height: 11),
                SizedBox(height: 20, child: Row(children: foot)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Where Jira puts the issue type: a square in the task's colour with a
/// smaller one drawn in it, and a tick in its place once the task is done.
class _TypeSquare extends StatelessWidget {
  final Color color;
  final bool done;

  const _TypeSquare({required this.color, required this.done});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 17,
      height: 17,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
      child: done
          ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
          : Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 1.6),
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
    );
  }
}

/// When a task is due, as Jira writes a due date on a card: a calendar and
/// the date on a grey lozenge, red once it has gone by.
class _Due extends StatelessWidget {
  final String when;
  final bool overdue;
  final Color ground;

  const _Due({required this.when, required this.overdue, required this.ground});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final ink = overdue ? AppColors.overdue : p.muted;
    return Container(
      padding: const EdgeInsets.fromLTRB(5, 2, 6, 2),
      decoration: BoxDecoration(
        color: overdue ? AppColors.overdue.withValues(alpha: 0.16) : ground,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.calendar_today_rounded, size: 11, color: ink),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              when,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.fade,
              style: TextStyle(
                color: ink,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

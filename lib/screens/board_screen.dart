import 'dart:async';

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

  /// The lanes, side by side, snapped so the one on show has the lanes
  /// either side of it showing (`_LaneSnap`).
  final _lanes = ScrollController();

  /// Whether a card is being carried.
  bool _carrying = false;

  /// Where the finger carrying a card is across the screen. The board's,
  /// since one card is carried at a time and picking it up rebuilds its
  /// lane.
  final _finger = ValueNotifier<double>(0);

  /// While a card is carried: which side of the screen it is at, and the
  /// timer that turns the board on again while it stays there.
  int _side = 0;
  Timer? _turning;

  @override
  void initState() {
    super.initState();
    _finger.addListener(_watchEdges);
    widget.shown?.addListener(_follow);
    _follow();
  }

  @override
  void dispose() {
    widget.shown?.removeListener(_follow);
    if (_listening) _tasks.removeListener(_load);
    _lanes.dispose();
    _turning?.cancel();
    _finger.dispose();
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

  void _lift(Task task) => _carrying = true;

  void _putDown() {
    _turning?.cancel();
    _side = 0;
    _carrying = false;
  }

  /// Turns the board towards the side a carried card is taken to, the
  /// moment it gets there, and on again every so often while it stays.
  /// It used to wait half a second first, which made reaching the next lane
  /// a matter of holding still at the edge, and the edge was the last 28
  /// points of the screen; the next lane is wanted on show sooner than that.
  void _watchEdges() {
    if (!_carrying) return;
    final x = _finger.value;
    final width = MediaQuery.sizeOf(context).width;
    final edge = width * _Board.edge;
    final side = x < edge
        ? -1
        : x > width - edge
        ? 1
        : 0;
    if (side == _side) return;
    _side = side;
    _turning?.cancel();
    if (side != 0) _turn();
  }

  void _turn() {
    if (_lanes.hasClients) {
      final at = _lanes.position;
      final stops = _LaneSnap.stops(at);
      final page = _LaneSnap.nearest(at, stops) + _side;
      if (page >= 0 && page < stops.length) {
        _lanes.animateTo(
          stops[page],
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    }
    _turning = Timer(_Board.nextTurn, _turn);
  }

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
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                key: boardLanesKey,
                controller: _lanes,
                scrollDirection: Axis.horizontal,
                physics: const _LaneSnap(),
                // A row rather than a list, so every lane stays built:
                // a lane thrown away while a card carried out of it is
                // still in the air takes the drag's callbacks with it,
                // and the board could neither turn back nor hear the
                // card let go.
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final stage in Stage.values)
                      Container(
                        width: box.maxWidth * _Board.laneFraction,
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
                          finger: _finger,
                          onLift: _lift,
                          onPutDown: _putDown,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The board's lanes, for tests to swipe.
const boardLanesKey = Key('boardLanes');

/// Snaps the lanes to where each is on show: the first against the left
/// edge, the last against the right, and the one between them centred, so
/// both its neighbours show at the sides. Paged a lane's width at a time,
/// as a `PageView` pages, the middle lane sat against the left edge too,
/// and the lane before it was nowhere on the screen.
class _LaneSnap extends ScrollPhysics {
  const _LaneSnap({super.parent});

  @override
  _LaneSnap applyTo(ScrollPhysics? ancestor) =>
      _LaneSnap(parent: buildParent(ancestor));

  /// Where the board stands with each lane on show: that lane's middle at
  /// the screen's, as far as the ends allow.
  static List<double> stops(ScrollMetrics m) {
    final width = m.viewportDimension;
    final lane = width * _Board.laneFraction;
    return [
      for (var i = 0; i < Stage.values.length; i++)
        ((i + 0.5) * lane + _Board.gap / 2 - width / 2).clamp(
          m.minScrollExtent,
          m.maxScrollExtent,
        ),
    ];
  }

  static int nearest(ScrollMetrics m, List<double> stops) {
    var best = 0;
    for (var i = 1; i < stops.length; i++) {
      if ((stops[i] - m.pixels).abs() < (stops[best] - m.pixels).abs()) {
        best = i;
      }
    }
    return best;
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if ((velocity <= 0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    final all = stops(position);
    // A swipe goes on to the next lane its way, however short, as a page
    // view's does; let go at rest, the board settles on the nearest.
    final double target;
    if (velocity > tolerance.velocity) {
      target = all.firstWhere(
        (stop) => stop > position.pixels + tolerance.distance,
        orElse: () => all.last,
      );
    } else if (velocity < -tolerance.velocity) {
      target = all.lastWhere(
        (stop) => stop < position.pixels - tolerance.distance,
        orElse: () => all.first,
      );
    } else {
      target = all[nearest(position, all)];
    }
    if ((target - position.pixels).abs() < tolerance.distance) return null;
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: tolerance,
    );
  }

  @override
  bool get allowImplicitScrolling => false;
}

/// One column, as a Jira board draws one: a grey lane with its name in
/// small capitals and how many are in it, over cards that scroll on their
/// own. A card carried over it rings it, as long as it would be a move.
class _Column extends StatelessWidget {
  final Stage stage;
  final List<Task> tasks;
  final ValueChanged<Task> onTap;
  final ValueChanged<Task> onDrop;

  /// Where the card being carried is, across the screen; the board's.
  final ValueNotifier<double> finger;

  /// A card in this lane has been picked up.
  final ValueChanged<Task> onLift;

  /// The card has been let go, wherever it was.
  final VoidCallback onPutDown;

  const _Column({
    required this.stage,
    required this.tasks,
    required this.onTap,
    required this.onDrop,
    required this.finger,
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
                        // Quicker than the platform's long press, which made
                        // every move start with a wait; a finger that moves
                        // first is still a scroll.
                        delay: _Board.pickUp,
                        hapticFeedbackOnStart: true,
                        onDragStarted: () => onLift(task),
                        onDragUpdate: (d) => finger.value = d.globalPosition.dx,
                        onDragEnd: (_) => onPutDown(),
                        feedback: _Lifted(
                          width: box.maxWidth - 2 * _Board.inset,
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

  /// How near the side, as a share of the screen's width, a carried card
  /// turns the board — about as far in as the strip of the next lane — and
  /// how often it turns again while it is held there.
  static const edge = 0.18;
  static const nextTurn = Duration(milliseconds: 900);

  /// How long a card is held before it comes up to be carried.
  static const pickUp = Duration(milliseconds: 300);
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

/// A card as it is carried: where it was taken hold of, a little larger
/// and shadowed, so it is above the board rather than in it. Held square —
/// tipped a degree or two, as Jira's are, it was asked to stop looking
/// crooked. It rode above the finger for a while, shrunk and then at its
/// size, and was asked back under the finger both times.
class _Lifted extends StatelessWidget {
  final double width;
  final Widget child;

  const _Lifted({required this.width, required this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Transform.scale(
        scale: 1.03,
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
            child: child,
          ),
        ),
      ),
    );
  }
}

/// A task on the board, drawn as a Jira card: a flat card a step lighter
/// than its lane with the title across the top; under it the group as
/// Jira labels an epic, a lozenge in its colour, and when it is due; and
/// along the foot the issue type's square in the task's colour and the
/// marks — repeat, checklist, priority as Jira's chevrons.
///
/// Neutral rather than inked like the cards elsewhere: three columns of
/// tinted cards in three tinted lanes were a wash of colour, and the square
/// says which colour the task is. A done card looks like any other but for
/// the tick in its square.
class BoardCard extends StatelessWidget {
  static const margin = EdgeInsets.only(bottom: 8);
  static const radius = 6.0;
  static const padding = 14.0;

  /// Whether the card carries Jira's issue key beside its square. Hidden
  /// for now: nothing else in the app knows a task by it, and it was asked
  /// what it meant.
  static const showKey = false;

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
  /// Struck through once done, as Jira strikes a resolved issue's.
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
      if (showKey) ...[
        const SizedBox(width: 7),
        Text(
          keyOf(group ?? '', task.id),
          style: meta.copyWith(
            decoration: task.done ? TextDecoration.lineThrough : null,
            decorationColor: p.muted,
          ),
        ),
      ],
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

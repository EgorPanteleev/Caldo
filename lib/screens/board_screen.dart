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
          const SizedBox(height: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final stage in Stage.values) ...[
                    if (stage != Stage.notStarted) const SizedBox(width: 5),
                    Expanded(
                      child: _Column(
                        stage: stage,
                        tasks: columns[stage]!,
                        onTap: _open,
                        onDrop: (task) => _move(task, stage),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One column: its name and how many are in it, over its cards, scrolled on
/// its own. A card carried over it lightens it, as long as it would be a move.
class _Column extends StatelessWidget {
  final Stage stage;
  final List<Task> tasks;
  final ValueChanged<Task> onTap;
  final ValueChanged<Task> onDrop;

  const _Column({
    required this.stage,
    required this.tasks,
    required this.onTap,
    required this.onDrop,
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
    return DragTarget<Task>(
      onWillAcceptWithDetails: (d) => d.data.stage != stage,
      onAcceptWithDetails: (d) => onDrop(d.data),
      builder: (context, over, _) {
        final ground = over.isNotEmpty ? p.panelHi : p.panel;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: ground,
            borderRadius: BorderRadius.circular(16),
          ),
          child: LayoutBuilder(
            builder: (context, box) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 11, 10, 9),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          nameOf(s, stage),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: p.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${tasks.length}',
                        style: TextStyle(
                          color: p.faint,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: tasks.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: Text(
                            s.boardEmpty,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: p.faint, fontSize: 12.5),
                          ),
                        )
                      : _FadeFoot(
                          child: ListView.builder(
                            // Room to scroll the last card clear of the fade.
                            padding: const EdgeInsets.only(bottom: 24),
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
                                // The card's ink is translucent, so it is
                                // carried over the ground it was standing on,
                                // cut to its own shape, or it goes muddy over
                                // whatever it passes.
                                feedback: _Lifted(
                                  width: box.maxWidth,
                                  ground: ground,
                                  child: card,
                                ),
                                childWhenDragging: Opacity(
                                  opacity: 0.3,
                                  child: card,
                                ),
                                child: card,
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Fades a column's foot out rather than letting the last card be cut off
/// square by the edge, as everything that runs under the add field does
/// elsewhere. A mask rather than the ground painted over the cards, since
/// the ground lightens while a card is held over the column.
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

/// A card as it is carried: its own shape in the column's ground, a little
/// larger, and shadowed so it is above the board rather than in it.
class _Lifted extends StatelessWidget {
  final double width;
  final Color ground;
  final Widget child;

  const _Lifted({
    required this.width,
    required this.ground,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Transform.scale(
        scale: 1.04,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: BoardCard.margin,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: ground,
                      borderRadius: BorderRadius.circular(BoardCard.radius),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.45),
                          blurRadius: 14,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// A task on the board: the title on up to three lines, a column being a
/// third of a phone wide, and under it when it is due. Inked with the task's
/// colour as the other cards are, and sunk the same way once done.
class BoardCard extends StatelessWidget {
  static const margin = EdgeInsets.fromLTRB(6, 0, 6, 6);
  static const radius = 12.0;

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

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final color = colorOfTask(
      task,
      list,
      fallback: AppTheme.accentOf(context).color,
    );
    final when = _when(MediaQuery.alwaysUse24HourFormatOf(context));
    final meta = task.done ? p.faint : p.muted;
    final marks = [
      if (when != null)
        Flexible(
          child: Text(
            when,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
            style: TextStyle(
              color: task.isOverdue ? AppColors.overdue : meta,
              fontSize: 11.5,
            ),
          ),
        ),
      if (task.repeat != Repeat.none) Icon(Icons.repeat, size: 12, color: meta),
      if (task.subtasks.isNotEmpty) ...[
        Icon(Icons.checklist_rounded, size: 12, color: meta),
        Text(
          '${task.subtasksDone}/${task.subtasks.length}',
          style: TextStyle(color: meta, fontSize: 11.5),
        ),
      ],
      if (task.priority != Priority.none)
        Icon(
          Icons.flag,
          size: 12,
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
            padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
            decoration: BoxDecoration(
              color: color.withValues(alpha: task.done ? 0.07 : 0.24),
              borderRadius: BorderRadius.circular(radius),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: task.done ? p.faint : p.text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    height: 1.25,
                    decoration: task.done ? TextDecoration.lineThrough : null,
                    decorationColor: p.faint,
                  ),
                ),
                if (marks.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      for (var i = 0; i < marks.length; i++) ...[
                        if (i > 0) const SizedBox(width: 4),
                        marks[i],
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

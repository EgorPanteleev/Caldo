import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import 'date_time_pickers.dart' show PickerSheet, showAppDatePicker;
import 'groups.dart';

/// Tasks picked out on one screen to be moved, ticked off or deleted
/// together.
///
/// A card is picked out by a long press let go where it was pressed. The
/// long press already belongs to the drag, and that stays as it was: a card
/// held and moved is carried, and only one held and let go without moving
/// is picked out — the card is the handle for both, as it is in a
/// notes app's grid. Once anything is picked out, a tap on any card picks it
/// out or puts it back, and the quick-add row gives its place to what can be
/// done with them ([SelectionSlot]).
class Selection extends ChangeNotifier {
  final Map<int, Task> _tasks = {};

  bool get active => _tasks.isNotEmpty;
  int get count => _tasks.length;
  bool has(Task task) => _tasks.containsKey(task.id);

  /// What is picked out, in the order it was picked.
  List<Task> get tasks => [..._tasks.values];

  void toggle(Task task) {
    final id = task.id;
    if (id == null) return;
    HapticFeedback.selectionClick();
    if (_tasks.remove(id) == null) {
      // One screen's selection at a time: a screen that has gone out of
      // view must not be left holding one, and back answering to it.
      for (final other in _live) {
        if (other != this) other.clear();
      }
      _tasks[id] = task;
    }
    notifyListeners();
  }

  void clear() {
    if (_tasks.isEmpty) return;
    _tasks.clear();
    notifyListeners();
  }

  /// Every selection there is, so another screen's can be let go of.
  static final _live = <Selection>{};

  /// Whether anything is picked out on any screen, which back answers to
  /// before the shell does.
  static bool get anyActive => _live.any((s) => s.active);

  /// Lets go of whatever is picked out anywhere — for the tab bar, which
  /// is the way off a screen.
  static void dropAll() {
    for (final selection in _live) {
      selection.clear();
    }
  }

  /// The selection over [context], if it has one.
  static Selection? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_SelectionSpot>()?.selection;

  /// The tasks a card being carried takes with it: everything picked out,
  /// if it is one of them, and otherwise itself. What is picked out is let
  /// go of, since it has been dealt with.
  static List<Task> carried(BuildContext context, Task task) {
    final selection = maybeOf(context);
    if (selection == null || !selection.has(task)) return [task];
    final tasks = [
      task,
      for (final t in selection.tasks)
        if (t.id != task.id) t,
    ];
    selection.clear();
    return tasks;
  }

  // ---- A long press let go where it was ------------------------------------

  int? _pointer;
  Offset? _down;
  Task? _lifted;
  bool _moved = false;

  /// How far a finger may wander between pressing and letting go and still
  /// be picking a card out rather than carrying it.
  static const _slop = 18.0;

  /// Called by a list when one of its cards is picked up.
  void lifted(Task task) => _lifted = task;

  void _pressed(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _down = event.position;
    _lifted = null;
    _moved = false;
  }

  void _moving(PointerMoveEvent event) {
    if (event.pointer != _pointer || _down == null) return;
    if ((event.position - _down!).distance > _slop) _moved = true;
  }

  void _let(PointerEvent event) {
    if (event.pointer != _pointer) return;
    final lifted = _lifted;
    if (event is PointerUpEvent && lifted != null && !_moved) toggle(lifted);
    _pointer = null;
    _down = null;
    _lifted = null;
  }
}

class _SelectionSpot extends InheritedWidget {
  final Selection selection;

  const _SelectionSpot({required this.selection, required super.child});

  @override
  bool updateShouldNotify(_SelectionSpot old) => old.selection != selection;
}

/// A screen whose cards can be picked out together: Schedule, the
/// calendar, and the day sheet over it. Back puts down what is picked out
/// before it does anything else, and so does choosing another group, since
/// the tasks picked out of the last one are no longer on show.
class SelectionScope extends StatefulWidget {
  final Widget child;

  const SelectionScope({super.key, required this.child});

  @override
  State<SelectionScope> createState() => _SelectionScopeState();
}

class _SelectionScopeState extends State<SelectionScope> {
  final _selection = Selection();
  int? _group;

  @override
  void initState() {
    super.initState();
    Selection._live.add(_selection);
  }

  @override
  void dispose() {
    Selection._live.remove(_selection);
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final group = context.select<TaskProvider, int?>((t) => t.group);
    if (group != _group) {
      _group = group;
      WidgetsBinding.instance.addPostFrameCallback((_) => _selection.clear());
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _selection._pressed,
      onPointerMove: _selection._moving,
      onPointerUp: _selection._let,
      onPointerCancel: _selection._let,
      child: ListenableBuilder(
        listenable: _selection,
        builder: (context, child) => PopScope(
          canPop: !_selection.active,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _selection.clear();
          },
          child: child!,
        ),
        child: _SelectionSpot(selection: _selection, child: widget.child),
      ),
    );
  }
}

/// The quick-add row, which gives its place to what can be done with the
/// tasks picked out for as long as any are, the way it gives it to Undo
/// after a tick.
class SelectionSlot extends StatefulWidget {
  final Widget child;

  const SelectionSlot({super.key, required this.child});

  @override
  State<SelectionSlot> createState() => _SelectionSlotState();
}

class _SelectionSlotState extends State<SelectionSlot>
    with SingleTickerProviderStateMixin {
  Selection? _selection;

  late final _swap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    reverseDuration: const Duration(milliseconds: 200),
  );

  late final _eased = CurvedAnimation(
    parent: _swap,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final selection = Selection.maybeOf(context);
    if (selection == _selection) return;
    _selection?.removeListener(_changed);
    _selection = selection?..addListener(_changed);
    _swap.value = selection?.active ?? false ? 1 : 0;
  }

  void _changed() {
    final active = _selection?.active ?? false;
    if (active && _swap.status != AnimationStatus.forward) {
      // The keyboard goes, the way an empty tick sends it: the field keeps
      // hold of it, so it comes back as it went.
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      _swap.forward();
    } else if (!active) {
      _swap.reverse();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _selection?.removeListener(_changed);
    _eased.dispose();
    _swap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selection = _selection;
    if (selection == null) return widget.child;
    final active = selection.active;
    return Stack(
      children: [
        // Kept in the tree, as under Undo, so what is typed survives.
        IgnorePointer(
          ignoring: active,
          child: FadeTransition(
            opacity: ReverseAnimation(_eased),
            child: widget.child,
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !active,
            child: FadeTransition(
              opacity: _eased,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, 0.18),
                  end: Offset.zero,
                ).animate(_eased),
                child: _SelectionBar(selection: selection),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Identifies the bar the quick-add row gives way to while tasks are picked
/// out.
const selectionBarKey = Key('selection-bar');

/// The field's own pill, at the field's own size: a cross that puts
/// everything down, how many are picked out, and what can be done with
/// them — another day, another group, ticked off (or back, when every one
/// is done already), deleted. Neutral, as the controls are; Delete wears
/// the red it wears on the form.
class _SelectionBar extends StatelessWidget {
  final Selection selection;

  const _SelectionBar({required this.selection});

  /// What is picked out as it is now, rather than as it was when it was
  /// picked: a reminder's button or the widget may have changed it since.
  List<Task> _tasks(BuildContext context) {
    final provider = context.read<TaskProvider>();
    return [for (final task in selection.tasks) ?provider.taskById(task.id!)];
  }

  Future<void> _moveToDay(BuildContext context) async {
    final tasks = _tasks(context);
    if (tasks.isEmpty) return selection.clear();
    final provider = context.read<TaskProvider>();
    final day = await showAppDatePicker(
      context: context,
      initial: tasks.first.dueDay,
    );
    if (day == null) return;
    selection.clear();
    await provider.moveAllToDay(tasks, day);
  }

  Future<void> _moveToGroup(BuildContext context) async {
    final tasks = _tasks(context);
    if (tasks.isEmpty) return selection.clear();
    final provider = context.read<TaskProvider>();
    final id = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PickerSheet(
        child: _GroupPicker(
          current: {for (final t in tasks) t.listId}.singleOrNull,
        ),
      ),
    );
    if (id == null) return;
    selection.clear();
    await provider.moveAllToGroup(tasks, id);
  }

  Future<void> _setDone(BuildContext context, bool done) async {
    final tasks = _tasks(context);
    selection.clear();
    await context.read<TaskProvider>().setAllDone(tasks, done: done);
  }

  Future<void> _delete(BuildContext context) async {
    final tasks = _tasks(context);
    if (tasks.isEmpty) return selection.clear();
    final provider = context.read<TaskProvider>();
    final s = S.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteTasksQuestion(tasks.length)),
        content: Text(s.cannotBeUndone),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    selection.clear();
    await provider.removeAll(tasks);
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    return ListenableBuilder(
      listenable: selection,
      builder: (context, _) {
        // Kept on screen while it fades out, with the last count it had.
        final count = selection.count;
        final allDone = count > 0 && selection.tasks.every((task) => task.done);
        Widget action(
          IconData icon,
          String tip,
          VoidCallback onTap, {
          Color? color,
        }) => IconButton(
          icon: Icon(icon, color: color ?? p.text, size: 22),
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          onPressed: onTap,
        );
        return Container(
          key: selectionBarKey,
          decoration: ShapeDecoration(
            color: p.field,
            shape: const StadiumBorder(),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              action(Icons.close, s.clearSelection, selection.clear),
              const SizedBox(width: 2),
              Expanded(
                child: Text(
                  count == 0 ? '' : s.selectedCount(count),
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              action(
                Icons.event_outlined,
                s.moveToDay,
                () => _moveToDay(context),
              ),
              action(
                Icons.folder_outlined,
                s.moveToGroup,
                () => _moveToGroup(context),
              ),
              action(
                allDone ? Icons.remove_done : Icons.done_all,
                allDone ? s.markNotDone : s.markDone,
                () => _setDone(context, !allDone),
              ),
              action(
                Icons.delete_outline,
                s.delete,
                () => _delete(context),
                color: AppColors.danger,
              ),
              const SizedBox(width: 4),
            ],
          ),
        );
      },
    );
  }
}

/// The groups as the form shows them, for the tasks picked out to be moved
/// into one — or a new one made for them.
class _GroupPicker extends StatelessWidget {
  /// The group every task picked out is already in, if they share one.
  final int? current;

  const _GroupPicker({required this.current});

  @override
  Widget build(BuildContext context) {
    final lists = context.select<TaskProvider, List<TaskList>>((t) => t.lists);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            S.of(context).moveToGroup,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final list in lists)
                GroupChip(
                  label: groupLabel(context, list),
                  color: list.style.color,
                  selected: list.id == current,
                  onTap: () => Navigator.of(context).pop(list.id),
                ),
              GroupChip.add(
                onTap: () async {
                  final navigator = Navigator.of(context);
                  final made = await showGroupSheet(context);
                  if (made != null) navigator.pop(made.id);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/foundation.dart';

import '../db/database.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../services/reminders.dart';

/// Strips the time from [date], giving the calendar day it belongs to.
DateTime dayOf(DateTime date) => DateTime(date.year, date.month, date.day);

/// Owns the user's lists, the tasks of the currently-open list, and the dated
/// tasks backing the calendar and the agenda, exposing CRUD to the UI.
class TaskProvider extends ChangeNotifier {
  final AppDatabase _db = AppDatabase.instance;

  List<TaskList> _lists = [];
  bool _listsLoading = false;

  int? _currentListId;
  List<Task> _tasks = [];
  String _query = '';
  bool _loading = false;
  bool _showCompleted = true;

  /// First day of the month the calendar is showing.
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  /// Dated tasks of [_month], grouped by the day they fall on.
  Map<DateTime, List<Task>> _byDay = {};

  /// Open tasks whose due date has already passed.
  List<Task> _overdue = [];

  /// Dated tasks from today onwards (done ones included, so a day's progress
  /// is visible), backing the Tasks screen and the calendar.
  List<Task> _upcoming = [];

  /// Tasks with no due date, listed after the dated ones.
  List<Task> _undated = [];

  List<TaskList> get lists => _lists;
  bool get listsLoading => _listsLoading;
  int? get currentListId => _currentListId;
  List<Task> get tasks => _tasks;
  String get query => _query;
  bool get loading => _loading;
  DateTime get month => _month;
  Map<DateTime, List<Task>> get tasksByDay => _byDay;
  List<Task> get overdue => _overdue;
  List<Task> get upcoming => _upcoming;
  List<Task> get undated => _undated;

  TaskList? get currentList {
    for (final l in _lists) {
      if (l.id == _currentListId) return l;
    }
    return null;
  }

  TaskList? listById(int id) {
    for (final l in _lists) {
      if (l.id == id) return l;
    }
    return null;
  }

  /// How many days ahead the Tasks screen looks.
  static const agendaDays = 30;

  // ---- Lists --------------------------------------------------------------

  Future<void> loadLists() async {
    _listsLoading = true;
    notifyListeners();
    _lists = await _db.getLists();
    _listsLoading = false;
    notifyListeners();
  }

  Future<TaskList> addList(TaskList list) async {
    final created = await _db.insertList(list);
    await loadLists();
    return created;
  }

  Future<void> updateList(TaskList list) async {
    await _db.updateList(list);
    await loadLists();
  }

  Future<void> removeList(int id) async {
    await _db.deleteList(id);
    if (_currentListId == id) {
      _currentListId = null;
      _tasks = [];
    }
    await _reloadAll();
  }

  // ---- Tasks in the open list --------------------------------------------

  /// Opens [id] as the current list and loads its tasks.
  Future<void> openList(int id) async {
    _currentListId = id;
    _query = '';
    await _loadListTasks();
  }

  Future<void> search(String query) async {
    _query = query;
    await _loadListTasks();
  }

  /// Mirrors the "show completed" setting into the list query.
  Future<void> setShowCompleted(bool value) async {
    if (_showCompleted == value) return;
    _showCompleted = value;
    await _loadListTasks();
  }

  /// Reloads the open list's tasks for the current query.
  Future<void> _loadListTasks() async {
    final id = _currentListId;
    if (id == null) {
      _tasks = [];
      notifyListeners();
      return;
    }
    _loading = true;
    notifyListeners();
    _tasks = await _db.getTasks(
      listId: id,
      query: _query,
      includeDone: _showCompleted,
    );
    _loading = false;
    notifyListeners();
  }

  /// Every task whose title or notes match [query], across all lists. Returned
  /// rather than held, since the search screen is the only thing that wants it.
  Future<List<Task>> searchAll(String query) =>
      _db.getTasks(query: query, includeDone: _showCompleted);

  // ---- Calendar and agenda ------------------------------------------------

  /// Loads the dated tasks of the month containing [date] (plus a little
  /// padding, so days of adjacent months shown in the grid are populated too).
  Future<void> loadMonth(DateTime date) async {
    _month = DateTime(date.year, date.month);
    final from = _month.subtract(const Duration(days: 7));
    final to = DateTime(
      _month.year,
      _month.month + 1,
    ).add(const Duration(days: 7));
    final tasks = await _db.getTasksInRange(
      from.millisecondsSinceEpoch,
      to.millisecondsSinceEpoch,
    );
    _byDay = _groupByDay(tasks);
    notifyListeners();
  }

  /// Tasks due on [day], open ones first.
  List<Task> tasksForDay(DateTime day) => _byDay[dayOf(day)] ?? const [];

  /// Loads what the Tasks screen shows: the overdue backlog, the next
  /// [agendaDays] days of dated tasks, and everything with no date.
  Future<void> loadTasks() async {
    final today = dayOf(DateTime.now());
    final to = today.add(const Duration(days: agendaDays));
    _overdue = await _db.getOverdue(today.millisecondsSinceEpoch);
    _upcoming = await _db.getTasksInRange(
      today.millisecondsSinceEpoch,
      to.millisecondsSinceEpoch,
    );
    _undated = await _db.getUndated();
    // Every path that changes a task ends here, which makes this the one place
    // the alarms have to be put back in step — an edited date, a tick, a
    // deletion. They are set from what is already loaded rather than from a
    // query of their own, so the reminder horizon is the agenda's.
    await Reminders.instance.sync(_upcoming);
    notifyListeners();
  }

  /// The dated tasks grouped into days, ordered soonest first.
  Map<DateTime, List<Task>> get upcomingByDay => _groupByDay(_upcoming);

  Map<DateTime, List<Task>> _groupByDay(List<Task> tasks) {
    final map = <DateTime, List<Task>>{};
    for (final task in tasks) {
      final day = task.dueDay;
      if (day == null) continue;
      map.putIfAbsent(day, () => []).add(task);
    }
    for (final entry in map.entries) {
      entry.value.sort(_compare);
    }
    return map;
  }

  /// Open before done, then where the day was dragged into, then earlier
  /// before later and all-day before timed.
  ///
  /// A finished task goes to the end of its day, under the ones still to do —
  /// asked for, once the move was something to watch rather than a jump: the
  /// list is read back with it in its new place, and every card slides from
  /// where it was to where it has landed (`SlideIntoPlace`, [rearranging]).
  /// The hand-placed order sits under "open before done" rather than over it,
  /// since ticking a task off is about whether it is still to be done. A task
  /// with no placement of its own goes after the ones that have it — it
  /// arrived in a day somebody had already arranged.
  static int _compare(Task a, Task b) {
    if (a.done != b.done) return a.done ? 1 : -1;
    if (a.sortOrder != b.sortOrder) {
      if (a.sortOrder == null) return 1;
      if (b.sortOrder == null) return -1;
      return a.sortOrder!.compareTo(b.sortOrder!);
    }
    if (a.hasTime != b.hasTime) return a.hasTime ? 1 : -1;
    final byDue = (a.dueAt ?? 0).compareTo(b.dueAt ?? 0);
    if (byDue != 0) return byDue;
    return b.createdAt.compareTo(a.createdAt);
  }

  // ---- Task mutations -----------------------------------------------------

  Future<void> add(Task task) async {
    await _db.insert(task);
    await _reloadAll();
  }

  Future<void> update(Task task) async {
    await _db.update(task);
    await _reloadAll();
  }

  Future<void> remove(int id) async {
    await _db.delete(id);
    await _reloadAll();
  }

  /// How long the tick takes to be drawn on a card. Matched to the card's
  /// own settle.
  static const settle = Duration(milliseconds: 240);

  /// How long a ticked card waits, tick drawn, before it is crossed out —
  /// and before a card that is leaving its run starts to go. The tick is
  /// the answer to the tap; being crossed out and leaving are what follow
  /// from it, and they follow a beat later so the tap is seen to have been
  /// taken before the card changes underneath it.
  static const linger = Duration(milliseconds: 400);

  /// How long a leaving card takes to fade and close up the gap it leaves.
  /// Matched to the card's own (`TaskCard`).
  static const leave = Duration(milliseconds: 280);

  /// Ticked just before a tick, an untick or an undo has the lists read back
  /// in a new order. Cards note where they stand when it does, and slide from
  /// there to wherever the new order puts them (`SlideIntoPlace`): a
  /// finished task drifts to the end of its day and the ones below it rise,
  /// rather than the card vanishing from one place and turning up in another.
  final ValueNotifier<int> rearranging = ValueNotifier<int>(0);

  /// Tasks whose tick has been drawn and that are not yet crossed out.
  final Set<int> _ticking = {};

  /// Tasks crossed out a moment ago, before the run is read back — the
  /// stretch in which a card that is leaving its run fades out of it.
  final Set<int> _settled = {};

  /// Ticked repeating tasks, which roll on to their next date and so leave
  /// every run they are in.
  final Set<int> _rolling = {};

  /// The latest tick on each task, so a second tap while a card is waiting
  /// — taking it back — stops the first one from finishing.
  final Map<int, int> _ticks = {};
  int _tickCount = 0;

  /// Whether [task]'s tick is drawn but its card not yet crossed out.
  bool isTicking(Task task) => task.id != null && _ticking.contains(task.id);

  /// Whether [task]'s card is fading out of its run. Only cards whose task
  /// will not be in that run once it is read back: a repeating task rolling
  /// on to another date leaves every run, and a done task leaves the overdue
  /// backlog — [fromOverdue] says that is the run being asked about. Any
  /// other ticked task stays where it is, crossed out; fading it out only to
  /// have the reload put it back was a card disappearing and reappearing.
  bool isLeaving(Task task, {bool fromOverdue = false}) =>
      task.id != null &&
      _settled.contains(task.id) &&
      (fromOverdue || _rolling.contains(task.id));

  /// Ticks a task off. A repeating task with a due date is not closed: it
  /// rolls forward to its next occurrence instead, which is what makes a
  /// recurring chore behave like one.
  ///
  /// The database is written at once; what is shown follows in steps. The
  /// tick is drawn on the card where it stands; [linger] later the card is
  /// crossed out, and a card that is leaving its run starts to fade; and
  /// [leave] after that the run is read back. Taken back, a tick goes
  /// straight away — undoing is a correction, not a flourish.
  Future<void> toggleDone(Task task) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final due = task.due;
    final rolls = !task.done && task.repeat != Repeat.none && due != null;
    if (rolls) {
      await _db.update(
        task.copyWith(
          dueAt: task.repeat.next(due)!.millisecondsSinceEpoch,
          completedAt: now,
        ),
      );
    } else {
      await _db.update(
        task.done
            ? task.copyWith(done: false, clearCompletedAt: true)
            : task.copyWith(done: true, completedAt: now),
      );
    }

    final id = task.id;
    final tick = ++_tickCount;
    if (id != null) {
      _ticks[id] = tick;
      _ticking.remove(id);
      _settled.remove(id);
      _rolling.remove(id);
    }
    // A repeating task is shown ticked too, where it stands, even though
    // what was written is its next date: it is being done today, and that
    // is what the tap should be seen to do.
    final done = rolls || !task.done;
    _showAsDone(task, done);

    if (!done) {
      notifyListeners();
      await Future<void>.delayed(settle);
      rearranging.value++;
      await _reloadAll();
      return;
    }
    if (id != null) {
      _ticking.add(id);
      if (rolls) _rolling.add(id);
    }
    notifyListeners();

    await Future<void>.delayed(settle + linger);
    if (id != null && _ticks[id] == tick) {
      _ticking.remove(id);
      _settled.add(id);
      notifyListeners();
      await Future<void>.delayed(leave);
      _settled.remove(id);
      _rolling.remove(id);
    }
    rearranging.value++;
    await _reloadAll();
  }

  /// Puts [original] back exactly as it was before it was ticked — not
  /// ticked off, and on its own date if it was a repeating task that had
  /// rolled on. What the undo after a tick does. A tick still playing out on
  /// the task is stopped where it is.
  Future<void> restore(Task original) async {
    final id = original.id;
    if (id == null) return;
    _ticks[id] = ++_tickCount;
    _ticking.remove(id);
    _settled.remove(id);
    _rolling.remove(id);
    await _db.update(original);
    rearranging.value++;
    await _reloadAll();
  }

  /// Marks the copies of [task] already on screen done or not, in place, so
  /// the card it is drawn on can animate without moving.
  void _showAsDone(Task task, bool done) {
    Task mark(Task t) => t.id == task.id
        ? t.copyWith(
            done: done,
            completedAt: done ? DateTime.now().millisecondsSinceEpoch : null,
            clearCompletedAt: !done,
          )
        : t;
    List<Task> marked(List<Task> run) => [for (final t in run) mark(t)];
    _tasks = marked(_tasks);
    _overdue = marked(_overdue);
    _upcoming = marked(_upcoming);
    _undated = marked(_undated);
    _byDay = {
      for (final entry in _byDay.entries) entry.key: marked(entry.value),
    };
  }

  /// Writes the order a run of tasks was dragged into — the whole run, in the
  /// order it now reads, not just the one that moved.
  Future<void> reorder(List<Task> ordered) async {
    final ids = [
      for (final task in ordered)
        if (task.id != null) task.id!,
    ];
    if (ids.length < 2) return;
    await _db.setOrder(ids);
    await _reloadAll();
  }

  /// Deletes every completed task of [listId], or of all lists when null.
  Future<int> clearCompleted({int? listId}) async {
    final removed = await _db.clearCompleted(listId: listId);
    await _reloadAll();
    return removed;
  }

  /// Reloads whatever the UI currently has on screen after a mutation.
  Future<void> _reloadAll() async {
    _lists = await _db.getLists();
    if (_currentListId != null) {
      _tasks = await _db.getTasks(
        listId: _currentListId!,
        query: _query,
        includeDone: _showCompleted,
      );
    }
    await loadMonth(_month);
    await loadTasks();
  }
}

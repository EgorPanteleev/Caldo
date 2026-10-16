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
    final to = DateTime(_month.year, _month.month + 1).add(
      const Duration(days: 7),
    );
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
  /// The hand-placed order comes first because it is the one the user chose;
  /// it sits under "open before done" rather than over it, since a task being
  /// ticked off is about whether it is still to be done, not about where in
  /// the day it sits. A task with no placement of its own goes after the ones
  /// that have it — it arrived in a day somebody had already arranged.
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

  /// Ticks a task off. A repeating task with a due date is not closed: it
  /// rolls forward to its next occurrence instead, which is what makes a
  /// recurring chore behave like one.
  Future<void> toggleDone(Task task) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final due = task.due;
    if (!task.done && task.repeat != Repeat.none && due != null) {
      final next = task.repeat.next(due);
      await _db.update(task.copyWith(
        dueAt: next?.millisecondsSinceEpoch,
        completedAt: now,
      ));
    } else {
      await _db.update(task.done
          ? task.copyWith(done: false, clearCompletedAt: true)
          : task.copyWith(done: true, completedAt: now));
    }
    await _reloadAll();
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

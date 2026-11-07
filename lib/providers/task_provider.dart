import 'package:flutter/foundation.dart';

import '../db/database.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../services/background.dart';
import '../services/reminders.dart';
import '../services/today_widget.dart';

/// Strips the time from [date], giving the calendar day it belongs to.
DateTime dayOf(DateTime date) => DateTime(date.year, date.month, date.day);

/// Owns the user's lists and the dated tasks backing the calendar and the
/// agenda, exposing CRUD to the UI.
class TaskProvider extends ChangeNotifier {
  final AppDatabase _db = AppDatabase.instance;

  /// A reminder's buttons and the widget change tasks without going through
  /// here; when they do, the lists are read back as after any other change.
  TaskProvider() {
    Background.changed.addListener(_changedOutside);
  }

  @override
  void dispose() {
    Background.changed.removeListener(_changedOutside);
    super.dispose();
  }

  void _changedOutside() {
    rearranging.value++;
    _reloadAll();
  }

  List<TaskList> _lists = [];

  /// Whether search turns up tasks that are already done.
  bool _showCompleted = true;

  /// First day of the month the calendar is showing.
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  /// Dated tasks of [_month], grouped by the day they fall on.
  Map<DateTime, List<Task>> _allByDay = {};

  /// Open tasks whose due date has already passed.
  List<Task> _allOverdue = [];

  /// Dated tasks from today onwards (done ones included, so a day's progress
  /// is visible), backing the Tasks screen and the calendar.
  List<Task> _allUpcoming = [];

  /// [_allUpcoming] grouped into days, sorted once when it is read in.
  /// Sorting it again on every build put a ticked task at the end of its day
  /// on Schedule the moment it was marked done — before it was crossed out,
  /// and with nothing to slide it there.
  Map<DateTime, List<Task>> _allUpcomingByDay = {};

  /// Tasks with no due date, listed after the dated ones.
  List<Task> _allUndated = [];

  /// The same, narrowed to the [group] on show — what the screens draw.
  /// Worked out once per read rather than per build, for the reason
  /// [_allUpcomingByDay] is.
  Map<DateTime, List<Task>> _byDay = {};
  List<Task> _overdue = [];
  List<Task> _upcoming = [];
  Map<DateTime, List<Task>> _upcomingByDay = {};
  List<Task> _undated = [];

  /// The id of the one group Schedule and the calendar are showing, or null
  /// for every task.
  int? _group;

  List<TaskList> get lists => _lists;
  DateTime get month => _month;
  Map<DateTime, List<Task>> get tasksByDay => _byDay;
  List<Task> get overdue => _overdue;
  List<Task> get upcoming => _upcoming;
  List<Task> get undated => _undated;
  int? get group => _group;

  /// The backlog and the days to come whichever group is on show: the
  /// home-screen widget and the menu's overdue dot are not looking at a
  /// screen, and what they say is about every task there is.
  List<Task> get allOverdue => _allOverdue;
  Map<DateTime, List<Task>> get allUpcomingByDay => _allUpcomingByDay;

  /// The group a task goes into when nothing says otherwise — the oldest,
  /// "Personal" unless it was renamed. It cannot be deleted.
  int get defaultGroup => _lists.isEmpty ? 1 : _lists.first.id!;

  /// The group a task made on a screen now goes into: the one on show, or
  /// the default group when everything is.
  int get groupForNew => _group ?? defaultGroup;

  /// Shows only the tasks of group [id] on Schedule and the calendar, or
  /// every task again when it is null. Held for the run of the app and not
  /// stored: a group left chosen yesterday is tasks gone missing today.
  void showGroup(int? id) {
    if (id == _group) return;
    _group = id;
    _narrow();
    notifyListeners();
  }

  /// Puts the narrowed views back in step with what was read.
  void _narrow() {
    final id = _group;
    List<Task> keep(List<Task> tasks) => id == null
        ? tasks
        : [
            for (final t in tasks)
              if (t.listId == id) t,
          ];
    Map<DateTime, List<Task>> keepDays(Map<DateTime, List<Task>> days) =>
        id == null
        ? days
        : {
            for (final MapEntry(:key, :value) in days.entries)
              if (keep(value) case final kept when kept.isNotEmpty) key: kept,
          };
    _byDay = keepDays(_allByDay);
    _overdue = keep(_allOverdue);
    _upcoming = keep(_allUpcoming);
    _upcomingByDay = keepDays(_allUpcomingByDay);
    _undated = keep(_allUndated);
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
    _lists = await _db.getLists();
    notifyListeners();
  }

  Future<TaskList> addList(TaskList list) async {
    final created = await _db.insertList(list);
    await loadLists();
    return created;
  }

  /// Renames or recolours a group. Its tasks are read back, since every one
  /// without a colour of its own is drawn in the group's.
  Future<void> updateList(TaskList list) async {
    await _db.updateList(list);
    await _reloadAll();
  }

  /// Deletes a group, moving its tasks into the default group. The default
  /// group itself stays.
  Future<void> deleteList(int id) async {
    if (id == defaultGroup) return;
    await _db.deleteList(id, into: defaultGroup);
    if (_group == id) _group = null;
    rearranging.value++;
    await _reloadAll();
  }

  /// Mirrors the "show completed" setting into search.
  void setShowCompleted(bool value) => _showCompleted = value;

  /// Every task whose title or notes match [query], across all lists. Returned
  /// rather than held, since the search screen is the only thing that wants it.
  Future<List<Task>> searchAll(String query) =>
      _db.getTasks(query: query, includeDone: _showCompleted);

  // ---- Calendar and agenda ------------------------------------------------

  /// Loads the dated tasks of the month containing [date] (plus a little
  /// padding, so days of adjacent months shown in the grid are populated too).
  ///
  /// With [keep], that day's tasks stay as they were even if the new month's
  /// range does not reach it: a task being carried across months is still a
  /// card in that day's list, and the list must not lose it from under the
  /// finger.
  Future<void> loadMonth(DateTime date, {DateTime? keep}) async {
    final kept = keep == null ? null : _allByDay[dayOf(keep)];
    await _readMonth(date);
    if (kept != null) {
      _allByDay.putIfAbsent(dayOf(keep!), () => kept);
      _narrow();
    }
    notifyListeners();
  }

  Future<void> _readMonth(DateTime date) async {
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
    _allByDay = _groupByDay(tasks);
    _narrow();
  }

  /// Tasks due on [day], open ones first.
  List<Task> tasksForDay(DateTime day) => _byDay[dayOf(day)] ?? const [];

  /// Loads what the Tasks screen shows: the overdue backlog, the next
  /// [agendaDays] days of dated tasks, and everything with no date.
  Future<void> loadTasks() async {
    await readAgenda();
    notifyListeners();
    await _afterRead();
  }

  /// Reads the agenda in whole before any of it is put in place, so nothing
  /// that rebuilds in between sees a backlog from after a change beside days
  /// from before it. Public for the background isolates, which read it to
  /// redraw the widget and tell nobody.
  Future<void> readAgenda() async {
    final today = dayOf(DateTime.now());
    final to = today.add(const Duration(days: agendaDays));
    final overdue = await _db.getOverdue(today.millisecondsSinceEpoch);
    final upcoming = await _db.getTasksInRange(
      today.millisecondsSinceEpoch,
      to.millisecondsSinceEpoch,
    );
    final undated = await _db.getUndated();
    _allOverdue = overdue;
    _allUpcoming = upcoming;
    _allUndated = undated;
    _allUpcomingByDay = _groupByDay(upcoming);
    _narrow();
  }

  /// Every path that changes a task ends in a read of the agenda, which makes
  /// that the one place the alarms have to be put back in step — an edited
  /// date, a tick, a deletion. They are set from what is already loaded rather
  /// than from a query of their own, so the reminder horizon is the agenda's,
  /// and after the notify rather than before it: alarms are set on the
  /// platform's main thread, which is also the one that hands out frames, and
  /// the lists should be on screen — their cards sliding — first.
  ///
  /// The overdue backlog goes in with the days to come: its tasks' own times
  /// have passed, but one snoozed late in the evening comes back after
  /// midnight, by which time it is in the backlog.
  ///
  /// The home-screen widget is redrawn from the same read, for the same
  /// reason the alarms are: every change ends here.
  Future<void> _afterRead() async {
    await Reminders.instance.sync([..._allOverdue, ..._allUpcoming]);
    await TodayWidget.publish(this);
  }

  /// The dated tasks grouped into days, ordered soonest first.
  Map<DateTime, List<Task>> get upcomingByDay => _upcomingByDay;

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
  ///
  /// Done tasks are in the order they were ticked, the latest last, ahead
  /// of any hand placement: the one just ticked off is the one that slides
  /// to the very end, rather than to wherever its creation date put it among
  /// the others already done.
  static int _compare(Task a, Task b) {
    if (a.done != b.done) return a.done ? 1 : -1;
    if (a.done) {
      final byTick = (a.completedAt ?? 0).compareTo(b.completedAt ?? 0);
      if (byTick != 0) return byTick;
    }
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
  static const linger = Duration(milliseconds: 250);

  /// How long a crossed-out card that is staying in its run holds still
  /// before the run is read back and it slides to the end of its day — long
  /// enough to be seen crossed out where it was.
  static const hold = Duration(milliseconds: 150);

  /// How long a leaving card takes to fade and close up the gap it leaves.
  /// Matched to the card's own (`TaskCard`).
  static const leave = Duration(milliseconds: 280);

  /// Ticked just before a tick, an untick or an undo has the lists read back
  /// in a new order. Cards note where they stand when it does, and slide from
  /// there to wherever the new order puts them (`SlideIntoPlace`): a
  /// finished task drifts to the end of its day and the ones below it rise,
  /// rather than the card vanishing from one place and turning up in another.
  final ValueNotifier<int> rearranging = ValueNotifier<int>(0);

  /// Fires as a tick plays out — drawn, crossed out, taken back — which is
  /// what a card listens to (`AsShown`) rather than to this provider.
  ///
  /// Only the card being ticked changes in those moments, and a notify from
  /// here rebuilds both screens, the calendar's whole month and pager among
  /// them: measured at 9–14ms a frame on the emulator, past the 8ms a 120Hz
  /// phone has, at the very frame each step of the tick starts on. The lists
  /// are read back, and this provider notifies, once the tick is over.
  final ValueNotifier<int> ticked = ValueNotifier<int>(0);

  /// Tasks shown done, or not, ahead of the lists being read back.
  final Map<int, bool> _shownDone = {};

  /// [task] as it should be drawn right now: ticked the moment it was tapped,
  /// although the list it came from is only read back once the tick is over.
  Task shown(Task task) {
    final done = _shownDone[task.id];
    if (done == null || done == task.done) return task;
    return task.copyWith(
      done: done,
      completedAt: done ? DateTime.now().millisecondsSinceEpoch : null,
      clearCompletedAt: !done,
    );
  }

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
    final rolls = task.rollsOn;
    if (task.done) {
      await _db.untick(task.reopened());
    } else {
      await _db.complete(task, now);
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
    if (id != null) _shownDone[id] = done;

    if (!done) {
      ticked.value++;
      await Future<void>.delayed(settle);
      await _readBack(id, tick);
      return;
    }
    if (id != null) {
      _ticking.add(id);
      if (rolls) _rolling.add(id);
    }
    ticked.value++;

    await Future<void>.delayed(settle + linger);
    if (id != null && _ticks[id] == tick) {
      _ticking.remove(id);
      _settled.add(id);
      ticked.value++;
      // A card that is leaving fades out first; one that is staying only has
      // to be seen crossed out before it moves.
      await Future<void>.delayed(
        rolls || _allOverdue.any((t) => t.id == id) ? leave : hold,
      );
      _settled.remove(id);
      _rolling.remove(id);
    }
    await _readBack(id, tick);
  }

  /// Reads the lists back once a tick on [id] is over, with the cards told
  /// first so they can slide to their new places. What the card was shown
  /// as is dropped only by the latest tick on it, and only once the lists
  /// say the same.
  Future<void> _readBack(int? id, int tick) async {
    rearranging.value++;
    await _reloadAll();
    if (id != null && _ticks[id] == tick) _shownDone.remove(id);
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
    _shownDone.remove(id);
    ticked.value++;
    // The tick being undone comes out of the Done log with it.
    await _db.untick(original);
    rearranging.value++;
    await _reloadAll();
  }

  /// Moves [task] to [day] — or off the calendar, when null — keeping the
  /// time of day it had.
  ///
  /// With [among], the run it was dropped into in its new order, that order
  /// is written for the whole run, the moved task included. Without, the
  /// task lets go of the place it had in its old day and goes after whatever
  /// the new one already has arranged, the way a task added to it would.
  Future<void> moveToDay(Task task, DateTime? day, {List<Task>? among}) =>
      moveAllToDay([task], day, among: among);

  /// Moves every one of [tasks] to [day], as [moveToDay] moves one — with
  /// one read back for the lot, so they all slide to their new places
  /// together.
  Future<void> moveAllToDay(
    List<Task> tasks,
    DateTime? day, {
    List<Task>? among,
  }) async {
    for (final task in tasks) {
      await _db.update(_movedTo(task, day));
    }
    final ids = [
      for (final t in among ?? const <Task>[])
        if (t.id != null) t.id!,
    ];
    if (ids.length > 1) await _db.setOrder(ids);
    rearranging.value++;
    await _reloadAll();
  }

  static Task _movedTo(Task task, DateTime? day) {
    if (day == null) {
      return task.copyWith(
        clearDueAt: true,
        hasTime: false,
        clearSortOrder: true,
        clearSnoozedUntil: true,
      );
    }
    final due = task.due;
    final at = task.hasTime && due != null
        ? DateTime(day.year, day.month, day.day, due.hour, due.minute)
        : dayOf(day);
    // A snooze was a reminder put off on the old date; the new one has its
    // own.
    return task.copyWith(
      dueAt: at.millisecondsSinceEpoch,
      clearSortOrder: true,
      clearSnoozedUntil: true,
    );
  }

  /// Puts every one of [tasks] in group [id], back on the group's colour —
  /// as the form does when a task changes group.
  Future<void> moveAllToGroup(List<Task> tasks, int id) async {
    for (final task in tasks) {
      if (task.listId == id) continue;
      await _db.update(task.copyWith(listId: id, clearStyleId: true));
    }
    rearranging.value++;
    await _reloadAll();
  }

  /// Ticks off every one of [tasks] that is still open, or with [done]
  /// false takes the tick back from every one that is done. Each tick is
  /// logged and a repeating task rolls on, as when it is ticked on its card;
  /// the cards are not played through a tick each, only slid to where the
  /// read back puts them.
  Future<void> setAllDone(List<Task> tasks, {required bool done}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final task in tasks) {
      if (task.done == done) continue;
      if (done) {
        await _db.complete(task, now);
      } else {
        await _db.untick(task.reopened());
      }
    }
    rearranging.value++;
    await _reloadAll();
  }

  Future<void> removeAll(List<Task> tasks) async {
    for (final task in tasks) {
      if (task.id != null) await _db.delete(task.id!);
    }
    rearranging.value++;
    await _reloadAll();
  }

  /// The task with [id] as it was last read, wherever it is on show.
  Task? taskById(int id) {
    for (final run in [
      _allOverdue,
      _allUpcoming,
      _allUndated,
      for (final day in _allByDay.values) day,
    ]) {
      for (final task in run) {
        if (task.id == id) return task;
      }
    }
    return null;
  }

  /// Puts [task] in the board's column for [stage]. Into Done is a tick like
  /// any other, logged and rolling a repeating task on; out of it is the
  /// tick taken back, so the log forgets it.
  Future<void> moveToStage(Task task, Stage stage) async {
    if (stage == task.stage) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (stage == Stage.done) {
      await _db.complete(task, now);
    } else if (task.done) {
      await _db.untick(task.toStage(stage, now));
    } else {
      await _db.update(task.toStage(stage, now));
    }
    rearranging.value++;
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

  /// Deletes every completed task.
  Future<int> clearCompleted() async {
    final removed = await _db.clearCompleted();
    await _reloadAll();
    return removed;
  }

  /// Reloads whatever the UI currently has on screen after a mutation.
  Future<void> _reloadAll() async {
    _lists = await _db.getLists();
    // One notify for the lot. It was one for the month and another for the
    // agenda, three queries later — each a rebuild of both screens, and on a
    // phone the second one landed a frame or two into the slide it started.
    await _readMonth(_month);
    await readAgenda();
    notifyListeners();
    await _afterRead();
  }
}

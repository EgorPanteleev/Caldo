import 'package:caldo/models/task.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_db.dart';

void main() {
  initTestDatabase();

  final day = dayOf(DateTime.now().add(const Duration(days: 3)));

  Future<TaskProvider> provider() async {
    await resetTestDatabase();
    final provider = TaskProvider();
    await provider.loadLists();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final title in ['one', 'two', 'three']) {
      await provider.add(
        Task(
          listId: provider.lists.first.id!,
          title: title,
          dueAt: day.millisecondsSinceEpoch,
          createdAt: now,
        ),
      );
    }
    await provider.loadMonth(day);
    return provider;
  }

  List<String> titles(TaskProvider p) => [
    for (final task in p.tasksForDay(day)) task.title,
  ];

  /// Just past the moment a ticked card is crossed out, before the run is
  /// read back.
  Future<void> untilCrossedOut() => Future<void>.delayed(
    TaskProvider.settle +
        TaskProvider.linger +
        const Duration(milliseconds: 80),
  );

  test(
    'a ticked task is crossed out a beat after its tick, then moves down',
    () async {
      final p = await provider();
      final first = p.tasksForDay(day).first;
      var rearranged = 0;
      p.rearranging.addListener(() => rearranged++);

      // Not awaited: what is being pinned is what the run looks like while it
      // plays out, which is before this returns.
      final ticking = p.toggleDone(first);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      // Ticked at once, where it stands — but not crossed out yet. Shown as
      // done rather than read back as done: the lists are only read again
      // once the tick is over, so that drawing it rebuilds the card alone.
      expect(titles(p).first, first.title);
      expect(p.tasksForDay(day).first.done, isFalse);
      expect(p.shown(p.tasksForDay(day).first).done, isTrue);
      expect(p.isTicking(first), isTrue);

      // A beat later it is crossed out, still in place, and not fading: a day's
      // done tasks are still listed, and fading one out only for the reload to
      // put it back was a card disappearing and reappearing.
      await untilCrossedOut();
      expect(p.isTicking(first), isFalse);
      expect(p.isLeaving(first), isFalse);
      expect(titles(p).first, first.title);
      expect(rearranged, 0);
      // Schedule too: its days were sorted afresh on every build, so there
      // the task went to the end the moment it was ticked.
      expect(p.upcomingByDay[day]!.first.title, first.title);

      // Then the run is read back with it at the end, under the ones still to
      // do — and the cards are told first, so they can slide there rather than
      // jump.
      await ticking;
      expect(rearranged, 1);
      expect(titles(p).last, first.title);
      expect(p.tasksForDay(day).last.done, isTrue);
      expect(p.upcomingByDay[day]!.last.title, first.title);
    },
  );

  test('an undo puts a ticked task back as it was', () async {
    final p = await provider();
    final first = p.tasksForDay(day).first;
    await p.toggleDone(first);
    expect(titles(p).last, first.title);

    await p.restore(first);
    expect(titles(p).first, first.title);
    expect(p.tasksForDay(day).first.done, isFalse);
  });

  test('an undo puts a repeating task back on its own date', () async {
    final p = await provider();
    await p.add(
      Task(
        listId: p.lists.first.id!,
        title: 'daily',
        dueAt: day.millisecondsSinceEpoch,
        repeat: Repeat.daily,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await p.loadMonth(day);
    final daily = p.tasksForDay(day).firstWhere((t) => t.title == 'daily');

    // Ticking rolls it on to tomorrow; ticking it again would only roll it a
    // second time, which is why the undo writes back the task it was.
    await p.toggleDone(daily);
    expect(p.tasksForDay(day).where((t) => t.title == 'daily'), isEmpty);

    await p.restore(daily);
    await p.loadMonth(day);
    final back = p.tasksForDay(day).singleWhere((t) => t.title == 'daily');
    expect(back.done, isFalse);
    expect(back.dueAt, daily.dueAt);
  });

  test('an undo during the tick stops it where it is', () async {
    final p = await provider();
    final first = p.tasksForDay(day).first;
    final ticking = p.toggleDone(first);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await p.restore(first);
    await ticking;
    expect(titles(p).first, first.title);
    expect(p.tasksForDay(day).first.done, isFalse);
    expect(p.shown(p.tasksForDay(day).first).done, isFalse);
    expect(p.isTicking(first), isFalse);
  });

  test(
    'a ticked overdue task fades out of the backlog, and only there',
    () async {
      final p = await provider();
      final yesterday = dayOf(DateTime.now().subtract(const Duration(days: 1)));
      await p.add(
        Task(
          listId: p.lists.first.id!,
          title: 'late',
          dueAt: yesterday.millisecondsSinceEpoch,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await p.loadTasks();
      final late = p.overdue.single;

      final ticking = p.toggleDone(late);
      await untilCrossedOut();
      // Done, it is not overdue any more, so the backlog loses it…
      expect(p.isLeaving(late, fromOverdue: true), isTrue);
      // …while its own day, which still lists done tasks, keeps it.
      expect(p.isLeaving(late), isFalse);
      await ticking;
      expect(p.overdue, isEmpty);
    },
  );

  test('a ticked repeating task leaves wherever it is', () async {
    final p = await provider();
    await p.add(
      Task(
        listId: p.lists.first.id!,
        title: 'daily',
        dueAt: day.millisecondsSinceEpoch,
        repeat: Repeat.daily,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await p.loadMonth(day);
    final daily = p.tasksForDay(day).firstWhere((t) => t.title == 'daily');

    final ticking = p.toggleDone(daily);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    // Shown ticked where it stands, though what was written is its next date.
    expect(p.isTicking(daily), isTrue);

    await untilCrossedOut();
    expect(p.isLeaving(daily), isTrue, reason: 'it rolls on to tomorrow');
    await ticking;
    expect(p.tasksForDay(day).where((t) => t.title == 'daily'), isEmpty);
  });

  test('taking a tick back does not linger', () async {
    final p = await provider();
    final first = p.tasksForDay(day).first;
    await p.toggleDone(first);
    final done = p.tasksForDay(day).firstWhere((t) => t.id == first.id);

    final undoing = p.toggleDone(done);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(p.isLeaving(done), isFalse, reason: 'a correction is no flourish');
    await undoing.timeout(TaskProvider.settle * 4);
    expect(
      p.tasksForDay(day).firstWhere((t) => t.id == first.id).done,
      isFalse,
    );
  });

  test('a day keeps the order it was dragged into', () async {
    final p = await provider();
    final start = p.tasksForDay(day);
    expect(start, hasLength(3));

    await p.reorder([start[2], start[0], start[1]]);
    await p.loadMonth(day);
    expect(titles(p), [start[2].title, start[0].title, start[1].title]);

    // And it survives being read back from the database rather than living in
    // whatever the provider happened to be holding.
    final second = TaskProvider();
    await second.loadLists();
    await second.loadMonth(day);
    expect(titles(second), titles(p));
  });

  test(
    'a task added to an arranged day goes after the arranged ones',
    () async {
      final p = await provider();
      final start = p.tasksForDay(day);
      await p.reorder([start[2], start[1], start[0]]);
      await p.add(
        Task(
          listId: p.lists.first.id!,
          title: 'latecomer',
          dueAt: day.millisecondsSinceEpoch,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await p.loadMonth(day);
      expect(titles(p).last, 'latecomer');
    },
  );

  test('the overdue backlog keeps the order it was dragged into', () async {
    await resetTestDatabase();
    final p = TaskProvider();
    await p.loadLists();
    final now = DateTime.now();
    // Three days late, two days late, one day late — so the order they fall
    // into on their own is the reverse of the order they were made in.
    for (var late = 3; late >= 1; late--) {
      await p.add(
        Task(
          listId: p.lists.first.id!,
          title: '$late days late',
          dueAt: dayOf(
            now.subtract(Duration(days: late)),
          ).millisecondsSinceEpoch,
          createdAt: now.millisecondsSinceEpoch,
        ),
      );
    }
    await p.loadTasks();
    expect(
      [for (final t in p.overdue) t.title],
      ['3 days late', '2 days late', '1 days late'],
    );

    final moved = [p.overdue[2], p.overdue[0], p.overdue[1]];
    await p.reorder(moved);
    await p.loadTasks();
    expect(
      [for (final t in p.overdue) t.title],
      ['1 days late', '3 days late', '2 days late'],
      reason: 'the arrangement outranks how late each one is',
    );
  });

  test('one task cannot be reordered, and nothing is written', () async {
    final p = await provider();
    final one = p.tasksForDay(day).first;
    await p.reorder([one]);
    await p.loadMonth(day);
    expect(p.tasksForDay(day).first.sortOrder, isNull);
  });
}

import 'package:caldo/models/task.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/widgets/month_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_db.dart';

void main() {
  initTestDatabase();

  final day = dayOf(DateTime.now().add(const Duration(days: 3)));
  final next = day.add(const Duration(days: 1));

  Future<TaskProvider> provider() async {
    await resetTestDatabase();
    final provider = TaskProvider();
    await provider.loadLists();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final title in ['one', 'two']) {
      await provider.add(
        Task(
          listId: provider.lists.first.id!,
          title: title,
          dueAt: day.millisecondsSinceEpoch,
          createdAt: now,
        ),
      );
    }
    await provider.add(
      Task(
        listId: provider.lists.first.id!,
        title: 'at three',
        dueAt: day.add(const Duration(hours: 15)).millisecondsSinceEpoch,
        hasTime: true,
        createdAt: now,
      ),
    );
    await provider.add(
      Task(
        listId: provider.lists.first.id!,
        title: 'there',
        dueAt: next.millisecondsSinceEpoch,
        createdAt: now,
      ),
    );
    await provider.loadMonth(day);
    return provider;
  }

  List<String> titles(TaskProvider p, DateTime d) => [
    for (final t in p.tasksForDay(d)) t.title,
  ];

  test('a task moved to another day keeps its time of day', () async {
    final p = await provider();
    final timed = p.tasksForDay(day).firstWhere((t) => t.title == 'at three');
    await p.moveToDay(timed, next);
    final moved = p.tasksForDay(next).singleWhere((t) => t.title == 'at three');
    expect(moved.hasTime, isTrue);
    expect(moved.due, next.add(const Duration(hours: 15)));
    expect(titles(p, day), isNot(contains('at three')));
  });

  test(
    'a task dropped among a day\'s tasks keeps the place it was put',
    () async {
      final p = await provider();
      final one = p.tasksForDay(day).firstWhere((t) => t.title == 'one');
      final there = p.tasksForDay(next).single;
      await p.moveToDay(one, next, among: [one, there]);
      expect(titles(p, next), ['one', 'there']);
    },
  );

  test('a task moved without a place lets go of the one it had', () async {
    final p = await provider();
    final one = p.tasksForDay(day).firstWhere((t) => t.title == 'one');
    final two = p.tasksForDay(day).firstWhere((t) => t.title == 'two');
    // Placed by hand on its old day — a placement that means nothing on the
    // new one, where it goes after whatever has been placed, as a new task
    // would.
    await p.reorder([two, one]);
    final placed = p.tasksForDay(day).first;
    expect(placed.sortOrder, isNotNull);
    await p.moveToDay(placed, next);
    final moved = p.tasksForDay(next).singleWhere((t) => t.id == placed.id);
    expect(moved.sortOrder, isNull);
  });

  test('a task moved to No date loses its date and its time', () async {
    final p = await provider();
    await p.loadTasks();
    final timed = p.tasksForDay(day).firstWhere((t) => t.title == 'at three');
    await p.moveToDay(timed, null);
    final moved = p.undated.singleWhere((t) => t.title == 'at three');
    expect(moved.dueAt, isNull);
    expect(moved.hasTime, isFalse);
  });

  group('the month laid out', () {
    // October 2026 starts on a Thursday: three days of September lead it
    // in when the week starts on Monday, and it runs to five rows.
    MonthLayout layout({double collapse = 0, DateTime? selected}) =>
        MonthLayout(
          month: DateTime(2026, 10),
          mondayFirst: true,
          selected: selected ?? DateTime(2026, 10, 19),
          weekCollapse: collapse,
          size: const Size(316, 250),
        );

    test('finds the day under a point, and that day\'s cell', () {
      final l = layout();
      expect(l.rows, 5);
      // 300 points across seven columns inside an 8-point inset.
      final cell = l.rectOf(DateTime(2026, 10, 22))!;
      expect(cell.left, closeTo(8 + 3 * 300 / 7, 0.001));
      expect(cell.top, 3 * 50);
      expect(l.dayAt(cell.center), DateTime(2026, 10, 22));
      expect(l.dayAt(const Offset(10, 5)), DateTime(2026, 9, 28));
      expect(l.dayAt(const Offset(2, 5)), isNull, reason: 'in the inset');
    });

    test('in the week view only the selected week is under the grid', () {
      final l = layout(collapse: 1);
      // One row fills the window, and it is the row of the 19th.
      expect(l.rowHeight, 250);
      expect(l.dayAt(const Offset(10, 100)), DateTime(2026, 10, 19));
      expect(l.rectOf(DateTime(2026, 10, 19))!.top, 0);
      expect(l.rectOf(DateTime(2026, 10, 26))!.top, 250);
    });
  });
}

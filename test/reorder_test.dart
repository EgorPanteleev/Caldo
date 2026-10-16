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
      await provider.add(Task(
        listId: provider.lists.first.id!,
        title: title,
        dueAt: day.millisecondsSinceEpoch,
        createdAt: now,
      ));
    }
    await provider.loadMonth(day);
    return provider;
  }

  List<String> titles(TaskProvider p) =>
      [for (final task in p.tasksForDay(day)) task.title];

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

  test('a task added to an arranged day goes after the arranged ones',
      () async {
    final p = await provider();
    final start = p.tasksForDay(day);
    await p.reorder([start[2], start[1], start[0]]);
    await p.add(Task(
      listId: p.lists.first.id!,
      title: 'latecomer',
      dueAt: day.millisecondsSinceEpoch,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    await p.loadMonth(day);
    expect(titles(p).last, 'latecomer');
  });

  test('the overdue backlog keeps the order it was dragged into', () async {
    await resetTestDatabase();
    final p = TaskProvider();
    await p.loadLists();
    final now = DateTime.now();
    // Three days late, two days late, one day late — so the order they fall
    // into on their own is the reverse of the order they were made in.
    for (var late = 3; late >= 1; late--) {
      await p.add(Task(
        listId: p.lists.first.id!,
        title: '$late days late',
        dueAt: dayOf(now.subtract(Duration(days: late)))
            .millisecondsSinceEpoch,
        createdAt: now.millisecondsSinceEpoch,
      ));
    }
    await p.loadTasks();
    expect([for (final t in p.overdue) t.title],
        ['3 days late', '2 days late', '1 days late']);

    final moved = [p.overdue[2], p.overdue[0], p.overdue[1]];
    await p.reorder(moved);
    await p.loadTasks();
    expect([for (final t in p.overdue) t.title],
        ['1 days late', '3 days late', '2 days late'],
        reason: 'the arrangement outranks how late each one is');
  });

  test('one task cannot be reordered, and nothing is written', () async {
    final p = await provider();
    final one = p.tasksForDay(day).first;
    await p.reorder([one]);
    await p.loadMonth(day);
    expect(p.tasksForDay(day).first.sortOrder, isNull);
  });
}

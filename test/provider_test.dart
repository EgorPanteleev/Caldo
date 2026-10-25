import 'dart:ui' show Color;

import 'package:caldo/models/task_list.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/test_db.dart';

/// Exercises the provider against a real (host-side, temporary) database.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(initTestDatabase);

  setUp(resetTestDatabase);

  test('starts with the default list and no tasks', () async {
    final provider = TaskProvider();
    await provider.loadLists();
    expect(provider.lists.map((l) => l.name), ['Personal']);
    expect(provider.lists.single.taskCount, 0);
  });

  test('counts open and done tasks per list', () async {
    final provider = await seedProvider();
    final work = provider.lists.firstWhere((l) => l.name == 'Work');
    expect(work.taskCount, 3);
    expect(work.openCount, 3);

    await provider.toggleDone(await taskNamed('Someday idea'));
    final after = provider.lists.firstWhere((l) => l.name == 'Work');
    expect(after.taskCount, 3);
    expect(after.openCount, 2);
  });

  test(
    'completing a repeating task rolls it forward instead of closing it',
    () async {
      final provider = await seedProvider();
      final task = await taskNamed('Water');
      final before = task.due!;

      await provider.toggleDone(task);

      final after = await taskNamed('Water');
      expect(after.done, isFalse);
      expect(after.due, before.add(const Duration(days: 7)));
      expect(after.completedAt, isNotNull);
    },
  );

  test('a one-off task is closed and can be reopened', () async {
    final provider = await seedProvider();
    final task = await taskNamed('Ship');

    await provider.toggleDone(task);
    expect((await taskNamed('Ship')).done, isTrue);

    await provider.toggleDone(await taskNamed('Ship'));
    final reopened = await taskNamed('Ship');
    expect(reopened.done, isFalse);
    expect(reopened.completedAt, isNull);
  });

  test('the overview holds dated, overdue and undated tasks', () async {
    final provider = await seedProvider();
    await provider.loadTasks();

    expect(provider.overdue.map((t) => t.title), ['Water']);
    expect(provider.upcoming.map((t) => t.title), ['Ship']);
    // Undated tasks are kept apart from the dated ones.
    expect(provider.upcoming.any((t) => t.title == 'Someday idea'), isFalse);
    expect(provider.undated.map((t) => t.title), ['Someday idea']);
  });

  test('the calendar groups a month by day', () async {
    final provider = await seedProvider();
    final today = dayOf(DateTime.now());
    await provider.loadMonth(today);

    expect(provider.tasksForDay(today).map((t) => t.title), ['Ship']);
    expect(provider.tasksForDay(today.add(const Duration(days: 1))), isEmpty);
  });

  test('search leaves out done tasks when completed ones are hidden', () async {
    final provider = await seedProvider();
    await provider.toggleDone(await taskNamed('Someday idea'));

    provider.setShowCompleted(false);
    expect(await provider.searchAll('someday'), isEmpty);
    provider.setShowCompleted(true);
    expect((await provider.searchAll('someday')).map((t) => t.title), [
      'Someday idea',
    ]);
  });

  test('clearing completed removes only the done tasks', () async {
    final provider = await seedProvider();
    await provider.toggleDone(await taskNamed('Someday idea'));
    final removed = await provider.clearCompleted();
    expect(removed, 1);
    expect(await allTasks(), hasLength(2));
  });

  test('a task moved to another list follows it', () async {
    final provider = await seedProvider();
    final personal = provider.lists.firstWhere((l) => l.name == 'Personal');
    final task = await taskNamed('Ship');

    await provider.update(task.copyWith(listId: personal.id));

    expect((await taskNamed('Ship')).listId, personal.id);
    expect(provider.lists.firstWhere((l) => l.name == 'Personal').taskCount, 1);
  });

  test('a task can carry its own colour, overriding its list', () async {
    final provider = await seedProvider();
    final work = provider.lists.firstWhere((l) => l.name == 'Work');
    final task = await taskNamed('Ship');

    await provider.update(task.copyWith(styleId: 'pink'));

    final stored = await taskNamed('Ship');
    expect(stored.styleId, 'pink');
    expect(
      colorOfTask(stored, work, fallback: const Color(0xFF000000)),
      ListStyle.byId('pink').color,
    );

    // Cleared, it falls back to the colour of its list.
    await provider.update(stored.copyWith(clearStyleId: true));
    final plain = await taskNamed('Ship');
    expect(plain.styleId, isNull);
    expect(
      colorOfTask(plain, work, fallback: const Color(0xFF000000)),
      work.style.color,
    );
  });
}

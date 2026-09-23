import 'package:caldo/models/task.dart';
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

    await provider.toggleDone(
      provider.tasks.firstWhere((t) => t.title == 'Someday idea'),
    );
    final after = provider.lists.firstWhere((l) => l.name == 'Work');
    expect(after.taskCount, 3);
    expect(after.openCount, 2);
  });

  test('completing a repeating task rolls it forward instead of closing it',
      () async {
    final provider = await seedProvider();
    final task = provider.tasks.firstWhere((t) => t.title == 'Water');
    final before = task.due!;

    await provider.toggleDone(task);

    final after = provider.tasks.firstWhere((t) => t.title == 'Water');
    expect(after.done, isFalse);
    expect(after.due, before.add(const Duration(days: 7)));
    expect(after.completedAt, isNotNull);
  });

  test('a one-off task is closed and can be reopened', () async {
    final provider = await seedProvider();
    final task = provider.tasks.firstWhere((t) => t.title == 'Ship');

    await provider.toggleDone(task);
    expect(provider.tasks.firstWhere((t) => t.title == 'Ship').done, isTrue);

    await provider.toggleDone(
      provider.tasks.firstWhere((t) => t.title == 'Ship'),
    );
    final reopened = provider.tasks.firstWhere((t) => t.title == 'Ship');
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

  test('search filters the open list', () async {
    final provider = await seedProvider();
    await provider.search('ship');
    expect(provider.tasks.map((t) => t.title), ['Ship']);
    await provider.search('');
    expect(provider.tasks.length, 3);
  });

  test('hiding completed tasks drops them from the list', () async {
    final provider = await seedProvider();
    await provider.toggleDone(
      provider.tasks.firstWhere((t) => t.title == 'Someday idea'),
    );
    await provider.setShowCompleted(false);
    expect(provider.tasks.any((t) => t.title == 'Someday idea'), isFalse);
    await provider.setShowCompleted(true);
    expect(provider.tasks.any((t) => t.title == 'Someday idea'), isTrue);
  });

  test('clearing completed removes only the done tasks', () async {
    final provider = await seedProvider();
    await provider.toggleDone(
      provider.tasks.firstWhere((t) => t.title == 'Someday idea'),
    );
    final removed = await provider.clearCompleted();
    expect(removed, 1);
    expect(provider.tasks.length, 2);
  });

  test('deleting a list takes its tasks with it', () async {
    final provider = await seedProvider();
    final work = provider.lists.firstWhere((l) => l.name == 'Work');

    await provider.removeList(work.id!);

    expect(provider.lists.map((l) => l.name), ['Personal']);
    expect(provider.currentListId, isNull);
    expect(provider.tasks, isEmpty);
    await provider.loadTasks();
    expect(provider.overdue, isEmpty);
    expect(provider.upcoming, isEmpty);
  });

  test('a renamed list keeps its tasks', () async {
    final provider = await seedProvider();
    final work = provider.lists.firstWhere((l) => l.name == 'Work');

    await provider.updateList(work.copyWith(name: 'Office', styleId: 'teal'));

    final renamed = provider.lists.firstWhere((l) => l.id == work.id);
    expect(renamed.name, 'Office');
    expect(renamed.style.id, 'teal');
    expect(renamed.taskCount, 3);
  });

  test('a task moved to another list follows it', () async {
    final provider = await seedProvider();
    final personal = provider.lists.firstWhere((l) => l.name == 'Personal');
    final task = provider.tasks.firstWhere((t) => t.title == 'Ship');

    await provider.update(task.copyWith(listId: personal.id));

    expect(provider.tasks.any((t) => t.title == 'Ship'), isFalse);
    expect(
      provider.lists.firstWhere((l) => l.name == 'Personal').taskCount,
      1,
    );
  });

  test('a new list starts empty and can be opened', () async {
    final provider = TaskProvider();
    await provider.loadLists();
    final created = await provider.addList(TaskList(
      name: 'Errands',
      styleId: 'green',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    await provider.openList(created.id!);

    expect(provider.currentList?.name, 'Errands');
    expect(provider.tasks, isEmpty);

    await provider.add(Task(
      listId: created.id!,
      title: 'Post the parcel',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    expect(provider.tasks.single.title, 'Post the parcel');
  });
}

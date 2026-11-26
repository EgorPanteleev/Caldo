import 'dart:ui' show Color;

import 'package:caldo/db/database.dart';
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

  test('a tick keeps what changed since the card was read', () async {
    final provider = await seedProvider();
    final card = await taskNamed('Someday idea');
    // An agent's answer lands in the notes after the card was drawn.
    await AppDatabase.instance.update(card.copyWith(notes: 'The answer'));
    await provider.toggleDone(card);
    final ticked = await taskNamed('Someday idea');
    expect(ticked.done, isTrue);
    expect(ticked.notes, 'The answer');
  });

  test('tasks sent to agents are marked and put in progress', () async {
    final provider = await seedProvider();
    await provider.toggleDone(await taskNamed('Someday idea'));
    final ship = await taskNamed('Ship');
    final idea = await taskNamed('Someday idea');
    expect(idea.done, isTrue);

    await provider.sentToAgents({ship: 'Opus', idea: 'Codex · gpt-5'});

    final shipAfter = await taskNamed('Ship');
    expect(shipAfter.agent, 'Opus');
    expect(shipAfter.stage, Stage.inProgress);
    // Done, it is opened again: an agent is working on it.
    final ideaAfter = await taskNamed('Someday idea');
    expect(ideaAfter.agent, 'Codex · gpt-5');
    expect(ideaAfter.stage, Stage.inProgress);
    // Nothing the watcher takes a task up by.
    expect(shipAfter.claude, isNull);

    // Sent again, one already in progress keeps its start.
    await provider.sentToAgents({shipAfter: 'Sonnet'});
    final again = await taskNamed('Ship');
    expect(again.agent, 'Sonnet');
    expect(again.startedAt, shipAfter.startedAt);
    // Waiting for its worker to take it up.
    expect(again.agentState, AgentState.waiting);
  });

  test('a task sent to start when due waits as it is', () async {
    final provider = await seedProvider();
    final ship = await taskNamed('Ship');
    expect(ship.stage, Stage.notStarted);

    await provider.sentToAgents({ship: 'Opus'}, later: {ship});

    final after = await taskNamed('Ship');
    expect(after.agent, 'Opus');
    expect(after.agentState, AgentState.waiting);
    // Not begun: its worker puts it in progress once it starts it.
    expect(after.stage, Stage.notStarted);
  });

  test('high priority leads a day nobody has arranged', () async {
    final provider = TaskProvider();
    await provider.loadLists();
    final day = dayOf(DateTime.now()).add(const Duration(days: 2));
    final list = provider.lists.first.id!;
    Future<void> add(String title, Priority priority, {int? hour}) =>
        provider.add(
          Task(
            listId: list,
            title: title,
            priority: priority,
            dueAt: (hour == null ? day : day.add(Duration(hours: hour)))
                .millisecondsSinceEpoch,
            hasTime: hour != null,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
    await add('Morning', Priority.none, hour: 8);
    await add('All day', Priority.low);
    await add('Urgent', Priority.high, hour: 18);
    await add('Soon', Priority.medium, hour: 12);
    List<String> titles() => [
      for (final t in provider.allUpcomingByDay[day]!) t.title,
    ];
    expect(titles(), ['Urgent', 'Soon', 'All day', 'Morning']);

    // Dragged into an order of its own, the day keeps it.
    final ids = [
      for (final t in provider.allUpcomingByDay[day]!.reversed) t.id!,
    ];
    await AppDatabase.instance.setOrder(ids);
    await provider.loadTasks();
    expect(titles(), ['Morning', 'All day', 'Soon', 'Urgent']);
  });

  test('high priority leads the overdue backlog too', () async {
    final provider = TaskProvider();
    await provider.loadLists();
    final list = provider.lists.first.id!;
    final today = dayOf(DateTime.now());
    Future<void> add(String title, int daysAgo, Priority priority) =>
        provider.add(
          Task(
            listId: list,
            title: title,
            priority: priority,
            dueAt: today
                .subtract(Duration(days: daysAgo))
                .millisecondsSinceEpoch,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
    await add('Oldest', 5, Priority.none);
    await add('Urgent', 1, Priority.high);
    await add('Older', 3, Priority.none);
    expect(provider.allOverdue.map((t) => t.title), [
      'Urgent',
      'Oldest',
      'Older',
    ]);
  });

  test('search folds case in any alphabet', () async {
    final provider = TaskProvider();
    await provider.loadLists();
    final list = provider.lists.first.id!;
    for (final title in ['Купить хлеб', 'Сдать отчёт']) {
      await provider.add(Task(listId: list, title: title, createdAt: 0));
    }
    Future<List<String>> find(String query) async => [
      for (final t in await provider.searchAll(query)) t.title,
    ];
    expect(await find('купить'), ['Купить хлеб']);
    expect(await find('ХЛЕБ'), ['Купить хлеб']);
    expect(await find('сдать'), ['Сдать отчёт']);
  });

  test('done tasks can be kept off the screens, not off the widget', () async {
    final provider = await seedProvider();
    await provider.toggleDone(await taskNamed('Ship'));
    final day = (await taskNamed('Ship')).dueDay!;
    expect(provider.upcomingByDay[day]?.map((t) => t.title), ['Ship']);

    provider.setShowCompleted(false);
    expect(provider.upcomingByDay[day], isNull);
    expect(provider.upcoming.any((t) => t.done), isFalse);
    expect(provider.allUpcomingByDay[day]?.map((t) => t.title), ['Ship']);
    expect(await provider.searchAll('Ship'), isEmpty);

    provider.setShowCompleted(true);
    expect(provider.upcomingByDay[day]?.map((t) => t.title), ['Ship']);
  });

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

  test('the calendar keeps the months either side of it read', () async {
    // Both neighbours are on screen while the grid is swiped, and the month
    // changes halfway: the one going out lost its tasks as it went.
    final provider = TaskProvider();
    await provider.loadLists();
    final month = DateTime(2026, 11);
    final before = DateTime(2026, 10, 3);
    final after = DateTime(2026, 12, 28);
    for (final day in [before, after]) {
      await provider.add(
        Task(
          listId: provider.lists.first.id!,
          title: 'on ${day.month}',
          dueAt: day.millisecondsSinceEpoch,
          createdAt: 0,
        ),
      );
    }
    await provider.loadMonth(month);
    expect(provider.tasksForDay(before).map((t) => t.title), ['on 10']);
    expect(provider.tasksForDay(after).map((t) => t.title), ['on 12']);
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

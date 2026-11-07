import 'package:caldo/db/database.dart';
import 'package:caldo/models/task.dart';
import 'package:caldo/models/task_list.dart';
import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/test_db.dart';

/// Groups: one per task, and what the screens can be narrowed to.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(initTestDatabase);

  setUp(resetTestDatabase);

  Future<TaskList> group(TaskProvider p, String name) => p.addList(
    TaskList(name: name, createdAt: DateTime.now().millisecondsSinceEpoch),
  );

  test('the screens can show one group, and nothing else follows', () async {
    final today = dayOf(DateTime.now());
    final provider = TaskProvider();
    await provider.loadLists();
    final uni = await group(provider, 'University');
    final friends = await group(provider, 'Friends');
    Future<void> add(String title, int list, {int days = 0}) => provider.add(
      Task(
        listId: list,
        title: title,
        dueAt: today.add(Duration(days: days)).millisecondsSinceEpoch,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await add('Essay', uni.id!);
    await add('Lecture', uni.id!, days: 1);
    await add('Pizza', friends.id!);
    await add('Laundry', provider.defaultGroup);
    await add('Old reading', uni.id!, days: -3);

    String titles(Map<DateTime, List<Task>> days) => [
      for (final day in days.keys.toList()..sort())
        for (final t in days[day]!) t.title,
    ].join(', ');

    provider.showGroup(uni.id);
    expect(titles(provider.upcomingByDay), 'Essay, Lecture');
    expect(provider.overdue.map((t) => t.title), ['Old reading']);
    expect(provider.tasksForDay(today).map((t) => t.title), ['Essay']);
    expect(provider.groupForNew, uni.id);
    // The widget and the menu's dot still see everything.
    expect(titles(provider.allUpcomingByDay), contains('Pizza'));
    expect(provider.allOverdue, hasLength(1));

    provider.showGroup(null);
    expect(titles(provider.upcomingByDay), contains('Laundry'));
    expect(provider.groupForNew, provider.defaultGroup);
  });

  test('deleting a group keeps its tasks, in the default group', () async {
    final provider = TaskProvider();
    await provider.loadLists();
    final friends = await group(provider, 'Friends');
    await provider.add(Task(listId: friends.id!, title: 'Pizza', createdAt: 1));
    provider.showGroup(friends.id);

    await provider.deleteList(friends.id!);
    expect(provider.lists.map((l) => l.name), ['Personal']);
    expect((await taskNamed('Pizza')).listId, provider.defaultGroup);
    expect(provider.group, isNull);

    // The default group is the one thing that cannot go.
    await provider.deleteList(provider.defaultGroup);
    expect(provider.lists, hasLength(1));
  });

  test('the colour new tasks used to start in becomes the default '
      "group's", () async {
    SharedPreferences.setMockInitialValues({'default_task_style': 'green'});
    await SettingsProvider().load();
    final lists = await AppDatabase.instance.getLists();
    expect(lists.first.styleId, 'green');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('default_task_style'), isNull);
  });
}

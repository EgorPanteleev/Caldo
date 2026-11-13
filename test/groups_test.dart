import 'package:caldo/db/database.dart';
import 'package:caldo/models/task.dart';
import 'package:caldo/models/task_list.dart';
import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/widgets/groups.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/test_db.dart';

/// Groups: one per task, and what the screens can be narrowed to.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(initTestDatabase);

  setUp(resetTestDatabase);

  Future<TaskList> makeGroup(TaskProvider p, String name) => p.addList(
    TaskList(name: name, createdAt: DateTime.now().millisecondsSinceEpoch),
  );

  test('the screens can show one group, and nothing else follows', () async {
    final today = dayOf(DateTime.now());
    final provider = TaskProvider();
    await provider.loadLists();
    final uni = await makeGroup(provider, 'University');
    final friends = await makeGroup(provider, 'Friends');
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
    final friends = await makeGroup(provider, 'Friends');
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

  test('the groups keep the order they are dragged into, and the default '
      'stays the oldest', () async {
    final provider = TaskProvider();
    await provider.loadLists();
    final personal = provider.defaultGroup;
    final uni = await makeGroup(provider, 'University');
    await makeGroup(provider, 'Friends');

    await provider.reorderLists([
      uni,
      ...provider.lists.where((l) => l.id != uni.id),
    ]);
    await provider.loadLists();
    expect(provider.lists.map((l) => l.name), [
      'University',
      'Personal',
      'Friends',
    ]);
    expect(provider.defaultGroup, personal);

    // One made after the arranging goes at the end, where its plus was.
    await makeGroup(provider, 'Gym');
    expect(provider.lists.last.name, 'Gym');
  });

  group('the row of chips', () {
    Future<TaskProvider> pumpChips(WidgetTester tester) async {
      late TaskProvider provider;
      await tester.runAsync(() async {
        provider = TaskProvider();
        await provider.loadLists();
        await makeGroup(provider, 'University');
        await makeGroup(provider, 'Friends');
      });
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            theme: AppTheme.dark(AppAccent.presets.first),
            home: const Scaffold(
              body: Center(
                child: SizedBox(width: double.infinity, child: GroupChips()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return provider;
    }

    testWidgets('a chip held and carried moves along the row', (tester) async {
      final provider = await pumpChips(tester);
      final from = tester.getCenter(find.text('Friends'));
      final to = tester.getCenter(find.text('Personal'));
      final gesture = await tester.startGesture(from);
      await tester.pump(const Duration(milliseconds: 600));
      for (var i = 1; i <= 10; i++) {
        await gesture.moveTo(
          Offset.lerp(from, to - const Offset(30, 0), i / 10)!,
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(provider.lists.map((l) => l.name), [
        'Friends',
        'Personal',
        'University',
      ]);
      expect(find.byKey(groupNameFieldKey), findsNothing);
    });

    testWidgets('a chip held and let go where it was opens it', (tester) async {
      final provider = await pumpChips(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('University')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byKey(groupNameFieldKey), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(groupNameFieldKey))
            .controller!
            .text,
        'University',
      );
      expect(provider.lists.map((l) => l.name), [
        'Personal',
        'University',
        'Friends',
      ]);
    });
  });
}

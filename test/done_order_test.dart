import 'package:caldo/models/task.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(initTestDatabase);

  setUp(resetTestDatabase);

  test('a day\'s done tasks are in the order they were ticked', () async {
    final today = dayOf(DateTime.now());
    final provider = TaskProvider();
    await provider.loadLists();
    for (final (i, title) in ['First', 'Second', 'Third'].indexed) {
      await provider.add(
        Task(
          listId: 1,
          title: title,
          dueAt: today.millisecondsSinceEpoch,
          createdAt: i,
        ),
      );
    }
    await provider.loadMonth(today);

    Task named(String title) =>
        provider.tasksForDay(today).firstWhere((t) => t.title == title);

    // Ticked oldest first: by creation, newest first, they would come out
    // the other way round.
    await provider.toggleDone(named('First'));
    await provider.toggleDone(named('Third'));

    expect(provider.tasksForDay(today).map((t) => t.title), [
      'Second',
      'First',
      'Third',
    ]);
  });
}

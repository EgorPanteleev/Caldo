import 'package:caldo/models/task.dart';
import 'package:caldo/models/task_list.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/widgets/task_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final list = TaskList(id: 1, name: 'Work', createdAt: 0);

  Future<void> pumpRow(
    WidgetTester tester,
    Task task, {
    VoidCallback? onToggle,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(AppAccent.presets.first),
        home: Scaffold(
          body: TaskRow(
            task: task,
            list: list,
            showList: true,
            onTap: () {},
            onLongPress: () {},
            onToggle: onToggle ?? () {},
          ),
        ),
      ),
    );
  }

  testWidgets('shows the title, the list and the repeat rule', (tester) async {
    await pumpRow(
      tester,
      Task(
        id: 1,
        listId: 1,
        title: 'Stand-up',
        dueAt: DateTime.now().millisecondsSinceEpoch,
        repeat: Repeat.daily,
        createdAt: 0,
      ),
    );
    expect(find.text('Stand-up'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Every day'), findsOneWidget);
    expect(find.textContaining('Today'), findsOneWidget);
  });

  testWidgets('strikes through a completed task', (tester) async {
    await pumpRow(
      tester,
      const Task(
        id: 2,
        listId: 1,
        title: 'Done thing',
        done: true,
        createdAt: 0,
      ),
    );
    final text = tester.widget<Text>(find.text('Done thing'));
    expect(text.style?.decoration, TextDecoration.lineThrough);
  });

  testWidgets('tapping the circle ticks the task off', (tester) async {
    var toggled = 0;
    await pumpRow(
      tester,
      const Task(id: 3, listId: 1, title: 'Tick me', createdAt: 0),
      onToggle: () => toggled++,
    );
    await tester.tap(find.byKey(checkKey));
    expect(toggled, 1);
  });

  testWidgets('a priority flag only shows when one is set', (tester) async {
    await pumpRow(
      tester,
      const Task(id: 4, listId: 1, title: 'Plain', createdAt: 0),
    );
    expect(find.byType(PriorityFlag), findsNothing);

    await pumpRow(
      tester,
      const Task(
        id: 5,
        listId: 1,
        title: 'Urgent',
        priority: Priority.high,
        createdAt: 0,
      ),
    );
    expect(find.byType(PriorityFlag), findsOneWidget);
  });
}

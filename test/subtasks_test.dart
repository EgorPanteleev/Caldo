import 'package:caldo/db/database.dart';
import 'package:caldo/models/task.dart';
import 'package:caldo/models/task_list.dart';
import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/screens/task_edit_screen.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/widgets/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/test_db.dart';

/// Keeps what the widgets would have written instead of writing it.
class _Capture extends TaskProvider {
  Task? added;
  Task? updated;

  @override
  Future<void> add(Task task) async => added = task;

  @override
  Future<void> update(Task task) async => updated = task;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(initTestDatabase);

  setUp(resetTestDatabase);

  const steps = [Subtask('Buy paint', done: true), Subtask('Paint the fence')];

  test('a checklist is stored with its task and read back in order', () async {
    final db = AppDatabase.instance;
    await db.insert(
      const Task(listId: 1, title: 'Fence', createdAt: 0, subtasks: steps),
    );

    final read = (await db.getTasks()).single;
    expect(read.subtasks, steps);
    expect(read.subtasksDone, 1);
  });

  test('a checklist that cannot be read leaves the task readable', () {
    final task = Task.fromMap({
      'id': 1,
      'title': 'Fence',
      'created_at': 0,
      'subtasks': 'not json',
    });
    expect(task.title, 'Fence');
    expect(task.subtasks, isEmpty);
  });

  test('a database from before checklists is brought up to date', () async {
    // The v3 tasks table, as a phone updating from 2.0.5 has it.
    await AppDatabase.instance.close();
    final path = '${await databaseFactory.getDatabasesPath()}/caldo.db';
    final old = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE lists (id INTEGER PRIMARY KEY AUTOINCREMENT, '
            "name TEXT NOT NULL, style_id TEXT NOT NULL DEFAULT 'violet', "
            'created_at INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE tasks (id INTEGER PRIMARY KEY AUTOINCREMENT, '
            'list_id INTEGER NOT NULL DEFAULT 1, title TEXT NOT NULL, '
            "notes TEXT NOT NULL DEFAULT '', due_at INTEGER, "
            'has_time INTEGER NOT NULL DEFAULT 0, '
            'done INTEGER NOT NULL DEFAULT 0, '
            'priority INTEGER NOT NULL DEFAULT 0, '
            "repeat_rule TEXT NOT NULL DEFAULT 'none', style_id TEXT, "
            'created_at INTEGER NOT NULL, completed_at INTEGER, '
            'sort_order INTEGER)',
          );
          await db.insert('tasks', {'title': 'Old one', 'created_at': 0});
        },
      ),
    );
    await old.close();

    final db = AppDatabase.instance;
    expect((await db.getTasks()).single.subtasks, isEmpty);
    await db.insert(
      const Task(listId: 1, title: 'New one', createdAt: 1, subtasks: steps),
    );
    final read = await db.getTasks();
    expect(read.firstWhere((t) => t.title == 'New one').subtasks, steps);
  });

  test('search finds a task by a step on its checklist', () async {
    final db = AppDatabase.instance;
    await db.insert(
      const Task(listId: 1, title: 'Fence', createdAt: 0, subtasks: steps),
    );
    await db.insert(const Task(listId: 1, title: 'Call mum', createdAt: 1));

    expect((await db.getTasks(query: 'paint')).map((t) => t.title), ['Fence']);
    // The checklist is stored as JSON: its keys are not words in it.
    expect(await db.getTasks(query: 'done'), isEmpty);
    expect(await db.getTasks(query: 'title'), isEmpty);
  });

  test(
    'a repeating task comes round again with its checklist unticked',
    () async {
      final provider = await seedProvider();
      final water = await taskNamed('Water');
      await provider.update(
        water.copyWith(
          subtasks: const [
            Subtask('Kitchen', done: true),
            Subtask('Balcony', done: true),
          ],
        ),
      );

      await provider.toggleDone(await taskNamed('Water'));

      final after = await taskNamed('Water');
      expect(after.subtasks.map((s) => s.title), ['Kitchen', 'Balcony']);
      expect(after.subtasksDone, 0);
    },
  );

  testWidgets('a card counts its checklist and ticks a step where it stands', (
    tester,
  ) async {
    final capture = _Capture();
    await tester.pumpWidget(
      ChangeNotifierProvider<TaskProvider>.value(
        value: capture,
        child: MaterialApp(
          theme: AppTheme.dark(AppAccent.presets.first),
          home: Scaffold(
            body: TaskCard(
              task: const Task(
                id: 1,
                listId: 1,
                title: 'Fence',
                createdAt: 0,
                subtasks: steps,
              ),
              list: TaskList(id: 1, name: 'Work', createdAt: 0),
              onTap: () {},
              onToggle: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('1/2'), findsOneWidget);
    // Closed, the steps are not on the card.
    expect(find.text('Paint the fence'), findsNothing);

    await tester.tap(find.byKey(subtaskCountKey));
    await tester.pumpAndSettle();
    expect(find.text('Buy paint'), findsOneWidget);

    await tester.tap(find.text('Paint the fence'));
    await tester.pump();
    expect(capture.updated?.subtasks, const [
      Subtask('Buy paint', done: true),
      Subtask('Paint the fence', done: true),
    ]);
  });

  testWidgets('the form writes a checklist a line at a time', (tester) async {
    final capture = _Capture();
    tester.view.physicalSize = const Size(960, 1920);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<TaskProvider>.value(value: capture),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(AppAccent.presets.first),
          home: const TaskEditScreen(),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextFormField).first, 'Fence');
    final field = find.byKey(newSubtaskFieldKey);
    await tester.ensureVisible(field);
    await tester.enterText(field, 'Buy paint');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // Filed as a step of its own, with the field cleared and still held for
    // the next one.
    expect(find.widgetWithText(TextField, 'Buy paint'), findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);

    // Left typed without Enter, the last line is still a step.
    await tester.enterText(field, 'Paint the fence');
    // Let go of the field first, or it scrolls itself back into view.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -800));
    await tester.pumpAndSettle();
    final save = find.text('Save');
    await tester.tap(save);
    await tester.pump();

    expect(capture.added?.title, 'Fence');
    expect(capture.added?.subtasks, const [
      Subtask('Buy paint'),
      Subtask('Paint the fence'),
    ]);
  });
}

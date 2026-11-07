import 'package:caldo/db/database.dart';
import 'package:caldo/models/task.dart';
import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/screens/board_screen.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/test_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initTestDatabase);
  setUp(resetTestDatabase);

  group('a task on the board', () {
    final now = DateTime(2026, 11, 4, 12).millisecondsSinceEpoch;
    final task = Task(
      id: 1,
      listId: 1,
      title: 'Essay',
      dueAt: DateTime(2026, 11, 4).millisecondsSinceEpoch,
      createdAt: 0,
    );

    test('is in progress once started, and a tick ends that', () {
      final started = task.toStage(Stage.inProgress, now);
      expect(started.stage, Stage.inProgress);
      expect(started.startedAt, now);

      final done = started.toStage(Stage.done, now);
      expect(done.stage, Stage.done);
      expect(done.startedAt, isNull);
      // A tick from anywhere else ends it too.
      expect(started.completed(now).startedAt, isNull);
    });

    test('a repeating one carried into Done rolls on, not started', () {
      final weekly = task
          .copyWith(repeat: Repeat.weekly)
          .toStage(Stage.inProgress, now);
      final next = weekly.toStage(Stage.done, now);
      expect(next.stage, Stage.notStarted);
      expect(next.dueDay, DateTime(2026, 11, 11));
    });

    test('carried out of Done is the tick taken back', () {
      final done = task.toStage(Stage.done, now);
      expect(done.toStage(Stage.notStarted, now).stage, Stage.notStarted);
      final again = done.toStage(Stage.inProgress, now);
      expect(again.stage, Stage.inProgress);
      expect(again.completedAt, isNull);
    });
  });

  test('moving between columns is written, and Done is logged', () async {
    final provider = await seedProvider();
    Future<List<String>> log() async => [
      for (final c in await AppDatabase.instance.getCompletions(0)) c.title,
    ];

    await provider.moveToStage(await taskNamed('Ship'), Stage.inProgress);
    final started = await taskNamed('Ship');
    expect(started.stage, Stage.inProgress);
    // The form writes a task back whole, so the start goes with it.
    await provider.update(started.copyWith(notes: 'changed'));
    expect((await taskNamed('Ship')).stage, Stage.inProgress);

    await provider.moveToStage(await taskNamed('Ship'), Stage.done);
    expect((await taskNamed('Ship')).stage, Stage.done);
    expect(await log(), ['Ship']);

    await provider.moveToStage(await taskNamed('Ship'), Stage.inProgress);
    expect((await taskNamed('Ship')).stage, Stage.inProgress);
    expect(await log(), isEmpty);
  });

  testWidgets('three columns, and a card carried across moves', (tester) async {
    // A small phone, so a column that overflows fails the run.
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    late TaskProvider provider;
    await tester.runAsync(() async {
      provider = await seedProvider();
      await provider.moveToStage(await taskNamed('Water'), Stage.inProgress);
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<TaskProvider>.value(value: provider),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(AppAccent.presets.first),
          home: const BoardScreen(),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    double columnOf(String title) => tester.getCenter(find.text(title)).dx;
    // The lanes are headed in capitals, the count in the same line.
    double laneOf(String name) =>
        tester.getCenter(find.textContaining(name, findRichText: true)).dx;
    final notStarted = laneOf('NOT STARTED');
    final inProgress = laneOf('IN PROGRESS');
    final done = laneOf('DONE');
    expect(notStarted < inProgress && inProgress < done, isTrue);

    final third = tester.getSize(find.byType(BoardScreen)).width / 3;
    bool under(String title, double column) =>
        (columnOf(title) - column).abs() < third / 2;
    expect(under('Ship', notStarted), isTrue);
    expect(under('Water', inProgress), isTrue);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Ship')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(
      Offset(
        done,
        tester.getCenter(find.textContaining('DONE', findRichText: true)).dy +
            80,
      ),
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();

    // Drawn in its new column at once, before the write lands.
    expect(find.text('Ship'), findsOneWidget);
    expect(under('Ship', done), isTrue);

    await tester.runAsync(() async {
      for (var i = 0; i < 50; i++) {
        if ((await taskNamed('Ship')).done) return;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.runAsync(
      () async => expect((await taskNamed('Ship')).done, isTrue),
    );
  });
}

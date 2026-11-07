import 'package:caldo/db/database.dart';
import 'package:caldo/models/task.dart';
import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/screens/board_screen.dart';
import 'package:caldo/screens/tasks_screen.dart';
import 'package:caldo/widgets/task_card.dart';
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

  testWidgets('three lanes, and a card carried across moves', (tester) async {
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

    // The lanes are headed in capitals, the count in the same line, and
    // the titles stand in line under the name of the lane they are in.
    final lane = find.textContaining('NOT STARTED', findRichText: true);
    final next = find.textContaining('IN PROGRESS', findRichText: true);
    double left(Finder f) => tester.getTopLeft(f).dx;
    bool under(String title, Finder header) =>
        (left(find.text(title)) - left(header)).abs() < 1;
    expect(under('Ship', lane), isTrue);
    expect(under('Water', next), isTrue);

    // A lane is most of the screen wide, and the next one shows beside it.
    final width = tester.getSize(find.byType(BoardScreen)).width;
    expect(left(next), greaterThan(width * 0.8));
    expect(left(next), lessThan(width));

    // Carried to the side and held there, the board turns towards Done.
    final y = tester.getCenter(find.text('Ship')).dy;
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Ship')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(Offset(width - 10, y));
    await tester.pump();
    for (var i = 0; i < 2; i++) {
      await tester.pump(const Duration(milliseconds: 950));
      await tester.pump(const Duration(milliseconds: 400));
    }
    final done = find.textContaining('DONE', findRichText: true);
    expect(left(done), lessThan(width / 2));

    await gesture.moveTo(Offset(left(done) + 60, y));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    // Drawn in its new lane at once, before the write lands.
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

  testWidgets('a task in progress says so on Schedule', (tester) async {
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
          home: const TasksScreen(),
        ),
      ),
    );
    await tester.pump();

    Finder badgeOn(String title) => find.descendant(
      of: find.ancestor(of: find.text(title), matching: find.byType(TaskCard)),
      matching: find.byType(InProgressBadge),
    );
    expect(badgeOn('Water'), findsOneWidget);
    expect(badgeOn('Ship'), findsNothing);
  });
}

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
    final lane = find.textContaining('NOT STARTED   ', findRichText: true);
    final next = find.textContaining('IN PROGRESS   ', findRichText: true);
    double left(Finder f) => tester.getTopLeft(f).dx;
    bool under(String title, Finder header) =>
        (left(find.text(title)) - left(header)).abs() < 1;
    expect(under('Ship', lane), isTrue);
    expect(under('Water', next), isTrue);

    // A lane is most of the screen wide, and the next one shows beside it.
    final width = tester.getSize(find.byType(BoardScreen)).width;
    expect(left(next), greaterThan(width * 0.8));
    expect(left(next), lessThan(width));

    // Nothing to drop on until a card is picked up; then a target for each
    // lane along the foot, so Done can be reached without the board turning.
    Finder target(String name) => find.text(name);
    bool hittable(Finder f) => f.hitTestable().evaluate().isNotEmpty;
    expect(hittable(target('DONE')), isFalse);

    Future<void> carry(String title, String to) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.text(title)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 300));
      expect(hittable(target(to)), isTrue);
      await gesture.moveTo(tester.getCenter(target(to)));
      await tester.pump();
      // The card is carried where it was held, a lane wide, so over the
      // bar it lets the targets show through it.
      final carried = tester.widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.text(title).last,
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      );
      expect(carried.opacity, lessThan(1));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> waitFor(String title, Stage stage) =>
        tester.runAsync(() async {
          for (var i = 0; i < 50; i++) {
            if ((await taskNamed(title)).stage == stage) return;
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect((await taskNamed(title)).stage, stage);
        });

    // Taken towards a side, the card turns the board that way at once —
    // well before the screen's edge, and with no holding still there.
    final home = left(lane);
    final lifted = await tester.startGesture(
      tester.getCenter(find.text('Ship')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    final y = tester.getCenter(find.text('Ship').first).dy;
    await lifted.moveTo(Offset(width * 0.85, y));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(left(next), lessThan(width / 2));
    await lifted.moveTo(Offset(width * 0.15, y));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(left(lane), closeTo(home, 1));
    // Let go over its own lane, which takes nothing.
    await lifted.moveTo(Offset(width / 3, y));
    await tester.pump();
    await lifted.up();
    await tester.pumpAndSettle();
    expect(left(lane), closeTo(home, 1));

    await carry('Ship', 'DONE');
    // The bar's Done reaches into the side, and the board stays put for it.
    expect(left(lane), closeTo(home, 1));
    // In its new lane at once, before the write lands.
    final done = find.textContaining('DONE   ', findRichText: true);
    expect(find.text('Ship'), findsOneWidget);
    expect(under('Ship', done), isTrue);
    await waitFor('Ship', Stage.done);

    // From In progress back to Not started, the lane that is off the
    // screen to the left — the one there was no way back to.
    await tester.fling(find.byKey(boardLanesKey), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(left(next), lessThan(width / 2));
    // Centred, with as much of the lane on either side of it showing. The
    // header stands as far into its lane as it did in the first, which was
    // a margin in from the screen's edge.
    const margin = 10.0;
    final inset = home - margin;
    final from = left(next) - inset;
    final before = from - margin;
    final after = width - (from + width * 0.84 - margin) - margin;
    expect(before, greaterThan(16));
    expect(before, closeTo(after, 1));
    await carry('Water', 'NOT STARTED');
    expect(find.text('Water'), findsOneWidget);
    expect(under('Water', lane), isTrue);
    await waitFor('Water', Stage.notStarted);

    // The write started from the screen finishes its reads in the test's
    // clock; let them, so none of their timers outlives the test.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
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

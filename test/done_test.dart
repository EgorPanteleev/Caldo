import 'package:caldo/db/database.dart';
import 'package:caldo/models/completion.dart';
import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/screens/done_screen.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initTestDatabase);
  setUp(resetTestDatabase);

  Completion at(DateTime when) => Completion(
    taskId: 1,
    title: 'x',
    listId: 1,
    doneAt: when.millisecondsSinceEpoch,
  );

  group('the figures over the log', () {
    // A Wednesday.
    final now = DateTime(2026, 11, 4, 18);

    test('today, this week and the last seven days', () {
      final stats = DoneStats.of([
        at(DateTime(2026, 11, 4, 9)),
        at(DateTime(2026, 11, 4, 10)),
        at(DateTime(2026, 11, 2, 12)), // Monday
        at(DateTime(2026, 11, 1, 12)), // Sunday, last week from Monday
        at(DateTime(2026, 10, 20, 12)), // out of the seven days
      ], now);
      expect(stats.today, 2);
      expect(stats.week, 3);
      expect(stats.lastSeven, [0, 0, 0, 1, 1, 0, 2]);

      // A week begun on Sunday takes that Sunday in.
      expect(
        DoneStats.of(
          [at(DateTime(2026, 11, 1, 12)), at(DateTime(2026, 11, 4, 9))],
          now,
          mondayFirst: false,
        ).week,
        2,
      );
    });

    test('a streak runs back from today, or from yesterday until today '
        'has a tick of its own', () {
      final run = [
        at(DateTime(2026, 11, 3, 9)),
        at(DateTime(2026, 11, 2, 9)),
        at(DateTime(2026, 11, 1, 9)),
        at(DateTime(2026, 10, 30, 9)), // a gap on the 31st
      ];
      expect(DoneStats.of(run, now).streak, 3);
      expect(
        DoneStats.of([at(DateTime(2026, 11, 4, 8)), ...run], now).streak,
        4,
      );
      expect(DoneStats.of([at(DateTime(2026, 11, 1))], now).streak, 0);
    });
  });

  group('the log of ticks', () {
    Future<List<Completion>> log() => AppDatabase.instance.getCompletions(0);

    test('a tick is logged, and taking it back unlogs it', () async {
      final provider = await seedProvider();
      await provider.toggleDone(await taskNamed('Someday idea'));
      expect((await log()).map((c) => c.title), ['Someday idea']);

      await provider.toggleDone(await taskNamed('Someday idea'));
      expect(await log(), isEmpty);
    });

    test('an undo takes its tick out of the log', () async {
      final provider = await seedProvider();
      final ship = await taskNamed('Ship');
      await provider.toggleDone(ship);
      expect(await log(), hasLength(1));
      await provider.restore(ship);
      expect(await log(), isEmpty);
    });

    test('a repeating task is logged every time round, and the log '
        'outlives the task', () async {
      final provider = await seedProvider();
      await provider.toggleDone(await taskNamed('Water'));
      await provider.toggleDone(await taskNamed('Water'));
      expect((await log()).map((c) => c.title), ['Water', 'Water']);

      await provider.remove((await taskNamed('Water')).id!);
      expect(await log(), hasLength(2));
    });
  });

  testWidgets('the Done screen lays out the figures and the log on a phone', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    late TaskProvider provider;
    await tester.runAsync(() async {
      provider = await seedProvider();
      await provider.toggleDone(await taskNamed('Someday idea'));
    });
    tester.view.physicalSize = const Size(960, 1920);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<TaskProvider>.value(value: provider),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(AppAccent.presets.first),
          home: const DoneScreen(),
        ),
      ),
    );
    // The log is read from the database, which fake time cannot finish.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();

    expect(find.text('Someday idea'), findsOneWidget);
    expect(find.text('today'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('1'), findsWidgets);
  });
}

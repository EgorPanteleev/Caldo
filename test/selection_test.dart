import 'package:caldo/db/database.dart';
import 'package:caldo/models/task.dart';
import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/screens/tasks_screen.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/widgets/selection.dart';
import 'package:caldo/widgets/task_card.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initTestDatabase);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
  });

  group('several at once', () {
    final next = dayOf(DateTime.now().add(const Duration(days: 4)));

    test('move to a day, each keeping its own time', () async {
      final p = await seedProvider();
      final ship = await taskNamed('Ship');
      final idea = await taskNamed('Someday idea');
      await p.moveAllToDay([ship, idea], next);
      expect(
        (await taskNamed('Ship')).due,
        next.add(const Duration(hours: 15)),
      );
      expect((await taskNamed('Someday idea')).due, next);
      expect(p.undated, isEmpty);
    });

    test('ticked off together, each logged, and taken back together', () async {
      final p = await seedProvider();
      final ship = await taskNamed('Ship');
      final water = await taskNamed('Water');
      final at = DateTime.now().millisecondsSinceEpoch - 1000;
      await p.setAllDone([ship, water], done: true);
      expect((await taskNamed('Ship')).done, isTrue);
      // A repeating task rolls on rather than closing.
      expect((await taskNamed('Water')).done, isFalse);
      expect((await taskNamed('Water')).dueAt, greaterThan(water.dueAt!));
      expect(await AppDatabase.instance.getCompletions(at), hasLength(2));

      await p.setAllDone([await taskNamed('Ship')], done: false);
      expect((await taskNamed('Ship')).done, isFalse);
      expect(await AppDatabase.instance.getCompletions(at), hasLength(1));
    });

    test('moved into a group, they take its colour', () async {
      final p = await seedProvider();
      final ship = (await taskNamed('Ship')).copyWith(styleId: 'red');
      await p.update(ship);
      final other = p.lists.firstWhere((l) => l.id != ship.listId).id!;
      await p.moveAllToGroup([ship], other);
      final moved = await taskNamed('Ship');
      expect(moved.listId, other);
      expect(moved.styleId, isNull);
    });

    test('deleted together', () async {
      final p = await seedProvider();
      await p.removeAll([await taskNamed('Ship'), await taskNamed('Water')]);
      expect([for (final t in await allTasks()) t.title], ['Someday idea']);
    });
  });

  Future<_CapturingProvider> pumpSchedule(WidgetTester tester) async {
    late _CapturingProvider provider;
    await tester.runAsync(() async {
      await seedProvider();
      provider = _CapturingProvider();
      await provider.loadLists();
      await provider.loadTasks();
    });
    tester.view.physicalSize = const Size(1080, 2280);
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
          home: const TasksScreen(),
        ),
      ),
    );
    await tester.pump();
    return provider;
  }

  /// A long press let go where it was pressed.
  Future<void> holdAndLet(WidgetTester tester, String title) async {
    final finger = await tester.startGesture(
      tester.getCenter(find.text(title)),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await finger.up();
    await tester.pumpAndSettle();
  }

  bool barShown(WidgetTester tester) =>
      tester
          .widget<IgnorePointer>(
            find
                .ancestor(
                  of: find.byKey(selectionBarKey),
                  matching: find.byType(IgnorePointer),
                )
                .first,
          )
          .ignoring ==
      false;

  testWidgets('a long press let go in place picks a card out', (tester) async {
    await pumpSchedule(tester);
    expect(barShown(tester), isFalse);

    await holdAndLet(tester, 'Ship');
    expect(barShown(tester), isTrue);
    expect(find.text('1 selected'), findsOneWidget);

    // From here a tap picks out, rather than opening the form.
    await tester.tap(find.text('Someday idea'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    // And the tick picks out too, rather than ticking it off.
    final water = find.ancestor(
      of: find.text('Water'),
      matching: find.byType(TaskCard),
    );
    await tester.tap(
      find.descendant(of: water, matching: find.byKey(taskCardTickKey)),
    );
    await tester.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);
    expect(tester.widget<TaskCard>(water).task.done, isFalse);

    await tester.tap(find.text('Ship'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear selection'));
    await tester.pumpAndSettle();
    expect(barShown(tester), isFalse);
  });

  testWidgets('a card held and moved is carried, not picked out', (
    tester,
  ) async {
    await pumpSchedule(tester);
    final from = tester.getCenter(find.text('Ship'));
    final finger = await tester.startGesture(from);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    for (var i = 1; i <= 5; i++) {
      await finger.moveTo(from + Offset(0, 12.0 * i));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await finger.moveTo(from);
    await tester.pump(const Duration(milliseconds: 16));
    await finger.up();
    await tester.pumpAndSettle();
    expect(barShown(tester), isFalse);
  });

  testWidgets('back puts down what is picked out', (tester) async {
    await pumpSchedule(tester);
    await holdAndLet(tester, 'Ship');
    expect(barShown(tester), isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(barShown(tester), isFalse);
    expect(find.byType(TasksScreen), findsOneWidget);
  });

  testWidgets('the cards picked out are deleted together', (tester) async {
    final provider = await pumpSchedule(tester);
    await holdAndLet(tester, 'Ship');
    await tester.tap(find.text('Someday idea'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 tasks?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(
      [for (final t in provider.removed!) t.title],
      ['Ship', 'Someday idea'],
    );
    expect(barShown(tester), isFalse);
  });

  testWidgets('a card picked out and carried takes the others with it', (
    tester,
  ) async {
    final provider = await pumpSchedule(tester);
    await holdAndLet(tester, 'Ship');
    await tester.tap(find.text('Water'));
    await tester.pumpAndSettle();

    // Ship, carried down into No date.
    final from = tester.getCenter(find.text('Ship'));
    final to =
        tester.getCenter(find.text('Someday idea')) + const Offset(0, 20);
    final finger = await tester.startGesture(from);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    for (var i = 1; i <= 10; i++) {
      await finger.moveTo(Offset.lerp(from, to, i / 10)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await finger.up();
    await tester.pumpAndSettle();

    expect([for (final t in provider.moved!) t.title], ['Ship', 'Water']);
    expect(provider.movedTo, isNull);
    expect(barShown(tester), isFalse, reason: 'they have been dealt with');
  });
}

class _CapturingProvider extends TaskProvider {
  List<Task>? removed;
  List<Task>? moved;
  DateTime? movedTo;

  @override
  Future<void> moveAllToDay(
    List<Task> tasks,
    DateTime? day, {
    List<Task>? among,
  }) async {
    moved = tasks;
    movedTo = day;
  }

  @override
  Future<void> removeAll(List<Task> tasks) async => removed = tasks;
}

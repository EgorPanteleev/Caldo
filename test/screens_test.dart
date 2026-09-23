import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/screens/agenda_screen.dart';
import 'package:caldo/screens/calendar_screen.dart';
import 'package:caldo/screens/lists_screen.dart';
import 'package:caldo/screens/settings_screen.dart';
import 'package:caldo/screens/task_edit_screen.dart';
import 'package:caldo/screens/task_list_screen.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/test_db.dart';

/// Renders the real screens on a phone-sized surface against a database that
/// has been seeded for real, which also catches layout overflows.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(initTestDatabase);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
  });

  /// Seeds outside the test's fake-async zone — real database I/O cannot
  /// complete inside it — then pumps [screen] with that provider.
  Future<TaskProvider> pumpScreen(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(1080, 2280),
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    late TaskProvider provider;
    await tester.runAsync(() async => provider = await seedProvider());

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<TaskProvider>.value(value: provider),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
      ],
      child: MaterialApp(
        theme: theme ?? AppTheme.dark(AppAccent.presets.first),
        home: screen,
      ),
    ));
    await tester.pump();
    return provider;
  }

  /// A small phone — the width where rows and headers are most likely to
  /// overflow.
  const narrow = Size(960, 1920);

  testWidgets('the agenda separates overdue from what is due today',
      (tester) async {
    await pumpScreen(tester, const AgendaScreen());

    expect(find.text('OVERDUE'), findsOneWidget);
    expect(find.text('Water'), findsOneWidget);
    expect(find.text('Ship'), findsOneWidget);
    expect(find.text('1 left of 1 today'), findsOneWidget);
    // Undated tasks belong to their list, not to the agenda.
    expect(find.text('Someday idea'), findsNothing);
  });

  testWidgets('the calendar lists the selected day below the month grid',
      (tester) async {
    await pumpScreen(tester, const CalendarScreen());

    expect(find.text('MON'), findsOneWidget);
    expect(find.text('SUN'), findsOneWidget);
    // Today is selected on open, so its timed task shows under the grid.
    expect(find.text('Ship'), findsOneWidget);
    expect(find.text('1 open'), findsOneWidget);
  });

  testWidgets('a list screen shows its tasks and its name', (tester) async {
    await pumpScreen(tester, const TaskListScreen());

    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Ship'), findsOneWidget);
    expect(find.text('Water'), findsOneWidget);
    expect(find.text('Someday idea'), findsOneWidget);
  });

  testWidgets('the lists screen counts each list', (tester) async {
    await pumpScreen(tester, const ListsScreen());

    expect(find.text('Work'), findsOneWidget);
    expect(find.text('3 open · 0 done'), findsOneWidget);
    expect(find.text('Personal'), findsOneWidget); // created on first run
    expect(find.text('Empty'), findsOneWidget);
  });

  testWidgets('the screens hold up on a narrow phone in light mode',
      (tester) async {
    final light = AppTheme.light(AppAccent.presets.first);
    await pumpScreen(tester, const CalendarScreen(),
        size: narrow, theme: light);
    expect(find.text('Ship'), findsOneWidget);

    await pumpScreen(tester, const TaskListScreen(),
        size: narrow, theme: light);
    expect(find.text('Someday idea'), findsOneWidget);

    await pumpScreen(tester, const AgendaScreen(), size: narrow, theme: light);
    expect(find.text('OVERDUE'), findsOneWidget);
  });

  testWidgets('the settings screen renders every section', (tester) async {
    await pumpScreen(tester, const SettingsScreen(), size: narrow);

    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(find.text('CALENDAR'), findsOneWidget);
    expect(find.text('TASKS'), findsOneWidget);
    expect(find.text('Start week on Monday'), findsOneWidget);
  });

  testWidgets('the editor pre-fills an existing task', (tester) async {
    late TaskProvider provider;
    await tester.runAsync(() async => provider = await seedProvider());
    final task = provider.tasks.firstWhere((t) => t.title == 'Ship');

    tester.view.physicalSize = narrow;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<TaskProvider>.value(value: provider),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(AppAccent.presets.first),
        home: TaskEditScreen(task: task),
      ),
    ));
    await tester.pump();

    expect(find.text('Edit task'), findsOneWidget);
    expect(find.text('Ship'), findsOneWidget);
    expect(find.text('tag it first'), findsOneWidget);
    expect(find.text('High'), findsOneWidget);
    // The save button sits below the fold on a small phone.
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump();
    expect(find.text('Save changes'), findsOneWidget);
  });

  testWidgets('searching a list narrows it down', (tester) async {
    final provider = await pumpScreen(tester, const TaskListScreen());

    await tester.enterText(find.byType(TextField), 'ship');
    await tester.runAsync(() => provider.search('ship'));
    await tester.pump();

    expect(find.text('Ship'), findsOneWidget);
    expect(find.text('Water'), findsNothing);
  });
}

import 'package:caldo/models/task.dart';
import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/screens/tasks_screen.dart';
import 'package:caldo/screens/calendar_screen.dart';
import 'package:caldo/screens/home_screen.dart';
import 'package:caldo/screens/lists_screen.dart';
import 'package:caldo/screens/settings_screen.dart';
import 'package:caldo/screens/task_edit_screen.dart';
import 'package:caldo/screens/task_list_screen.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/utils/dates.dart';
import 'package:caldo/widgets/month_grid.dart';
import 'package:caldo/widgets/screen_header.dart';
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

  /// Opens the task editor on a small phone, either empty or on the seeded
  /// "Ship" task.
  Future<void> pumpEditor(WidgetTester tester, {bool existing = false}) async {
    late TaskProvider provider;
    await tester.runAsync(() async => provider = await seedProvider());

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
        home: TaskEditScreen(
          task: existing
              ? provider.tasks.firstWhere((t) => t.title == 'Ship')
              : null,
          listId: provider.currentListId,
        ),
      ),
    ));
    await tester.pump();
  }

  /// Lets the database reads a screen started (a month change, say) finish
  /// before the test ends and the next case closes the database.
  Future<void> drainDatabase(WidgetTester tester) =>
      tester.runAsync(() => Future<void>.delayed(
            const Duration(milliseconds: 80),
          ));

  testWidgets('the tasks screen separates overdue from what is due today',
      (tester) async {
    await pumpScreen(tester, const TasksScreen());

    expect(find.text('OVERDUE'), findsOneWidget);
    expect(find.text('Water'), findsOneWidget);
    expect(find.text('Ship'), findsOneWidget);
    expect(find.text('1 left of 1 today'), findsOneWidget);
    // Undated tasks come last, under their own heading.
    expect(find.text('NO DATE'), findsOneWidget);
    expect(find.text('Someday idea'), findsOneWidget);
  });

  testWidgets('the calendar lists the selected day below the month grid',
      (tester) async {
    await pumpScreen(tester, const CalendarScreen());

    // One-letter weekday heads, weekend last.
    expect(find.text('M'), findsOneWidget);
    expect(find.text('W'), findsOneWidget);
    expect(find.text('S'), findsNWidgets(2));
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

    await pumpScreen(tester, const TasksScreen(), size: narrow, theme: light);
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
    await pumpEditor(tester, existing: true);

    expect(find.text('Edit task'), findsOneWidget);
    expect(find.text('Ship'), findsOneWidget);
    expect(find.text('tag it first'), findsOneWidget);
    expect(find.text('High'), findsOneWidget);
    // The save button sits below the fold on a small phone.
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump();
    expect(find.text('Save changes'), findsOneWidget);
  });

  /// Asserts a header title is either drawn in full or given every pixel the
  /// controls beside it leave — never squeezed into a share of the free width,
  /// which is what truncates long names. Glyph widths are not compared
  /// directly: the test font draws every character as a full em square.
  void expectTitleGetsTheRoom(
    WidgetTester tester,
    Finder title, {
    required double controlsWidth,
  }) {
    final text = tester.widget<Text>(title);
    final painter = TextPainter(
      text: TextSpan(text: text.data, style: text.style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final screen = tester.getSize(find.byType(MaterialApp)).width;
    final deserved = painter.width < screen - controlsWidth
        ? painter.width
        : screen - controlsWidth;
    expect(
      tester.getSize(title).width,
      greaterThanOrEqualTo(deserved - 1),
      reason: '"${text.data}" is squeezed by the controls beside it',
    );
  }

  testWidgets('the month name is centred and never clipped', (tester) async {
    await pumpScreen(tester, const CalendarScreen(), size: narrow);

    // A year's worth, so both the bare month and the form carrying a year
    // are covered whatever today's date is.
    for (var i = 0; i < 12; i++) {
      final finder = find.byKey(monthTitleKey);
      final text = tester.widget<Text>(finder);
      final painter = TextPainter(
        text: TextSpan(text: text.data, style: text.style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      expect(
        tester.getSize(finder).width,
        greaterThanOrEqualTo(painter.width - 0.5),
        reason: '"${text.data}" is clipped',
      );
      final screen = tester.getSize(find.byType(MaterialApp)).width;
      expect(
        (tester.getCenter(finder).dx - screen / 2).abs(),
        lessThan(2),
        reason: '"${text.data}" should sit in the middle of the header',
      );
      await tester.tap(find.byTooltip('Next month'));
      await tester.pumpAndSettle();
    }
    await drainDatabase(tester);
  });

  testWidgets('the month name carries the year only when it is not this one',
      (tester) async {
    final thisYear = DateTime(DateTime.now().year, 6);
    final nextYear = DateTime(DateTime.now().year + 1, 6);
    expect(Dates.monthTitle(thisYear), 'Jun');
    expect(Dates.monthTitle(nextYear), 'Jun ${nextYear.year}');
  });

  testWidgets('a long list name gets the whole screen header', (tester) async {
    await pumpScreen(tester, const TaskListScreen(), size: narrow);

    expectTitleGetsTheRoom(
      tester,
      find.byKey(screenTitleKey),
      // A back arrow and the add button, plus the count pill beside the name.
      controlsWidth: 160,
    );
  });

  testWidgets('the due date comes from the app calendar sheet', (tester) async {
    await pumpEditor(tester);

    await tester.tap(find.text('Due date'));
    await tester.pumpAndSettle();
    // The app's own calendar, not the Material dialog.
    expect(find.byType(MonthGrid), findsWidgets);
    expect(find.text('Next week'), findsOneWidget);

    await tester.tap(find.text('Tomorrow'));
    await tester.pumpAndSettle();

    final tomorrow = dayOf(DateTime.now()).add(const Duration(days: 1));
    expect(find.text(Dates.longDay(tomorrow)), findsOneWidget);
  });

  testWidgets('the time comes from the wheel sheet', (tester) async {
    await pumpEditor(tester);
    expect(find.text('All day'), findsOneWidget);

    await tester.tap(find.text('Time'));
    await tester.pumpAndSettle();
    expect(find.text('Set time'), findsOneWidget);

    await tester.tap(find.text('18:00').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set time'));
    await tester.pumpAndSettle();

    expect(find.text('All day'), findsNothing);
    expect(find.text('18:00'), findsOneWidget);
  });

  testWidgets('the calendar opens up to spell out each day', (tester) async {
    await pumpScreen(tester, const CalendarScreen());

    // Compact: the day's tasks are listed below the grid, and the grid marks
    // them with bars rather than words.
    expect(find.text('Ship'), findsOneWidget);

    await tester.drag(find.byKey(calendarHandleKey), const Offset(0, 320));
    await tester.pumpAndSettle();

    // Opened: the title is now written inside its day as well.
    expect(find.text('Ship'), findsNWidgets(2));

    await tester.tap(find.byKey(calendarHandleKey));
    await tester.pumpAndSettle();
    expect(find.text('Ship'), findsOneWidget);
    await drainDatabase(tester);
  });

  testWidgets('picking a day in the opened month closes it again',
      (tester) async {
    await pumpScreen(tester, const CalendarScreen());
    await tester.tap(find.byKey(calendarHandleKey));
    await tester.pumpAndSettle();
    expect(find.text('Ship'), findsNWidgets(2));

    final today = dayOf(DateTime.now());
    await tester.tap(find.text('${today.day}').first);
    await tester.pumpAndSettle();

    expect(find.text('Ship'), findsOneWidget);
    await drainDatabase(tester);
  });

  testWidgets('the quick-add field schedules on the day in view',
      (tester) async {
    // A provider that captures instead of writing: a tap inside the widget
    // tree cannot await real database work, but the task it hands over can
    // still be checked.
    late _CapturingProvider provider;
    await tester.runAsync(() async {
      provider = _CapturingProvider();
      await provider.loadLists();
    });
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<TaskProvider>.value(value: provider),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(AppAccent.presets.first),
        home: const CalendarScreen(),
      ),
    ));
    await tester.pump();

    final today = dayOf(DateTime.now());
    expect(find.text('Add task on ${Dates.shortDay(today)}'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Buy milk');
    await tester.tap(find.byTooltip('Add task'));
    await tester.pump();

    final added = provider.added;
    expect(added, isNotNull);
    expect(added!.title, 'Buy milk');
    expect(added.dueAt, today.millisecondsSinceEpoch);
    expect(added.hasTime, isFalse);
    expect(added.listId, provider.lists.first.id);
    // The field empties as soon as the task is handed over.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, isEmpty);
  });

  testWidgets('the shell carries Tasks, Calendar and Settings', (tester) async {
    await pumpScreen(tester, const HomeScreen());

    expect(find.text('Tasks'), findsWidgets);
    expect(find.text('Calendar'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    // Lists moved out of the tab bar, onto the Tasks screen's header.
    expect(find.text('Lists'), findsNothing);
    expect(find.byTooltip('Lists'), findsOneWidget);
    await drainDatabase(tester);
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

/// Records what the UI asks to create instead of writing it.
class _CapturingProvider extends TaskProvider {
  Task? added;

  @override
  Future<void> add(Task task) async => added = task;
}

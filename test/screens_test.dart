import 'package:caldo/models/task.dart';
import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/screens/tasks_screen.dart';
import 'package:caldo/screens/calendar_screen.dart';
import 'package:caldo/screens/home_screen.dart';
import 'package:caldo/screens/lists_screen.dart';
import 'package:caldo/screens/search_screen.dart';
import 'package:caldo/screens/settings_screen.dart';
import 'package:caldo/screens/task_edit_screen.dart';
import 'package:caldo/screens/task_list_screen.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/utils/dates.dart';
import 'package:caldo/widgets/day_sheet.dart';
import 'package:caldo/widgets/menu_button.dart';
import 'package:caldo/widgets/task_row.dart';
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

  /// A day number inside the month grid. The Today button carries today's
  /// number too, so a bare text finder can land on the wrong one.
  Finder dayInGrid(int day) => find
      .descendant(of: find.byType(MonthGrid), matching: find.text('$day'))
      .first;

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

    // The day headings are written as dates now, not shouted section labels.
    expect(find.text('Overdue'), findsOneWidget);
    expect(find.text('Water'), findsOneWidget);
    expect(find.text('Ship'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    // Undated tasks come last, under their own heading — and each card says
    // the same thing under its title, so there is more than one of it.
    expect(find.text('No date'), findsWidgets);
    expect(find.text('Someday idea'), findsOneWidget);
  });

  testWidgets('the calendar lists the selected day below the month grid',
      (tester) async {
    await pumpScreen(tester, const CalendarScreen());

    // One-letter weekday heads, weekend last.
    expect(find.text('M'), findsOneWidget);
    expect(find.text('W'), findsOneWidget);
    expect(find.text('S'), findsNWidgets(2));
    // Today is selected on open, so its timed task shows under the grid,
    // under a bar naming the day and nothing else.
    expect(find.text('Ship'), findsOneWidget);
    final today = dayOf(DateTime.now());
    expect(find.text(Dates.weekdayShort(today)), findsOneWidget);
    expect(find.textContaining('open'), findsNothing);
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
    expect(find.text('Overdue'), findsOneWidget);
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
      // The chevrons are gone; the month is changed by swiping the grid.
      await tester.drag(find.byType(MonthGrid).first, const Offset(-400, 0));
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
    // Two plain words at the foot, and an AM/PM wheel beside the numbers.
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('PM'), findsWidgets);

    await tester.tap(find.text('6:00 PM').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('All day'), findsNothing);
    expect(find.text('18:00'), findsOneWidget);
  });

  testWidgets('the wheel being turned is the tinted one', (tester) async {
    await pumpEditor(tester);
    await tester.tap(find.text('Time'));
    await tester.pumpAndSettle();

    final accent = AppAccent.presets.first.color;
    // The hour wheel alone: each wheel marks its own landed value, so turning
    // one is not supposed to take the accent off the other two.
    bool tinted() => tester
        .widgetList<Text>(find.descendant(
          of: find.byType(ListWheelScrollView).first,
          matching: find.byType(Text),
        ))
        .any((t) => t.style?.color == accent);

    expect(tinted(), isFalse, reason: 'at rest the numbers are plain');

    // Held, not flicked: the tint says which wheel the finger has hold of, so
    // it has to be there while the finger still is.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('9').first),
    );
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    expect(tinted(), isTrue, reason: 'the wheel being turned is tinted');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(tinted(), isFalse, reason: 'and plain again once it stops');
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

  testWidgets('the calendar squeezes down to a single week', (tester) async {
    await pumpScreen(tester, const CalendarScreen());
    final month = tester.getSize(find.byType(MonthGrid).first).height;

    // Pushing the grip up collapses the month to the selected day's week.
    await tester.drag(find.byKey(calendarHandleKey), const Offset(0, -300));
    await tester.pumpAndSettle();
    final week = tester.getSize(find.byType(MonthGrid).first).height;
    expect(week, lessThan(month / 3),
        reason: 'a week should be a fraction of the month');
    // The day's tasks keep their place, with more room than before.
    expect(find.text('Ship'), findsOneWidget);

    // And a tap brings the month back.
    await tester.tap(find.byKey(calendarHandleKey));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(MonthGrid).first).height,
        closeTo(month, 1));
    await drainDatabase(tester);
  });

  testWidgets('tapping the grip walks through the three states',
      (tester) async {
    await pumpScreen(tester, const CalendarScreen());
    double height() => tester.getSize(find.byType(MonthGrid).first).height;
    final month = height();

    // Open, back to the month, on down to the week: a tap is a step, not a
    // toggle between two states.
    await tester.tap(find.byKey(calendarHandleKey));
    await tester.pumpAndSettle();
    expect(height(), greaterThan(month));

    await tester.tap(find.byKey(calendarHandleKey));
    await tester.pumpAndSettle();
    expect(height(), closeTo(month, 1));

    await tester.tap(find.byKey(calendarHandleKey));
    await tester.pumpAndSettle();
    expect(height(), lessThan(month / 3));
    await drainDatabase(tester);
  });

  testWidgets('a short drag is enough to change state', (tester) async {
    await pumpScreen(tester, const CalendarScreen());
    final month = tester.getSize(find.byType(MonthGrid).first).height;

    // Well short of the distance between the two states, but clearly meant.
    await tester.drag(find.byKey(calendarHandleKey), const Offset(0, 90));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(MonthGrid).first).height,
        greaterThan(month * 1.3));
    await drainDatabase(tester);
  });

  testWidgets('the days below the grid are a row that can be swiped',
      (tester) async {
    await pumpScreen(tester, const CalendarScreen());
    final today = dayOf(DateTime.now());
    final tomorrow = today.add(const Duration(days: 1));
    expect(find.text(Dates.weekdayShort(today)), findsOneWidget);

    // Swiping the day sideways brings the next one in from the edge.
    await tester.drag(
      find.text(Dates.weekdayShort(today)),
      const Offset(-400, 0),
    );
    await tester.pumpAndSettle();

    expect(find.text(Dates.weekdayShort(tomorrow)), findsOneWidget);
    expect(find.text(Dates.weekdayShort(today)), findsNothing);
    // And the rest of the screen follows the day that is now in view.
    expect(find.text('Add task on ${Dates.shortDay(tomorrow)}'), findsOneWidget);
    await drainDatabase(tester);
  });

  testWidgets('picking a day in the grid slides the day across',
      (tester) async {
    await pumpScreen(tester, const CalendarScreen());
    final today = dayOf(DateTime.now());
    // A day in the same week, so the grid has it whichever day today is.
    final other = today.day > 15
        ? today.subtract(const Duration(days: 2))
        : today.add(const Duration(days: 2));

    await tester.tap(dayInGrid(other.day));
    await tester.pumpAndSettle();

    expect(find.text(Dates.weekdayShort(other)), findsOneWidget);
    expect(find.text('Add task on ${Dates.shortDay(other)}'), findsOneWidget);
    await drainDatabase(tester);
  });

  testWidgets('picking a day in the opened month opens it on top',
      (tester) async {
    await pumpScreen(tester, const CalendarScreen());
    await tester.tap(find.byKey(calendarHandleKey));
    await tester.pumpAndSettle();
    expect(find.byKey(daySheetKey), findsNothing);
    expect(find.text('Ship'), findsNWidgets(2));

    final today = dayOf(DateTime.now());
    await tester.tap(dayInGrid(today.day));
    await tester.pumpAndSettle();

    // The day comes forward as a card, with the month still behind it.
    expect(find.byKey(daySheetKey), findsOneWidget);
    expect(find.text(Dates.weekdayLong(today)), findsOneWidget);
    expect(find.text('Add task on ${Dates.shortDay(today)}'), findsWidgets);

    // Dismissed, the month is as it was.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(daySheetKey), findsNothing);
    expect(find.text('Ship'), findsNWidgets(2));
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

  testWidgets('search finds a task in any list by title or notes',
      (tester) async {
    await pumpScreen(tester, const SearchScreen());

    // Nothing is claimed until something has been typed.
    expect(find.text('Search your tasks'), findsOneWidget);

    await tester.enterText(find.byKey(searchFieldKey), 'Ship');
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    // Scoped to a result row: the field itself now reads "Ship" too.
    expect(
      find.descendant(of: find.byType(TaskRow), matching: find.text('Ship')),
      findsOneWidget,
    );

    await tester.enterText(find.byKey(searchFieldKey), 'nothing matches this');
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('Nothing found'), findsOneWidget);
    await drainDatabase(tester);
  });

  testWidgets('the calendar offers a way back to today and a way to search',
      (tester) async {
    await pumpScreen(tester, const CalendarScreen());

    expect(find.byTooltip('Today'), findsOneWidget);
    expect(find.byTooltip('Search'), findsOneWidget);
    // The month chevrons are gone; swiping the grid moves the month now.
    expect(find.byTooltip('Next month'), findsNothing);
    expect(find.byTooltip('Previous month'), findsNothing);

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    expect(find.byKey(searchFieldKey), findsOneWidget);
    await drainDatabase(tester);
  });

  testWidgets('Today brings the grid back with the selection', (tester) async {
    await pumpScreen(tester, const CalendarScreen());
    final today = dayOf(DateTime.now());
    final thisMonth = Dates.monthTitle(DateTime(today.year, today.month));
    final next = Dates.monthTitle(DateTime(today.year, today.month + 1));

    await tester.drag(find.byType(MonthGrid).first, const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(monthTitleKey)).data, next);

    await tester.tap(find.byTooltip('Today'));
    await tester.pumpAndSettle();

    // Both have to come back: the pagers report the pages their animations
    // pass through, and those used to be taken for picks and send the grid
    // straight back to the month it had just left.
    expect(tester.widget<Text>(find.byKey(monthTitleKey)).data, thisMonth);
    expect(find.text('Add task on ${Dates.shortDay(today)}'), findsOneWidget);
    await drainDatabase(tester);
  });

  testWidgets('the shell keeps its three screens behind the menu button',
      (tester) async {
    await pumpScreen(tester, const HomeScreen());

    // Nothing but the screen itself until the menu is opened — there is no
    // bar along the bottom naming the other two.
    expect(find.text('Schedule'), findsWidgets);
    expect(find.text('Calendar'), findsNothing);
    expect(find.text('Settings'), findsNothing);

    await tester.tap(find.byKey(menuButtonKey));
    await tester.pumpAndSettle();

    expect(find.text('Calendar'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    // The menu is the three destinations and nothing else.
    expect(find.text('Lists'), findsNothing);

    // Picking one closes the menu and swaps the screen under it.
    await tester.tap(find.text('Calendar'));
    await tester.pumpAndSettle();
    expect(find.byKey(monthTitleKey), findsOneWidget);
    expect(find.text('Settings'), findsNothing);
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

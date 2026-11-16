import 'package:caldo/main.dart';
import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/screens/board_screen.dart';
import 'package:caldo/screens/desk_shell.dart';
import 'package:caldo/screens/home_screen.dart';
import 'package:caldo/screens/search_screen.dart';
import 'package:caldo/screens/task_edit_screen.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/widgets/date_time_pickers.dart';
import 'package:caldo/widgets/desk.dart';
import 'package:caldo/widgets/month_grid.dart';
import 'package:caldo/widgets/quick_add_bar.dart';
import 'package:caldo/widgets/selection.dart';
import 'package:caldo/widgets/task_card.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_db.dart';

/// The desktop's own layout: what a wide window on Linux draws that a phone
/// does not, and that a phone — and a window the shape of one — still gets
/// what it always did.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    initTestDatabase();
    await initializeDateFormatting();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
  });

  tearDown(() {
    TaskPanel.instance.close();
    KeyboardGap.instance.forget();
  });

  /// Just Linux: the tests are told they are on Android unless they say.
  final linux = TargetPlatformVariant.only(TargetPlatform.linux);

  const wide = Size(1240, 780);

  /// The shell under what `CaldoApp` puts over it on a desktop, in a window
  /// of [size], over the seeded tasks.
  Future<TaskProvider> pumpApp(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late TaskProvider provider;
    await tester.runAsync(() async => provider = await seedProvider());
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<TaskProvider>.value(value: provider),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(AppAccent.presets.first),
          navigatorKey: navigator,
          navigatorObservers: [DeskScope.observer],
          builder: (context, child) => DeskScope(
            navigator: navigator,
            builder: (context, wide) => DeskKeys(
              navigator: navigator,
              wide: wide,
              child: PhoneWide(on: !wide, child: child!),
            ),
          ),
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pump();
    return provider;
  }

  /// Lets the reads a screen started on being shown come back.
  Future<void> drain(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump();
  }

  Finder inSidebar(String text) => find.descendant(
    of: find.byKey(deskSidebarKey),
    matching: find.text(text),
  );

  Future<void> show(WidgetTester tester, String screen) async {
    await tester.tap(inSidebar(screen));
    await tester.pumpAndSettle();
    await drain(tester);
  }

  Finder cardOf(String title) =>
      find.ancestor(of: find.text(title), matching: find.byType(TaskCard));

  testWidgets('a wide window has the sidebar, and a narrow one the tab bar', (
    tester,
  ) async {
    await pumpApp(tester, wide);
    expect(find.byKey(deskSidebarKey), findsOneWidget);
    expect(find.byKey(tabBarKey), findsNothing);
    // The groups are in the sidebar, and the overdue count on Schedule.
    expect(inSidebar('Work'), findsOneWidget);
    expect(inSidebar('1'), findsOneWidget);

    // Dragged narrow, it is the phone's app — on the screen it was on.
    await show(tester, 'Done');
    tester.view.physicalSize = const Size(480, 800);
    await tester.pumpAndSettle();
    expect(find.byKey(deskSidebarKey), findsNothing);
    expect(find.byKey(tabBarKey), findsOneWidget);
    expect(find.byKey(const Key('screen-title')).hitTestable(), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('screen-title')).hitTestable())
          .data,
      'Done',
    );
    await drain(tester);
  }, variant: linux);

  testWidgets('a phone as wide as a desk is still a phone', (tester) async {
    await pumpApp(tester, wide);
    expect(find.byKey(deskSidebarKey), findsNothing);
    expect(find.byKey(tabBarKey), findsOneWidget);
    await drain(tester);
  });

  testWidgets('every screen fits in the narrowest wide window', (tester) async {
    // Overflows fail the run, as on the phones the other screens are
    // pumped at.
    await pumpApp(tester, const Size(Desk.breakpoint, 560));
    expect(find.byKey(deskSidebarKey), findsOneWidget);
    for (final screen in ['Calendar', 'Board', 'Done', 'Settings']) {
      await show(tester, screen);
    }
    // And with a form open over each.
    await show(tester, 'Schedule');
    await tester.tap(find.byKey(deskNewTaskKey));
    await tester.pumpAndSettle();
    expect(find.byKey(deskFormKey), findsOneWidget);
    for (final screen in ['Calendar', 'Board', 'Done', 'Settings']) {
      await show(tester, screen);
    }
    await drain(tester);
  }, variant: linux);

  testWidgets('a task opens in a panel, beside the list it came from', (
    tester,
  ) async {
    await pumpApp(tester, wide);
    final before = tester.getRect(cardOf('Ship'));
    await tester.tap(find.text('Ship'));
    await tester.pumpAndSettle();

    final form = tester.getRect(find.byKey(deskFormKey));
    expect(form.right, wide.width);
    expect(form.width, Desk.side);
    expect(form.height, wide.height);
    // No page was pushed: the list is still there, moved over for it.
    expect(find.byType(TaskEditScreen), findsOneWidget);
    final beside = tester.getRect(cardOf('Ship'));
    expect(beside.right, lessThanOrEqualTo(form.left));
    expect(beside.width, lessThan(before.width));

    // Another task clicked takes the panel over.
    await tester.tap(find.text('Water'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TaskEditScreen>(find.byType(TaskEditScreen)).task?.title,
      'Water',
    );

    // Escape closes it, and the list has its room back.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(deskFormKey), findsNothing);
    expect(tester.getRect(cardOf('Ship')), before);
    await drain(tester);
  }, variant: linux);

  testWidgets('a form with changes in it does not give way', (tester) async {
    await pumpApp(tester, wide);
    await tester.tap(find.text('Ship'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(deskFormKey),
        matching: find.byType(TextFormField).first,
      ),
      'Ship it',
    );
    await tester.pump();
    expect(TaskPanel.instance.dirty, isTrue);

    await tester.tap(find.text('Water'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TaskEditScreen>(find.byType(TaskEditScreen)).task?.title,
      'Ship',
    );
    expect(find.text('Ship it'), findsOneWidget);

    // Escape with the caret in a field only leaves the field; again, and
    // the form goes, as Cancel would have it.
    await tester.tap(find.text('Ship it'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(deskFormKey), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(deskFormKey), findsNothing);
    await drain(tester);
  }, variant: linux);

  testWidgets('the layout is kept while a form is open', (tester) async {
    await pumpApp(tester, wide);
    await tester.tap(find.text('Ship'));
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(600, 780);
    await tester.pumpAndSettle();
    expect(find.byKey(deskSidebarKey), findsOneWidget);
    expect(find.byKey(deskFormKey), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(deskSidebarKey), findsNothing);
    expect(find.byKey(tabBarKey), findsOneWidget);
    await drain(tester);
  }, variant: linux);

  testWidgets('the month is opened out, with its day down the side', (
    tester,
  ) async {
    await pumpApp(tester, wide);
    await show(tester, 'Calendar');

    final grid = tester.getRect(find.byType(MonthGrid).first);
    final field = tester.getRect(find.byType(QuickAddBar).hitTestable());
    expect(field.left, greaterThanOrEqualTo(grid.right));
    expect(field.width, closeTo(Desk.side, 1));
    // Today's task is written in the month as well as listed beside it.
    expect(find.text('Ship'), findsNWidgets(2));
    // A title clicked in the month opens its task.
    await tester.tap(
      find.descendant(
        of: find.byType(MonthGrid).first,
        matching: find.text('Ship'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TaskEditScreen>(find.byType(TaskEditScreen)).task?.title,
      'Ship',
    );
    // The form is as wide as the day, and covers it and nothing else.
    expect(tester.getRect(find.byKey(deskFormKey)).left, grid.right);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // The keys move the day, and the month with it.
    final title = find.byKey(const Key('month-title'));
    final month = tester.widget<Text>(title).data;
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(title).data, isNot(month));
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(title).data, month);
    await drain(tester);
  }, variant: linux);

  testWidgets('the board has its three lanes on show', (tester) async {
    await pumpApp(tester, wide);
    await show(tester, 'Board');
    final lanes = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(boardLanesKey),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(lanes.position.maxScrollExtent, 0);
    await drain(tester);
  }, variant: linux);

  testWidgets('what is a sheet on a phone is a dialog here', (tester) async {
    await pumpApp(tester, wide);
    await tester.tap(find.text('Ship'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Due date'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(PickerSheet), findsNothing);
    expect(find.text('Next week'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Next week'), findsNothing);
    // The panel under it is untouched by the Escape that closed the dialog.
    expect(find.byKey(deskFormKey), findsOneWidget);
    await drain(tester);
  }, variant: linux);

  testWidgets('the keys open a new task and search', (tester) async {
    await pumpApp(tester, wide);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final form = tester.widget<TaskEditScreen>(find.byType(TaskEditScreen));
    expect(form.task, isNull);
    expect(form.initialDate, dayOf(DateTime.now()));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(deskFormKey), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(searchFieldKey), findsOneWidget);
    // Over the screen, not in place of it.
    expect(find.byKey(deskSidebarKey), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(searchFieldKey), findsNothing);
    await drain(tester);
  }, variant: linux);

  testWidgets('Ctrl and a click picks a card out, and a right click offers', (
    tester,
  ) async {
    await pumpApp(tester, wide);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('Ship'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(deskFormKey), findsNothing);
    expect(find.byKey(selectionBarKey).hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(selectionBarKey).hitTestable(), findsNothing);

    await tester.tap(find.text('Ship'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Edit task'), findsOneWidget);
    expect(find.text('Pick day'), findsOneWidget);
    await tester.tap(find.text('Edit task'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TaskEditScreen>(find.byType(TaskEditScreen)).task?.title,
      'Ship',
    );
    await drain(tester);
  }, variant: linux);

  test('a time is read as it is typed', () {
    TimeOfDay at(int h, int m) => TimeOfDay(hour: h, minute: m);
    expect(parseClock('9'), at(9, 0));
    expect(parseClock('930'), at(9, 30));
    expect(parseClock('9:30'), at(9, 30));
    expect(parseClock('21.15'), at(21, 15));
    expect(parseClock('1530'), at(15, 30));
    expect(parseClock('9:30 pm'), at(21, 30));
    expect(parseClock('12am'), at(0, 0));
    expect(parseClock('12 PM'), at(12, 0));
    expect(parseClock('9p'), at(21, 0));
    expect(parseClock('25'), isNull);
    expect(parseClock('9:75'), isNull);
    expect(parseClock('13pm'), isNull);
    expect(parseClock('soon'), isNull);
    expect(parseClock(''), isNull);
  });
}

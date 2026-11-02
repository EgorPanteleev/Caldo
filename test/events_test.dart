import 'package:caldo/providers/events_provider.dart';
import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/screens/tasks_screen.dart';
import 'package:caldo/services/device_calendars.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/widgets/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_db.dart';

/// Events handed in directly, in place of the phone's calendars.
class _FakeEvents extends EventsProvider {
  final Map<DateTime, List<CalendarEvent>> events;

  _FakeEvents(this.events);

  @override
  Map<DateTime, List<CalendarEvent>> get byDay => events;

  @override
  List<CalendarEvent> on(DateTime day) => events[dayOf(day)] ?? const [];
}

CalendarEvent event({
  required int begin,
  required int end,
  bool allDay = false,
  String title = 'Dentist',
}) => CalendarEvent.fromMap({
  'id': 1,
  'begin': begin,
  'end': end,
  'allDay': allDay,
  'title': title,
  'colour': 0xFF3F7DE0,
  'calendar': '3',
  'calendarName': 'Home',
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initTestDatabase);
  setUp(resetTestDatabase);

  group('the days an event is on', () {
    test('an all-day event keeps its dates whatever the zone', () {
      // Stored at midnight UTC: read in the device's zone, west of
      // Greenwich, that would be the evening before.
      final holiday = event(
        begin: DateTime.utc(2026, 11, 5).millisecondsSinceEpoch,
        end: DateTime.utc(2026, 11, 6).millisecondsSinceEpoch,
        allDay: true,
      );
      expect(holiday.days, [DateTime(2026, 11, 5)]);

      final trip = event(
        begin: DateTime.utc(2026, 11, 5).millisecondsSinceEpoch,
        end: DateTime.utc(2026, 11, 8).millisecondsSinceEpoch,
        allDay: true,
      );
      expect(trip.days, [
        DateTime(2026, 11, 5),
        DateTime(2026, 11, 6),
        DateTime(2026, 11, 7),
      ]);
    });

    test('a timed event is on every day it touches, and no more', () {
      final party = event(
        begin: DateTime(2026, 11, 5, 21).millisecondsSinceEpoch,
        end: DateTime(2026, 11, 6, 2).millisecondsSinceEpoch,
      );
      expect(party.days, [DateTime(2026, 11, 5), DateTime(2026, 11, 6)]);

      // Ending at midnight is ending on the day it started.
      final evening = event(
        begin: DateTime(2026, 11, 5, 20).millisecondsSinceEpoch,
        end: DateTime(2026, 11, 6).millisecondsSinceEpoch,
      );
      expect(evening.days, [DateTime(2026, 11, 5)]);
    });
  });

  testWidgets('a day with only an event on it still has a run on Schedule', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final tomorrow = dayOf(DateTime.now()).add(const Duration(days: 2));
    final dentist = event(
      begin: tomorrow.add(const Duration(hours: 9)).millisecondsSinceEpoch,
      end: tomorrow.add(const Duration(hours: 10)).millisecondsSinceEpoch,
    );
    late TaskProvider provider;
    await tester.runAsync(() async {
      provider = TaskProvider();
      await provider.loadLists();
      await provider.loadTasks();
    });
    tester.view.physicalSize = const Size(960, 1920);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<TaskProvider>.value(value: provider),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
          ChangeNotifierProvider<EventsProvider>(
            create: (_) => _FakeEvents({
              tomorrow: [dentist],
            }),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(AppAccent.presets.first),
          home: const TasksScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(EventCard), findsOneWidget);
    expect(find.text('Dentist'), findsOneWidget);
    expect(find.textContaining('Home'), findsOneWidget);
    // It is not a task: there is no tick on it.
    expect(
      find.descendant(
        of: find.byType(EventCard),
        matching: find.byKey(taskCardTickKey),
      ),
      findsNothing,
    );
  });
}

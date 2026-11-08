import 'package:caldo/models/task.dart';
import 'package:caldo/models/task_list.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/widgets/day_hours.dart';
import 'package:caldo/widgets/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final day = DateTime(2026, 11, 4);

  Task at(String title, int hour, {int minute = 0, int? duration}) => Task(
    id: title.hashCode,
    listId: 1,
    title: title,
    dueAt: DateTime(2026, 11, 4, hour, minute).millisecondsSinceEpoch,
    hasTime: true,
    duration: duration,
    createdAt: 0,
  );

  Future<void> pump(WidgetTester tester, List<Task> tasks) async {
    // A small phone, so anything drawn past its room fails the run.
    tester.view.physicalSize = const Size(960, 1600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(AppAccent.presets.first),
        home: Scaffold(
          body: DayHours(
            date: day,
            tasks: tasks,
            holidays: const [],
            events: const [],
            lists: [TaskList(id: 1, name: 'Personal', createdAt: 0)],
            onOpen: (_) {},
            onToggle: (_) {},
            isTicking: (_) => false,
            isLeaving: (_) => false,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a block runs from its start to its end', (tester) async {
    await pump(tester, [at('Dentist', 13, duration: 90)]);
    final box = tester.getRect(
      find
          .ancestor(of: find.text('Dentist'), matching: find.byType(Material))
          .first,
    );
    expect(box.height, closeTo(1.5 * DayHours.hour - 2, 0.5));
  });

  testWidgets('blocks that overlap share the width', (tester) async {
    await pump(tester, [
      at('Standup', 10, duration: 60),
      at('Review', 10, minute: 30, duration: 60),
      at('Lunch', 12, duration: 60),
    ]);
    Rect rect(String title) => tester.getRect(
      find
          .ancestor(of: find.text(title), matching: find.byType(Material))
          .first,
    );
    final standup = rect('Standup');
    final review = rect('Review');
    final lunch = rect('Lunch');
    // Side by side, half the width each.
    expect(review.left, greaterThan(standup.right - 1));
    expect(standup.width, closeTo(review.width, 1));
    // Lunch overlaps neither, so it has the whole width.
    expect(lunch.width, greaterThan(standup.width * 1.8));
  });

  testWidgets('what has no time goes across the top as cards', (tester) async {
    await pump(tester, [
      Task(
        id: 1,
        listId: 1,
        title: 'Pay rent',
        dueAt: day.millisecondsSinceEpoch,
        createdAt: 0,
      ),
      at('Gym', 7),
    ]);
    expect(find.widgetWithText(TaskCard, 'Pay rent'), findsOneWidget);
    expect(find.widgetWithText(TaskCard, 'Gym'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Pay rent')).dy,
      lessThan(tester.getTopLeft(find.text('Gym')).dy),
    );
  });

  testWidgets('it opens a little above the first thing on the day', (
    tester,
  ) async {
    await pump(tester, [at('Lunch', 13)]);
    await tester.pump();
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    // Half an hour above one o'clock, under the scroll's top padding.
    expect(position.pixels, closeTo(4 + 12.5 * DayHours.hour, 1));
  });
}

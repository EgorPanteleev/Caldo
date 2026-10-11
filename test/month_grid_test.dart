import 'package:caldo/data/holidays.dart';
import 'package:caldo/models/task.dart';
import 'package:caldo/models/task_list.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/widgets/month_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // September 2026: the 4th is a Friday, the 5th a Saturday, the 6th a Sunday.
  final month = DateTime(2026, 9);
  final work = TaskList(id: 1, name: 'Work', styleId: 'blue', createdAt: 0);

  Future<void> pumpGrid(
    WidgetTester tester, {
    Map<DateTime, List<Task>> tasks = const {},
    Map<DateTime, List<Holiday>> holidays = const {},
    double expansion = 0,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(AppAccent.presets.first),
      home: Scaffold(
        body: SizedBox(
          // Five week rows at roughly the height the opened calendar gives
          // them on a phone, so a day has room for the two lines a title is
          // allowed to wrap over.
          height: 520,
          child: MonthGrid(
            month: month,
            selected: DateTime(2026, 9, 1),
            mondayFirst: true,
            tasksByDay: tasks,
            holidaysByDay: holidays,
            lists: [work],
            expansion: expansion,
            onSelect: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  Color colorOfNumber(WidgetTester tester, int day) {
    final texts = tester
        .widgetList<Text>(find.text('$day'))
        .where((t) => t.style?.color != null);
    return texts.first.style!.color!;
  }

  testWidgets('only Sundays are red', (tester) async {
    await pumpGrid(tester);

    expect(colorOfNumber(tester, 6), AppColors.weekend, reason: 'Sunday');
    expect(colorOfNumber(tester, 5), isNot(AppColors.weekend),
        reason: 'Saturday');
    expect(colorOfNumber(tester, 4), isNot(AppColors.weekend),
        reason: 'Friday');
  });

  testWidgets('a holiday leaves its number alone and marks it green',
      (tester) async {
    await pumpGrid(tester, holidays: {
      DateTime(2026, 9, 10): [
        Holiday(DateTime(2026, 9, 10), 'Made-up Day'),
      ],
    });

    expect(colorOfNumber(tester, 10), isNot(AppColors.weekend));

    // The day is marked by a green line rather than a red number.
    final marks = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) =>
            c.decoration is BoxDecoration &&
            (c.decoration! as BoxDecoration).color?.toARGB32() ==
                AppColors.holiday.toARGB32());
    expect(marks, isNotEmpty);
  });

  testWidgets('an opened month writes holidays out in green', (tester) async {
    await pumpGrid(
      tester,
      expansion: 1,
      holidays: {
        DateTime(2026, 9, 10): [
          Holiday(DateTime(2026, 9, 10), 'Made-up Day'),
        ],
      },
      tasks: {
        DateTime(2026, 9, 10): [
          Task(listId: 1, title: 'Standup', createdAt: 0),
        ],
      },
    );

    expect(find.text('Made-up Day'), findsOneWidget);
    expect(find.text('Standup'), findsOneWidget);
    final chip = tester.widget<Container>(
      find
          .ancestor(of: find.text('Made-up Day'), matching: find.byType(Container))
          .first,
    );
    final decoration = chip.decoration! as BoxDecoration;
    expect(
      decoration.color!.toARGB32(),
      dayChipColour(AppColors.holiday, AppPalette.dark.calendar).toARGB32(),
    );
  });

  testWidgets('week rules only arrive as the month finishes opening',
      (tester) async {
    expect(weekRuleAlpha(0), 0, reason: 'compact month');
    expect(weekRuleAlpha(0.5), 0, reason: 'halfway open');
    expect(weekRuleAlpha(0.75), 0, reason: 'three quarters open');
    expect(weekRuleAlpha(1), 1, reason: 'fully open');
    expect(weekRuleAlpha(0.875), closeTo(0.5, 0.001));
  });

  testWidgets('a task keeps its own colour over its list', (tester) async {
    await pumpGrid(
      tester,
      expansion: 1,
      tasks: {
        DateTime(2026, 9, 10): [
          Task(listId: 1, title: 'Own colour', styleId: 'pink', createdAt: 0),
        ],
      },
    );

    final chip = tester.widget<Container>(
      find
          .ancestor(of: find.text('Own colour'), matching: find.byType(Container))
          .first,
    );
    final decoration = chip.decoration! as BoxDecoration;
    final pink = ListStyle.byId('pink').color;
    expect(
      decoration.color!.toARGB32(),
      dayChipColour(pink, AppPalette.dark.calendar).toARGB32(),
      reason: 'the chip wears the task\'s own colour, not its list\'s',
    );
    expect(
      decoration.color!.toARGB32(),
      isNot(dayChipColour(work.style.color, AppPalette.dark.calendar)
          .toARGB32()),
    );
  });
}

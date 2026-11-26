// Days across a daylight saving change. Each check holds in any zone, but
// only bites in one that changes its clocks; run it as
// `TZ=Europe/Berlin flutter test test/dst_test.dart` to see it do so.
import 'package:caldo/data/holidays.dart';
import 'package:caldo/models/task.dart';
import 'package:caldo/services/reminders.dart';
import 'package:caldo/utils/days.dart';
import 'package:caldo/widgets/month_grid.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

bool _midnight(DateTime d) =>
    d.hour == 0 && d.minute == 0 && d.second == 0 && d.millisecond == 0;

void main() {
  // Europe's changes: the last Sundays of March and October.
  final changes = [DateTime(2026, 3, 29), DateTime(2026, 10, 25)];

  test('stepping a day lands on the next midnight', () {
    for (final change in changes) {
      var day = addDays(change, -3);
      for (var i = 0; i < 7; i++) {
        final next = addDays(day, 1);
        expect(_midnight(next), isTrue, reason: '$next');
        expect(daysBetween(day, next), 1, reason: '$day → $next');
        day = next;
      }
    }
    expect(daysBetween(DateTime(2026, 3, 28), DateTime(2026, 3, 30)), 2);
    expect(daysBetween(DateTime(2026, 10, 26), DateTime(2026, 10, 24)), -2);
  });

  test('every cell of a month grid is its own day, at midnight', () {
    for (final month in [DateTime(2026, 3), DateTime(2026, 10)]) {
      final layout = MonthLayout(
        month: month,
        mondayFirst: true,
        selected: null,
        weekCollapse: 0,
        size: const Size(400, 400),
      );
      final seen = <DateTime>{};
      for (var row = 0; row < layout.rows; row++) {
        for (var col = 0; col < 7; col++) {
          final day = layout.dayOfCell(row, col);
          expect(_midnight(day), isTrue, reason: '$day');
          expect(seen.add(day), isTrue, reason: '$day twice');
          expect(layout.rectOf(day), isNotNull);
        }
      }
    }
  });

  test('the week holding a day after the change is the one picked', () {
    // Monday the 30th of March opens the sixth row of March 2026.
    final layout = MonthLayout(
      month: DateTime(2026, 3),
      mondayFirst: true,
      selected: DateTime(2026, 3, 30),
      weekCollapse: 1,
      size: const Size(400, 400),
    );
    expect(layout.selectedRow, 5);
  });

  test('holidays counted from Easter fall on midnight', () {
    // Easter 2027 is the day the clocks go forward.
    for (final country in ['DE', 'FR', 'PL', 'NL', 'IT', 'ES', 'UA', 'RU']) {
      for (final year in [2024, 2027]) {
        for (final holiday in Holidays.forYear(country, year)) {
          expect(
            _midnight(holiday.date),
            isTrue,
            reason: '$country ${holiday.name} ${holiday.date}',
          );
        }
      }
    }
    final whit = Holidays.forYear(
      'DE',
      2027,
    ).firstWhere((h) => h.name == 'Pfingstmontag');
    expect(whit.date, DateTime(2027, 5, 17));
  });

  test('an all-day reminder keeps its hour on the day of the change', () {
    for (final change in changes) {
      final task = Task(
        id: 1,
        listId: 1,
        title: 't',
        dueAt: change.millisecondsSinceEpoch,
        createdAt: 0,
      );
      expect(
        Reminders.whenToAnnounce(task, 9 * 60),
        DateTime(change.year, change.month, change.day, 9),
      );
    }
  });
}

import 'package:caldo/l10n/strings.dart';
import 'package:caldo/models/task.dart';
import 'package:caldo/utils/dates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting());
  tearDown(() => S.use('en'));

  group('Russian', () {
    setUp(() => S.use('ru'));

    test('counts in three forms', () {
      final s = S.current;
      expect(s.daysInARow(1), 'день подряд');
      expect(s.daysInARow(3), 'дня подряд');
      expect(s.daysInARow(5), 'дней подряд');
      expect(s.daysInARow(11), 'дней подряд');
      expect(s.daysInARow(21), 'день подряд');
      expect(s.daysInARow(22), 'дня подряд');
      expect(s.hoursBefore(2), 'за 2 часа');
      expect(s.hoursBefore(5), 'за 5 часов');
      expect(s.shownForNext(30), 'Задачи с датой показаны на 30 дней вперёд.');
    });

    test('dates open a line with a capital and put the day first', () {
      // A Monday, whatever year the test is run in; the year is written
      // after it when it is not the current one, hence the prefixes.
      final day = DateTime(2026, 11, 2);
      expect(Dates.dayDate(day), startsWith('Пн, 2 нояб'));
      expect(Dates.shortDay(day), startsWith('2 нояб'));
      expect(Dates.longDay(day), startsWith('Понедельник, 2 ноября'));
      // In full on the header: the short form carries a full stop.
      expect(Dates.monthTitle(DateTime(DateTime.now().year, 11)), 'Ноябрь');
    });

    test('words for nearby days, leads and the reminder line', () {
      expect(Dates.dayWord(DateTime.now()), 'Сегодня');
      expect(Dates.lead(0), 'в срок');
      expect(Dates.lead(15), 'за 15 мин');
      expect(Dates.lead(Duration.minutesPerDay), 'за день');
      final s = S.current;
      expect(s.dueLine(time: '15:00', past: false), 'Срок: сегодня в 15:00');
      expect(s.dueLine(day: s.tomorrowInline, past: false), 'Срок: завтра');
      expect(s.repeatField(Repeat.weekly), 'Повтор: каждую неделю');
    });
  });

  test('English is unchanged', () {
    S.use('en');
    final s = S.current;
    expect(s.dueLine(time: '3:00 PM', past: false), 'Due at 3:00 PM');
    expect(s.dueLine(day: 'tomorrow', past: false), 'Due tomorrow');
    expect(s.repeatField(Repeat.weekly), 'Repeat: every week');
    expect(Dates.lead(60), '1 hour before');
    expect(Dates.monthTitle(DateTime(DateTime.now().year, 11)), 'Nov');
  });
}

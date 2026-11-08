import 'package:caldo/l10n/strings.dart';
import 'package:caldo/l10n/words_en.dart';
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
      expect(s.repeatName(Repeat.weekly), 'Каждую неделю');
      expect(
        s.repeatName(const Repeat(unit: RepeatUnit.week, every: 3)),
        'Каждые 3 недели',
      );
    });
  });

  test('English is unchanged', () {
    S.use('en');
    final s = S.current;
    expect(s.dueLine(time: '3:00 PM', past: false), 'Due at 3:00 PM');
    expect(s.dueLine(day: 'tomorrow', past: false), 'Due tomorrow');
    expect(s.repeatName(Repeat.weekly), 'Every week');
    expect(Dates.lead(60), '1 hour before');
    expect(Dates.monthTitle(DateTime(DateTime.now().year, 11)), 'Nov');
  });

  group('every language', () {
    Set<String> holes(Object text) => {
      for (final m in RegExp(
        r'\{(\w+)\}',
      ).allMatches(text is List ? text.join() : text as String))
        m.group(1)!,
    };

    test('has every word, with the same blanks to fill in', () {
      for (final code in S.names.keys) {
        S.use(code);
        for (final key in en.keys) {
          final own = S.current.hasOwn(key);
          expect(own, isTrue, reason: '$code is missing $key');
          expect(
            holes(S.current.raw(key)),
            holes(en[key]!),
            reason: '$code has different blanks in $key',
          );
        }
      }
    });

    test('counts by its own rule', () {
      S.use('pl');
      expect(S.current.daysInARow(1), 'dzień z rzędu');
      expect(S.current.daysInARow(22), 'dni z rzędu');
      expect(S.current.hoursBefore(21), '21 godzin wcześniej');
      S.use('uk');
      expect(S.current.daysBefore(3), 'за 3 дні');
      expect(Dates.lead(14 * Duration.minutesPerDay), 'за 2 тижні');
      S.use('fr');
      expect(S.current.daysInARow(0), 'jour d’affilée');
      expect(S.current.daysInARow(2), 'jours d’affilée');
      S.use('tr');
      expect(S.current.daysBefore(5), '5 gün önce');
      S.use('de');
      expect(S.current.removedCompleted(3), '3 erledigte Aufgaben entfernt');
    });

    test('dates follow the language', () {
      S.use('de');
      expect(Dates.dayDate(DateTime(2026, 11, 2)), startsWith('Mo., 2. Nov'));
      S.use('fr');
      expect(Dates.monthTitle(DateTime(DateTime.now().year, 11)), 'Novembre');
    });
  });
}

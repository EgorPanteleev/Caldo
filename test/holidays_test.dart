import 'package:caldo/data/holidays.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DateTime? dateOf(String country, int year, String name) {
    for (final holiday in Holidays.forYear(country, year)) {
      if (holiday.name == name) return holiday.date;
    }
    return null;
  }

  group('fixed dates', () {
    test('Russia keeps its new year run and its national days', () {
      final year = Holidays.forYear('RU', 2026);
      expect(dateOf('RU', 2026, 'Orthodox Christmas'), DateTime(2026, 1, 7));
      expect(dateOf('RU', 2026, 'Victory Day'), DateTime(2026, 5, 9));
      expect(dateOf('RU', 2026, 'Unity Day'), DateTime(2026, 11, 4));
      // 1-6 and 8 January, plus Christmas on the 7th.
      final january = year.where((h) => h.date.month == 1).length;
      expect(january, 8);
    });
  });

  group('weekday rules', () {
    test('US Thanksgiving is the fourth Thursday of November', () {
      expect(dateOf('US', 2026, 'Thanksgiving'), DateTime(2026, 11, 26));
      expect(dateOf('US', 2027, 'Thanksgiving'), DateTime(2027, 11, 25));
    });

    test('US Memorial Day is the last Monday of May', () {
      expect(dateOf('US', 2026, 'Memorial Day'), DateTime(2026, 5, 25));
      expect(dateOf('US', 2028, 'Memorial Day'), DateTime(2028, 5, 29));
    });

    test('US Labor Day is the first Monday of September', () {
      expect(dateOf('US', 2026, 'Labor Day'), DateTime(2026, 9, 7));
    });
  });

  group('Easter', () {
    test('Gregorian Easter matches the known dates', () {
      expect(Holidays.gregorianEaster(2026), DateTime(2026, 4, 5));
      expect(Holidays.gregorianEaster(2027), DateTime(2027, 3, 28));
      expect(Holidays.gregorianEaster(2030), DateTime(2030, 4, 21));
    });

    test('UK bank holidays hang off it', () {
      expect(dateOf('GB', 2026, 'Good Friday'), DateTime(2026, 4, 3));
      expect(dateOf('GB', 2026, 'Easter Monday'), DateTime(2026, 4, 6));
    });

    test('Orthodox Easter runs on the Julian reckoning', () {
      expect(Holidays.orthodoxEaster(2026), DateTime(2026, 4, 12));
      expect(dateOf('UA', 2026, 'Easter'), DateTime(2026, 4, 12));
      // Trinity Sunday is seven weeks later.
      expect(dateOf('UA', 2026, 'Trinity Sunday'), DateTime(2026, 5, 31));
    });
  });

  group('lookups', () {
    test('a month carries only its own holidays', () {
      final december = Holidays.forMonth('GB', 2026, 12);
      expect(december[DateTime(2026, 12, 25)]?.single.name, 'Christmas Day');
      expect(december[DateTime(2026, 12, 26)]?.single.name, 'Boxing Day');
      expect(december[DateTime(2026, 11, 11)], isNull);
    });

    test('the neighbours of a month come along for the grid', () {
      final around = Holidays.around('US', DateTime(2026, 12));
      // November's Thanksgiving and January's New Year both show up.
      expect(around[DateTime(2026, 11, 26)], isNotNull);
      expect(around[DateTime(2027, 1, 1)], isNotNull);
    });

    test('a country with no table has no holidays', () {
      expect(Holidays.forYear('ZZ', 2026), isEmpty);
      expect(Holidays.forYear(null, 2026), isEmpty);
      expect(Holidays.forMonth(null, 2026, 5), isEmpty);
    });

    test('every listed country actually has a table', () {
      for (final code in Holidays.countries.keys) {
        expect(Holidays.forYear(code, 2026), isNotEmpty, reason: code);
      }
    });
  });
}

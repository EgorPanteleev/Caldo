import 'dart:ui' show PlatformDispatcher;

/// A public holiday on a given day.
class Holiday {
  final DateTime date;
  final String name;

  const Holiday(this.date, this.name);
}

/// One entry in a country's table: a name and the rule that dates it.
class _Rule {
  final String name;
  final DateTime Function(int year) on;

  const _Rule(this.name, this.on);
}

/// Public holidays, worked out on the device — no network, no data to keep in
/// step. Each country is a small table of rules: fixed dates, the nth weekday
/// of a month, or an offset from Easter.
class Holidays {
  Holidays._();

  /// The countries with a table here, by ISO code.
  static const countries = <String, String>{
    'AU': 'Australia',
    'BY': 'Belarus',
    'CA': 'Canada',
    'DE': 'Germany',
    'ES': 'Spain',
    'FR': 'France',
    'GB': 'United Kingdom',
    'IT': 'Italy',
    'KZ': 'Kazakhstan',
    'NL': 'Netherlands',
    'PL': 'Poland',
    'RU': 'Russia',
    'TR': 'Türkiye',
    'UA': 'Ukraine',
    'US': 'United States',
  };

  /// The country the device is set to, when there is a table for it.
  static String? detectCountry() {
    final code = PlatformDispatcher.instance.locale.countryCode?.toUpperCase();
    return code != null && countries.containsKey(code) ? code : null;
  }

  /// Every holiday of [year] in [country], or nothing when it has no table.
  static List<Holiday> forYear(String? country, int year) {
    final rules = _tables[country];
    if (rules == null) return const [];
    return [
      for (final rule in rules) Holiday(rule.on(year), rule.name),
    ];
  }

  /// The holidays of one month, keyed by day.
  static Map<DateTime, List<Holiday>> forMonth(
    String? country,
    int year,
    int month,
  ) {
    final map = <DateTime, List<Holiday>>{};
    for (final holiday in forYear(country, year)) {
      if (holiday.date.month != month || holiday.date.year != year) continue;
      map.putIfAbsent(holiday.date, () => []).add(holiday);
    }
    return map;
  }

  /// Three years' worth of rules, run and kept. Nothing here depends on
  /// anything but the country and the year, and [around] is called from inside
  /// the calendar's build — which runs on every frame the month is being
  /// dragged open, so working them out afresh each time was three full years
  /// of rules per frame per page on screen.
  static final _cache = <String, Map<DateTime, List<Holiday>>>{};

  /// The holidays of [month] together with its neighbours, so the days of
  /// adjacent months shown in a grid are marked too.
  static Map<DateTime, List<Holiday>> around(String? country, DateTime month) {
    return _cache.putIfAbsent('$country|${month.year}-${month.month}', () {
      final map = <DateTime, List<Holiday>>{};
      for (final m in [
        DateTime(month.year, month.month - 1),
        DateTime(month.year, month.month),
        DateTime(month.year, month.month + 1),
      ]) {
        map.addAll(forMonth(country, m.year, m.month));
      }
      return map;
    });
  }

  // ---- Rule helpers -------------------------------------------------------

  static DateTime Function(int) _fixed(int month, int day) =>
      (year) => DateTime(year, month, day);

  /// The [n]th [weekday] of [month]; n = 1 is the first.
  static DateTime Function(int) _nth(int month, int weekday, int n) =>
      (year) {
        final first = DateTime(year, month, 1);
        final shift = (weekday - first.weekday + 7) % 7;
        return DateTime(year, month, 1 + shift + (n - 1) * 7);
      };

  static DateTime Function(int) _last(int month, int weekday) => (year) {
        final last = DateTime(year, month + 1, 0);
        final shift = (last.weekday - weekday + 7) % 7;
        return DateTime(year, month, last.day - shift);
      };

  static DateTime Function(int) _easter(int offsetDays) =>
      (year) => gregorianEaster(year).add(Duration(days: offsetDays));

  static DateTime Function(int) _orthodox(int offsetDays) =>
      (year) => orthodoxEaster(year).add(Duration(days: offsetDays));

  /// Gregorian Easter Sunday (the anonymous Gregorian algorithm).
  static DateTime gregorianEaster(int year) {
    final a = year % 19;
    final b = year ~/ 100;
    final c = year % 100;
    final d = b ~/ 4;
    final e = b % 4;
    final f = (b + 8) ~/ 25;
    final g = (b - f + 1) ~/ 3;
    final h = (19 * a + b - d - g + 15) % 30;
    final i = c ~/ 4;
    final k = c % 4;
    final l = (32 + 2 * e + 2 * i - h - k) % 7;
    final m = (a + 11 * h + 22 * l) ~/ 451;
    final month = (h + l - 7 * m + 114) ~/ 31;
    final day = ((h + l - 7 * m + 114) % 31) + 1;
    return DateTime(year, month, day);
  }

  /// Orthodox Easter Sunday, converted from the Julian calendar.
  static DateTime orthodoxEaster(int year) {
    final a = year % 4;
    final b = year % 7;
    final c = year % 19;
    final d = (19 * c + 15) % 30;
    final e = (2 * a + 4 * b - d + 34) % 7;
    final month = (d + e + 114) ~/ 31;
    final day = ((d + e + 114) % 31) + 1;
    final julian = DateTime(year, month, day);
    // The Julian calendar runs 13 days behind through 1900-2099.
    return julian.add(const Duration(days: 13));
  }

  // ---- Country tables -----------------------------------------------------

  static final Map<String, List<_Rule>> _tables = {
    'RU': [
      _Rule('New Year holidays', _fixed(1, 1)),
      _Rule('New Year holidays', _fixed(1, 2)),
      _Rule('New Year holidays', _fixed(1, 3)),
      _Rule('New Year holidays', _fixed(1, 4)),
      _Rule('New Year holidays', _fixed(1, 5)),
      _Rule('New Year holidays', _fixed(1, 6)),
      _Rule('Orthodox Christmas', _fixed(1, 7)),
      _Rule('New Year holidays', _fixed(1, 8)),
      _Rule('Defender of the Fatherland Day', _fixed(2, 23)),
      _Rule("International Women's Day", _fixed(3, 8)),
      _Rule('Spring and Labour Day', _fixed(5, 1)),
      _Rule('Victory Day', _fixed(5, 9)),
      _Rule('Russia Day', _fixed(6, 12)),
      _Rule('Unity Day', _fixed(11, 4)),
    ],
    'UA': [
      _Rule("New Year's Day", _fixed(1, 1)),
      _Rule('Christmas', _fixed(12, 25)),
      _Rule("International Women's Day", _fixed(3, 8)),
      _Rule('Easter', _orthodox(0)),
      _Rule('Trinity Sunday', _orthodox(49)),
      _Rule('Labour Day', _fixed(5, 1)),
      _Rule('Day of Remembrance and Victory', _fixed(5, 9)),
      _Rule('Constitution Day', _fixed(6, 28)),
      _Rule('Statehood Day', _fixed(7, 15)),
      _Rule('Independence Day', _fixed(8, 24)),
      _Rule('Defenders Day', _fixed(10, 1)),
    ],
    'BY': [
      _Rule("New Year's Day", _fixed(1, 1)),
      _Rule("New Year holiday", _fixed(1, 2)),
      _Rule('Orthodox Christmas', _fixed(1, 7)),
      _Rule("International Women's Day", _fixed(3, 8)),
      _Rule('Labour Day', _fixed(5, 1)),
      _Rule('Victory Day', _fixed(5, 9)),
      _Rule('Independence Day', _fixed(7, 3)),
      _Rule('October Revolution Day', _fixed(11, 7)),
      _Rule('Catholic Christmas', _fixed(12, 25)),
    ],
    'KZ': [
      _Rule("New Year's Day", _fixed(1, 1)),
      _Rule('New Year holiday', _fixed(1, 2)),
      _Rule('Orthodox Christmas', _fixed(1, 7)),
      _Rule("International Women's Day", _fixed(3, 8)),
      _Rule('Nauryz', _fixed(3, 21)),
      _Rule('Nauryz', _fixed(3, 22)),
      _Rule('Nauryz', _fixed(3, 23)),
      _Rule('Unity Day', _fixed(5, 1)),
      _Rule("Defender of the Fatherland Day", _fixed(5, 7)),
      _Rule('Victory Day', _fixed(5, 9)),
      _Rule('Capital City Day', _fixed(7, 6)),
      _Rule('Constitution Day', _fixed(8, 30)),
      _Rule('Republic Day', _fixed(10, 25)),
      _Rule('Independence Day', _fixed(12, 16)),
    ],
    'US': [
      _Rule("New Year's Day", _fixed(1, 1)),
      _Rule('Martin Luther King Jr. Day', _nth(1, DateTime.monday, 3)),
      _Rule("Presidents' Day", _nth(2, DateTime.monday, 3)),
      _Rule('Memorial Day', _last(5, DateTime.monday)),
      _Rule('Juneteenth', _fixed(6, 19)),
      _Rule('Independence Day', _fixed(7, 4)),
      _Rule('Labor Day', _nth(9, DateTime.monday, 1)),
      _Rule('Columbus Day', _nth(10, DateTime.monday, 2)),
      _Rule('Veterans Day', _fixed(11, 11)),
      _Rule('Thanksgiving', _nth(11, DateTime.thursday, 4)),
      _Rule('Christmas Day', _fixed(12, 25)),
    ],
    'GB': [
      _Rule("New Year's Day", _fixed(1, 1)),
      _Rule('Good Friday', _easter(-2)),
      _Rule('Easter Monday', _easter(1)),
      _Rule('Early May Bank Holiday', _nth(5, DateTime.monday, 1)),
      _Rule('Spring Bank Holiday', _last(5, DateTime.monday)),
      _Rule('Summer Bank Holiday', _last(8, DateTime.monday)),
      _Rule('Christmas Day', _fixed(12, 25)),
      _Rule('Boxing Day', _fixed(12, 26)),
    ],
    'DE': [
      _Rule('Neujahr', _fixed(1, 1)),
      _Rule('Karfreitag', _easter(-2)),
      _Rule('Ostermontag', _easter(1)),
      _Rule('Tag der Arbeit', _fixed(5, 1)),
      _Rule('Christi Himmelfahrt', _easter(39)),
      _Rule('Pfingstmontag', _easter(50)),
      _Rule('Tag der Deutschen Einheit', _fixed(10, 3)),
      _Rule('Erster Weihnachtstag', _fixed(12, 25)),
      _Rule('Zweiter Weihnachtstag', _fixed(12, 26)),
    ],
    'FR': [
      _Rule("Jour de l'an", _fixed(1, 1)),
      _Rule('Lundi de Pâques', _easter(1)),
      _Rule('Fête du Travail', _fixed(5, 1)),
      _Rule('Victoire 1945', _fixed(5, 8)),
      _Rule('Ascension', _easter(39)),
      _Rule('Lundi de Pentecôte', _easter(50)),
      _Rule('Fête nationale', _fixed(7, 14)),
      _Rule('Assomption', _fixed(8, 15)),
      _Rule('Toussaint', _fixed(11, 1)),
      _Rule('Armistice 1918', _fixed(11, 11)),
      _Rule('Noël', _fixed(12, 25)),
    ],
    'ES': [
      _Rule('Año Nuevo', _fixed(1, 1)),
      _Rule('Epifanía', _fixed(1, 6)),
      _Rule('Viernes Santo', _easter(-2)),
      _Rule('Día del Trabajador', _fixed(5, 1)),
      _Rule('Asunción', _fixed(8, 15)),
      _Rule('Fiesta Nacional', _fixed(10, 12)),
      _Rule('Todos los Santos', _fixed(11, 1)),
      _Rule('Día de la Constitución', _fixed(12, 6)),
      _Rule('Inmaculada Concepción', _fixed(12, 8)),
      _Rule('Navidad', _fixed(12, 25)),
    ],
    'IT': [
      _Rule('Capodanno', _fixed(1, 1)),
      _Rule('Epifania', _fixed(1, 6)),
      _Rule("Lunedì dell'Angelo", _easter(1)),
      _Rule('Festa della Liberazione', _fixed(4, 25)),
      _Rule('Festa del Lavoro', _fixed(5, 1)),
      _Rule('Festa della Repubblica', _fixed(6, 2)),
      _Rule('Ferragosto', _fixed(8, 15)),
      _Rule('Ognissanti', _fixed(11, 1)),
      _Rule('Immacolata', _fixed(12, 8)),
      _Rule('Natale', _fixed(12, 25)),
      _Rule('Santo Stefano', _fixed(12, 26)),
    ],
    'PL': [
      _Rule('Nowy Rok', _fixed(1, 1)),
      _Rule('Trzech Króli', _fixed(1, 6)),
      _Rule('Wielkanoc', _easter(0)),
      _Rule('Poniedziałek Wielkanocny', _easter(1)),
      _Rule('Święto Pracy', _fixed(5, 1)),
      _Rule('Święto Konstytucji', _fixed(5, 3)),
      _Rule('Boże Ciało', _easter(60)),
      _Rule('Wniebowzięcie NMP', _fixed(8, 15)),
      _Rule('Wszystkich Świętych', _fixed(11, 1)),
      _Rule('Święto Niepodległości', _fixed(11, 11)),
      _Rule('Boże Narodzenie', _fixed(12, 25)),
      _Rule('Drugi dzień Bożego Narodzenia', _fixed(12, 26)),
    ],
    'NL': [
      _Rule('Nieuwjaarsdag', _fixed(1, 1)),
      _Rule('Goede Vrijdag', _easter(-2)),
      _Rule('Tweede Paasdag', _easter(1)),
      _Rule('Koningsdag', _fixed(4, 27)),
      _Rule('Bevrijdingsdag', _fixed(5, 5)),
      _Rule('Hemelvaartsdag', _easter(39)),
      _Rule('Tweede Pinksterdag', _easter(50)),
      _Rule('Eerste Kerstdag', _fixed(12, 25)),
      _Rule('Tweede Kerstdag', _fixed(12, 26)),
    ],
    'CA': [
      _Rule("New Year's Day", _fixed(1, 1)),
      _Rule('Good Friday', _easter(-2)),
      _Rule('Victoria Day', _last(5, DateTime.monday)),
      _Rule('Canada Day', _fixed(7, 1)),
      _Rule('Labour Day', _nth(9, DateTime.monday, 1)),
      _Rule('Thanksgiving', _nth(10, DateTime.monday, 2)),
      _Rule('Remembrance Day', _fixed(11, 11)),
      _Rule('Christmas Day', _fixed(12, 25)),
      _Rule('Boxing Day', _fixed(12, 26)),
    ],
    'AU': [
      _Rule("New Year's Day", _fixed(1, 1)),
      _Rule('Australia Day', _fixed(1, 26)),
      _Rule('Good Friday', _easter(-2)),
      _Rule('Easter Monday', _easter(1)),
      _Rule('Anzac Day', _fixed(4, 25)),
      _Rule('Christmas Day', _fixed(12, 25)),
      _Rule('Boxing Day', _fixed(12, 26)),
    ],
    'TR': [
      _Rule('Yılbaşı', _fixed(1, 1)),
      _Rule('Ulusal Egemenlik ve Çocuk Bayramı', _fixed(4, 23)),
      _Rule('Emek ve Dayanışma Günü', _fixed(5, 1)),
      _Rule('Atatürk’ü Anma, Gençlik ve Spor Bayramı', _fixed(5, 19)),
      _Rule('Demokrasi ve Millî Birlik Günü', _fixed(7, 15)),
      _Rule('Zafer Bayramı', _fixed(8, 30)),
      _Rule('Cumhuriyet Bayramı', _fixed(10, 29)),
    ],
  };
}

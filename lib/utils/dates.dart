import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter/widgets.dart' show Characters;
import 'package:intl/intl.dart';

import '../l10n/strings.dart';
import '../models/task.dart';
import '../providers/task_provider.dart' show dayOf;

/// Date/time formatting shared by the calendar, the agenda and task rows.
///
/// In whichever language `S` has in force, which also sets `intl`'s.
/// English keeps the patterns it was drawn with — "Sat, 4 Oct", the day
/// before the month. Every other language takes `intl`'s own pattern for
/// the same thing, which knows where its language puts the day, the month
/// and the dots ("Sa., 4. Okt." in German, "sam. 4 oct." in French). Many
/// write weekdays and months in lower case, so whatever opens a line is
/// given a capital of its own ([_lead]).
class Dates {
  static bool get _english => S.current.code == 'en';

  /// [text] with a capital first letter: "пн, 2 нояб." opens a line as
  /// "Пн, 2 нояб.".
  static String _lead(String text) => text.isEmpty
      ? text
      : Characters(text).first.toUpperCase() + Characters(text).skip(1).string;

  /// The calendar's month header: "Oct" while browsing the current year,
  /// "Oct 2027" once the year is no longer this one. In any other language
  /// the month is written in full — "Ноябрь", "November" — since most short
  /// forms carry a full stop, which reads as a typo on a header standing
  /// alone.
  static String monthTitle(DateTime month) {
    final thisYear = month.year == DateTime.now().year;
    if (!_english) {
      return _lead(DateFormat(thisYear ? 'LLLL' : 'LLLL y').format(month));
    }
    return DateFormat(thisYear ? 'MMM' : 'MMM yyyy').format(month);
  }

  /// "M", "T", "W", … starting on Monday or Sunday, for the calendar header.
  static List<String> weekdayLabels({required bool mondayFirst}) {
    // 2024-01-01 was a Monday, giving a stable base to read names off.
    final monday = DateTime(2024, 1, 1);
    final names = [
      for (var i = 0; i < 7; i++) weekdayNarrow(monday.add(Duration(days: i))),
    ];
    return mondayFirst ? names : [names.last, ...names.take(6)];
  }

  /// The one-letter form — "M" — falling back to the first letter of the
  /// short name for locales where the narrow pattern gives something longer.
  static String weekdayNarrow(DateTime day) {
    final narrow = DateFormat('EEEEE').format(day);
    if (Characters(narrow).length == 1) return narrow.toUpperCase();
    return Characters(DateFormat('EEE').format(day)).first.toUpperCase();
  }

  /// Sundays, which the calendar marks in red.
  static bool isSunday(DateTime day) => day.weekday == DateTime.sunday;

  /// A day, spoken the way a person would: "Today", "Tomorrow", "Sat, 4 Oct",
  /// and with the year once it is no longer the current one.
  static String day(DateTime date) => dayWord(date) ?? dayDate(date);

  /// The date alone, with no "Today" standing in for it: "Sat, 4 Oct". The
  /// run of days in Schedule writes both — the word on a badge, the date
  /// beside it — so a reader never has to work out which day "Today" is.
  static String dayDate(DateTime date) {
    final d = dayOf(date);
    final thisYear = d.year == dayOf(DateTime.now()).year;
    if (!_english) {
      return _lead(
        (thisYear ? DateFormat.MMMEd() : DateFormat.yMMMEd()).format(d),
      );
    }
    return DateFormat(thisYear ? 'EEE, d MMM' : 'EEE, d MMM yyyy').format(d);
  }

  /// The word for a day near today — "Today", "Tomorrow", "Yesterday" — or
  /// null for any other day.
  static String? dayWord(DateTime date) {
    final diff = dayOf(date).difference(dayOf(DateTime.now())).inDays;
    return switch (diff) {
      0 => S.current.today,
      1 => S.current.tomorrow,
      -1 => S.current.yesterday,
      _ => null,
    };
  }

  /// A longer form for headers: "Saturday, 4 October".
  static String longDay(DateTime date) {
    final thisYear = date.year == dayOf(DateTime.now()).year;
    if (!_english) {
      return _lead(
        (thisYear ? DateFormat.MMMMEEEEd() : DateFormat.yMMMMEEEEd()).format(
          date,
        ),
      );
    }
    return DateFormat(
      thisYear ? 'EEEE, d MMMM' : 'EEEE, d MMMM yyyy',
    ).format(date);
  }

  /// Whether times are written on a 24-hour clock — what Settings says, or
  /// until it says anything, what the phone does (`SettingsProvider`).
  ///
  /// Read directly only by what is written away from any screen, which is a
  /// notification. A widget passes [time]'s `h24` from
  /// `MediaQuery.alwaysUse24HourFormatOf`, which the app sets from the same
  /// choice: reading it there is what has the widget redrawn when it changes.
  static bool use24Hour = false;

  /// "15:00" or "3:00 PM", as [use24Hour] — or [h24], where given — says.
  /// The one place a time of day is written, so the cards, the picker, its
  /// shortcuts and the notifications cannot disagree; they did, a 12-hour
  /// picker over 24-hour cards, until there was a setting for it.
  static String time(DateTime date, {bool? h24}) =>
      DateFormat((h24 ?? use24Hour) ? 'HH:mm' : 'h:mm a').format(date);

  /// "Sep 23" — compact enough for a hint or a chip; "2 нояб.", "2. Nov."
  /// in languages that put the day first.
  static String shortDay(DateTime date) =>
      (_english ? DateFormat('MMM d') : DateFormat.MMMd()).format(date);

  /// "Wednesday" — the weekday spelled out beside a big day number.
  static String weekdayLong(DateTime date) =>
      _lead(DateFormat('EEEE').format(date));

  /// "WED" — the weekday beside a big day number.
  static String weekdayShort(DateTime date) =>
      DateFormat('EEE').format(date).toUpperCase();

  /// [time], for a time with no date attached.
  static String clock(TimeOfDay time, {bool? h24}) =>
      Dates.time(DateTime(2000, 1, 1, time.hour, time.minute), h24: h24);

  /// How far ahead a reminder comes: "at the time", "15 min before",
  /// "1 hour before", "1 day before", "1 week before".
  static String lead(int minutes) {
    final s = S.current;
    if (minutes <= 0) return s.atTheTime;
    const week = Duration.minutesPerDay * DateTime.daysPerWeek;
    if (minutes % week == 0) return s.weeksBefore(minutes ~/ week);
    if (minutes % Duration.minutesPerDay == 0) {
      return s.daysBefore(minutes ~/ Duration.minutesPerDay);
    }
    if (minutes % 60 == 0) return s.hoursBefore(minutes ~/ 60);
    return s.minutesBefore(minutes);
  }

  /// How a task's due date reads on its row: "Today 18:30", "Yesterday", "".
  static String due(Task task, {bool? h24}) {
    final d = task.due;
    if (d == null) return '';
    return task.hasTime ? '${day(d)} ${time(d, h24: h24)}' : day(d);
  }
}

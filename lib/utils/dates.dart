import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter/widgets.dart' show Characters;
import 'package:intl/intl.dart';

import '../models/task.dart';
import '../providers/task_provider.dart' show dayOf;

/// Date/time formatting shared by the calendar, the agenda and task rows.
class Dates {
  /// The calendar's month header: "Oct" while browsing the current year,
  /// "Oct 2027" once the year is no longer this one.
  static String monthTitle(DateTime month) => month.year == DateTime.now().year
      ? DateFormat('MMM').format(month)
      : DateFormat('MMM yyyy').format(month);

  /// "M", "T", "W", … starting on Monday or Sunday, for the calendar header.
  static List<String> weekdayLabels({required bool mondayFirst}) {
    // 2024-01-01 was a Monday, giving a stable base to read names off.
    final monday = DateTime(2024, 1, 1);
    final names = [
      for (var i = 0; i < 7; i++) _narrowWeekday(monday.add(Duration(days: i))),
    ];
    return mondayFirst ? names : [names.last, ...names.take(6)];
  }

  /// The one-letter form, falling back to the first letter of the short name
  /// for locales where the narrow pattern gives something longer.
  static String _narrowWeekday(DateTime day) {
    final narrow = DateFormat('EEEEE').format(day);
    if (Characters(narrow).length == 1) return narrow.toUpperCase();
    return Characters(DateFormat('EEE').format(day)).first.toUpperCase();
  }

  /// Sundays, which the calendar marks in red.
  static bool isSunday(DateTime day) => day.weekday == DateTime.sunday;

  /// A day, spoken the way a person would: "Today", "Tomorrow", "Sat, 4 Oct",
  /// and with the year once it is no longer the current one.
  static String day(DateTime date) {
    final d = dayOf(date);
    final today = dayOf(DateTime.now());
    final diff = d.difference(today).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    if (diff == -1) return 'Yesterday';
    final pattern = d.year == today.year ? 'EEE, d MMM' : 'EEE, d MMM yyyy';
    return DateFormat(pattern).format(d);
  }

  /// The date alone, with no "Today" standing in for it: "Sat, 4 Oct". The
  /// run of days in Schedule writes both — the word on a badge, the date
  /// beside it — so a reader never has to work out which day "Today" is.
  static String dayDate(DateTime date) {
    final d = dayOf(date);
    final pattern = d.year == dayOf(DateTime.now()).year
        ? 'EEE, d MMM'
        : 'EEE, d MMM yyyy';
    return DateFormat(pattern).format(d);
  }

  /// The word for a day near today — "Today", "Tomorrow", "Yesterday" — or
  /// null for any other day.
  static String? dayWord(DateTime date) {
    final diff = dayOf(date).difference(dayOf(DateTime.now())).inDays;
    return switch (diff) {
      0 => 'Today',
      1 => 'Tomorrow',
      -1 => 'Yesterday',
      _ => null,
    };
  }

  /// A longer form for headers: "Saturday, 4 October".
  static String longDay(DateTime date) {
    final today = dayOf(DateTime.now());
    final pattern = date.year == today.year
        ? 'EEEE, d MMMM'
        : 'EEEE, d MMMM yyyy';
    return DateFormat(pattern).format(date);
  }

  static String time(DateTime date) => DateFormat('HH:mm').format(date);

  /// "Sep 23" — compact enough for a hint or a chip.
  static String shortDay(DateTime date) => DateFormat('MMM d').format(date);

  /// "Wednesday" — the weekday spelled out beside a big day number.
  static String weekdayLong(DateTime date) => DateFormat('EEEE').format(date);

  /// "WED" — the weekday beside a big day number.
  static String weekdayShort(DateTime date) =>
      DateFormat('EEE').format(date).toUpperCase();

  /// "9:00 AM" — how the time picker's own wheels read, so the shortcuts
  /// beneath them are written the same way.
  static String clock(TimeOfDay time) {
    final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${time.hour >= 12 ? 'PM' : 'AM'}';
  }

  /// The same 24-hour clock as [time], for a time with no date attached.
  static String formatTimeOfDay(TimeOfDay time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';

  /// How a task's due date reads on its row: "Today 18:30", "Yesterday", "".
  static String due(Task task) {
    final d = task.due;
    if (d == null) return '';
    return task.hasTime ? '${day(d)} ${time(d)}' : day(d);
  }
}

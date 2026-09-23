import 'package:intl/intl.dart';

import '../models/task.dart';
import '../providers/task_provider.dart' show dayOf;

/// Date/time formatting shared by the calendar, the agenda and task rows.
class Dates {
  /// "October 2026" — the calendar's month header.
  static String monthTitle(DateTime month) =>
      DateFormat('MMMM yyyy').format(month);

  /// "Mon", "Tue", … starting on Monday or Sunday, for the calendar header.
  static List<String> weekdayLabels({required bool mondayFirst}) {
    // 2024-01-01 was a Monday, giving a stable base to read names off.
    final monday = DateTime(2024, 1, 1);
    final names = [
      for (var i = 0; i < 7; i++)
        DateFormat('EEE').format(monday.add(Duration(days: i))),
    ];
    return mondayFirst ? names : [names.last, ...names.take(6)];
  }

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

  /// A longer form for headers: "Saturday, 4 October".
  static String longDay(DateTime date) {
    final today = dayOf(DateTime.now());
    final pattern =
        date.year == today.year ? 'EEEE, d MMMM' : 'EEEE, d MMMM yyyy';
    return DateFormat(pattern).format(date);
  }

  static String time(DateTime date) => DateFormat('HH:mm').format(date);

  /// How a task's due date reads on its row: "Today 18:30", "Yesterday", "".
  static String due(Task task) {
    final d = task.due;
    if (d == null) return '';
    return task.hasTime ? '${day(d)} ${time(d)}' : day(d);
  }
}

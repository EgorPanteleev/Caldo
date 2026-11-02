import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../providers/task_provider.dart' show dayOf;

/// One of the phone's calendars: an account's, a shared one, a subscription.
class DeviceCalendar {
  final String id;
  final String name;
  final String account;
  final Color color;

  const DeviceCalendar({
    required this.id,
    required this.name,
    required this.account,
    required this.color,
  });
}

/// One occurrence of an event from the phone's calendars. Read-only, like a
/// holiday: Caldo shows it and opens it in the calendar app, and nothing more.
class CalendarEvent {
  final int eventId;
  final String title;

  /// For an all-day event, the first day and the day after the last, at
  /// local midnight; otherwise the moments it starts and ends.
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final Color color;
  final String calendarId;
  final String calendarName;

  /// What Android was handed, for opening the event at this occurrence.
  final int beginMs;
  final int endMs;

  const CalendarEvent({
    required this.eventId,
    required this.title,
    required this.start,
    required this.end,
    required this.allDay,
    required this.color,
    required this.calendarId,
    required this.calendarName,
    required this.beginMs,
    required this.endMs,
  });

  /// An all-day event is stored at midnight UTC on its dates, which is the
  /// day before somewhere west of Greenwich: its dates are read off in UTC
  /// and set at local midnight.
  factory CalendarEvent.fromMap(Map<Object?, Object?> map) {
    final begin = (map['begin'] as num).toInt();
    final end = (map['end'] as num).toInt();
    final allDay = map['allDay'] == true;
    DateTime dayIn(int ms) {
      final utc = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
      return DateTime(utc.year, utc.month, utc.day);
    }

    return CalendarEvent(
      eventId: (map['id'] as num).toInt(),
      title: map['title'] as String? ?? '',
      start: allDay ? dayIn(begin) : DateTime.fromMillisecondsSinceEpoch(begin),
      end: allDay ? dayIn(end) : DateTime.fromMillisecondsSinceEpoch(end),
      allDay: allDay,
      color: Color((map['colour'] as num).toInt()),
      calendarId: map['calendar'] as String? ?? '',
      calendarName: map['calendarName'] as String? ?? '',
      beginMs: begin,
      endMs: end,
    );
  }

  /// Every day the event is on: an all-day one up to the day before its
  /// end, a timed one up to the day its last moment falls on.
  List<DateTime> get days {
    final first = dayOf(start);
    final last = allDay
        ? dayOf(end).subtract(const Duration(days: 1))
        : dayOf(
            end.isAfter(start)
                ? end.subtract(const Duration(milliseconds: 1))
                : start,
          );
    return [
      for (
        var d = first;
        !d.isAfter(last);
        d = DateTime(d.year, d.month, d.day + 1)
      )
        d,
      if (last.isBefore(first)) first,
    ];
  }
}

/// Talks to the activity about the phone's calendars (`MainActivity`).
///
/// A no-op until [enable], as the alarms and the widget are: the widget tests
/// have no activity to answer, and a missing answer is a wait, not an error.
class DeviceCalendars {
  DeviceCalendars._();

  static const _channel = MethodChannel('caldo/calendars');
  static bool _enabled = false;

  static void enable() => _enabled = true;

  static Future<T?> _call<T>(String method, [Object? args]) async {
    if (!_enabled) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('Calendars: $error');
      return null;
    }
  }

  static Future<bool> permitted() async =>
      await _call<bool>('permitted') ?? false;

  /// Asks Android to let Caldo read the calendars, if it may not already.
  static Future<bool> ask() async => await _call<bool>('ask') ?? false;

  static Future<List<DeviceCalendar>> calendars() async {
    final rows = await _call<List<Object?>>('calendars') ?? const [];
    return [
      for (final row in rows.cast<Map<Object?, Object?>>())
        DeviceCalendar(
          id: row['id'] as String,
          name: row['name'] as String? ?? '',
          account: row['account'] as String? ?? '',
          color: Color((row['colour'] as num).toInt()),
        ),
    ];
  }

  static Future<List<CalendarEvent>> events(DateTime from, DateTime to) async {
    final rows =
        await _call<List<Object?>>('events', {
          'from': from.millisecondsSinceEpoch,
          'to': to.millisecondsSinceEpoch,
        }) ??
        const [];
    return [
      for (final row in rows.cast<Map<Object?, Object?>>())
        CalendarEvent.fromMap(row),
    ];
  }

  /// Opens [event] in the calendar app, at this occurrence of it.
  static Future<bool> open(CalendarEvent event) async =>
      await _call<bool>('open', {
        'id': event.eventId,
        'begin': event.beginMs,
        'end': event.endMs,
      }) ??
      false;
}

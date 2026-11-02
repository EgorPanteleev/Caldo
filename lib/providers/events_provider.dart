import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../services/device_calendars.dart';
import 'task_provider.dart' show dayOf, TaskProvider;

/// The events from the phone's calendars that fall in the stretch of days
/// on screen, by day — what the grid, the day panel and Schedule draw beside
/// the tasks.
///
/// Read again when the app comes back to the front: the events are kept in
/// another app, and whatever was added there while Caldo was away should be
/// here when it is looked at again.
class EventsProvider extends ChangeNotifier {
  EventsProvider() {
    _lifecycle = AppLifecycleListener(onResume: _read);
  }

  late final AppLifecycleListener _lifecycle;

  bool _on = false;
  Set<String> _hidden = const {};

  /// The stretch asked for so far: the agenda's days always, and the month
  /// the calendar is on.
  DateTime? _month;

  Map<DateTime, List<CalendarEvent>> _byDay = const {};

  Map<DateTime, List<CalendarEvent>> get byDay => _byDay;

  List<CalendarEvent> on(DateTime day) => _byDay[dayOf(day)] ?? const [];

  /// Takes what Settings says: whether to show events at all, and which of
  /// the phone's calendars to leave out.
  void configure({required bool on, required Set<String> hidden}) {
    if (on == _on && setEquals(hidden, _hidden)) return;
    _on = on;
    _hidden = hidden;
    _read();
  }

  /// Has the events of [month] read as well, with a week either side of
  /// it, which is what the grid shows of its neighbours.
  void cover(DateTime month) {
    final first = DateTime(month.year, month.month);
    if (first == _month) return;
    _month = first;
    _read();
  }

  int _reads = 0;

  Future<void> _read() async {
    final read = ++_reads;
    if (!_on) {
      if (_byDay.isNotEmpty) {
        _byDay = const {};
        notifyListeners();
      }
      return;
    }
    final today = dayOf(DateTime.now());
    var from = today.subtract(const Duration(days: 1));
    var to = today.add(const Duration(days: TaskProvider.agendaDays + 1));
    final month = _month;
    if (month != null) {
      final monthFrom = month.subtract(const Duration(days: 7));
      final monthTo = DateTime(month.year, month.month + 1, 8);
      if (monthFrom.isBefore(from)) from = monthFrom;
      if (monthTo.isAfter(to)) to = monthTo;
    }
    final events = await DeviceCalendars.events(from, to);
    // A slower read started earlier must not land over a newer one.
    if (read != _reads) return;
    final byDay = <DateTime, List<CalendarEvent>>{};
    for (final event in events) {
      if (_hidden.contains(event.calendarId)) continue;
      for (final day in event.days) {
        byDay.putIfAbsent(day, () => []).add(event);
      }
    }
    // All-day ones first, as a day's untimed tasks come first, then by when
    // they start.
    for (final list in byDay.values) {
      list.sort((a, b) {
        if (a.allDay != b.allDay) return a.allDay ? -1 : 1;
        return a.start.compareTo(b.start);
      });
    }
    _byDay = byDay;
    notifyListeners();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }
}

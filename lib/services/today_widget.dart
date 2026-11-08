import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/strings.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';

/// Hands the home-screen widget what it shows (`TodayWidget.kt`).
///
/// The widget is drawn by the launcher, with the app usually not running, so
/// it cannot ask for anything: it is left a copy of the agenda in the app's
/// own preferences, and the application redraws it whenever that copy
/// changes. Days are written as dates rather than as "today" — the widget
/// works out which day is today when it draws, so a copy left overnight is
/// still sorted into the right runs in the morning.
///
/// A no-op until [enable], like the alarms: the widget tests drive the real
/// provider and have no preferences to write to.
class TodayWidget {
  TodayWidget._();

  static const key = 'today_widget';

  static bool _enabled = false;

  /// What was last published from, so a change of language can write the
  /// copy again without waiting for the lists to be read.
  static TaskProvider? _last;

  static void enable() => _enabled = true;

  static const _launches = MethodChannel('caldo/widget');

  /// Has [open] called for each tap on the widget that asks for a form —
  /// with a task's id for one of its rows, with null for its add button —
  /// including the tap the app was started by, if it was.
  static Future<void> listen(void Function(int? task) open) async {
    if (!_enabled) return;
    void take(Object? request) {
      if (request is Map) open(request['task'] as int?);
    }

    _launches.setMethodCallHandler((call) async {
      if (call.method == 'open') take(call.arguments);
    });
    try {
      take(await _launches.invokeMethod<Object?>('take'));
    } on MissingPluginException {
      // Not on Android.
    }
  }

  /// Writes what [tasks] has loaded: the overdue backlog and then the dated
  /// days in order, each in the order its screen shows it. Undated tasks
  /// stay out — the widget is about what is due.
  static Future<void> publish(TaskProvider tasks) async {
    if (!_enabled) return;
    _last = tasks;
    try {
      final rows = [
        for (final task in tasks.allOverdue) _row(task, tasks),
        for (final day in tasks.allUpcomingByDay.keys.toList()..sort())
          for (final task in tasks.allUpcomingByDay[day]!) _row(task, tasks),
      ];
      // Written every time, though most re-reads of the lists change
      // nothing the widget shows: Android only reports a value that differs
      // from the one it holds, so an unchanged copy redraws nothing. A copy
      // remembered here instead would go stale the moment the widget's own
      // isolate, or its optimistic tick, wrote one.
      final prefs = await SharedPreferences.getInstance();
      // The language goes with it: the widget is drawn by the launcher, in
      // the phone's language, which need not be the one chosen here.
      // So is whether the phone's events are wanted, and from which
      // calendars: the widget reads the events themselves as it is drawn,
      // since they change in other apps and this copy only when Caldo does.
      final events = SettingsProvider.storedEvents(prefs);
      await prefs.setString(
        key,
        jsonEncode({
          'lang': S.current.code,
          'tasks': rows,
          'events': {'on': events.on, 'hidden': events.hidden},
        }),
      );
    } catch (error, stack) {
      debugPrint('Could not update the widget: $error\n$stack');
    }
  }

  /// Writes the copy again as it was last written — in the language now in
  /// force, which the widget reads off it.
  static Future<void> republish() async {
    final last = _last;
    if (last != null) await publish(last);
  }

  static Map<String, Object?> _row(Task task, TaskProvider tasks) {
    final due = task.due!;
    String two(int n) => n.toString().padLeft(2, '0');
    return {
      'id': task.id,
      'title': task.title,
      'day': '${due.year}-${two(due.month)}-${two(due.day)}',
      'time': task.hasTime ? due.hour * 60 + due.minute : null,
      'end': switch (task.end) {
        final end? => end.hour * 60 + end.minute,
        null => null,
      },
      'done': task.done,
      // A repeating task rolls on to its next date when ticked, so on the
      // widget, as in the app, its card leaves the run rather than sliding
      // to the end of it — unless this is its last round, which closes it.
      'repeats': task.rollsOn,
      'colour': colorOfTask(
        task,
        tasks.listById(task.listId),
        fallback: AppColors.accent,
      ).toARGB32(),
    };
  }
}

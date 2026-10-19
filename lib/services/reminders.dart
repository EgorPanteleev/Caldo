import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    hide Priority;
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as fln
    show Priority;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/task.dart';
import '../providers/task_provider.dart' show TaskProvider, dayOf;
import '../utils/dates.dart';

/// Puts a notification on each dated task, at the minute it is due.
///
/// Android holds scheduled notifications itself, so the app does not have to
/// be running — but it also forgets them on a reboot or an update, which is
/// what the boot receiver in the manifest is there to undo.
///
/// Everything here is a no-op until [init] has been through. That is what lets
/// the widget tests drive the real providers: nothing in a test has a platform
/// to answer the plugin's channels, and a reminder that quietly does not get
/// set is a far better failure there than a crash on every save.
class Reminders {
  Reminders._();

  static final Reminders instance = Reminders._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _ready = false;
  bool _enabled = true;

  /// Minutes past midnight an all-day task is announced at. A task with no
  /// time of day still has to be mentioned at some point in the day, and
  /// midnight is the one hour nobody wants to hear about it.
  int _allDayMinutes = 9 * 60;

  /// Whether exact alarms are allowed. Without them Android is free to batch a
  /// reminder into whenever it next wakes up, which can be an hour late.
  bool _exact = true;

  /// What the alarms currently standing were set from, so a change of settings
  /// can re-set them against the same tasks.
  List<Task> _last = const [];
  bool _synced = false;

  /// The alarms this run of the app has set, by task id, each with what it
  /// was set to say and when — so a sync only touches the ones that changed.
  /// Null until the first sync, which clears whatever an earlier run left.
  Map<int, String>? _standing;

  /// How far ahead reminders are set — the same window the agenda loads, since
  /// that is what they are set from. Android caps how many alarms one app may
  /// hold, and a task two months out does not need its alarm booked today:
  /// every save re-syncs, so the window keeps moving forward on its own.
  static const _horizon = Duration(days: TaskProvider.agendaDays + 1);

  /// The most alarms held at once, soonest first.
  static const _limit = 60;

  static const _channelId = 'caldo_reminders';

  bool get ready => _ready;

  /// Starts the plugin and works out which zone the device keeps time in.
  /// Scheduling is done in that zone rather than in UTC, so a reminder set for
  /// nine in the morning stays at nine when the clocks change.
  Future<void> init() async {
    if (_ready) return;
    try {
      tzdata.initializeTimeZones();
      final zone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(zone.identifier));

      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_notification'),
        ),
      );

      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          'Task reminders',
          description: 'One notification per task, when it is due.',
          importance: Importance.high,
        ),
      );
      _exact = await android?.canScheduleExactNotifications() ?? false;
      _ready = true;
    } catch (error, stack) {
      // A device that will not have us is not a reason to fail to start: the
      // app works without reminders, it just does not nudge.
      debugPrint('Reminders unavailable: $error\n$stack');
      _ready = false;
    }
  }

  /// Asks for permission to post notifications, which Android 13 and later
  /// will not give without being asked. Returns whether we have it.
  Future<bool> requestPermission() async {
    if (!_ready) return false;
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final granted = await android?.requestNotificationsPermission() ?? false;
    if (granted && !_exact) {
      // Worth one ask: without it the alarm still arrives, just not on time.
      _exact = await android?.requestExactAlarmsPermission() ?? false;
    }
    return granted;
  }

  /// Takes the settings that decide whether and when anything is announced,
  /// and re-sets what is already standing against them.
  ///
  /// The re-set is the point. Settings and the agenda load at the same time
  /// when the app starts, and whichever lands first wins: if the tasks got
  /// there first, every alarm was worked out against the default hour, and an
  /// all-day task would have gone on announcing itself at nine however many
  /// times the hour had been changed in Settings.
  Future<void> configure({
    required bool enabled,
    required int allDayMinutes,
  }) async {
    if (_enabled == enabled && _allDayMinutes == allDayMinutes) return;
    _enabled = enabled;
    _allDayMinutes = allDayMinutes;
    if (_synced) await sync(_last);
  }

  /// Brings the alarms in line with [tasks]: one per task that is still to
  /// come.
  ///
  /// The first sync cancels everything and sets the lot, since an earlier run
  /// of the app may have left alarms behind. After that only what changed is
  /// cancelled or set. Re-setting all of them used to run on every tick, and
  /// the plugin rewrites its whole store of alarms for each one it sets, all
  /// on the platform's main thread — which is where frames come from, so the
  /// card sliding into place after a tick stuttered through it.
  Future<void> sync(List<Task> tasks) async {
    if (!_ready) return;
    _last = tasks;
    _synced = true;
    try {
      final wanted = <int, (DateTime, Task, String)>{};
      if (_enabled) {
        final now = DateTime.now();
        final until = now.add(_horizon);
        final due = <(DateTime, Task)>[];
        for (final task in tasks) {
          final at = whenToAnnounce(task, _allDayMinutes);
          if (at == null || at.isBefore(now) || at.isAfter(until)) continue;
          due.add((at, task));
        }
        due.sort((a, b) => a.$1.compareTo(b.$1));
        for (final (at, task) in due.take(_limit)) {
          final body = _body(task);
          wanted[task.id!] = (
            at,
            task,
            '${at.toIso8601String()}|${task.title}|$body|$_exact',
          );
        }
      }

      var standing = _standing;
      if (standing == null) {
        await _plugin.cancelAll();
        standing = _standing = {};
      }
      for (final id in [...standing.keys]) {
        if (wanted[id]?.$3 == standing[id]) continue;
        await _plugin.cancel(id: id);
        standing.remove(id);
      }
      for (final MapEntry(key: id, value: (at, task, said)) in wanted.entries) {
        if (standing[id] == said) continue;
        await _plugin.zonedSchedule(
          id: id,
          scheduledDate: tz.TZDateTime.from(at, tz.local),
          title: task.title,
          body: _body(task),
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              'Task reminders',
              channelDescription: 'One notification per task, when it is due.',
              importance: Importance.high,
              priority: fln.Priority.high,
              category: AndroidNotificationCategory.reminder,
            ),
          ),
          androidScheduleMode: _exact
              ? AndroidScheduleMode.exactAllowWhileIdle
              : AndroidScheduleMode.inexactAllowWhileIdle,
        );
        standing[id] = said;
      }
    } catch (error, stack) {
      // Whatever is standing is no longer known for sure; start over next time.
      _standing = null;
      debugPrint('Could not set reminders: $error\n$stack');
    }
  }

  /// When [task] should be announced, or null if it never should — it has no
  /// date, it is already done, or it has no id to hang an alarm on.
  ///
  /// Public because it is the one piece of this with a decision in it, and a
  /// test can check it without a device.
  static DateTime? whenToAnnounce(Task task, int allDayMinutes) {
    if (task.id == null || task.done) return null;
    final due = task.due;
    if (due == null) return null;
    if (task.hasTime) return due;
    final day = dayOf(due);
    return day.add(Duration(minutes: allDayMinutes));
  }

  String _body(Task task) {
    final due = task.due;
    if (due == null) return '';
    return task.hasTime ? 'Due at ${Dates.time(due)}' : 'Due today';
  }
}

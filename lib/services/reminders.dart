import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    hide Priority;
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as fln
    show Priority;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../l10n/strings.dart';
import '../models/task.dart';
import '../providers/task_provider.dart' show TaskProvider, dayOf;
import '../utils/dates.dart';
import 'background.dart';

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

  /// Minutes ahead of its time a timed task is announced, unless it says
  /// otherwise for itself (`Task.remindBefore`).
  int _lead = 0;

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

  /// The buttons on a reminder, by the id the plugin hands back.
  ///
  /// Android draws three at most, so the notification carries Done, the
  /// shorter snooze and Dismiss, which takes the reminder away and leaves
  /// the task as it was (asked for by name, beside snooze). The full-screen
  /// page has room for both snoozes: what "later" means depends on what was
  /// interrupted.
  static const done = 'done';
  static const dismissed = 'dismiss';
  static const snoozes = {'snooze-15': 15, 'snooze-60': 60};

  /// The task whose reminder has been opened — tapped, or put up over the
  /// lock screen — for the shell to show it full screen. Set back to null
  /// once it has been taken.
  static final opened = ValueNotifier<int?>(null);

  /// Lets the app show over the lock screen, and takes that back: it is
  /// allowed only while a reminder is up, so the app itself never shows
  /// without the phone being unlocked.
  static const _lock = MethodChannel('caldo/reminder');

  bool get ready => _ready;

  /// Whether a reminder takes the whole screen when the phone is locked,
  /// the way an alarm does. Android decides: in use, the phone shows it as
  /// a notification across the top instead.
  bool _fullScreen = true;

  static void _onOpened(NotificationResponse response) {
    if (response.notificationResponseType ==
            NotificationResponseType.selectedNotification &&
        response.id != null) {
      opened.value = response.id;
    }
  }

  /// Whether the app was started by a reminder, and if so, which; from
  /// `main` alone, since only the app's own process was started by one.
  Future<void> takeLaunch() async {
    if (!_ready) return;
    try {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final response = launch?.notificationResponse;
      if (launch?.didNotificationLaunchApp == true && response != null) {
        _onOpened(response);
      }
    } catch (error, stack) {
      debugPrint('Could not read the launch: $error\n$stack');
    }
  }

  /// Gives back the lock screen once a reminder has been answered, and
  /// steps aside if the phone is still locked.
  static Future<void> release() async {
    try {
      await _lock.invokeMethod<void>('release');
    } on MissingPluginException {
      // Not on a phone: there is no lock screen to give back.
    }
  }

  /// Asks Android to let reminders take the screen. Granted on install to an
  /// app that is not from the Play Store; this opens the page to allow it
  /// where it has been taken away.
  Future<void> requestFullScreen() async {
    if (!_ready) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestFullScreenIntentPermission();
    } catch (error, stack) {
      debugPrint('Could not ask for full screen: $error\n$stack');
    }
  }

  /// Starts the plugin and works out which zone the device keeps time in.
  /// Scheduling is done in that zone rather than in UTC, so a reminder set for
  /// nine in the morning stays at nine when the clocks change.
  Future<void> init() async {
    if (_ready) return;
    try {
      tzdata.initializeTimeZones();
      final zone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(zone.identifier));

      // The buttons are answered on an isolate of their own, whether or not
      // the app is open: they are meant to be pressed without opening it.
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_notification'),
        ),
        onDidReceiveBackgroundNotificationResponse: onReminderAction,
        onDidReceiveNotificationResponse: _onOpened,
      );

      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.createNotificationChannel(
        AndroidNotificationChannel(
          _channelId,
          S.current.reminderChannel,
          description: S.current.reminderChannelHint,
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
  /// Sets the alarms again from the tasks they were last set from — for a
  /// change in how they are worded rather than in when they go off, such as
  /// the clock times are written on.
  Future<void> refresh() async {
    if (_synced) await sync(_last);
  }

  Future<void> configure({
    required bool enabled,
    required int allDayMinutes,
    int lead = 0,
    bool fullScreen = true,
  }) async {
    if (_enabled == enabled &&
        _allDayMinutes == allDayMinutes &&
        _lead == lead &&
        _fullScreen == fullScreen) {
      return;
    }
    _enabled = enabled;
    _allDayMinutes = allDayMinutes;
    _lead = lead;
    _fullScreen = fullScreen;
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
          final at = whenToAnnounce(task, _allDayMinutes, lead: _lead);
          if (at == null || at.isBefore(now) || at.isAfter(until)) continue;
          due.add((at, task));
        }
        due.sort((a, b) => a.$1.compareTo(b.$1));
        for (final (at, task) in due.take(_limit)) {
          final body = describe(task, at);
          wanted[task.id!] = (
            at,
            task,
            '${at.toIso8601String()}|${task.title}|$body|$_exact|$_fullScreen|${S.current.code}',
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
        await _schedule(id, at, task);
        standing[id] = said;
      }
    } catch (error, stack) {
      // Whatever is standing is no longer known for sure; start over next time.
      _standing = null;
      debugPrint('Could not set reminders: $error\n$stack');
    }
  }

  /// Brings the one alarm for [task] in line with it, leaving every other
  /// alarm and notification alone — for a reminder's buttons and the
  /// home-screen widget, which change one task from an isolate that has
  /// never synced and so knows nothing of what else is standing. Whatever is
  /// showing for the task goes, since it has just been answered.
  Future<void> reset(Task task) async {
    if (!_ready || task.id == null) return;
    try {
      await _plugin.cancel(id: task.id!);
      if (!_enabled) return;
      final at = whenToAnnounce(task, _allDayMinutes, lead: _lead);
      final now = DateTime.now();
      if (at == null || at.isBefore(now) || at.isAfter(now.add(_horizon))) {
        return;
      }
      await _schedule(task.id!, at, task);
    } catch (error, stack) {
      debugPrint('Could not reset reminder: $error\n$stack');
    }
  }

  /// Takes down the alarm and any notification for a task that is gone.
  Future<void> dismiss(int id) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(id: id);
    } catch (error, stack) {
      debugPrint('Could not dismiss reminder: $error\n$stack');
    }
  }

  Future<void> _schedule(int id, DateTime at, Task task) =>
      _plugin.zonedSchedule(
        id: id,
        scheduledDate: tz.TZDateTime.from(at, tz.local),
        title: task.title,
        body: describe(task, at),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            S.current.reminderChannel,
            channelDescription: S.current.reminderChannelHint,
            importance: Importance.high,
            priority: fln.Priority.high,
            category: AndroidNotificationCategory.reminder,
            fullScreenIntent: _fullScreen,
            actions: [
              AndroidNotificationAction(done, S.current.reminderDone),
              AndroidNotificationAction(
                snoozes.keys.first,
                snoozeLabel(snoozes.values.first),
              ),
              AndroidNotificationAction(dismissed, S.current.reminderDismiss),
            ],
          ),
        ),
        androidScheduleMode: _exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
      );

  /// What a snooze of [minutes] is called on its button.
  static String snoozeLabel(int minutes) =>
      minutes < 60 ? S.current.snoozeMinutes(minutes) : S.current.snoozeHour;

  /// When [task] should be announced, or null if it never should — it has no
  /// date, it is already done, it is [Task.silent], or it has no id to hang
  /// an alarm on.
  ///
  /// [lead] is how far ahead a timed task is announced when it does not say
  /// for itself. An all-day task takes only whole days of its own lead and
  /// none of the default: it is announced at [allDayMinutes] on its day, or
  /// on a day before, and "fifteen minutes before nine" on a day it has no
  /// time on would be a reminder set off by nothing.
  ///
  /// Public because it is the one piece of this with a decision in it, and a
  /// test can check it without a device.
  static DateTime? whenToAnnounce(
    Task task,
    int allDayMinutes, {
    int lead = 0,
  }) {
    if (task.id == null || task.done) return null;
    final snoozed = task.snoozedUntil;
    if (snoozed != null) return DateTime.fromMillisecondsSinceEpoch(snoozed);
    final due = task.due;
    if (due == null) return null;
    final before = task.remindBefore;
    if (before != null && before < 0) return null;
    if (task.hasTime) return due.subtract(Duration(minutes: before ?? lead));
    final days = (before ?? 0) ~/ Duration.minutesPerDay;
    final day = dayOf(due);
    return DateTime(
      day.year,
      day.month,
      day.day - days,
    ).add(Duration(minutes: allDayMinutes));
  }

  /// What the notification says under the title, from where [at] stands:
  /// a task announced a day early is due tomorrow, and one snoozed past its
  /// time was due rather than is.
  static String describe(Task task, DateTime at) {
    final due = task.due;
    if (due == null) return '';
    final s = S.current;
    final days = dayOf(due).difference(dayOf(at)).inDays;
    final day = switch (days) {
      0 => null,
      1 => s.tomorrowInline,
      -1 => s.yesterdayInline,
      _ => Dates.dayDate(due),
    };
    return s.dueLine(
      day: day,
      time: task.hasTime ? Dates.time(due) : null,
      past: task.hasTime ? due.isBefore(at) : days < 0,
    );
  }
}

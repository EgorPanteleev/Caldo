import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show NotificationResponse;

import '../db/database.dart';
import '../models/task.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import 'reminders.dart';
import 'today_widget.dart';

/// Changes made to a task from outside the app's screens: a reminder's
/// buttons, and a tick on the home-screen widget.
///
/// Both run in an isolate of their own, which may be the only one there is —
/// the point of either is not having to open the app. So each does the whole
/// of what a change needs for itself: writes the task, puts its one alarm
/// right, and redraws the widget. If the app is open after all, it is told,
/// and reads its lists back.
class Background {
  Background._();

  static const _port = 'caldo/changed';

  /// Bumped in the app's own isolate when a task was changed from outside
  /// it. `TaskProvider` listens.
  static final changed = ValueNotifier<int>(0);

  /// Starts listening for changes made elsewhere. From `main`, and only
  /// there: a name registered twice is refused, and the widget tests never
  /// have anything to hear.
  static void listen() {
    final port = ReceivePort();
    IsolateNameServer.removePortNameMapping(_port);
    IsolateNameServer.registerPortWithName(port.sendPort, _port);
    port.listen((_) => changed.value++);
  }

  static bool _prepared = false;

  /// What a fresh isolate needs before it can touch a task: plugins, the
  /// alarm service, and the settings that decide what an alarm says and
  /// when. Settings are read again every time, since this isolate can
  /// outlive a change made to them in the app.
  static Future<void> _prepare() async {
    if (!_prepared) {
      WidgetsFlutterBinding.ensureInitialized();
      DartPluginRegistrant.ensureInitialized();
      await Reminders.instance.init();
      TodayWidget.enable();
      _prepared = true;
    }
    await SettingsProvider.prime();
  }

  /// Writes [change] of the task with [id], when there still is one, and
  /// follows it through: its alarm, the widget, and the app if it is open.
  /// A change that returns the task as it was writes nothing.
  static Future<void> _change(int id, Task Function(Task) change) async {
    await _prepare();
    final db = AppDatabase.instance;
    final task = await db.getTask(id);
    if (task == null) {
      await Reminders.instance.dismiss(id);
    } else {
      final changed = change(task);
      if (!identical(changed, task)) await db.update(changed);
      await Reminders.instance.reset(changed);
    }
    final tasks = TaskProvider();
    await tasks.loadLists();
    await tasks.readAgenda();
    await TodayWidget.publish(tasks);
    IsolateNameServer.lookupPortByName(_port)?.send(null);
  }

  /// A reminder's Done: ticks the task off, unless it already is.
  static Future<void> complete(int id) => _change(
    id,
    (task) => task.done
        ? task
        : task.completed(DateTime.now().millisecondsSinceEpoch),
  );

  /// A reminder's Snooze: announces the task again [minutes] from now.
  static Future<void> snooze(int id, int minutes) => _change(
    id,
    (task) => task.done
        ? task
        : task.copyWith(
            snoozedUntil: DateTime.now()
                .add(Duration(minutes: minutes))
                .millisecondsSinceEpoch,
          ),
  );

  /// A tick on the widget, which takes a tick back as well as making one —
  /// the widget has no Undo, and a second tap is how a slip is put right.
  static Future<void> toggle(int id) => _change(
    id,
    (task) => task.done
        ? task.reopened()
        : task.completed(DateTime.now().millisecondsSinceEpoch),
  );
}

/// What a reminder's buttons call, on the notification plugin's own isolate.
@pragma('vm:entry-point')
Future<void> onReminderAction(NotificationResponse response) async {
  final id = response.id;
  if (id == null) return;
  final action = response.actionId;
  try {
    if (action == Reminders.done) {
      await Background.complete(id);
    } else if (Reminders.snoozes[action] case final minutes?) {
      await Background.snooze(id, minutes);
    }
  } catch (error, stack) {
    debugPrint('Reminder action $action on $id failed: $error\n$stack');
  }
}

/// Where the engine the widget starts begins (`Headless` in the activity's
/// package). It answers ticks one at a time, in the order they were made: a
/// second tap landing while the first is still being written would otherwise
/// redraw the widget from a read taken before the first was done.
@pragma('vm:entry-point')
Future<void> widgetMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('caldo/headless');
  var queue = Future<void>.value();
  channel.setMethodCallHandler((call) {
    final answered = queue.then((_) async {
      final id = (call.arguments as Map)['id'] as int;
      if (call.method == 'toggle') await Background.toggle(id);
    });
    queue = answered.catchError((Object error, StackTrace stack) {
      debugPrint('Widget ${call.method} failed: $error\n$stack');
    });
    return queue;
  });
  await channel.invokeMethod<void>('ready');
}

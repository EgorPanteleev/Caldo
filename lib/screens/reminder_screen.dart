import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../db/database.dart';
import '../l10n/strings.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../providers/task_provider.dart';
import '../services/background.dart';
import '../services/reminders.dart';
import '../theme/app_theme.dart';

/// A reminder taking the whole screen, the way an alarm does: put up over
/// the lock screen when a task comes due with the phone locked, and opened
/// by a tap on the notification otherwise.
///
/// Everything the notification offers is here, with room for both snoozes,
/// where the notification has room for three buttons in all. Each answer
/// goes through the same path as the notification's own buttons
/// ([Background]), so the alarm, the widget and the lists all follow, and
/// then the page goes and the lock screen is given back.
class ReminderScreen extends StatefulWidget {
  final int taskId;

  const ReminderScreen({super.key, required this.taskId});

  @override
  State<ReminderScreen> createState() => _ReminderScreenState();
}

class _ReminderScreenState extends State<ReminderScreen> {
  late final Future<Task?> _task = AppDatabase.instance.getTask(widget.taskId);

  /// Set once an answer has been given, so a second tap on the way out does
  /// not give another.
  bool _answered = false;

  Future<void> _answer(Future<void> Function() answer) async {
    if (_answered) return;
    _answered = true;
    HapticFeedback.selectionClick();
    await answer();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    // However the page goes — an answer, Back — the app stops showing over
    // the lock screen with it.
    Reminders.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Task?>(
      future: _task,
      builder: (context, snapshot) {
        final task = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(body: SizedBox.expand());
        }
        if (task == null || task.done) {
          // Deleted or ticked off since it was announced: nothing to ask.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).maybePop();
          });
          return const Scaffold(body: SizedBox.expand());
        }
        return _Reminder(
          task: task,
          onDone: () => _answer(() => Background.complete(task.id!)),
          onSnooze: (minutes) =>
              _answer(() => Background.snooze(task.id!, minutes)),
          onDismiss: () => _answer(() => Reminders.instance.dismiss(task.id!)),
        );
      },
    );
  }
}

class _Reminder extends StatelessWidget {
  final Task task;
  final VoidCallback onDone;
  final ValueChanged<int> onSnooze;
  final VoidCallback onDismiss;

  const _Reminder({
    required this.task,
    required this.onDone,
    required this.onSnooze,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final list = context.read<TaskProvider?>()?.listById(task.listId);
    final colour = colorOfTask(
      task,
      list,
      fallback: AppTheme.accentOf(context).color,
    );
    // Read to the minute, as the alarm was set: seconds after a task fell
    // due, it is still due rather than was.
    final now = DateTime.now();
    final line = Reminders.describe(
      task,
      DateTime(now.year, now.month, now.day, now.hour, now.minute),
    );

    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 2),
              // The task's colour, as its card wears it: a quarter of it for
              // the ground, the bell in it whole.
              Center(
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: colour.withValues(alpha: 0.25),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.notifications_active_rounded,
                    color: colour,
                    size: 36,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Text(
                task.title,
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: p.text,
                  fontSize: 28,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (line.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  line,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.muted, fontSize: 16),
                ),
              ],
              const Spacer(flex: 3),
              _Button(
                label: s.reminderDone,
                icon: Icons.check_rounded,
                fill: colour,
                ink: Colors.white,
                onTap: onDone,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final (i, minutes)
                      in Reminders.snoozes.values.indexed) ...[
                    if (i > 0) const SizedBox(width: 12),
                    Expanded(
                      child: _Button(
                        label: Reminders.snoozeLabel(minutes),
                        icon: Icons.snooze_rounded,
                        fill: p.field,
                        ink: p.text,
                        onTap: () => onSnooze(minutes),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: onDismiss,
                style: TextButton.styleFrom(
                  foregroundColor: p.muted,
                  minimumSize: const Size.fromHeight(52),
                ),
                child: Text(
                  s.reminderDismiss,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Button extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color fill;
  final Color ink;
  final VoidCallback onTap;

  const _Button({
    required this.label,
    required this.icon,
    required this.fill,
    required this.ink,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: fill,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: ink, size: 20),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: ink,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import '../screens/task_edit_screen.dart';
import '../theme/app_theme.dart';
import 'date_time_pickers.dart';
import 'put_off.dart';
import 'selection.dart';
import 'tick_off.dart';

enum _Do { edit, tick, today, nextDay, pickDay, group, select, delete }

/// What a right click on a task's card offers, at the pointer: everything a
/// phone does to a card by a gesture a mouse has no word for — the swipe
/// that puts it off, the long press that picks it out — and the things a
/// card is otherwise opened to do.
///
/// A move to another day is offered back as a swipe's is (`PutOff.move`),
/// and a tick as a tick's, in the add row of the screen the card is on.
Future<void> showTaskMenu(BuildContext context, Offset at, Task task) async {
  final s = S.of(context);
  final p = AppTheme.of(context);
  final provider = context.read<TaskProvider>();
  final selection = Selection.maybeOf(context);
  final today = dayOf(DateTime.now());
  final later = task.dueDay?.isAfter(today) ?? false;
  final screen = Overlay.of(context).context.findRenderObject()! as RenderBox;

  PopupMenuItem<_Do> item(
    _Do what,
    IconData icon,
    String label, {
    Color? ink,
  }) => PopupMenuItem(
    value: what,
    height: 38,
    child: Row(
      children: [
        Icon(icon, size: 19, color: ink ?? p.muted),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: ink ?? p.text, fontSize: 14)),
      ],
    ),
  );

  final chosen = await showMenu<_Do>(
    context: context,
    position: RelativeRect.fromRect(at & Size.zero, Offset.zero & screen.size),
    items: [
      item(_Do.edit, Icons.edit_outlined, s.editTask),
      item(
        _Do.tick,
        task.done ? Icons.remove_done : Icons.done,
        task.done ? s.markNotDone : s.markDone,
      ),
      if (!task.done) ...[
        const PopupMenuDivider(height: 9),
        if (task.dueDay != today)
          item(_Do.today, Icons.today_outlined, s.today),
        item(_Do.nextDay, Icons.redo_rounded, later ? s.putOffDay : s.tomorrow),
        item(_Do.pickDay, Icons.event_outlined, s.pickDay),
      ],
      if (provider.lists.length > 1)
        item(_Do.group, Icons.folder_outlined, s.moveToGroup),
      const PopupMenuDivider(height: 9),
      if (selection != null)
        item(_Do.select, Icons.check_box_outlined, s.select),
      item(_Do.delete, Icons.delete_outline, s.delete, ink: AppColors.danger),
    ],
  );
  if (chosen == null || !context.mounted) return;

  switch (chosen) {
    case _Do.edit:
      openTaskForm(context, task: task);
    case _Do.tick:
      tickOff(context, task);
    case _Do.today:
      PutOff.move(context, task, today, Icons.today_outlined);
    case _Do.nextDay:
      PutOff.move(
        context,
        task,
        PutOff.nextDay(task, DateTime.now()),
        Icons.redo_rounded,
      );
    case _Do.pickDay:
      final day = await showAppDatePicker(
        context: context,
        initial: task.dueDay ?? today,
      );
      if (day == null || day == task.dueDay || !context.mounted) return;
      PutOff.move(context, task, day, Icons.event_outlined);
    case _Do.group:
      final id = await pickGroup(context, current: task.listId);
      if (id != null) await provider.moveAllToGroup([task], id);
    case _Do.select:
      selection?.toggle(task);
    case _Do.delete:
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(s.deleteTaskQuestion),
          content: Text(s.willBeRemoved(task.title)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(s.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(s.delete),
            ),
          ],
        ),
      );
      if (ok == true && task.id != null) await provider.remove(task.id!);
  }
}

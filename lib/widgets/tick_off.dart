import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/task.dart';
import '../providers/task_provider.dart';

/// Ticks [task] off, or takes its tick back, from a card — and when it was
/// ticked off, offers a moment to take that back.
///
/// The bar stays four seconds. Undo puts the task back exactly as it was
/// before the tap (`TaskProvider.restore`): not done, and on its own date if
/// it was a repeating task that had rolled on — ticking it again would only
/// have rolled it a second time. Taking a tick back by tapping the tick needs
/// no bar: it is already an undo.
void tickOff(BuildContext context, Task task) {
  final provider = context.read<TaskProvider>();
  final messenger = ScaffoldMessenger.of(context);
  final completing = !task.done;
  provider.toggleDone(task);
  if (!completing) return;

  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          'Done — ${task.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        duration: const Duration(seconds: 4),
        // A bar with an action otherwise stays until it is dismissed, and an
        // offer to take a tick back is only worth making for a moment.
        persist: false,
        // Over the add field rather than on it: the field is the next thing
        // most often reached for, and a bar sitting on it for four seconds
        // would be in the way of exactly that.
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 78),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => provider.restore(task),
        ),
      ),
    );
}

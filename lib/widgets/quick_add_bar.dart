import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/task.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';

/// Identifies the button beside the quick-add field.
const quickAddButtonKey = Key('quick-add-button');

/// The field under a day's tasks: type a title, confirm, and it lands on the
/// day in view without opening the full form. Used by the calendar and by the
/// day card that opens over it.
class QuickAddBar extends StatefulWidget {
  final DateTime date;
  final TextEditingController controller;
  final VoidCallback onSubmit;

  /// Opens the full form. The button is a plus until the field is opened, and
  /// a plus has to lead somewhere — pressing it on an empty field used to do
  /// nothing at all.
  final VoidCallback onFullForm;

  /// Room around the row; the day card sets its own, tighter than the
  /// calendar's.
  final EdgeInsets padding;

  const QuickAddBar({
    super.key,
    required this.date,
    required this.controller,
    required this.onSubmit,
    required this.onFullForm,
    this.padding = const EdgeInsets.fromLTRB(16, 6, 16, 10),
  });

  @override
  State<QuickAddBar> createState() => _QuickAddBarState();
}

class _QuickAddBarState extends State<QuickAddBar> {
  late final FocusNode _focus = FocusNode()
    ..addListener(() {
      if (mounted) setState(() {});
    });

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// Hands the title over and closes the field. The task is filed at that
  /// point, so leaving the keyboard up over a day whose list has just changed
  /// hides the very thing the tap was meant to produce.
  void _submit() {
    widget.onSubmit();
    _focus.unfocus();
  }

  /// A plus opens the form; a tick files what has been typed.
  void _press() => _focus.hasFocus ? _submit() : widget.onFullForm();

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    // Opening the field is the moment the button's job changes: from here on
    // it finishes the task being typed, so it says so. Waiting for the first
    // character left it a plus over an active field.
    final writing = _focus.hasFocus;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(26),
      borderSide: BorderSide(color: p.border),
    );

    return Padding(
      padding: widget.padding,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              style: TextStyle(color: p.text, fontSize: 14.5),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Add task on ${Dates.shortDay(widget.date)}',
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
                border: border,
                enabledBorder: border,
                // A neutral outline on focus rather than the accent: the
                // cursor already says where the typing goes, and a coloured
                // ring around half the screen was the loudest thing on it.
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(26),
                  borderSide: BorderSide(color: p.muted),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _ConfirmButton(
            key: quickAddButtonKey,
            icon: writing ? Icons.check_rounded : Icons.add,
            tooltip: writing ? 'Add task' : 'New task',
            onTap: _press,
          ),
        ],
      ),
    );
  }
}

/// The round button beside the field. Plain rather than the accent gradient
/// the screen headers wear: it sits next to the field the eye is already on,
/// and a bright disc there pulled attention off what was being typed.
class _ConfirmButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _ConfirmButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: p.panelHi,
        shape: CircleBorder(side: BorderSide(color: p.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(icon, color: p.text, size: 26),
          ),
        ),
      ),
    );
  }
}

/// Files an all-day task on [day] from a one-line title, in the colour new
/// tasks are set to start in.
Future<void> quickAddTask(
  BuildContext context, {
  required DateTime day,
  required String title,
}) async {
  final trimmed = title.trim();
  if (trimmed.isEmpty) return;
  final provider = context.read<TaskProvider>();
  final styleId = context.read<SettingsProvider>().defaultTaskStyleId;
  final lists = provider.lists;
  await provider.add(
    Task(
      listId: lists.isNotEmpty ? lists.first.id! : 1,
      title: trimmed,
      dueAt: dayOf(day).millisecondsSinceEpoch,
      styleId: styleId,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ),
  );
}

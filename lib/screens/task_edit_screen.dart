import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/task.dart';
import '../models/task_list.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/date_time_pickers.dart';
import '../widgets/task_row.dart' show PriorityFlag;

/// Add a new task or edit an existing one. When [task] is null this is a
/// creation form; otherwise the fields are pre-filled for editing.
class TaskEditScreen extends StatefulWidget {
  final Task? task;

  /// The list a new task should go into (a starting choice; the user can
  /// change it when there is more than one list).
  final int? listId;

  /// Pre-selected due date for a task created from the calendar.
  final DateTime? initialDate;

  const TaskEditScreen({
    super.key,
    this.task,
    this.listId,
    this.initialDate,
  });

  @override
  State<TaskEditScreen> createState() => _TaskEditScreenState();
}

class _TaskEditScreenState extends State<TaskEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _notes;

  int? _selectedListId;
  DateTime? _date;
  TimeOfDay? _time;
  Priority _priority = Priority.none;
  Repeat _repeat = Repeat.none;

  /// Null means the task keeps its list's colour.
  String? _styleId;

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    _title = TextEditingController(text: task?.title ?? '');
    _notes = TextEditingController(text: task?.notes ?? '');
    _priority = task?.priority ?? Priority.none;
    _repeat = task?.repeat ?? Repeat.none;
    _styleId = task?.styleId;

    final due = task?.due;
    if (due != null) {
      _date = DateTime(due.year, due.month, due.day);
      if (task!.hasTime) _time = TimeOfDay(hour: due.hour, minute: due.minute);
    } else if (task == null && widget.initialDate != null) {
      _date = dayOf(widget.initialDate!);
    }

    final lists = context.read<TaskProvider>().lists;
    _selectedListId = task?.listId ??
        widget.listId ??
        (lists.isNotEmpty ? lists.first.id : null);
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  /// The chosen date merged with the chosen time, or null for an undated task.
  DateTime? get _due {
    final date = _date;
    if (date == null) return null;
    final time = _time;
    return time == null
        ? date
        : DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _pickDate() async {
    final picked = await showAppDatePicker(
      context: context,
      initial: _date ?? dayOf(DateTime.now()),
    );
    if (picked != null) setState(() => _date = dayOf(picked));
  }

  Future<void> _pickTime() async {
    final picked = await showAppTimePicker(
      context: context,
      initial: _time,
    );
    if (picked != null) {
      setState(() {
        _time = picked;
        _date ??= dayOf(DateTime.now());
      });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final provider = context.read<TaskProvider>();
    final lists = provider.lists;
    final listId =
        (_selectedListId != null && lists.any((l) => l.id == _selectedListId))
            ? _selectedListId!
            : (lists.isNotEmpty ? lists.first.id! : 1);
    final due = _due;
    final existing = widget.task;

    if (existing == null) {
      await provider.add(Task(
        listId: listId,
        title: _title.text.trim(),
        notes: _notes.text.trim(),
        dueAt: due?.millisecondsSinceEpoch,
        hasTime: _time != null,
        priority: _priority,
        repeat: due == null ? Repeat.none : _repeat,
        styleId: _styleId,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
    } else {
      await provider.update(existing.copyWith(
        listId: listId,
        title: _title.text.trim(),
        notes: _notes.text.trim(),
        dueAt: due?.millisecondsSinceEpoch,
        clearDueAt: due == null,
        hasTime: _time != null,
        priority: _priority,
        repeat: due == null ? Repeat.none : _repeat,
        styleId: _styleId,
        clearStyleId: _styleId == null,
      ));
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final task = widget.task;
    if (task?.id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete task?'),
        content: Text('"${task!.title}" will be removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<TaskProvider>().remove(task!.id!);
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final isEdit = widget.task != null;
    final lists = context.watch<TaskProvider>().lists;
    final validId = lists.any((l) => l.id == _selectedListId)
        ? _selectedListId
        : (lists.isNotEmpty ? lists.first.id : null);

    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? 'Edit task' : 'New task'),
        actions: [
          if (isEdit)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: AppColors.danger),
              tooltip: 'Delete',
              onPressed: _delete,
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextFormField(
              controller: _title,
              autofocus: !isEdit,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Task'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _notes,
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
              ),
            ),
            const SizedBox(height: 20),
            _FieldTile(
              icon: Icons.event_outlined,
              label: 'Due date',
              value: _date == null ? 'None' : Dates.longDay(_date!),
              onTap: _pickDate,
              onClear: _date == null
                  ? null
                  : () => setState(() {
                        _date = null;
                        _time = null;
                        _repeat = Repeat.none;
                      }),
            ),
            const SizedBox(height: 12),
            _FieldTile(
              icon: Icons.schedule,
              label: 'Time',
              value: _time == null
                  ? 'All day'
                  : Dates.formatTimeOfDay(_time!),
              onTap: _pickTime,
              onClear: _time == null ? null : () => setState(() => _time = null),
            ),
            const SizedBox(height: 12),
            _RepeatField(
              value: _repeat,
              enabled: _date != null,
              onChanged: (v) => setState(() => _repeat = v),
            ),
            const SizedBox(height: 22),
            Text('PRIORITY',
                style: TextStyle(
                  color: p.faint,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                )),
            const SizedBox(height: 10),
            _PrioritySelector(
              value: _priority,
              onChanged: (v) => setState(() => _priority = v),
            ),
            const SizedBox(height: 22),
            Text('COLOUR',
                style: TextStyle(
                  color: p.faint,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                )),
            const SizedBox(height: 10),
            _ColourSelector(
              value: _styleId,
              listColor: lists
                      .where((l) => l.id == validId)
                      .map((l) => l.style.color)
                      .firstOrNull ??
                  AppTheme.accentOf(context).color,
              onChanged: (v) => setState(() => _styleId = v),
            ),
            if (lists.length > 1) ...[
              const SizedBox(height: 22),
              DropdownButtonFormField<int>(
                initialValue: validId,
                decoration: const InputDecoration(labelText: 'List'),
                items: lists
                    .map((l) => DropdownMenuItem(
                          value: l.id,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.circle,
                                  size: 10, color: l.style.color),
                              const SizedBox(width: 8),
                              Text(l.name),
                            ],
                          ),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _selectedListId = v),
              ),
            ],
            const SizedBox(height: 26),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.check, size: 20),
                label: Text(isEdit ? 'Save changes' : 'Add task'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A tappable settings-style row: icon, label, current value, optional clear.
class _FieldTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  const _FieldTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: p.panel,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.border),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: p.muted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(color: p.faint, fontSize: 12)),
                    const SizedBox(height: 3),
                    Text(value,
                        style: TextStyle(
                            color: p.text,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              if (onClear != null)
                IconButton(
                  icon: Icon(Icons.clear, size: 18, color: p.faint),
                  tooltip: 'Clear',
                  onPressed: onClear,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Repeat rule chooser. Disabled until the task has a date, since a recurring
/// task needs something to recur from.
class _RepeatField extends StatelessWidget {
  final Repeat value;
  final bool enabled;
  final ValueChanged<Repeat> onChanged;

  const _RepeatField({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.border),
        ),
        child: Row(
          children: [
            Icon(Icons.repeat, size: 20, color: p.muted),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<Repeat>(
                  value: value,
                  isExpanded: true,
                  dropdownColor: p.panel,
                  borderRadius: BorderRadius.circular(10),
                  icon: Icon(Icons.expand_more, color: p.muted),
                  style: TextStyle(
                    color: p.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  items: Repeat.values
                      .map((r) => DropdownMenuItem(
                            value: r,
                            child: Text('Repeat: ${r.label.toLowerCase()}'),
                          ))
                      .toList(),
                  onChanged: enabled
                      ? (v) => onChanged(v ?? Repeat.none)
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A row of priority chips — a segmented control that wraps instead of
/// clipping its labels on narrow screens.
class _PrioritySelector extends StatelessWidget {
  final Priority value;
  final ValueChanged<Priority> onChanged;

  const _PrioritySelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final priority in Priority.values)
          _PriorityChip(
            priority: priority,
            selected: priority == value,
            palette: p,
            onTap: () => onChanged(priority),
          ),
      ],
    );
  }
}

class _PriorityChip extends StatelessWidget {
  final Priority priority;
  final bool selected;
  final AppPalette palette;
  final VoidCallback onTap;

  const _PriorityChip({
    required this.priority,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = priority == Priority.none
        ? palette.muted
        : PriorityFlag.colorOf(priority);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? color.withValues(alpha: 0.18)
              : palette.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? color : palette.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              priority == Priority.none ? Icons.flag_outlined : Icons.flag,
              size: 15,
              color: selected ? color : palette.muted,
            ),
            const SizedBox(width: 6),
            Text(
              priority.label,
              style: TextStyle(
                color: selected ? color : palette.muted,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Picks the colour a task is drawn in: its list's by default, or any of the
/// same swatches a list can wear.
class _ColourSelector extends StatelessWidget {
  final String? value;
  final Color listColor;
  final ValueChanged<String?> onChanged;

  const _ColourSelector({
    required this.value,
    required this.listColor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _Swatch(
          color: listColor,
          selected: value == null,
          // The "same as the list" choice, marked with a link rather than a
          // colour of its own.
          icon: Icons.link,
          onTap: () => onChanged(null),
          border: p.border,
        ),
        for (final style in ListStyle.presets)
          _Swatch(
            color: style.color,
            selected: value == style.id,
            onTap: () => onChanged(style.id),
            border: p.border,
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final IconData? icon;
  final Color border;
  final VoidCallback onTap;

  const _Swatch({
    required this.color,
    required this.selected,
    required this.border,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: selected ? 1 : 0.35),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? AppTheme.of(context).text : border,
            width: selected ? 2 : 1,
          ),
        ),
        child: icon != null
            ? Icon(icon, size: 17, color: Colors.white)
            : (selected
                ? const Icon(Icons.check, size: 18, color: Colors.white)
                : null),
      ),
    );
  }
}

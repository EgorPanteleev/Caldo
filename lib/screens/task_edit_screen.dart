import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/task.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/colour_selector.dart';
import '../widgets/date_time_pickers.dart';
import '../widgets/task_card.dart' show CheckMark;
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

  const TaskEditScreen({super.key, this.task, this.listId, this.initialDate});

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

  /// The checklist as it is being edited, and the field that adds to it.
  final List<_Draft> _steps = [];
  final _newStep = TextEditingController();
  final _newStepFocus = FocusNode();

  /// Whether anything has been touched since the form opened. Until it has,
  /// the back arrow is the only way out and there is nothing to save; once it
  /// has, the arrow goes and the two words at the foot take over — leaving by
  /// accident with edits on the screen is the thing being prevented.
  bool _dirty = false;

  void _touched() {
    if (!_dirty) setState(() => _dirty = true);
  }

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    _title = TextEditingController(text: task?.title ?? '')
      ..addListener(_touched);
    _notes = TextEditingController(text: task?.notes ?? '')
      ..addListener(_touched);
    _priority = task?.priority ?? Priority.none;
    _repeat = task?.repeat ?? Repeat.none;
    for (final step in task?.subtasks ?? const <Subtask>[]) {
      _steps.add(_Draft(step.title, done: step.done, onEdit: _touched));
    }
    _newStep.addListener(_touched);
    // A new task starts in the colour Settings says new tasks start in; an
    // existing one keeps whatever it was given.
    _styleId = task == null
        ? context.read<SettingsProvider>().defaultTaskStyleId
        : task.styleId;

    final due = task?.due;
    if (due != null) {
      _date = DateTime(due.year, due.month, due.day);
      if (task!.hasTime) _time = TimeOfDay(hour: due.hour, minute: due.minute);
    } else if (task == null && widget.initialDate != null) {
      _date = dayOf(widget.initialDate!);
    }

    final lists = context.read<TaskProvider>().lists;
    _selectedListId =
        task?.listId ??
        widget.listId ??
        (lists.isNotEmpty ? lists.first.id : null);
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    for (final step in _steps) {
      step.dispose();
    }
    _newStep.dispose();
    _newStepFocus.dispose();
    super.dispose();
  }

  /// Files what is in the add field as a step and leaves the field ready for
  /// the next one, keyboard up: a checklist is written several lines at once.
  void _addStep() {
    final title = _newStep.text.trim();
    if (title.isEmpty) return;
    setState(() => _steps.add(_Draft(title, onEdit: _touched)));
    _newStep.clear();
    _newStepFocus.requestFocus();
    // The new line pushes the field down a row each time, and nothing else
    // scrolls it back out from under the keyboard.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final field = _newStepFocus.context;
      if (field == null || !field.mounted) return;
      Scrollable.ensureVisible(
        field,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  /// The checklist to save: every step with words in it, and whatever was
  /// left typed in the add field without Enter being pressed, since that was
  /// meant as a step too.
  List<Subtask> get _subtasks => [
    for (final step in _steps)
      if (step.title.text.trim().isNotEmpty)
        Subtask(step.title.text.trim(), done: step.done),
    if (_newStep.text.trim().isNotEmpty) Subtask(_newStep.text.trim()),
  ];

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
    if (picked != null) {
      _touched();
      setState(() => _date = dayOf(picked));
    }
  }

  Future<void> _pickTime() async {
    final picked = await showAppTimePicker(context: context, initial: _time);
    if (picked != null) {
      _touched();
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
      await provider.add(
        Task(
          listId: listId,
          title: _title.text.trim(),
          notes: _notes.text.trim(),
          dueAt: due?.millisecondsSinceEpoch,
          hasTime: _time != null,
          priority: _priority,
          repeat: due == null ? Repeat.none : _repeat,
          styleId: _styleId,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          subtasks: _subtasks,
        ),
      );
    } else {
      await provider.update(
        existing.copyWith(
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
          subtasks: _subtasks,
        ),
      );
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
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
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
        // Once something has been changed there is no way out but the two
        // words at the foot: an arrow beside unsaved edits is an invitation
        // to lose them.
        automaticallyImplyLeading: !_dirty,
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
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
            ),
            const SizedBox(height: 22),
            Text(
              'SUBTASKS',
              style: TextStyle(
                color: p.faint,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 10),
            _Checklist(
              steps: _steps,
              newStep: _newStep,
              newStepFocus: _newStepFocus,
              onAdd: _addStep,
              onToggle: (step) {
                _touched();
                setState(() => step.done = !step.done);
              },
              onRemove: (step) {
                _touched();
                setState(() => _steps.remove(step));
                step.dispose();
              },
            ),
            const SizedBox(height: 20),
            _FieldTile(
              icon: Icons.event_outlined,
              label: 'Due date',
              value: _date == null ? 'None' : Dates.longDay(_date!),
              onTap: _pickDate,
              onClear: _date == null
                  ? null
                  : () {
                      _touched();
                      setState(() {
                        _date = null;
                        _time = null;
                        _repeat = Repeat.none;
                      });
                    },
            ),
            const SizedBox(height: 12),
            _FieldTile(
              icon: Icons.schedule,
              label: 'Time',
              value: _time == null
                  ? 'All day'
                  : Dates.clock(
                      _time!,
                      h24: MediaQuery.alwaysUse24HourFormatOf(context),
                    ),
              onTap: _pickTime,
              onClear: _time == null
                  ? null
                  : () {
                      _touched();
                      setState(() => _time = null);
                    },
            ),
            const SizedBox(height: 12),
            _RepeatField(
              value: _repeat,
              enabled: _date != null,
              onChanged: (v) {
                _touched();
                setState(() => _repeat = v);
              },
            ),
            const SizedBox(height: 22),
            Text(
              'PRIORITY',
              style: TextStyle(
                color: p.faint,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 10),
            _PrioritySelector(
              value: _priority,
              onChanged: (v) {
                _touched();
                setState(() => _priority = v);
              },
            ),
            const SizedBox(height: 22),
            Text(
              'COLOUR',
              style: TextStyle(
                color: p.faint,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 10),
            ColourSelector(
              value: _styleId,
              listColor:
                  lists
                      .where((l) => l.id == validId)
                      .map((l) => l.style.color)
                      .firstOrNull ??
                  AppTheme.accentOf(context).color,
              onChanged: (v) {
                _touched();
                setState(() => _styleId = v);
              },
            ),
            if (lists.length > 1) ...[
              const SizedBox(height: 22),
              DropdownButtonFormField<int>(
                initialValue: validId,
                decoration: const InputDecoration(labelText: 'List'),
                items: lists
                    .map(
                      (l) => DropdownMenuItem(
                        value: l.id,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.circle, size: 10, color: l.style.color),
                            const SizedBox(width: 8),
                            Text(l.name),
                          ],
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  _touched();
                  setState(() => _selectedListId = v);
                },
              ),
            ],
            const SizedBox(height: 26),
            if (_dirty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  // The same pair, drawn in towards the middle the same way.
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _FootAction(
                      label: 'Cancel',
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    _FootAction(label: 'Save', onTap: _save),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A step of the checklist while the form is open.
class _Draft {
  final TextEditingController title;
  bool done;

  _Draft(String text, {this.done = false, required VoidCallback onEdit})
    : title = TextEditingController(text: text)..addListener(onEdit);

  void dispose() => title.dispose();
}

/// The checklist in the form: each step with its tick, its words, which can
/// be edited where they stand, and a way to take it out; and under them a
/// line to add the next. One panel, in the same grey as the fields around
/// it, rather than a field per step.
class _Checklist extends StatelessWidget {
  final List<_Draft> steps;
  final TextEditingController newStep;
  final FocusNode newStepFocus;
  final VoidCallback onAdd;
  final ValueChanged<_Draft> onToggle;
  final ValueChanged<_Draft> onRemove;

  const _Checklist({
    required this.steps,
    required this.newStep,
    required this.newStepFocus,
    required this.onAdd,
    required this.onToggle,
    required this.onRemove,
  });

  static const _bare = InputDecoration(
    isDense: true,
    filled: false,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    contentPadding: EdgeInsets.symmetric(vertical: 12),
  );

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Container(
      padding: const EdgeInsets.only(left: 14, right: 4),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      child: Column(
        children: [
          for (final step in steps)
            Row(
              key: ObjectKey(step),
              children: [
                GestureDetector(
                  onTap: () => onToggle(step),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: step.done ? p.muted : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: p.muted, width: 1.6),
                      ),
                      child: CustomPaint(
                        painter: CheckMark(
                          progress: step.done ? 1 : 0,
                          color: p.panel,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: step.title,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: _bare,
                    style: TextStyle(
                      color: step.done ? p.faint : p.text,
                      fontSize: 15,
                      decoration: step.done ? TextDecoration.lineThrough : null,
                      decorationColor: p.faint,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, size: 18, color: p.faint),
                  tooltip: 'Remove',
                  onPressed: () => onRemove(step),
                ),
              ],
            ),
          Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Icon(Icons.add, size: 20, color: p.faint),
              ),
              Expanded(
                child: TextField(
                  key: newSubtaskFieldKey,
                  controller: newStep,
                  focusNode: newStepFocus,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.done,
                  decoration: _bare.copyWith(hintText: 'Add a subtask'),
                  style: TextStyle(color: p.text, fontSize: 15),
                  // Enter on a step adds it and stays for the next; on an empty line
                  // it is the way out, and the keyboard goes.
                  onEditingComplete: () => newStep.text.trim().isEmpty
                      ? newStepFocus.unfocus()
                      : onAdd(),
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
        ],
      ),
    );
  }
}

/// The field at the foot of the form's checklist that adds a step.
const newSubtaskFieldKey = Key('new-subtask-field');

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
                    Text(label, style: TextStyle(color: p.faint, fontSize: 12)),
                    const SizedBox(height: 3),
                    Text(
                      value,
                      style: TextStyle(
                        color: p.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
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
                      .map(
                        (r) => DropdownMenuItem(
                          value: r,
                          child: Text('Repeat: ${r.label.toLowerCase()}'),
                        ),
                      )
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
          color: selected ? color.withValues(alpha: 0.18) : palette.panel,
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

/// A word at the foot of the form. The same two plain words the picker sheets
/// end with, for the same reason: neither is more the answer than the other.
class _FootAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _FootAction({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text(
            label,
            style: TextStyle(
              color: p.text,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

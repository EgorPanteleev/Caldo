import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/task.dart';
import '../models/task_list.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../services/attachments.dart';
import '../db/database.dart';
import '../services/agents.dart';
import 'agents_screen.dart' show openChat, sendToAgents;
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../utils/platform.dart';
import '../widgets/attachments_field.dart';
import '../widgets/colour_selector.dart';
import '../widgets/choice_sheet.dart';
import '../widgets/date_time_pickers.dart';
import '../widgets/desk.dart';
import '../widgets/repeat_sheet.dart';
import '../widgets/groups.dart';
import '../widgets/form_actions.dart';
import '../widgets/quick_add_bar.dart'
    show GroundFade, KeyboardLift, KeyboardRoom;
import '../widgets/task_card.dart' show CheckMark, ClaudeMark, TaskCard;

/// Opens the form on [task], or a new one starting on [initialDate] — a
/// subtask of [parent], if given: a page over a phone's screen, and in the
/// wide layout the panel down the right of the window ([TaskPanel]), where
/// the returned future does not wait for it to be closed.
Future<void> openTaskForm(
  BuildContext context, {
  Task? task,
  DateTime? initialDate,
  Task? parent,
}) {
  if (Desk.isWide(context)) {
    TaskPanel.instance.open(task: task, date: initialDate, parent: parent);
    return Future.value();
  }
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          TaskEditScreen(task: task, initialDate: initialDate, parent: parent),
    ),
  );
}

/// Add a new task or edit an existing one. When [task] is null this is a
/// creation form; otherwise the fields are pre-filled for editing.
class TaskEditScreen extends StatefulWidget {
  final Task? task;

  /// Whether this is the form in the wide layout's panel rather than a
  /// page of its own: it closes by asking the panel to, and tells it when
  /// something has been changed.
  final bool inPanel;

  /// The group a new task should go into (a starting choice; the form can
  /// change it).
  final int? listId;

  /// Pre-selected due date for a task created from the calendar.
  final DateTime? initialDate;

  /// The task a new one is made a subtask of; it starts in its group.
  final Task? parent;

  const TaskEditScreen({
    super.key,
    this.task,
    this.listId,
    this.initialDate,
    this.parent,
    this.inPanel = false,
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

  /// How many minutes the task lasts from [_time], or null for no end.
  int? _duration;
  Priority _priority = Priority.none;
  Repeat _repeat = Repeat.none;

  /// Null means the task keeps its list's colour.
  String? _styleId;

  /// Minutes ahead the task is announced; null follows Settings.
  int? _remindBefore;
  String? _claude;

  /// The chat the task was sent to from Schedule or the calendar, if it
  /// was: looked for as the form opens, since nothing on the task says so.
  String? _chat;

  /// The checklist as it is being edited, and the field that adds to it.
  final List<_Draft> _steps = [];
  final _newStep = TextEditingController();
  final _newStepFocus = FocusNode();

  /// What is attached, as it is being edited.
  final List<Attachment> _attachments = [];

  /// Whether anything has been touched since the form opened. Until it has,
  /// the back arrow is the only way out and there is nothing to save; once it
  /// has, the arrow goes and the two words at the foot take over — leaving by
  /// accident with edits on the screen is the thing being prevented.
  bool _dirty = false;

  void _touched() {
    if (!_dirty) setState(() => _dirty = true);
    if (widget.inPanel) TaskPanel.instance.dirty = true;
  }

  /// A text field's controller has spoken — which it does when the caret
  /// is put in it as well as when something is typed. The form is touched
  /// either way, as it always was; but the panel is only told there is
  /// something to lose once the words differ, so a new task opened and left
  /// alone gives way to a click on another, and closes on one Escape.
  void _typed() {
    if (!_dirty) setState(() => _dirty = true);
    if (widget.inPanel && _wordsDiffer) TaskPanel.instance.dirty = true;
  }

  bool get _wordsDiffer {
    final task = widget.task;
    final steps = task?.subtasks ?? const <Subtask>[];
    if (_title.text != (task?.title ?? '') ||
        _notes.text != (task?.notes ?? '') ||
        _newStep.text.isNotEmpty ||
        _steps.length != steps.length) {
      return true;
    }
    for (var i = 0; i < steps.length; i++) {
      if (_steps[i].title.text != steps[i].title) return true;
    }
    return false;
  }

  /// The way out once there is nothing left to ask: back off the page, or
  /// out of the panel.
  void _close() =>
      widget.inPanel ? TaskPanel.instance.close() : Navigator.of(context).pop();

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    _title = TextEditingController(text: task?.title ?? '')
      ..addListener(_typed);
    _notes = TextEditingController(text: task?.notes ?? '')
      ..addListener(_typed);
    _priority = task?.priority ?? Priority.none;
    _repeat = task?.repeat ?? Repeat.none;
    _remindBefore = task?.remindBefore;
    _claude = task?.claude;
    for (final step in task?.subtasks ?? const <Subtask>[]) {
      _steps.add(_Draft(step.title, done: step.done, onEdit: _typed));
    }
    _newStep.addListener(_typed);
    _attachments.addAll(task?.attachments ?? const []);
    // A new task takes its group's colour; an existing one keeps whatever
    // it was given.
    _styleId = task?.styleId;

    final due = task?.due;
    if (due != null) {
      _date = DateTime(due.year, due.month, due.day);
      if (task!.hasTime) {
        _time = TimeOfDay(hour: due.hour, minute: due.minute);
        _duration = task.duration;
      }
    } else if (task == null && widget.initialDate != null) {
      _date = dayOf(widget.initialDate!);
    }

    // A new task goes into the group on show, as one quick-added does; a
    // new subtask into its parent's.
    _selectedListId =
        task?.listId ??
        widget.listId ??
        widget.parent?.listId ??
        context.read<TaskProvider>().groupForNew;

    if (task?.id != null && Agents.instance.signedIn) {
      unawaited(_findChat(task!.id!));
    }
  }

  /// The tasks the task is part of, the outermost first; a new subtask's
  /// parent's and the parent itself.
  List<Task> _parentsIn(TaskProvider tasks) {
    final task = widget.task;
    final parent = widget.parent;
    if (task != null) return tasks.parentsOf(task);
    if (parent != null) return [...tasks.parentsOf(parent), parent];
    return const [];
  }

  /// A new subtask of the task, in a form of its own. The phone's comes
  /// back here; the wide layout's panel gives way to it.
  Future<void> _addChild() async {
    final task = _now;
    if (task == null) return;
    await openTaskForm(context, parent: task);
  }

  Future<void> _findChat(int id) async {
    final uuid = await AppDatabase.instance.taskUuid(id);
    if (uuid == null) return;
    final chat = await Agents.instance.chatOfTask(uuid).catchError((_) => null);
    if (chat != null && mounted) setState(() => _chat = chat);
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

  /// Leaves the form with the keyboard put away. Left up, it is handed on
  /// to whatever field had it on the screen underneath.
  void _leave() {
    FocusManager.instance.primaryFocus?.unfocus();
    widget.inPanel
        ? TaskPanel.instance.close()
        : Navigator.of(context).maybePop();
  }

  /// Files what is in the add field as a step and leaves the field ready for
  /// the next one, keyboard up: a checklist is written several lines at once.
  void _addStep() {
    final title = _newStep.text.trim();
    if (title.isEmpty) return;
    _touched();
    setState(() => _steps.add(_Draft(title, onEdit: _typed)));
    _newStep.clear();
    _newStepFocus.requestFocus();
    // The new line pushes the field down a row each time, and nothing else
    // scrolls it back out from under the keyboard.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final field = _newStepFocus.context?.findRenderObject();
      if (field is! RenderBox || !field.attached) return;
      // With the room a field keeps when it is typed in, so it comes to
      // rest above the fade over Cancel and Save rather than in it.
      field.showOnScreen(
        rect: _reveal.inflateRect(Offset.zero & field.size),
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
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

  /// Has the user pick what to attach, and adds whatever comes back. The
  /// keyboard goes first: left up, it comes back over the form when the
  /// picker hands back to it.
  Future<void> _attach(AttachFrom from) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final picked = await Attachments.instance.pick(from);
    if (!mounted) return;
    if (picked.attached.isNotEmpty) {
      _touched();
      setState(() => _attachments.addAll(picked.attached));
    }
    if (picked.tooBig.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.of(context).tooBigToAttach(picked.tooBig.join(', '))),
        ),
      );
    }
  }

  /// Moves the task into group [id]. Its colour goes back to following the
  /// group's: a task put into University is meant to look like University.
  void _pickGroup(int? id) {
    if (id == null || id == _selectedListId) return;
    _touched();
    setState(() {
      _selectedListId = id;
      _styleId = null;
    });
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

  /// When the task ends, worked out from its start and length.
  TimeOfDay? get _endTime {
    final start = _time;
    final minutes = _duration;
    if (start == null || minutes == null) return null;
    final end = start.hour * 60 + start.minute + minutes;
    return TimeOfDay(hour: end ~/ 60 % 24, minute: end % 60);
  }

  /// Asks for the end; what is kept is the length from the start, so moving
  /// the start later carries the end with it. An end at or before the start
  /// is turned down rather than taken for the next day: a task here lives
  /// on one day.
  Future<void> _pickEnd() async {
    final start = _time;
    if (start == null) return;
    final from = start.hour * 60 + start.minute;
    final initial =
        _endTime ??
        TimeOfDay(hour: (from + 60) ~/ 60 % 24, minute: (from + 60) % 60);
    final picked = await showAppTimePicker(context: context, initial: initial);
    if (picked == null || !mounted) return;
    final minutes = picked.hour * 60 + picked.minute - from;
    if (minutes <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(S.of(context).endBeforeStart)));
      return;
    }
    _touched();
    setState(() => _duration = minutes);
  }

  /// Which Claude model the task is handed to, if any. "" stands for none
  /// in the sheet, which gives null back for "put away".
  Future<void> _openChat() async {
    final id = widget.task?.id;
    if (id == null) return;
    final uuid = await AppDatabase.instance.taskUuid(id);
    final chat = uuid == null
        ? _chat
        : await Agents.instance.chatOfTask(uuid).catchError((_) => _chat);
    if (!mounted) return;
    if (chat == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(S.of(context).noChats)));
      return;
    }
    await openChat(context, chat);
  }

  /// The task as it stands now: sent from here, its mark and state are
  /// the provider's, not the form's.
  Task? get _now {
    final id = widget.task?.id;
    if (id == null) return widget.task;
    return context.read<TaskProvider>().taskById(id) ?? widget.task;
  }

  /// Whether the task has a chat to open: sent to an agent, or handed to
  /// Claude by the watcher.
  bool get _sentAlready =>
      _chat != null || _now?.agent != null || _now?.claude != null;

  /// "Opus · Working", or that it has not been sent.
  String _agentLine(S s) {
    final task = _now;
    final mark = task == null ? null : ClaudeMark.of(task);
    if (task == null || mark == null) {
      return _chat == null ? s.agentNotSent : s.chatOpen;
    }
    final stands = task.done ? null : ClaudeMark.nameOf(s, task.agentState);
    return stands == null ? mark : '$mark · $stands';
  }

  /// The form to send the task to an agent; sent, its chat is looked for
  /// again, so the row opens it.
  Future<void> _send() async {
    final task = _now;
    if (task == null) return;
    final sent = await sendToAgents(context, [task]);
    if (sent && mounted) {
      setState(() {});
      unawaited(_findChat(task.id!));
    }
  }

  Future<void> _pickClaude() async {
    final s = S.of(context);
    final picked = await choose<String>(
      context,
      title: s.claudeLabel,
      selected: _claude ?? '',
      options: [
        Option('', s.claudeNone),
        for (final m in ClaudeModels.all) Option(m, ClaudeModels.name(m)),
      ],
    );
    if (picked == null || picked == (_claude ?? '')) return;
    _touched();
    setState(() => _claude = picked.isEmpty ? null : picked);
  }

  Future<void> _pickRepeat() async {
    final date = _date;
    if (date == null) return;
    final picked = await showRepeatSheet(
      context: context,
      initial: _repeat,
      due: date,
    );
    if (picked != null && picked != _repeat) {
      _touched();
      setState(() => _repeat = picked);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final provider = context.read<TaskProvider>();
    final lists = provider.lists;
    final listId =
        (_selectedListId != null && lists.any((l) => l.id == _selectedListId))
        ? _selectedListId!
        : provider.defaultGroup;
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
          attachments: List.of(_attachments),
          remindBefore: _remindBefore,
          duration: _time == null ? null : _duration,
          claude: _claude,
          parentId: widget.parent?.id,
        ),
      );
    } else {
      // A snooze put off the reminder this task had; a new date or a new
      // lead is a new reminder, and the snooze would only stand in its way.
      final reminderMoved =
          due?.millisecondsSinceEpoch != existing.dueAt ||
          _remindBefore != existing.remindBefore;
      // A task moved to another day lets go of its place in the old one, as
      // a card carried there does (`TaskProvider.moveToDay`).
      final dayMoved = (due == null ? null : dayOf(due)) != existing.dueDay;
      // What the form does not show is taken from the task as it stands
      // now, not as it stood when the form was opened: a tick from the
      // widget or a reminder's Done, or a start on the board, made while
      // the form was open would otherwise be written back over.
      final id = existing.id;
      final current = (id == null ? null : provider.taskById(id)) ?? existing;
      await provider.update(
        current.copyWith(
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
          attachments: List.of(_attachments),
          remindBefore: _remindBefore,
          clearRemindBefore: _remindBefore == null,
          clearSnoozedUntil: reminderMoved,
          clearSortOrder: dayMoved,
          duration: _time == null ? null : _duration,
          clearDuration: _time == null || _duration == null,
          claude: _claude,
          clearClaude: _claude == null,
        ),
      );
    }
    if (mounted) _close();
  }

  Future<void> _delete() async {
    final task = widget.task;
    if (task?.id == null) return;
    final s = S.of(context);
    final hasSubtasks = context
        .read<TaskProvider>()
        .subtasksOf(task!.id!)
        .isNotEmpty;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteTaskQuestion),
        content: Text(
          hasSubtasks
              ? '${s.willBeRemoved(task.title)} ${s.subtasksGoToo}'
              : s.willBeRemoved(task.title),
        ),
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
    if (ok == true && mounted) {
      await context.read<TaskProvider>().remove(task.id!);
      if (mounted) _close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final isEdit = widget.task != null;
    final provider = context.watch<TaskProvider>();
    final lists = provider.lists;
    final parents = _parentsIn(provider);
    final children = widget.task?.id == null
        ? const <Task>[]
        : provider.subtasksOf(widget.task!.id!);
    final validId = lists.any((l) => l.id == _selectedListId)
        ? _selectedListId
        : (lists.isNotEmpty ? provider.defaultGroup : null);

    final form = Scaffold(
      // The keyboard arrives over the form rather than resizing it, and the
      // foot is attached to it (`KeyboardLift`) the way the quick-add bar
      // is. Resized, the pair did what that bar used to: rode the layout's
      // idea of the inset rather than the keys themselves.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        // Once something has been changed there is no way out but the two
        // words at the foot: an arrow beside unsaved edits is an invitation
        // to lose them.
        automaticallyImplyLeading: !_dirty && !widget.inPanel,
        // The panel has no page under it to go back to: it is closed.
        leading: widget.inPanel && !_dirty
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: _leave,
              )
            : null,
        title: Text(isEdit ? s.editTask : s.newTask),
        actions: [
          if (isEdit)
            IconButton(
              icon: Icon(Icons.delete_outline, color: AppColors.danger),
              tooltip: s.delete,
              onPressed: _delete,
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        // The gesture bar's strip stays reserved under the keys, as it does
        // in the shell; `KeyboardGap` takes the lift from there.
        maintainBottomViewPadding: true,
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Column(
                      children: [
                        Expanded(
                          child: ListView(
                            padding: const EdgeInsets.all(20),
                            children: [
                              if (parents.isNotEmpty) ...[
                                _PartOf(
                                  parents: parents,
                                  onOpen: (t) => openTaskForm(context, task: t),
                                ),
                                const SizedBox(height: 8),
                              ],
                              TextFormField(
                                scrollPadding: _reveal,
                                controller: _title,
                                autofocus: !isEdit,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                // At a keyboard, Enter on the name is the
                                // form filled in; a phone's keys go on to
                                // the next field instead.
                                onFieldSubmitted: onDesktop
                                    ? (_) => _save()
                                    : null,
                                decoration: InputDecoration(
                                  labelText: s.taskField,
                                ),
                                validator: (v) =>
                                    (v == null || v.trim().isEmpty)
                                    ? s.required
                                    : null,
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                scrollPadding: _reveal,
                                controller: _notes,
                                minLines: 2,
                                maxLines: 5,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                decoration: InputDecoration(
                                  labelText: s.notesField,
                                ),
                              ),
                              const SizedBox(height: 22),
                              Text(
                                s.sectionChecklist,
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
                              // Only a task already saved has an id for
                              // its subtasks to hang from.
                              if (isEdit) ...[
                                const SizedBox(height: 22),
                                Text(
                                  s.sectionSubtasks,
                                  style: TextStyle(
                                    color: p.faint,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                _Children(
                                  children: children,
                                  lists: lists,
                                  onOpen: (t) => openTaskForm(context, task: t),
                                  onTick: provider.toggleDone,
                                  onAdd: _addChild,
                                ),
                              ],
                              const SizedBox(height: 22),
                              Text(
                                s.sectionAttachments,
                                style: TextStyle(
                                  color: p.faint,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 10),
                              AttachmentsField(
                                attachments: _attachments,
                                onAdd: _attach,
                                onRemove: (a) {
                                  _touched();
                                  setState(() => _attachments.remove(a));
                                },
                              ),
                              const SizedBox(height: 20),
                              _FieldTile(
                                icon: Icons.event_outlined,
                                label: s.dueDate,
                                value: _date == null
                                    ? s.none
                                    : Dates.longDay(_date!),
                                onTap: _pickDate,
                                onClear: _date == null
                                    ? null
                                    : () {
                                        _touched();
                                        setState(() {
                                          _date = null;
                                          _time = null;
                                          _duration = null;
                                          _repeat = Repeat.none;
                                        });
                                      },
                              ),
                              const SizedBox(height: 12),
                              _FieldTile(
                                icon: Icons.schedule,
                                label: s.time,
                                value: _time == null
                                    ? s.allDay
                                    : Dates.clock(
                                        _time!,
                                        h24: MediaQuery.alwaysUse24HourFormatOf(
                                          context,
                                        ),
                                      ),
                                onTap: _pickTime,
                                onClear: _time == null
                                    ? null
                                    : () {
                                        _touched();
                                        setState(() {
                                          _time = null;
                                          _duration = null;
                                        });
                                      },
                              ),
                              const SizedBox(height: 12),
                              // Only a task with a start can have an end.
                              if (_time != null) ...[
                                _FieldTile(
                                  icon: Icons.timelapse_outlined,
                                  label: s.endsAt,
                                  value: _duration == null
                                      ? s.none
                                      : Dates.clock(
                                          _endTime!,
                                          h24:
                                              MediaQuery.alwaysUse24HourFormatOf(
                                                context,
                                              ),
                                        ),
                                  onTap: _pickEnd,
                                  onClear: _duration == null
                                      ? null
                                      : () {
                                          _touched();
                                          setState(() => _duration = null);
                                        },
                                ),
                                const SizedBox(height: 12),
                              ],
                              // A task with no date has nothing to repeat
                              // from, so the row waits for one.
                              Opacity(
                                opacity: _date == null ? 0.5 : 1,
                                child: IgnorePointer(
                                  ignoring: _date == null,
                                  child: _FieldTile(
                                    icon: Icons.repeat,
                                    label: s.repeatLabel,
                                    value: s.repeatName(_repeat),
                                    onTap: _pickRepeat,
                                    onClear: _repeat.isNone
                                        ? null
                                        : () {
                                            _touched();
                                            setState(
                                              () => _repeat = Repeat.none,
                                            );
                                          },
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              _ReminderField(
                                value: _remindBefore,
                                timed: _time != null,
                                enabled: _date != null,
                                onChanged: (v) {
                                  _touched();
                                  setState(() => _remindBefore = v);
                                },
                              ),
                              const SizedBox(height: 12),
                              _FieldTile(
                                key: claudeFieldKey,
                                icon: _claude == null
                                    ? Icons.auto_awesome_outlined
                                    : Icons.auto_awesome,
                                label: s.claudeLabel,
                                value: _claude == null
                                    ? s.claudeNone
                                    : ClaudeModels.name(_claude!),
                                onTap: _pickClaude,
                                onClear: _claude == null
                                    ? null
                                    : () {
                                        _touched();
                                        setState(() => _claude = null);
                                      },
                              ),
                              // Sent to an agent, or to be: where it stands,
                              // and its chat to watch it or say more.
                              if (widget.task?.id != null &&
                                  Agents.instance.signedIn) ...[
                                const SizedBox(height: 12),
                                _FieldTile(
                                  key: agentFieldKey,
                                  icon: Icons.terminal_rounded,
                                  label: s.agentLabel,
                                  value: _agentLine(s),
                                  onTap: _sentAlready ? _openChat : _send,
                                ),
                              ],
                              const SizedBox(height: 22),
                              Text(
                                s.sectionPriority,
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
                                s.sectionGroup,
                                style: TextStyle(
                                  color: p.faint,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                key: groupFieldKey,
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final list in lists)
                                    GroupChip(
                                      label: groupLabel(context, list),
                                      color: list.style.color,
                                      selected: list.id == validId,
                                      onTap: () => _pickGroup(list.id),
                                      onLongPress: () =>
                                          showGroupSheet(context, group: list),
                                    ),
                                  GroupChip.add(
                                    onTap: () async {
                                      final made = await showGroupSheet(
                                        context,
                                      );
                                      if (made != null) _pickGroup(made.id);
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 22),
                              Text(
                                s.sectionColour,
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
                                sample: _title.text.trim().isEmpty
                                    ? s.taskField
                                    : _title.text.trim(),
                                groupColour:
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
                            ],
                          ),
                        ),
                        // The list ends where the keys begin, so a field's own
                        // scroll into view clears them; only the list is
                        // shortened, and what it gives up is behind the keyboard.
                        const KeyboardRoom(),
                      ],
                    ),
                    // The form runs on under the foot; soften where it is cut
                    // off, as Schedule does above its add field.
                    if (_dirty)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: KeyboardLift(child: GroundFade(ground: p.bg)),
                      ),
                  ],
                ),
              ),
              // Pinned to the foot of the screen rather than written after the
              // last field: on a long form the pair was a scroll away, and the
              // way out of an edit should not have to be looked for.
              if (_dirty)
                FormActions(
                  onCancel: _leave,
                  onSave: _save,
                  wrapActions: (child) => _Nudged(child: child),
                ),
            ],
          ),
        ),
      ),
    );
    if (!onDesktop) return form;
    // Saved from the keys as well, wherever in the form the caret is.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
      },
      child: form,
    );
  }
}

/// Shakes Cancel and Save when the panel's form was asked to give way with
/// changes in it ([TaskPanel.nudged]) — a click on another task, which does
/// nothing until one of the two has answered for this one. The head-shake
/// a card's tick gives when it is held back, for the same reason.
class _Nudged extends StatefulWidget {
  final Widget child;

  const _Nudged({required this.child});

  @override
  State<_Nudged> createState() => _NudgedState();
}

class _NudgedState extends State<_Nudged> with SingleTickerProviderStateMixin {
  late final _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  @override
  void initState() {
    super.initState();
    TaskPanel.instance.nudged.addListener(_nudge);
  }

  @override
  void dispose() {
    TaskPanel.instance.nudged.removeListener(_nudge);
    _shake.dispose();
    super.dispose();
  }

  void _nudge() => _shake.forward(from: 0);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _shake,
      builder: (context, child) {
        final t = _shake.value;
        return Transform.translate(
          offset: Offset(6 * math.sin(t * 6 * math.pi) * (1 - t), 0),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// What a field keeps clear around itself when it is scrolled into view.
/// The stock twenty points below it land a field at the foot of the list
/// inside the fade over the Cancel/Save pair, dimmed; this puts it above.
const _reveal = EdgeInsets.fromLTRB(20, 20, 20, 20 + GroundFade.height);

/// What a subtask is part of, the outermost first, each opening its own
/// form: its context, which an agent it is sent to is told as well.
class _PartOf extends StatelessWidget {
  final List<Task> parents;
  final ValueChanged<Task> onOpen;

  const _PartOf({required this.parents, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Text(s.partOf, style: TextStyle(color: p.faint, fontSize: 13)),
        ),
        for (final (i, parent) in parents.indexed) ...[
          if (i > 0) Icon(Icons.chevron_right, size: 16, color: p.faint),
          InkWell(
            onTap: () => onOpen(parent),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Text(
                parent.title.trim(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: p.muted,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A task's subtasks in its form: each a task of its own, ticked here and
/// opened in a form of its own; and under them a line making the next.
class _Children extends StatelessWidget {
  final List<Task> children;
  final List<TaskList> lists;
  final ValueChanged<Task> onOpen;
  final ValueChanged<Task> onTick;
  final VoidCallback onAdd;

  const _Children({
    required this.children,
    required this.lists,
    required this.onOpen,
    required this.onTick,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final h24 = MediaQuery.alwaysUse24HourFormatOf(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      child: Column(
        children: [
          for (final child in children)
            InkWell(
              key: ValueKey(child.id),
              onTap: () => onOpen(child),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => onTick(child),
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: _Tick(
                          done: child.done,
                          color: colorOfTask(
                            child,
                            lists
                                .where((l) => l.id == child.listId)
                                .firstOrNull,
                            fallback: AppTheme.accentOf(context).color,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        child.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: child.done ? p.faint : p.text,
                          fontSize: 15,
                          decoration: child.done
                              ? TextDecoration.lineThrough
                              : null,
                          decorationColor: p.faint,
                        ),
                      ),
                    ),
                    if (child.due != null) ...[
                      const SizedBox(width: 10),
                      Text(
                        Dates.due(child, h24: h24),
                        style: TextStyle(
                          color: child.isOverdue ? AppColors.overdue : p.muted,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                    if (ClaudeMark.of(child) != null) ...[
                      const SizedBox(width: 8),
                      Icon(
                        Icons.auto_awesome,
                        size: 14,
                        color: child.done || child.agentState == null
                            ? p.faint
                            : ClaudeMark.colourOf(p, child.agentState!),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          InkWell(
            onTap: onAdd,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Icon(Icons.add, size: 20, color: p.faint),
                  ),
                  Expanded(
                    child: Text(
                      s.addSubtask,
                      style: TextStyle(color: p.faint, fontSize: 15),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A subtask's round tick, in its colour.
class _Tick extends StatelessWidget {
  final bool done;
  final Color color;

  const _Tick({required this.done, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    width: 20,
    height: 20,
    decoration: BoxDecoration(
      color: done ? color : Colors.transparent,
      shape: BoxShape.circle,
      border: Border.all(color: color, width: 1.6),
    ),
    child: CustomPaint(
      painter: CheckMark(progress: done ? 1 : 0, color: Colors.white),
    ),
  );
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
                    scrollPadding: _reveal,
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
                  tooltip: S.of(context).remove,
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
                  scrollPadding: _reveal,
                  key: newSubtaskFieldKey,
                  controller: newStep,
                  focusNode: newStepFocus,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.done,
                  decoration: _bare.copyWith(hintText: S.of(context).addStep),
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

/// The form's row of groups.
const groupFieldKey = Key('group-field');

/// The field at the foot of the form's checklist that adds a step.
const newSubtaskFieldKey = Key('new-subtask-field');

/// A tappable settings-style row: icon, label, current value, optional clear.
class _FieldTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;
  final VoidCallback? onClear;

  const _FieldTile({
    super.key,
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
                  tooltip: S.of(context).clear,
                  onPressed: onClear,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// When the task is announced. What is offered depends on whether it has a
/// time: a timed task can be announced minutes, hours or days ahead; an
/// all-day one is announced at the hour Settings names, on its day or up to
/// two weeks before. Either can follow Settings, which is where a task starts, or
/// be left unannounced.
class _ReminderField extends StatelessWidget {
  final int? value;
  final bool timed;
  final bool enabled;
  final ValueChanged<int?> onChanged;

  const _ReminderField({
    required this.value,
    required this.timed,
    required this.enabled,
    required this.onChanged,
  });

  /// Stands for null in the sheet, which gives null back for "put away".
  static const _followSettings = -2;

  static const _day = Duration.minutesPerDay;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final h24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final s = S.of(context);
    final options = <int, String>{
      _followSettings: timed
          ? s.remindLead(Dates.lead(settings.reminderLead))
          : s.remindOnDayAt(Dates.clock(settings.reminderTime, h24: h24)),
      if (timed)
        for (final lead in SettingsProvider.leads)
          if (lead != settings.reminderLead)
            lead: s.remindLead(Dates.lead(lead)),
      for (final lead in SettingsProvider.dayLeads)
        lead: !timed && lead == _day
            ? s.remindDayBefore
            : s.remindLead(Dates.lead(lead)),
      Task.silent: s.noReminder,
    };
    // A lead chosen for a timed task and kept when its time is taken off
    // reads as the nearest thing an all-day task can do with it: the
    // longest whole-day lead that does not go past it.
    var shown = value ?? _followSettings;
    if (!options.containsKey(shown)) {
      shown = SettingsProvider.dayLeads.lastWhere(
        (lead) => lead <= shown,
        orElse: () => _followSettings,
      );
    }
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: _FieldTile(
        key: reminderFieldKey,
        icon: shown == Task.silent
            ? Icons.notifications_off_outlined
            : Icons.notifications_none,
        label: s.reminderLabel,
        value: options[shown]!,
        onTap: enabled
            ? () async {
                final picked = await choose<int>(
                  context,
                  title: s.reminderLabel,
                  selected: shown,
                  options: [
                    for (final MapEntry(key: lead, value: label)
                        in options.entries)
                      Option(lead, label),
                  ],
                );
                if (picked == null || picked == shown) return;
                onChanged(picked == _followSettings ? null : picked);
              }
            : null,
      ),
    );
  }
}

/// The form's reminder row.
const reminderFieldKey = Key('reminder-field');

/// The form's row handing the task to Claude.
const claudeFieldKey = Key('claude-field');

/// The form's row sending the task to an agent, or opening its chat.
const agentFieldKey = Key('agent-field');

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
        : TaskCard.priorityColor(priority);
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
              S.of(context).priorityName(priority),
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

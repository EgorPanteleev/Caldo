import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/task_list.dart';
import '../providers/events_provider.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import 'date_time_pickers.dart' show PickerSheet, SheetAction;

/// What a group is called on screen. The default group is made before
/// anyone has named anything, as "Personal" in English; until it is
/// renamed it is written in the app's language.
String groupLabel(BuildContext context, TaskList list) =>
    list.name == 'Personal' ? S.of(context).personal : list.name;

/// The phone's calendar events to put beside the tasks: none while one
/// group is on show. An event is in no group, and a screen asked for
/// University should show University and nothing else.
EventsProvider? eventsOnShow(BuildContext context) {
  final events = context.watch<EventsProvider?>();
  final grouped = context.select<TaskProvider, bool>((t) => t.group != null);
  return grouped ? null : events;
}

/// Identifies the row of groups under a screen's header.
const groupChipsKey = Key('group-chips');

/// The row under the Schedule and calendar headers that picks which group
/// is on show: All, then each group in the order it was made, then a plus
/// for a new one. Always there, even with only the default group, because
/// it is where groups are found to exist at all.
///
/// One row for both screens, reading one choice from the provider, so the
/// two cannot come to show different groups. A long press on a group opens
/// it to be renamed, recoloured or deleted — there is no list of groups to
/// manage anywhere else.
class GroupChips extends StatelessWidget {
  const GroupChips({super.key});

  @override
  Widget build(BuildContext context) {
    final lists = context.select<TaskProvider, List<TaskList>>((t) => t.lists);
    final shown = context.select<TaskProvider, int?>((t) => t.group);
    final tasks = context.read<TaskProvider>();
    // As wide as the screen, so a short row starts at the left edge rather
    // than being centred by the column it is in.
    return SingleChildScrollView(
      key: groupChipsKey,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          GroupChip(
            label: S.of(context).allGroups,
            selected: shown == null,
            onTap: () => tasks.showGroup(null),
          ),
          for (final list in lists) ...[
            const SizedBox(width: 8),
            GroupChip(
              label: groupLabel(context, list),
              color: list.style.color,
              selected: shown == list.id,
              onTap: () => tasks.showGroup(list.id),
              onLongPress: () => showGroupSheet(context, group: list),
            ),
          ],
          const SizedBox(width: 8),
          GroupChip.add(
            onTap: () async {
              final made = await showGroupSheet(context);
              if (made != null) tasks.showGroup(made.id);
            },
          ),
        ],
      ),
    );
  }
}

/// One group as a chip: its colour as a dot before its name, filled in the
/// field's grey while it is the one chosen. Neutral rather than the accent,
/// as every control here is; the dot is the only colour on it.
class GroupChip extends StatelessWidget {
  final String? label;
  final Color? color;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const GroupChip({
    super.key,
    required String this.label,
    this.color,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  /// The chip that makes a new group: a plus and nothing else.
  const GroupChip.add({super.key, required this.onTap})
    : label = null,
      color = null,
      selected = false,
      onLongPress = null;

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Material(
      color: selected ? p.field : Colors.transparent,
      shape: StadiumBorder(
        side: selected ? BorderSide.none : BorderSide(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        onLongPress: onLongPress == null
            ? null
            : () {
                HapticFeedback.mediumImpact();
                onLongPress!();
              },
        child: Padding(
          padding: label == null
              ? const EdgeInsets.symmetric(horizontal: 9, vertical: 6)
              : const EdgeInsets.fromLTRB(14, 6, 14, 6),
          child: label == null
              ? Icon(
                  Icons.add,
                  size: 20,
                  color: p.muted,
                  semanticLabel: S.of(context).newGroup,
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (color != null) ...[
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      label!,
                      style: TextStyle(
                        color: selected ? p.text : p.muted,
                        fontSize: 14,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Makes a group, or with [group] renames, recolours or deletes it. Returns
/// the group made, or null if none was.
Future<TaskList?> showGroupSheet(BuildContext context, {TaskList? group}) {
  return showModalBottomSheet<TaskList>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => PickerSheet(child: _GroupSheet(group: group)),
  );
}

class _GroupSheet extends StatefulWidget {
  final TaskList? group;

  const _GroupSheet({this.group});

  @override
  State<_GroupSheet> createState() => _GroupSheetState();
}

class _GroupSheetState extends State<_GroupSheet> {
  late final TextEditingController _name;
  late String _styleId;

  @override
  void initState() {
    super.initState();
    final group = widget.group;
    _name = TextEditingController(
      text: group == null ? '' : groupLabel(context, group),
    );
    // A new group starts in a colour no group has yet, while there is one,
    // so two groups made one after another can be told apart unasked.
    final taken = {
      for (final l in context.read<TaskProvider>().lists) l.styleId,
    };
    _styleId =
        group?.styleId ??
        ListStyle.presets
            .map((s) => s.id)
            .firstWhere((id) => !taken.contains(id), orElse: () => 'violet');
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final tasks = context.read<TaskProvider>();
    final group = widget.group;
    TaskList? made;
    if (group == null) {
      made = await tasks.addList(
        TaskList(
          name: name,
          styleId: _styleId,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } else {
      await tasks.updateList(group.copyWith(name: name, styleId: _styleId));
    }
    if (mounted) Navigator.of(context).pop(made);
  }

  Future<void> _delete() async {
    final group = widget.group!;
    final tasks = context.read<TaskProvider>();
    final s = S.of(context);
    final into = tasks.lists.firstWhere((l) => l.id == tasks.defaultGroup);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteGroupQuestion(groupLabel(context, group))),
        content: Text(s.groupTasksMoveTo(groupLabel(context, into))),
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
    if (ok != true) return;
    await tasks.deleteList(group.id!);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final group = widget.group;
    final deletable =
        group != null && group.id != context.read<TaskProvider>().defaultGroup;
    return Padding(
      // A sheet is not lifted the way a screen is, so it makes the
      // keyboard's room out of its own height.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    group == null ? s.newGroup : s.editGroup,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (deletable)
                  IconButton(
                    icon: const Icon(
                      Icons.delete_outline,
                      color: AppColors.danger,
                    ),
                    tooltip: s.delete,
                    onPressed: _delete,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: groupNameFieldKey,
              controller: _name,
              autofocus: group == null,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(labelText: s.groupName),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final style in ListStyle.presets)
                  GestureDetector(
                    onTap: () => setState(() => _styleId = style.id),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: style.color.withValues(
                          alpha: _styleId == style.id ? 1 : 0.35,
                        ),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _styleId == style.id ? p.text : p.border,
                          width: _styleId == style.id ? 2 : 1,
                        ),
                      ),
                      child: _styleId == style.id
                          ? const Icon(
                              Icons.check,
                              size: 18,
                              color: Colors.white,
                            )
                          : null,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              // The same pair the pickers end with, drawn in towards the
              // middle rather than out to the corners.
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                SheetAction(
                  label: s.cancel,
                  onTap: () => Navigator.of(context).pop(),
                ),
                SheetAction(label: s.save, onTap: _save),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The name field in the group sheet.
const groupNameFieldKey = Key('group-name-field');

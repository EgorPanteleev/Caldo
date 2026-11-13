import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/task_list.dart';
import '../providers/events_provider.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import 'colour_selector.dart';
import 'date_time_pickers.dart' show PickerSheet, SheetAction;
import 'quick_add_bar.dart' show BarRoom;

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
/// is on show: All, then each group in the order the user has put them in,
/// then a plus for a new one. Always there, even with only the default
/// group, because it is where groups are found to exist at all.
///
/// One row for both screens, reading one choice from the provider, so the
/// two cannot come to show different groups. A long press on a group picks
/// it up, to be carried along the row into another place; one let go where
/// it was pressed opens it to be renamed, recoloured or deleted, as a card
/// held and let go is picked out — there is no list of groups to manage
/// anywhere else.
class GroupChips extends StatefulWidget {
  /// What the row stands on, painted under a chip while it is carried: the
  /// screen's ground unless said otherwise. A chip not chosen is only an
  /// outline, and carried over its neighbours, their names showed through it.
  final Color? ground;

  const GroupChips({super.key, this.ground});

  @override
  State<GroupChips> createState() => _GroupChipsState();
}

class _GroupChipsState extends State<GroupChips> {
  /// How far a finger may wander between pressing and letting go and still
  /// be opening the group rather than moving it — the selection's figure.
  static const _slop = 18.0;

  int? _pointer;
  Offset? _down;
  bool _moved = false;
  TaskList? _lifted;

  /// The group held and let go in place, opened as it is dropped.
  TaskList? _open;

  void _pressed(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _down = event.position;
    _moved = false;
    _lifted = null;
  }

  void _moving(PointerMoveEvent event) {
    if (event.pointer != _pointer || _down == null) return;
    if ((event.position - _down!).distance > _slop) _moved = true;
  }

  // The release reaches this before the list's drag hears of it, so the
  // group to open is known by the time the drop is reported.
  void _let(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerUpEvent && _lifted != null && !_moved) _open = _lifted;
    _pointer = null;
    _down = null;
    _lifted = null;
  }

  // Called as the chip is let go, before it has settled: the sheet rises
  // while it does, rather than after a pause.
  void _dropped(int _) {
    final open = _open;
    _open = null;
    if (open != null) showGroupSheet(context, group: open);
  }

  void _reorder(List<TaskList> lists, int from, int to) {
    if (to > from) to--;
    if (to == from) return;
    final ordered = [...lists];
    ordered.insert(to, ordered.removeAt(from));
    context.read<TaskProvider>().reorderLists(ordered);
  }

  @override
  Widget build(BuildContext context) {
    final lists = context.select<TaskProvider, List<TaskList>>((t) => t.lists);
    final shown = context.select<TaskProvider, int?>((t) => t.group);
    final tasks = context.read<TaskProvider>();
    final ground = widget.ground ?? AppTheme.of(context).bg;
    // A list has to be told its height; the chips' own, at the text size
    // in force, so a larger font is not cut off.
    final height = math.max(
      32.0,
      MediaQuery.textScalerOf(context).scale(14) * 1.3 + 12,
    );
    return Listener(
      onPointerDown: _pressed,
      onPointerMove: _moving,
      onPointerUp: _let,
      onPointerCancel: _let,
      child: SizedBox(
        height: height,
        child: ReorderableListView(
          key: groupChipsKey,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          // A chip is lifted as a card is, with a little scale rather than
          // the shadowed slab a reorderable list puts under it.
          proxyDecorator: (child, _, animation) => AnimatedBuilder(
            animation: animation,
            builder: (_, child) => Transform.scale(
              scale: 1 + 0.06 * Curves.easeOut.transform(animation.value),
              child: child,
            ),
            child: Material(type: MaterialType.transparency, child: child),
          ),
          onReorderStart: (i) {
            HapticFeedback.mediumImpact();
            _lifted = lists[i];
          },
          onReorderEnd: _dropped,
          onReorder: (from, to) => _reorder(lists, from, to),
          header: Center(
            child: GroupChip(
              label: S.of(context).allGroups,
              selected: shown == null,
              onTap: () => tasks.showGroup(null),
            ),
          ),
          footer: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Center(
              child: GroupChip.add(
                onTap: () async {
                  final made = await showGroupSheet(context);
                  if (made != null) tasks.showGroup(made.id);
                },
              ),
            ),
          ),
          children: [
            for (final list in lists)
              Padding(
                key: ValueKey(list.id),
                padding: const EdgeInsets.only(left: 8),
                child: Center(
                  // The ground it stands on, so it is unchanged at rest.
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: ground,
                      shape: const StadiumBorder(),
                    ),
                    child: GroupChip(
                      label: groupLabel(context, list),
                      color: list.style.color,
                      selected: shown == list.id,
                      onTap: () => tasks.showGroup(list.id),
                    ),
                  ),
                ),
              ),
          ],
        ),
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
      // Rimmed as the tab bar is, chosen or not: in the hairline border
      // grey the chips were drawn more faintly than the bar under them.
      shape: StadiumBorder(
        side: BorderSide(color: BarRoom.rim(p), width: BarRoom.rimWidth),
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
    _styleId =
        group?.styleId ??
        ListStyle.freeFor({
          for (final l in context.read<TaskProvider>().lists) l.styleId,
        });
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
            ColourSelector(
              value: _styleId,
              sample: _name.text.trim().isEmpty
                  ? s.groupName
                  : _name.text.trim(),
              onChanged: (v) => setState(() => _styleId = v!),
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

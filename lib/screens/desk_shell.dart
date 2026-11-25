import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/task_list.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/desk.dart';
import '../widgets/groups.dart';
import '../widgets/quick_add_bar.dart' show BarRoom;
import 'home_screen.dart' show screenItems;
import 'task_edit_screen.dart';

/// Identifies the wide layout's sidebar, and the panel a form opens in.
const deskSidebarKey = Key('desk-sidebar');
const deskFormKey = Key('desk-form');

/// What stands down the left of the wide layout: the way to a new task and
/// to search, the screens, and the groups.
///
/// The screens are the phone's tab bar stood on end, in its order and with
/// its overdue mark — a count here, since there is room to say how many.
/// Settings takes any of the four out of it, as out of the bar. The groups
/// are the row of chips the phone has under each header, as a list: here
/// they are in one place for every screen rather than at the top of three.
class DeskSidebar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelected;
  final VoidCallback onNew;
  final VoidCallback onSearch;

  const DeskSidebar({
    super.key,
    required this.index,
    required this.onSelected,
    required this.onNew,
    required this.onSearch,
  });

  /// Settings, after the screens [AppScreen] names.
  static final _settings = AppScreen.values.length;

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final overdue = context.select<TaskProvider, int>(
      (p) => p.allOverdue.length,
    );
    final hidden = context.select<SettingsProvider, Set<AppScreen>>(
      (s) => s.hiddenScreens,
    );
    // The backlog is Schedule's — or the calendar's, while Schedule is out.
    final late = !hidden.contains(AppScreen.schedule)
        ? AppScreen.schedule.index
        : AppScreen.calendar.index;

    return Container(
      key: deskSidebarKey,
      width: Desk.sidebar,
      decoration: BoxDecoration(
        color: p.sidebar,
        border: Border(right: BorderSide(color: p.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Caldo',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  Dates.longDay(DateTime.now()),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.faint, fontSize: 12.5),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: _NewTask(onTap: onNew),
          ),
          SideItem(
            icon: Icons.search,
            label: s.search,
            hint: 'Ctrl F',
            onTap: onSearch,
          ),
          const SizedBox(height: 10),
          for (final screen in AppScreen.values)
            if (!hidden.contains(screen))
              SideItem(
                icon: index == screen.index
                    ? screenItems[screen.index].activeIcon
                    : screenItems[screen.index].icon,
                label: screenItems[screen.index].label(s),
                selected: index == screen.index,
                badge: screen.index == late && overdue > 0 ? overdue : null,
                onTap: () => onSelected(screen.index),
              ),
          const SizedBox(height: 14),
          Expanded(
            child: _Groups(
              // A group picked from a screen that does not go by groups
              // goes to one that does: the click was to see its tasks.
              onPicked: () {
                if (index > AppScreen.board.index) {
                  onSelected(
                    AppScreen.values
                        .firstWhere((s) => !hidden.contains(s))
                        .index,
                  );
                }
              },
            ),
          ),
          Divider(height: 1, color: p.border),
          const SizedBox(height: 6),
          SideItem(
            icon: index == _settings
                ? screenItems[_settings].activeIcon
                : screenItems[_settings].icon,
            label: s.settings,
            selected: index == _settings,
            onTap: () => onSelected(_settings),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Identifies the sidebar's New task button.
const deskNewTaskKey = Key('desk-new-task');

/// The way to a new task: the one filled thing in the sidebar, in the add
/// field's grey and rim — the plus above the phone's tab bar, with room
/// here to say what it is.
class _NewTask extends StatelessWidget {
  final VoidCallback onTap;

  const _NewTask({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Material(
      key: deskNewTaskKey,
      color: p.field,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(11),
        side: BorderSide(color: BarRoom.rim(p), width: BarRoom.rimWidth),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(11, 9, 12, 9),
          child: Row(
            children: [
              Icon(Icons.add_rounded, size: 21, color: p.text),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  S.of(context).newTask,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text('Ctrl N', style: TextStyle(color: p.muted, fontSize: 11.5)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row of the sidebar: an icon or a group's dot, a name, and at its far
/// end a count, the keys that do the same, or whatever [trailing] is. The
/// one in force is lifted in the field's grey, neutral, as the tab bar's
/// current screen is.
class SideItem extends StatelessWidget {
  final IconData? icon;

  /// A group's colour, drawn as a dot where the icon would be.
  final Color? dot;
  final String label;
  final bool selected;
  final int? badge;
  final String? hint;
  final Widget? trailing;
  final VoidCallback onTap;
  final VoidCallback? onSecondaryTap;

  const SideItem({
    super.key,
    this.icon,
    this.dot,
    required this.label,
    this.selected = false,
    this.badge,
    this.hint,
    this.trailing,
    required this.onTap,
    this.onSecondaryTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final colour = selected ? p.text : p.muted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Material(
        color: selected ? p.field : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onSecondaryTap: onSecondaryTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  child: dot != null
                      ? Center(
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: dot,
                              shape: BoxShape.circle,
                            ),
                          ),
                        )
                      : Icon(icon, size: 20, color: colour),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colour,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                if (hint != null)
                  Text(hint!, style: TextStyle(color: p.faint, fontSize: 11.5)),
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.overdue.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '$badge',
                      style: TextStyle(
                        color: AppColors.overdue,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Identifies the sidebar's list of groups.
const deskGroupsKey = Key('desk-groups');

/// The groups, down the sidebar: All, then each in the order the user has
/// put them in, and a plus beside the heading for a new one.
///
/// A click shows that group alone on Schedule, the calendar and the board;
/// a drag carries one to another place in the order; and the pencil that
/// comes up under the pointer, or a right click, opens it to be renamed,
/// recoloured or deleted — what a long press let go of does on the phone's
/// row of chips, where there is no pointer to hover and no second button.
class _Groups extends StatelessWidget {
  final VoidCallback onPicked;

  const _Groups({required this.onPicked});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final lists = context.select<TaskProvider, List<TaskList>>((t) => t.lists);
    final shown = context.select<TaskProvider, int?>((t) => t.group);
    final tasks = context.read<TaskProvider>();

    void show(int? id) {
      tasks.showGroup(id);
      onPicked();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 8, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  s.sectionGroups,
                  style: TextStyle(
                    color: p.faint,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.add, size: 18, color: p.muted),
                tooltip: s.newGroup,
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  final made = await showGroupSheet(context);
                  if (made != null) show(made.id);
                },
              ),
            ],
          ),
        ),
        SideItem(
          icon: Icons.all_inbox_outlined,
          label: s.allGroups,
          selected: shown == null,
          onTap: () => show(null),
        ),
        Expanded(
          child: ReorderableListView.builder(
            key: deskGroupsKey,
            padding: const EdgeInsets.only(bottom: 8),
            buildDefaultDragHandles: false,
            // Lifted as a card is: a little larger, and nothing under it.
            proxyDecorator: (child, _, animation) => AnimatedBuilder(
              animation: animation,
              builder: (_, child) => Transform.scale(
                scale: 1 + 0.03 * Curves.easeOut.transform(animation.value),
                child: child,
              ),
              child: Material(type: MaterialType.transparency, child: child),
            ),
            onReorder: (from, to) {
              if (to > from) to--;
              if (to == from) return;
              final ordered = [...lists];
              ordered.insert(to, ordered.removeAt(from));
              tasks.reorderLists(ordered);
            },
            itemCount: lists.length,
            itemBuilder: (context, i) {
              final list = lists[i];
              void edit() => showGroupSheet(context, group: list);
              return pickUpListener(
                context,
                key: ValueKey(list.id),
                index: i,
                child: _Hovered(
                  builder: (context, over) => SideItem(
                    dot: list.style.color,
                    label: groupLabel(context, list),
                    selected: shown == list.id,
                    onTap: () => show(list.id),
                    onSecondaryTap: edit,
                    trailing: over
                        ? _Pencil(tooltip: s.editGroup, onTap: edit)
                        : null,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Builds [builder] again as the pointer comes over it and goes.
class _Hovered extends StatefulWidget {
  final Widget Function(BuildContext context, bool over) builder;

  const _Hovered({required this.builder});

  @override
  State<_Hovered> createState() => _HoveredState();
}

class _HoveredState extends State<_Hovered> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _over = true),
      onExit: (_) => setState(() => _over = false),
      child: widget.builder(context, _over),
    );
  }
}

/// The pencil at the end of a group under the pointer. Small, so the row
/// keeps its height whether or not it is there.
class _Pencil extends StatelessWidget {
  final String tooltip;
  final VoidCallback onTap;

  const _Pencil({required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(Icons.edit_outlined, size: 16, color: p.muted),
        ),
      ),
    );
  }
}

/// A task's form, down the right of the wide layout ([TaskPanel]).
///
/// It comes in from the edge over whatever is there — the calendar's day,
/// which is its width, or the room the other screens make for it — rather
/// than taking the window: what it was opened from stays on show and can
/// still be read, scrolled and ticked beside it. A click on another task
/// swaps the form for that one's, unless this one has changes in it.
class DeskFormPanel extends StatefulWidget {
  const DeskFormPanel({super.key});

  @override
  State<DeskFormPanel> createState() => _DeskFormPanelState();
}

class _DeskFormPanelState extends State<DeskFormPanel>
    with SingleTickerProviderStateMixin {
  /// The form on show — kept, once closed, for as long as it takes to go.
  FormRequest? _shown = TaskPanel.instance.request;

  late final AnimationController _slide;
  late final CurvedAnimation _eased;

  @override
  void initState() {
    super.initState();
    // Made here rather than when first asked for: with no form ever opened
    // the first to ask would be `dispose`, by when it is too late to make
    // a ticker.
    _slide = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 180),
      value: _shown == null ? 0 : 1,
    )..addStatusListener(_onSlide);
    _eased = CurvedAnimation(
      parent: _slide,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    TaskPanel.instance.addListener(_changed);
  }

  @override
  void dispose() {
    TaskPanel.instance.removeListener(_changed);
    _eased.dispose();
    _slide.dispose();
    super.dispose();
  }

  void _changed() {
    final request = TaskPanel.instance.request;
    if (request == null) {
      _slide.reverse();
    } else {
      setState(() => _shown = request);
      _slide.forward();
    }
  }

  void _onSlide(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) {
      setState(() => _shown = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown == null) return const SizedBox.shrink();
    final p = AppTheme.of(context);
    return LayoutBuilder(
      builder: (context, box) => SlideTransition(
        position: Tween(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(_eased),
        child: Container(
          key: deskFormKey,
          width: math.min(Desk.side, box.maxWidth),
          decoration: BoxDecoration(
            color: p.bg,
            border: Border(left: BorderSide(color: p.border)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 24,
                offset: const Offset(-6, 0),
              ),
            ],
          ),
          // A form of its own for each thing opened, so one task's fields
          // are never left standing under another's name.
          child: TaskEditScreen(
            key: ObjectKey(shown),
            task: shown.task,
            initialDate: shown.date,
            parent: shown.parent,
            inPanel: true,
          ),
        ),
      ),
    );
  }
}

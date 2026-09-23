import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/task_list.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/gradient_icon_button.dart';
import '../widgets/screen_header.dart';
import '../widgets/selection_bar.dart';
import 'list_edit_screen.dart';
import 'task_list_screen.dart';

/// Top-level view of the user's task lists. Each list groups tasks; tapping
/// one opens it.
class ListsScreen extends StatefulWidget {
  const ListsScreen({super.key});

  @override
  State<ListsScreen> createState() => _ListsScreenState();
}

class _ListsScreenState extends State<ListsScreen> {
  final _searchController = TextEditingController();
  String _query = '';
  final Set<int> _selected = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggle(int id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  Future<void> _create() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ListEditScreen()),
    );
  }

  Future<void> _edit(TaskList list) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ListEditScreen(list: list)),
    );
  }

  Future<void> _editSelected() async {
    final list = context.read<TaskProvider>().listById(_selected.first);
    _clearSelection();
    if (list != null) await _edit(list);
  }

  Future<void> _deleteSelected() async {
    final provider = context.read<TaskProvider>();
    final lists =
        _selected.map(provider.listById).whereType<TaskList>().toList();
    final taskTotal = lists.fold<int>(0, (s, l) => s + l.taskCount);
    final n = lists.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(n == 1 ? 'Delete list?' : 'Delete $n lists?'),
        content: Text(taskTotal == 0
            ? (n == 1
                ? '"${lists.first.name}" will be removed.'
                : 'These lists will be removed.')
            : 'This also removes $taskTotal '
                '${taskTotal == 1 ? "task" : "tasks"} inside '
                '${n == 1 ? "it" : "them"}.'),
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
      for (final list in lists) {
        await provider.removeList(list.id!);
      }
      _clearSelection();
    }
  }

  Future<void> _open(TaskList list) async {
    await context.read<TaskProvider>().openList(list.id!);
    if (mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const TaskListScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final provider = context.watch<TaskProvider>();
    final all = provider.lists;
    final q = _query.trim().toLowerCase();
    final lists = q.isEmpty
        ? all
        : all.where((l) => l.name.toLowerCase().contains(q)).toList();
    final selecting = _selected.isNotEmpty;

    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        body: Column(
          children: [
            selecting
                ? SelectionBar(
                    count: _selected.length,
                    onClose: _clearSelection,
                    onEdit: _selected.length == 1 ? _editSelected : null,
                    onDelete: _deleteSelected,
                  )
                : ScreenHeader(
                    title: 'Lists',
                    count: all.length,
                    showBack: Navigator.of(context).canPop(),
                    actions: [
                      GradientIconButton(
                        icon: Icons.add,
                        tooltip: 'New list',
                        onTap: _create,
                      ),
                    ],
                  ),
            if (!selecting && all.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: TextField(
                  controller: _searchController,
                  onChanged: (v) => setState(() => _query = v),
                  style: TextStyle(color: p.text, fontSize: 14),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search lists…',
                    prefixIcon: Icon(Icons.search, size: 20, color: p.faint),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            icon: Icon(Icons.clear, size: 18, color: p.faint),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                          ),
                  ),
                ),
              ),
            Divider(height: 1, color: p.border),
            Expanded(
              child: provider.listsLoading && all.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : all.isEmpty
                      ? EmptyState(
                          icon: Icons.list_alt_outlined,
                          title: 'No lists yet',
                          message: 'Create a list to group your tasks — '
                              'Work, Errands, anything.',
                        )
                      : lists.isEmpty
                          ? Center(
                              child: Text('No matching lists',
                                  style:
                                      TextStyle(color: p.muted, fontSize: 14)),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.only(bottom: 90),
                              itemCount: lists.length,
                              itemBuilder: (context, i) {
                                final list = lists[i];
                                return _ListRow(
                                  list: list,
                                  selected: _selected.contains(list.id),
                                  onTap: () => selecting
                                      ? _toggle(list.id!)
                                      : _open(list),
                                  onLongPress: () => _toggle(list.id!),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ListRow extends StatelessWidget {
  final TaskList list;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ListRow({
    required this.list,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context);
    final style = list.style;
    final done = list.taskCount - list.openCount;
    final progress = list.taskCount == 0 ? 0.0 : done / list.taskCount;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          decoration: BoxDecoration(
            color: selected ? accent.color.withValues(alpha: 0.14) : null,
            border: Border(bottom: BorderSide(color: p.border)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 14, 16, 14),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: style.color.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(12),
                      border:
                          Border.all(color: style.color.withValues(alpha: 0.35)),
                    ),
                    child: Icon(style.icon, color: style.color, size: 22),
                  ),
                  if (selected)
                    const Positioned(
                        right: -4, bottom: -4, child: SelectionCheck()),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      list.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      list.taskCount == 0
                          ? 'Empty'
                          : '${list.openCount} open · $done done',
                      style: TextStyle(color: p.muted, fontSize: 13),
                    ),
                    if (list.taskCount > 0) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          backgroundColor: p.panelHi,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(style.color),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(Icons.chevron_right, color: p.faint),
            ],
          ),
        ),
      ),
    );
  }
}

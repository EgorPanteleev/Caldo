import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/task.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/tick_off.dart';
import '../widgets/gradient_icon_button.dart';
import '../widgets/screen_header.dart';
import '../widgets/selection_bar.dart';
import '../widgets/task_row.dart';
import 'task_edit_screen.dart';

/// The tasks of one list: search, browse, tick off, add, edit and delete.
class TaskListScreen extends StatefulWidget {
  const TaskListScreen({super.key});

  @override
  State<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends State<TaskListScreen> {
  final _searchController = TextEditingController();
  final Set<int> _selected = {};

  @override
  void initState() {
    super.initState();
    // Honour the "show completed" preference for this list's query.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<TaskProvider>().setShowCompleted(
        context.read<SettingsProvider>().showCompleted,
      );
    });
  }

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

  Future<void> _openEditor([Task? task]) async {
    final listId = context.read<TaskProvider>().currentListId;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TaskEditScreen(task: task, listId: listId),
      ),
    );
  }

  Future<void> _editSelected() async {
    final id = _selected.first;
    Task? task;
    for (final t in context.read<TaskProvider>().tasks) {
      if (t.id == id) {
        task = t;
        break;
      }
    }
    _clearSelection();
    if (task != null) await _openEditor(task);
  }

  Future<void> _deleteSelected() async {
    final ids = _selected.toList();
    final n = ids.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(n == 1 ? 'Delete task?' : 'Delete $n tasks?'),
        content: Text(
          n == 1
              ? 'This task will be removed.'
              : 'These $n tasks will be removed.',
        ),
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
      final provider = context.read<TaskProvider>();
      for (final id in ids) {
        await provider.remove(id);
      }
      _clearSelection();
    }
  }

  Future<void> _clearCompleted(int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear completed?'),
        content: Text(
          '$count completed '
          '${count == 1 ? "task" : "tasks"} will be removed from this list.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final provider = context.read<TaskProvider>();
    final removed = await provider.clearCompleted(
      listId: provider.currentListId,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Removed $removed completed '
            '${removed == 1 ? "task" : "tasks"}',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final provider = context.watch<TaskProvider>();
    final list = provider.currentList;
    final tasks = provider.tasks;
    final open = tasks.where((t) => !t.done).toList();
    final done = tasks.where((t) => t.done).toList();
    final selecting = _selected.isNotEmpty;

    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              selecting
                  ? SelectionBar(
                      count: _selected.length,
                      onClose: _clearSelection,
                      onEdit: _selected.length == 1 ? _editSelected : null,
                      onDelete: _deleteSelected,
                    )
                  : ScreenHeader(
                      title: list?.name ?? 'Tasks',
                      count: open.length,
                      showBack: true,
                      actions: [
                        if (done.isNotEmpty)
                          IconButton(
                            icon: Icon(
                              Icons.cleaning_services_outlined,
                              color: p.muted,
                            ),
                            tooltip: 'Clear completed',
                            onPressed: () => _clearCompleted(done.length),
                          ),
                        GradientIconButton(
                          icon: Icons.add,
                          tooltip: 'New task',
                          onTap: () => _openEditor(),
                        ),
                      ],
                    ),
              if (!selecting)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: TextField(
                    controller: _searchController,
                    onChanged: (v) => provider.search(v),
                    style: TextStyle(color: p.text, fontSize: 14),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Search tasks…',
                      prefixIcon: Icon(Icons.search, size: 20, color: p.faint),
                      suffixIcon: _searchController.text.isEmpty
                          ? null
                          : IconButton(
                              icon: Icon(Icons.clear, size: 18, color: p.faint),
                              onPressed: () {
                                _searchController.clear();
                                provider.search('');
                              },
                            ),
                    ),
                  ),
                ),
              Divider(height: 1, color: p.border),
              Expanded(
                child: provider.loading && tasks.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : tasks.isEmpty
                    ? EmptyState(
                        icon: provider.query.isEmpty
                            ? Icons.task_alt
                            : Icons.search_off,
                        title: provider.query.isEmpty
                            ? 'Nothing here yet'
                            : 'No matching tasks',
                        message: provider.query.isEmpty
                            ? 'Tap + to add the first task to this list.'
                            : 'Try a different search.',
                      )
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 90),
                        children: [
                          for (final task in open)
                            AsShown(
                              task: task,
                              builder: (context, shown) => TaskRow(
                                task: shown,
                                list: list,
                                selected: _selected.contains(task.id),
                                onTap: () => selecting
                                    ? _toggle(task.id!)
                                    : _openEditor(task),
                                onLongPress: () => _toggle(task.id!),
                                onToggle: () => provider.toggleDone(task),
                              ),
                            ),
                          if (done.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                              child: SectionLabel('COMPLETED · ${done.length}'),
                            ),
                          for (final task in done)
                            AsShown(
                              task: task,
                              builder: (context, shown) => TaskRow(
                                task: shown,
                                list: list,
                                selected: _selected.contains(task.id),
                                onTap: () => selecting
                                    ? _toggle(task.id!)
                                    : _openEditor(task),
                                onLongPress: () => _toggle(task.id!),
                                onToggle: () => provider.toggleDone(task),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

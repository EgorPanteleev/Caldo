import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/task.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/screen_header.dart';
import '../widgets/task_row.dart';
import 'task_edit_screen.dart';

/// Identifies the search field, for tests and for the calendar that opens it.
const searchFieldKey = Key('search-field');

/// Searches every list at once by title and notes — the calendar's way of
/// finding a task whose date you no longer remember.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  List<Task> _results = const [];
  String _query = '';

  /// Which search the results on screen came from. A slow query answering
  /// after a later one would otherwise overwrite fresher results.
  String _answered = '';

  @override
  void initState() {
    super.initState();
    // The screen exists to be typed into, so it opens ready for it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _search(String raw) async {
    final query = raw.trim();
    setState(() => _query = query);
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _answered = '';
      });
      return;
    }
    final found = await context.read<TaskProvider>().searchAll(query);
    if (!mounted || _query != query) return;
    setState(() {
      _results = found;
      _answered = query;
    });
  }

  Future<void> _openEditor(Task task) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => TaskEditScreen(task: task)));
    if (mounted) await _search(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final provider = context.watch<TaskProvider>();
    final showList = provider.lists.length > 1;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const ScreenHeader(title: 'Search', showBack: true),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                key: searchFieldKey,
                controller: _controller,
                focusNode: _focus,
                textInputAction: TextInputAction.search,
                onChanged: _search,
                style: TextStyle(color: p.text, fontSize: 15),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Title or notes',
                  prefixIcon: Icon(Icons.search, color: p.faint, size: 21),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: Icon(Icons.close, color: p.faint, size: 19),
                          tooltip: 'Clear',
                          onPressed: () {
                            _controller.clear();
                            _search('');
                          },
                        ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  border: _outline(p.border),
                  enabledBorder: _outline(p.border),
                  focusedBorder: _outline(p.muted),
                ),
              ),
            ),
            Expanded(
              child: _query.isEmpty
                  ? const EmptyState(
                      icon: Icons.search,
                      title: 'Search your tasks',
                      message: 'Matches titles and notes, across every list.',
                    )
                  : _answered != _query
                  // Nothing said until the query has actually been run: an
                  // empty state between keystrokes reads as "no matches".
                  ? const SizedBox.shrink()
                  : _results.isEmpty
                  ? EmptyState(
                      icon: Icons.search_off,
                      title: 'Nothing found',
                      message: 'No task mentions "$_query".',
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: _results.length,
                      itemBuilder: (context, i) {
                        final task = _results[i];
                        return TaskRow(
                          task: task,
                          list: provider.listById(task.listId),
                          showList: showList,
                          onTap: () => _openEditor(task),
                          onLongPress: () => _openEditor(task),
                          onToggle: () async {
                            await provider.toggleDone(task);
                            await _search(_controller.text);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  OutlineInputBorder _outline(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(24),
    borderSide: BorderSide(color: color),
  );
}

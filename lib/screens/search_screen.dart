import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/screen_header.dart';
import '../widgets/task_card.dart';
import '../widgets/tick_off.dart';
import 'task_edit_screen.dart';

/// Identifies the search field, for tests and for the calendar that opens it.
const searchFieldKey = Key('search-field');

/// Searches every list at once by title and notes — the calendar's way of
/// finding a task whose date you no longer remember.
///
/// The results are laid out as Schedule lays out its days, in the same cards
/// under the same headings, so a task found here looks like the task it is
/// everywhere else. It was a list of bordered rows with round ticks, the last
/// screen left in the app's first style.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  late final TaskProvider _tasks = context.read<TaskProvider>();

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
    // A tick here is read back like a tick anywhere, and the results follow
    // that read rather than a query of their own fired at the tap, which
    // would answer before the card had been seen to tick.
    _tasks.addListener(_again);
  }

  @override
  void dispose() {
    _tasks.removeListener(_again);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _again() {
    if (_query.isNotEmpty) _search(_controller.text);
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
    final found = await _tasks.searchAll(query);
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
    final s = S.of(context);
    // The same filled grey as the add field, and for the same reason: an
    // outlined pill on true black reads as a hole cut in the screen.
    const border = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(26)),
      borderSide: BorderSide.none,
    );

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            ScreenHeader(title: s.search, showBack: true),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: TextField(
                key: searchFieldKey,
                controller: _controller,
                focusNode: _focus,
                textInputAction: TextInputAction.search,
                onChanged: _search,
                style: TextStyle(color: p.text, fontSize: 14.5),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: p.field,
                  hintText: s.searchField,
                  hintStyle: TextStyle(color: p.muted, fontSize: 14.5),
                  prefixIcon: Icon(Icons.search, color: p.muted, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: Icon(Icons.close, color: p.muted, size: 19),
                          tooltip: s.clear,
                          onPressed: () {
                            _controller.clear();
                            _search('');
                          },
                        ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  border: border,
                  enabledBorder: border,
                  focusedBorder: border,
                ),
              ),
            ),
            Expanded(
              child: _query.isEmpty
                  ? EmptyState(
                      icon: Icons.search,
                      title: s.searchYourTasks,
                      message: s.searchHint,
                    )
                  : _answered != _query
                  // Nothing said until the query has actually been run: an
                  // empty state between keystrokes reads as "no matches".
                  ? const SizedBox.shrink()
                  : _results.isEmpty
                  ? EmptyState(
                      icon: Icons.search_off,
                      title: s.nothingFound,
                      message: s.noTaskMentions(_query),
                    )
                  : _Results(tasks: _results, onOpen: _openEditor),
            ),
          ],
        ),
      ),
    );
  }
}

/// What was found, in runs: what is overdue, the days from today on, what
/// has no date, and then the days gone by, latest first. A search is more
/// often after something still to do than after something long finished,
/// so what is still to do comes first, as on Schedule.
class _Results extends StatelessWidget {
  final List<Task> tasks;
  final ValueChanged<Task> onOpen;

  const _Results({required this.tasks, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<TaskProvider>();
    final s = S.of(context);
    final today = dayOf(DateTime.now());

    final overdue = <Task>[];
    final ahead = <DateTime, List<Task>>{};
    final undated = <Task>[];
    final past = <DateTime, List<Task>>{};
    for (final task in tasks) {
      final day = task.dueDay;
      if (day == null) {
        undated.add(task);
      } else if (!day.isBefore(today)) {
        (ahead[day] ??= []).add(task);
      } else if (!task.done) {
        overdue.add(task);
      } else {
        (past[day] ??= []).add(task);
      }
    }

    DayHeader dated(DateTime day) =>
        DayHeader(word: Dates.dayWord(day), label: Dates.dayDate(day));
    final runs = <(Widget, List<Task>)>[
      if (overdue.isNotEmpty)
        (DayHeader(word: s.overdue, color: AppColors.overdue), overdue),
      for (final day in ahead.keys.toList()..sort()) (dated(day), ahead[day]!),
      if (undated.isNotEmpty) (DayHeader(word: s.noDate), undated),
      for (final day in past.keys.toList()..sort((a, b) => b.compareTo(a)))
        (dated(day), past[day]!),
    ];
    final rows = <Widget Function()>[
      for (final (heading, tasks) in runs) ...[
        () => heading,
        for (final task in tasks)
          () => AsShown(
            task: task,
            builder: (context, shown) => TaskCard(
              task: shown,
              list: provider.listById(task.listId),
              onTap: () => onOpen(task),
              onToggle: () => tickOff(context, shown),
              ticking: provider.isTicking(task),
              leaving: provider.isLeaving(
                task,
                fromOverdue: overdue.contains(task),
              ),
            ),
          ),
      ],
    ];
    return ListView.builder(
      // The first heading's own top padding is room enough under the field.
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: rows.length,
      itemBuilder: (context, i) => rows[i](),
    );
  }
}

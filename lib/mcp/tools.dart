import 'dart:convert';
import 'dart:math';

import '../models/task.dart';
import 'book.dart';
import 'remote.dart';

/// What a tool says when it will not do what it was asked, in words for
/// whoever asked.
class Refusal implements Exception {
  final String message;
  const Refusal(this.message);

  @override
  String toString() => message;
}

/// One tool: its name, what it is for, the shape of what it takes, and what
/// it does with it.
class Tool {
  final String name;
  final String description;
  final Map<String, Object?> input;
  final bool reads;
  final Future<String> Function(Map<String, Object?> args) run;

  const Tool(
    this.name,
    this.description,
    this.input,
    this.run, {
    this.reads = false,
  });

  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': input,
    'annotations': {'readOnlyHint': reads},
  };
}

/// Caldo for an assistant: the account's tasks, groups, ticks and special
/// days, read from the server and written back to it as one more device.
///
/// Every tool first pulls what has changed, so it answers from what the
/// phone last sent. A write goes up as the rows a device would send for the
/// same change, made with the app's own model, and is read back before it
/// is reported done: an edit that lost to one made on another device at
/// the same moment is said to have, not passed off as made.
class Caldo {
  final Remote remote;
  final Book book = Book();

  /// The time, put back for tests.
  final DateTime Function() _now;

  Caldo(this.remote, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const _page = 1000;

  /// Takes up everything written since the last pull.
  Future<void> refresh() async {
    while (true) {
      final rows = await remote.pull(book.cursor, _page);
      book.take(rows);
      if (rows.length < _page) return;
    }
  }

  /// Sends [rows] and reads them back; says so if one did not hold.
  Future<void> _write(List<ServerRow> rows) async {
    await remote.push(rows);
    await refresh();
    for (final r in rows) {
      final held = book.row(r.table, r.uuid);
      if (held == null ||
          held.updatedAt != r.updatedAt ||
          held.deleted != r.deleted) {
        throw const Refusal(
          'Another device changed this at the same moment, and its change '
          'was kept. Read the task again and retry if still needed.',
        );
      }
    }
  }

  int get _ms => _now().millisecondsSinceEpoch;

  /// A stamp later than [after]: an edit made on what the server holds is
  /// the later edit, even if the phone that wrote it runs a little ahead.
  int _stamp(int after) => max(_ms, after + 1);

  // ---- Finding things ---------------------------------------------------

  Held _task(Object? id) {
    final want = _idIn(id);
    final found = book.tasks.where((h) => h.uuid.startsWith(want)).toList();
    if (found.isEmpty) throw Refusal('No task with id $want.');
    if (found.length > 1) {
      throw Refusal(
        'Id $want matches ${found.length} tasks: '
        '${found.map((h) => '[${h.id}] ${h.task.title}').join(', ')}.',
      );
    }
    return found.single;
  }

  static String _idIn(Object? id) {
    final text = (id as String? ?? '').trim().toLowerCase().replaceAll(
      RegExp(r'[\[\]]'),
      '',
    );
    if (text.length < 4) {
      throw const Refusal('Give the task id, as [abcd1234].');
    }
    return text;
  }

  Group _group(Object? name) {
    final want = (name as String).trim().toLowerCase();
    final all = book.groups;
    final exact = all.where((g) => g.name.toLowerCase() == want).toList();
    if (exact.length == 1) return exact.single;
    final starts = all
        .where((g) => g.name.toLowerCase().startsWith(want))
        .toList();
    if (starts.length == 1) return starts.single;
    throw Refusal(
      'No single group "$name". Groups: '
      '${all.map((g) => g.name).join(', ')}.',
    );
  }

  Group get _home =>
      book.home ??
      (throw const Refusal(
        'The account has no groups yet: open Caldo on a device signed in '
        'to it first.',
      ));

  String _groupName(String uuid) => book.group(uuid)?.name ?? '?';

  // ---- Reading ----------------------------------------------------------

  Future<String> agenda(Map<String, Object?> args) async {
    final today = _today;
    final from = args['from'] == null ? today : _day(args['from']);
    final days = (args['days'] as num?)?.toInt() ?? 7;
    if (days < 1 || days > 92) throw const Refusal('days is 1 to 92.');
    final withDone = args['include_done'] == true;
    final undated = args['include_undated'] != false;
    final only = args['group'] == null ? null : _group(args['group']).uuid;
    final tasks = _sorted([
      for (final h in book.tasks)
        if (only == null || h.group == only) h,
    ]);
    final out = StringBuffer('Today is ${_dayName(today)}.\n');
    if (only != null) out.writeln('Group: ${_groupName(only)} only.');
    if (!from.isAfter(today)) {
      // Days gone by, as the app's backlog has it; earlier today is today's.
      final late = [
        for (final h in tasks)
          if (!h.task.done && h.task.dueDay?.isBefore(today) == true) h,
      ];
      if (late.isNotEmpty) {
        out.writeln('\nOverdue');
        for (final h in late) {
          out.writeln(_line(h, date: true));
        }
      }
    }
    var shown = false;
    for (var i = 0; i < days; i++) {
      final day = DateTime(from.year, from.month, from.day + i);
      final mine = [
        for (final h in tasks)
          if (h.task.dueDay == day && (withDone || !h.task.done)) h,
      ];
      final special = [
        for (final y in book.yearly)
          if (y.inYear(day.year) == day) y,
      ];
      if (mine.isEmpty && special.isEmpty) continue;
      shown = true;
      out.writeln('\n${_dayName(day)}${day == today ? ' (today)' : ''}');
      for (final y in special) {
        out.writeln(_yearlyLine(y, day.year));
      }
      for (final h in mine) {
        out.writeln(_line(h));
      }
    }
    if (!shown) {
      final last = DateTime(from.year, from.month, from.day + days - 1);
      out.writeln('\nNothing from ${_dayName(from)} to ${_dayName(last)}.');
    }
    if (undated) {
      final loose = [
        for (final h in tasks)
          if (h.task.dueAt == null && (withDone || !h.task.done)) h,
      ];
      if (loose.isNotEmpty) {
        out.writeln('\nNo date');
        for (final h in loose) {
          out.writeln(_line(h));
        }
      }
    }
    return out.toString().trimRight();
  }

  Future<String> search(Map<String, Object?> args) async {
    final words = (args['text'] as String? ?? '').trim().toLowerCase();
    if (words.isEmpty) throw const Refusal('Say what to look for.');
    final withDone = args['include_done'] != false;
    bool hits(Task t) =>
        t.title.toLowerCase().contains(words) ||
        t.notes.toLowerCase().contains(words) ||
        t.subtasks.any((s) => s.title.toLowerCase().contains(words));
    final found = [
      for (final h in book.tasks)
        if (hits(h.task) && (withDone || !h.task.done)) h,
    ];
    if (found.isEmpty) return 'No task matches "$words".';
    // As Search lays them out: overdue, what is coming, no date, then
    // what is done, latest first.
    int rank(Task t) => t.done
        ? 3
        : t.isOverdue
        ? 0
        : t.dueAt == null
        ? 2
        : 1;
    found.sort((a, b) {
      final r = rank(a.task).compareTo(rank(b.task));
      if (r != 0) return r;
      if (a.task.done) {
        return (b.task.completedAt ?? 0).compareTo(a.task.completedAt ?? 0);
      }
      return (a.task.dueAt ?? 0).compareTo(b.task.dueAt ?? 0);
    });
    final shown = found.take(50).toList();
    return [
      'Found ${found.length}${found.length > 50 ? ' (first 50)' : ''}:',
      for (final h in shown) _line(h, date: true),
    ].join('\n');
  }

  Future<String> task(Map<String, Object?> args) async {
    final h = _task(args['id']);
    final t = h.task;
    final out = StringBuffer()
      ..writeln('[${h.id}] ${t.title}')
      ..writeln('Group: ${_groupName(h.group)}')
      ..writeln('Due: ${_due(t)}')
      ..writeln('Status: ${_status(t)}');
    if (t.priority != Priority.none) {
      out.writeln('Priority: ${t.priority.name}');
    }
    if (!t.repeat.isNone) out.writeln('Repeats: ${describeRepeat(t.repeat)}');
    out.writeln('Reminder: ${_reminder(t)}');
    if (t.claude != null) out.writeln('Handed to Claude: ${t.claude}');
    if (t.subtasks.isNotEmpty) {
      out.writeln('Checklist:');
      for (final (i, s) in t.subtasks.indexed) {
        out.writeln('  ${i + 1}. [${s.done ? 'x' : ' '}] ${s.title}');
      }
    }
    if (t.attachments.isNotEmpty) {
      out.writeln(
        'Attachments: ${t.attachments.map((a) => a.name).join(', ')}',
      );
    }
    out.writeln('Created: ${_moment(t.createdAt)}');
    if (t.notes.isNotEmpty) out.write('Notes:\n${t.notes}');
    return out.toString().trimRight();
  }

  Future<String> groups(Map<String, Object?> args) async {
    final home = book.home?.uuid;
    final open = <String, int>{};
    for (final h in book.tasks) {
      if (!h.task.done) open[h.group] = (open[h.group] ?? 0) + 1;
    }
    final all = book.groups;
    if (all.isEmpty) return 'No groups yet.';
    return [
      for (final g in all)
        '- ${g.name}${g.uuid == home ? ' (default)' : ''}: '
            '${open[g.uuid] ?? 0} open',
    ].join('\n');
  }

  Future<String> doneLog(Map<String, Object?> args) async {
    final days = (args['days'] as num?)?.toInt() ?? 7;
    if (days < 1 || days > 366) throw const Refusal('days is 1 to 366.');
    final since = DateTime(
      _today.year,
      _today.month,
      _today.day - days + 1,
    ).millisecondsSinceEpoch;
    final ticks = [
      for (final t in book.ticks)
        if (t.doneAt >= since) t,
    ]..sort((a, b) => b.doneAt.compareTo(a.doneAt));
    if (ticks.isEmpty) return 'Nothing ticked off in the last $days days.';
    return [
      '${ticks.length} ticked off in the last $days days:',
      for (final t in ticks)
        '- ${_moment(t.doneAt)} ${t.title}'
            '${t.group == null ? '' : ' (${_groupName(t.group!)})'}',
    ].join('\n');
  }

  Future<String> specialDays(Map<String, Object?> args) async {
    final today = _today;
    DateTime next(Yearly y) {
      final here = y.inYear(today.year);
      return here.isBefore(today) ? y.inYear(today.year + 1) : here;
    }

    final all = book.yearly..sort((a, b) => next(a).compareTo(next(b)));
    if (all.isEmpty) return 'No special days yet.';
    return [
      for (final y in all) _yearlyLine(y, next(y).year, date: true),
    ].join('\n');
  }

  // ---- Writing ----------------------------------------------------------

  Future<String> addTask(Map<String, Object?> args) async {
    final title = (args['title'] as String? ?? '').trim();
    if (title.isEmpty) throw const Refusal('A task needs a title.');
    final group = args['group'] == null ? _home : _group(args['group']);
    var task = Task(
      listId: 0,
      title: title,
      notes: (args['notes'] as String? ?? '').trim(),
      createdAt: _ms,
    );
    task = _changed(task, args);
    final uuid = newUuid();
    await _write([
      ServerRow(
        table: 'tasks',
        uuid: uuid,
        data: Book.dataOf(task, group.uuid),
        updatedAt: _ms,
      ),
    ]);
    return 'Added ${_line(Held(uuid, group.uuid, task), date: true, bullet: false)}';
  }

  Future<String> updateTask(Map<String, Object?> args) async {
    final h = _task(args['id']);
    var task = h.task;
    var group = h.group;
    if (args['title'] case final String title) {
      if (title.trim().isEmpty) throw const Refusal('A title cannot be empty.');
      task = task.copyWith(title: title.trim());
    }
    if (args['notes'] case final String notes) {
      task = task.copyWith(notes: notes.trim());
    }
    if (args['append_notes'] case final String more) {
      task = task.copyWith(
        notes: [
          if (task.notes.isNotEmpty) task.notes,
          more.trim(),
        ].join('\n\n'),
      );
    }
    if (args['group'] != null) {
      final to = _group(args['group']).uuid;
      // Back on the group's colour, as the form and Move to group do.
      if (to != group) task = task.copyWith(clearStyleId: true);
      group = to;
    }
    task = _changed(task, args);
    return _save(h, task, group, 'Updated');
  }

  Future<String> completeTask(Map<String, Object?> args) async {
    final h = _task(args['id']);
    if (h.task.done) return '[${h.id}] ${h.task.title} is already done.';
    final now = _ms;
    final row = book.row('tasks', h.uuid)!;
    final ticked = h.task.completed(now);
    await _write([
      _diff(row, Book.dataOf(ticked, h.group)),
      // The Done log's line, as `AppDatabase.complete` writes it.
      ServerRow(
        table: 'completions',
        uuid: newUuid(),
        data: {
          'task_uuid': h.uuid,
          'list_uuid': h.group,
          'title': h.task.title,
          'style_id': h.task.styleId,
          'done_at': now,
        },
        updatedAt: now,
      ),
    ]);
    return ticked.done
        ? 'Ticked off [${h.id}] ${h.task.title}.'
        : 'Ticked off [${h.id}] ${h.task.title}; it repeats, so it is now '
              'due ${_due(ticked)}.';
  }

  Future<String> setStage(Map<String, Object?> args) async {
    final h = _task(args['id']);
    final stage = switch (args['stage']) {
      'not_started' => Stage.notStarted,
      'in_progress' => Stage.inProgress,
      'done' => Stage.done,
      _ => throw const Refusal('stage is not_started, in_progress or done.'),
    };
    if (stage == h.task.stage) {
      return '[${h.id}] ${h.task.title} is already ${args['stage']}.';
    }
    if (stage == Stage.done) return completeTask(args);
    final moved = h.task.toStage(stage, _ms);
    if (!h.task.done) return _save(h, moved, h.group, 'Moved');
    // Out of Done: the tick is taken back, and its line in the log with it,
    // as `AppDatabase.untick` has it.
    final row = book.row('tasks', h.uuid)!;
    final last = ([
      for (final t in book.ticks)
        if (t.task == h.uuid) t,
    ]..sort((a, b) => b.doneAt.compareTo(a.doneAt))).firstOrNull;
    await _write([
      _diff(row, Book.dataOf(moved, h.group)),
      if (last != null)
        ServerRow(
          table: 'completions',
          uuid: last.uuid,
          updatedAt: _stamp(book.row('completions', last.uuid)!.updatedAt),
          deleted: true,
        ),
    ]);
    return 'Reopened ${_line(Held(h.uuid, h.group, moved), date: true, bullet: false)}';
  }

  Future<String> deleteTask(Map<String, Object?> args) async {
    final h = _task(args['id']);
    final row = book.row('tasks', h.uuid)!;
    await _write([
      ServerRow(
        table: 'tasks',
        uuid: h.uuid,
        updatedAt: _stamp(row.updatedAt),
        deleted: true,
      ),
    ]);
    return 'Deleted [${h.id}] ${h.task.title}.';
  }

  Future<String> addSpecialDay(Map<String, Object?> args) async {
    final name = (args['name'] as String? ?? '').trim();
    if (name.isEmpty) throw const Refusal('A special day needs a name.');
    final month = (args['month'] as num?)?.toInt() ?? 0;
    final day = (args['day'] as num?)?.toInt() ?? 0;
    // Any year with a 29th of February, so one can be kept.
    if (month < 1 ||
        month > 12 ||
        day < 1 ||
        day > DateTime(2024, month + 1, 0).day) {
      throw const Refusal('No such day of the year.');
    }
    final year = (args['year'] as num?)?.toInt();
    if (year != null && (year < 1900 || year > _today.year)) {
      throw Refusal('year is 1900 to ${_today.year}, or left out.');
    }
    final kind = args['kind'] as String? ?? 'birthday';
    // The colour each kind starts in (`widgets/special_days.dart`).
    final style = switch (kind) {
      'birthday' => 'pink',
      'anniversary' => 'red',
      'other' => 'amber',
      _ => throw const Refusal('kind is birthday, anniversary or other.'),
    };
    final uuid = newUuid();
    await _write([
      ServerRow(
        table: 'special_days',
        uuid: uuid,
        data: {
          'name': name,
          'kind': kind,
          'month': month,
          'day': day,
          'year': year,
          'style_id': style,
          'remind': args['remind'] == false ? 0 : 1,
          'created_at': _ms,
        },
        updatedAt: _ms,
      ),
    ]);
    final added = Yearly(uuid, name, kind, month, day, year);
    final next = added.inYear(_today.year).isBefore(_today)
        ? _today.year + 1
        : _today.year;
    return 'Added ${_yearlyLine(added, next, date: true, bullet: false)}';
  }

  /// [task] with what [args] says of its date, time, length, priority,
  /// repeat, reminder and checklist — the fields adding and editing share.
  Task _changed(Task task, Map<String, Object?> args) {
    if (args.containsKey('date')) {
      final text = args['date'];
      if (text == null || text == 'none') {
        // As Move to day "No date" has it: a time means nothing without one.
        task = task.copyWith(
          clearDueAt: true,
          hasTime: false,
          clearDuration: true,
          clearSortOrder: true,
          clearSnoozedUntil: true,
        );
      } else {
        final day = _day(text);
        final due = task.due;
        final at = task.hasTime && due != null
            ? DateTime(day.year, day.month, day.day, due.hour, due.minute)
            : day;
        // A move to another day, as `TaskProvider._movedTo` makes it.
        task = task.copyWith(
          dueAt: at.millisecondsSinceEpoch,
          clearSortOrder: true,
          clearSnoozedUntil: true,
        );
      }
    }
    if (args.containsKey('time')) {
      final text = args['time'];
      final day = task.dueDay;
      if (text == null || text == 'none') {
        if (day != null) {
          task = task.copyWith(
            dueAt: day.millisecondsSinceEpoch,
            hasTime: false,
            clearDuration: true,
            clearSnoozedUntil: true,
          );
        }
      } else {
        if (day == null) throw const Refusal('A time needs a date as well.');
        final (h, m) = _clock(text);
        task = task.copyWith(
          dueAt: DateTime(
            day.year,
            day.month,
            day.day,
            h,
            m,
          ).millisecondsSinceEpoch,
          hasTime: true,
          clearSnoozedUntil: true,
        );
      }
    }
    if (args.containsKey('end')) {
      final text = args['end'];
      if (text == null || text == 'none') {
        task = task.copyWith(clearDuration: true);
      } else {
        final start = task.due;
        if (!task.hasTime || start == null) {
          throw const Refusal('An end needs a start time.');
        }
        final (h, m) = _clock(text);
        final minutes = h * 60 + m - (start.hour * 60 + start.minute);
        if (minutes <= 0) {
          throw const Refusal(
            'The end must be after the start, on the same day.',
          );
        }
        task = task.copyWith(duration: minutes);
      }
    }
    if (args['duration_minutes'] case final num minutes) {
      final start = task.due;
      if (!task.hasTime || start == null) {
        throw const Refusal('A length needs a start time.');
      }
      final end = start.add(Duration(minutes: minutes.toInt()));
      if (minutes <= 0 || end.day != start.day) {
        throw const Refusal('A task ends after it starts, on the same day.');
      }
      task = task.copyWith(duration: minutes.toInt());
    }
    if (args['priority'] case final String name) {
      task = task.copyWith(
        priority:
            Priority.values.asNameMap()[name] ??
            (throw const Refusal('priority is none, low, medium or high.')),
      );
    }
    if (args['repeat'] case final String rule) {
      final repeat = readRepeat(rule);
      if (!repeat.isNone && task.dueAt == null) {
        throw const Refusal('A repeating task needs a date.');
      }
      task = task.copyWith(repeat: repeat);
    }
    if (args.containsKey('remind_before_minutes')) {
      final lead = (args['remind_before_minutes'] as num?)?.toInt();
      task = lead == null
          ? task.copyWith(clearRemindBefore: true)
          : task.copyWith(remindBefore: lead < 0 ? Task.silent : lead);
    }
    if (args.containsKey('claude')) {
      final model = args['claude'];
      if (model == null || model == 'none') {
        task = task.copyWith(clearClaude: true);
      } else if (ClaudeModels.all.contains(model)) {
        task = task.copyWith(claude: model as String);
      } else {
        throw Refusal('claude is ${ClaudeModels.all.join(', ')} or none.');
      }
    }
    if (args['checklist'] case final List steps) {
      task = task.copyWith(
        subtasks: [
          for (final s in steps)
            if (s is String && s.trim().isNotEmpty)
              Subtask(s.trim())
            else if (s is Map && (s['title'] as String? ?? '').trim() != '')
              Subtask((s['title'] as String).trim(), done: s['done'] == true),
        ],
      );
    }
    return task;
  }

  Future<String> _save(Held h, Task task, String group, String said) async {
    final row = book.row('tasks', h.uuid)!;
    final next = _diff(row, Book.dataOf(task, group));
    if (next.data!.isEmpty) return 'Nothing to change on [${h.id}].';
    await _write([next]);
    return '$said ${_line(Held(h.uuid, group, task), date: true, bullet: false)}';
  }

  /// The fields of [data] that differ from what [row] holds: the server lays
  /// them over the rest, so a field changed on the phone meanwhile — one
  /// this edit did not touch — is not put back to what it was.
  ServerRow _diff(ServerRow row, Map<String, Object?> data) => ServerRow(
    table: row.table,
    uuid: row.uuid,
    data: {
      for (final MapEntry(:key, :value) in data.entries)
        if (!_same(row.data?[key], value)) key: value,
    },
    updatedAt: _stamp(row.updatedAt),
  );

  static bool _same(Object? held, Object? next) {
    if (held is num && next is num) return held == next;
    if (held is String && next is String && held != next) {
      // A checklist or attachments written with other spacing.
      try {
        return jsonEncode(jsonDecode(held)) == jsonEncode(jsonDecode(next));
      } on FormatException {
        return false;
      }
    }
    return held == next;
  }

  // ---- Words ------------------------------------------------------------

  DateTime get _today {
    final n = _now();
    return DateTime(n.year, n.month, n.day);
  }

  DateTime _day(Object? text) {
    final t = (text as String? ?? '').trim().toLowerCase();
    final today = _today;
    switch (t) {
      case 'today':
        return today;
      case 'tomorrow':
        return DateTime(today.year, today.month, today.day + 1);
      case 'yesterday':
        return DateTime(today.year, today.month, today.day - 1);
    }
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(t);
    if (m != null) {
      final d = DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
      if (d.month == int.parse(m[2]!) && d.day == int.parse(m[3]!)) return d;
    }
    throw Refusal('"$text" is not a date: use YYYY-MM-DD, today or tomorrow.');
  }

  static (int, int) _clock(Object? text) {
    final m = RegExp(
      r'^(\d{1,2}):(\d{2})$',
    ).firstMatch((text as String).trim());
    final h = int.tryParse(m?[1] ?? '');
    final min = int.tryParse(m?[2] ?? '');
    if (h == null || min == null || h > 23 || min > 59) {
      throw Refusal('"$text" is not a time: use HH:MM, 24-hour.');
    }
    return (h, min);
  }

  /// The order a day's tasks stand in, as the app's database gives them.
  static List<Held> _sorted(List<Held> tasks) => tasks
    ..sort((x, y) {
      final a = x.task, b = y.task;
      int by(Comparable? p, Comparable? q) =>
          p == null || q == null ? 0 : p.compareTo(q);
      int last(Object? p, Object? q) =>
          (p == null ? 1 : 0).compareTo(q == null ? 1 : 0);
      for (final c in [
        (a.done ? 1 : 0).compareTo(b.done ? 1 : 0),
        a.done ? by(a.completedAt, b.completedAt) : 0,
        last(a.sortOrder, b.sortOrder),
        by(a.sortOrder, b.sortOrder),
        b.priority.index.compareTo(a.priority.index),
        last(a.dueAt, b.dueAt),
        by(a.dueAt, b.dueAt),
        b.createdAt.compareTo(a.createdAt),
      ]) {
        if (c != 0) return c;
      }
      return 0;
    });

  String _line(Held h, {bool date = false, bool bullet = true}) {
    final t = h.task;
    final when = <String>[
      if (date) t.dueDay == null ? 'no date' : _dayName(t.dueDay!),
      if (t.hasTime && t.due != null)
        t.end == null ? _hm(t.due!) : '${_hm(t.due!)}–${_hm(t.end!)}',
    ];
    final about = <String>[
      _groupName(h.group),
      if (t.priority != Priority.none) '${t.priority.name} priority',
      if (!t.repeat.isNone) 'repeats ${describeRepeat(t.repeat)}',
      if (t.subtasks.isNotEmpty)
        'checklist ${t.subtasksDone}/${t.subtasks.length}',
      if (t.stage == Stage.inProgress) 'in progress',
      if (t.claude != null) 'for Claude',
      if (t.notes.isNotEmpty) 'has notes',
      if (t.attachments.isNotEmpty) '${t.attachments.length} attached',
    ];
    return '${bullet ? '- ' : ''}[${h.id}] ${t.done ? '✓ ' : ''}'
        '${when.isEmpty ? '' : '${when.join(' ')} '}'
        '${t.title} (${about.join('; ')})';
  }

  String _yearlyLine(
    Yearly y,
    int year, {
    bool date = false,
    bool bullet = true,
  }) {
    final since = y.year;
    final count = since == null || since >= year ? null : year - since;
    final what = switch (y.kind) {
      'birthday' => count == null ? 'birthday' : 'birthday, turns $count',
      'anniversary' => count == null ? 'anniversary' : '$count years',
      _ => count == null ? 'special day' : '$count years',
    };
    return '${bullet ? '- ' : ''}[${y.id}] ★ ${date ? '${_dayName(y.inYear(year))} ' : ''}'
        '${y.name} ($what)';
  }

  String _due(Task t) {
    final day = t.dueDay;
    if (day == null) return 'no date';
    if (!t.hasTime) return '${_dayName(day)}, all day';
    final end = t.end;
    return '${_dayName(day)}, ${_hm(t.due!)}${end == null ? '' : '–${_hm(end)}'}';
  }

  String _status(Task t) => switch (t.stage) {
    Stage.done =>
      'done${t.completedAt == null ? '' : ' ${_moment(t.completedAt!)}'}',
    Stage.inProgress => 'in progress since ${_moment(t.startedAt!)}',
    Stage.notStarted => t.isOverdue ? 'open, overdue' : 'open',
  };

  static String _reminder(Task t) {
    final lead = t.remindBefore;
    if (lead == Task.silent) return 'never';
    if (lead == null) return 'as in Settings';
    if (lead == 0) return 'at the time';
    if (lead % 1440 == 0) return '${lead ~/ 1440} day(s) before';
    if (lead % 60 == 0) return '${lead ~/ 60} h before';
    return '$lead min before';
  }

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  static String _dayName(DateTime d) =>
      '${_weekdays[d.weekday - 1]} ${d.year}-${_two(d.month)}-${_two(d.day)}';

  static String _hm(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

  static String _moment(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${_dayName(d)} ${_hm(d)}';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// A repeat in plain words.
  static String describeRepeat(Repeat r) {
    final unit = switch (r.unit) {
      RepeatUnit.none => '',
      RepeatUnit.day => 'day',
      RepeatUnit.week => 'week',
      RepeatUnit.month => 'month',
      RepeatUnit.year => 'year',
    };
    final every = r.every == 1
        ? switch (r.unit) {
            RepeatUnit.day => 'daily',
            RepeatUnit.week => 'weekly',
            RepeatUnit.month => 'monthly',
            _ => 'yearly',
          }
        : 'every ${r.every} ${unit}s';
    final until = r.until;
    return [
      every,
      if (r.weekdays.isNotEmpty)
        'on ${(r.weekdays.toList()..sort()).map((d) => _weekdays[d - 1]).join(', ')}',
      if (r.monthEnd) 'on the last day',
      if (until != null)
        'until ${until.year}-${_two(until.month)}-${_two(until.day)}',
      if (r.left != null) '${r.left} round(s) left',
    ].join(' ');
  }

  /// A repeat as asked for: a plain name or the app's own rule.
  static Repeat readRepeat(String rule) {
    final text = rule.trim();
    final named = switch (text.toLowerCase()) {
      'none' => Repeat.none,
      'daily' => Repeat.daily,
      'weekly' => Repeat.weekly,
      'monthly' => Repeat.monthly,
      'yearly' => Repeat.yearly,
      'weekdays' => Repeat.weekdaysOnly,
      _ => null,
    };
    if (named != null) return named;
    final read = Repeat.fromRule(text.toUpperCase());
    if (read.isNone) {
      throw Refusal(
        '"$rule" is not a repeat: use none, daily, weekly, monthly, yearly, '
        'weekdays, or a rule such as FREQ=WEEKLY;INTERVAL=2;BYDAY=1,3.',
      );
    }
    return read;
  }

  // ---- The list ---------------------------------------------------------

  static const _id = {
    'type': 'string',
    'description': 'The task id, the 8 characters in brackets: [3fa2b1c0].',
  };
  static const _date = {
    'type': 'string',
    'description': 'YYYY-MM-DD, "today" or "tomorrow"; "none" for no date.',
  };
  static const _time = {
    'type': 'string',
    'description': 'HH:MM, 24-hour; "none" makes it all-day.',
  };
  static const _fields = <String, Object?>{
    'date': _date,
    'time': _time,
    'end': {
      'type': 'string',
      'description':
          'When a timed task ends, HH:MM the same day; "none" '
          'for no end.',
    },
    'duration_minutes': {
      'type': 'integer',
      'description': 'Its length, instead of an end.',
    },
    'priority': {
      'type': 'string',
      'enum': ['none', 'low', 'medium', 'high'],
    },
    'repeat': {
      'type': 'string',
      'description':
          'none, daily, weekly, monthly, yearly, weekdays, or a '
          'rule: FREQ=DAILY|WEEKLY|MONTHLY|YEARLY with INTERVAL=n, '
          'BYDAY=1,3 (1 Monday … 7 Sunday), BYMONTHDAY=-1 (last day), '
          'UNTIL=YYYYMMDD, COUNT=n, joined by ";".',
    },
    'remind_before_minutes': {
      'type': ['integer', 'null'],
      'description':
          'Minutes before its time it is announced; all-day tasks '
          'count whole days (1440). -1 never; null follows Settings.',
    },
    'claude': {
      'type': ['string', 'null'],
      'enum': [...ClaudeModels.all, 'none', null],
      'description':
          'Hands the task to Claude on the user\'s computer with this '
          'model (caldo-mcp watch does it once due, and writes the answer '
          'into the notes); none takes it back.',
    },
    'checklist': {
      'type': 'array',
      'description':
          'The checklist, replacing any there is: step titles, '
          'or {title, done}.',
      'items': {
        'anyOf': [
          {'type': 'string'},
          {
            'type': 'object',
            'properties': {
              'title': {'type': 'string'},
              'done': {'type': 'boolean'},
            },
            'required': ['title'],
          },
        ],
      },
    },
  };

  static Map<String, Object?> _shape(
    Map<String, Object?> properties, [
    List<String> required = const [],
  ]) => {
    'type': 'object',
    'properties': properties,
    if (required.isNotEmpty) 'required': required,
  };

  late final List<Tool> tools = [
    Tool(
      'agenda',
      'Caldo tasks day by day, as Schedule shows them: overdue first, then '
          'each day with its tasks and special days (birthdays…), then tasks '
          'with no date. Says what today is.',
      _shape({
        'from': {
          ..._date,
          'description': 'First day, YYYY-MM-DD or "today" (default).',
        },
        'days': {
          'type': 'integer',
          'description': 'How many days, 1–92 (default 7).',
        },
        'group': {'type': 'string', 'description': "Only this group's tasks."},
        'include_done': {
          'type': 'boolean',
          'description': 'Show ticked-off tasks too (default false).',
        },
        'include_undated': {
          'type': 'boolean',
          'description': 'List tasks with no date (default true).',
        },
      }),
      agenda,
      reads: true,
    ),
    Tool(
      'search',
      'Finds tasks whose title, notes or checklist hold the words.',
      _shape(
        {
          'text': {'type': 'string'},
          'include_done': {'type': 'boolean', 'description': 'Default true.'},
        },
        ['text'],
      ),
      search,
      reads: true,
    ),
    Tool(
      'task',
      'Everything about one task: notes, checklist, repeat, reminder, '
          'status.',
      _shape({'id': _id}, ['id']),
      task,
      reads: true,
    ),
    Tool(
      'groups',
      'The groups (lists) tasks are in, with how many are open in each.',
      _shape({}),
      groups,
      reads: true,
    ),
    Tool(
      'done_log',
      'What was ticked off lately, latest first.',
      _shape({
        'days': {
          'type': 'integer',
          'description': 'How many days back, today included (default 7).',
        },
      }),
      doneLog,
      reads: true,
    ),
    Tool(
      'special_days',
      'Birthdays, anniversaries and other yearly days, next one first.',
      _shape({}),
      specialDays,
      reads: true,
    ),
    Tool(
      'add_task',
      'Adds a task. It reaches every device signed in within seconds and '
          'its reminder is set there.',
      _shape(
        {
          'title': {'type': 'string'},
          'notes': {'type': 'string'},
          'group': {
            'type': 'string',
            'description': 'Group name; the default group if left out.',
          },
          ..._fields,
        },
        ['title'],
      ),
      addTask,
    ),
    Tool(
      'update_task',
      'Changes a task: only the fields given. A new date keeps its time.',
      _shape(
        {
          'id': _id,
          'title': {'type': 'string'},
          'notes': {'type': 'string', 'description': 'Replaces the notes.'},
          'append_notes': {
            'type': 'string',
            'description': 'Added after the notes, as a new paragraph.',
          },
          'group': {'type': 'string', 'description': 'Moves it to this group.'},
          ..._fields,
        },
        ['id'],
      ),
      updateTask,
    ),
    Tool(
      'complete_task',
      'Ticks a task off, as the tick on its card does. A repeating task '
          'rolls on to its next date instead of closing.',
      _shape({'id': _id}, ['id']),
      completeTask,
    ),
    Tool(
      'set_stage',
      "Moves a task on the Board: not_started, in_progress or done. Out of "
          'done reopens it.',
      _shape(
        {
          'id': _id,
          'stage': {
            'type': 'string',
            'enum': ['not_started', 'in_progress', 'done'],
          },
        },
        ['id', 'stage'],
      ),
      setStage,
    ),
    Tool(
      'delete_task',
      'Deletes a task on every device. Ask the user first.',
      _shape({'id': _id}, ['id']),
      deleteTask,
    ),
    Tool(
      'add_special_day',
      'Adds a birthday, anniversary or other day that comes back every year.',
      _shape(
        {
          'name': {'type': 'string'},
          'month': {'type': 'integer'},
          'day': {'type': 'integer'},
          'year': {
            'type': 'integer',
            'description': 'The year it began, if known (for ages).',
          },
          'kind': {
            'type': 'string',
            'enum': ['birthday', 'anniversary', 'other'],
          },
          'remind': {
            'type': 'boolean',
            'description': 'Remind on the day (default true).',
          },
        },
        ['name', 'month', 'day'],
      ),
      addSpecialDay,
    ),
  ];

  /// Told to the assistant when it connects.
  static const instructions =
      "Caldo is the user's calendar and to-do app (Android and Linux). These "
      'tools read and change their tasks through Caldo\'s sync server, as '
      'one more device: changes reach their phone within seconds. Tasks are '
      'named by the 8-character id in brackets, e.g. [3fa2b1c0]; read one '
      'from agenda or search before changing it. Dates are YYYY-MM-DD and '
      "times HH:MM in the user's own time zone. Tasks sit in groups (lists). "
      'Ask before deleting anything.';
}

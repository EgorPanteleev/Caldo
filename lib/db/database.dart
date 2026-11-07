import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/completion.dart';
import '../models/task.dart';
import '../models/task_list.dart';

/// Thin wrapper around the local sqflite database that stores task lists and
/// the tasks they contain.
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  static const _dbName = 'caldo.db';
  static const _dbVersion = 7;
  static const _lists = 'lists';
  static const _tasks = 'tasks';
  static const _completions = 'completions';

  Database? _db;

  Future<Database> get database async {
    return _db ??= await _open();
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, _dbName);
    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_lists (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            style_id TEXT NOT NULL DEFAULT 'violet',
            created_at INTEGER NOT NULL
          )
        ''');
        await db.insert(_lists, {
          'name': 'Personal',
          'style_id': 'violet',
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
        await db.execute('''
          CREATE TABLE $_tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            list_id INTEGER NOT NULL DEFAULT 1,
            title TEXT NOT NULL,
            notes TEXT NOT NULL DEFAULT '',
            due_at INTEGER,
            has_time INTEGER NOT NULL DEFAULT 0,
            done INTEGER NOT NULL DEFAULT 0,
            priority INTEGER NOT NULL DEFAULT 0,
            repeat_rule TEXT NOT NULL DEFAULT 'none',
            style_id TEXT,
            created_at INTEGER NOT NULL,
            completed_at INTEGER,
            sort_order INTEGER,
            subtasks TEXT NOT NULL DEFAULT '[]',
            tags TEXT NOT NULL DEFAULT '[]',
            remind_before INTEGER,
            snoozed_until INTEGER
          )
        ''');
        await db.execute('CREATE INDEX idx_tasks_due ON $_tasks (due_at)');
        await db.execute('CREATE INDEX idx_tasks_list ON $_tasks (list_id)');
        await _createCompletions(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // v1 -> a task can override the colour it takes from its list.
          await db.execute('ALTER TABLE $_tasks ADD COLUMN style_id TEXT');
        }
        if (oldVersion < 3) {
          // v2 -> a day can be put in an order of the user's own. Null until
          // one is, so every day that has never been dragged keeps the
          // ordering it has always had.
          await db.execute('ALTER TABLE $_tasks ADD COLUMN sort_order INTEGER');
        }
        if (oldVersion < 4) {
          // v3 -> a task can carry a checklist, as JSON beside it.
          await db.execute(
            "ALTER TABLE $_tasks ADD COLUMN subtasks TEXT NOT NULL DEFAULT '[]'",
          );
        }
        if (oldVersion < 5) {
          // v4 -> a task can be announced ahead of its time, and a reminder
          // put off from its notification. Null for both follows Settings.
          await db.execute(
            'ALTER TABLE $_tasks ADD COLUMN remind_before INTEGER',
          );
          await db.execute(
            'ALTER TABLE $_tasks ADD COLUMN snoozed_until INTEGER',
          );
        }
        if (oldVersion < 6) {
          // v5 -> a log of ticks, for the Done screen. Started from the
          // last tick each task remembers: a repeating task's earlier rounds
          // were never written down, but its latest one was.
          await _createCompletions(db);
          await db.execute('''
            INSERT INTO $_completions
              (task_id, title, list_id, style_id, done_at)
            SELECT id, title, list_id, style_id, completed_at
            FROM $_tasks WHERE completed_at IS NOT NULL
          ''');
        }
        if (oldVersion < 7) {
          // v6 -> a task can carry tags, as JSON beside it.
          await db.execute(
            "ALTER TABLE $_tasks ADD COLUMN tags TEXT NOT NULL DEFAULT '[]'",
          );
        }
      },
    );
  }

  static Future<void> _createCompletions(Database db) async {
    await db.execute('''
      CREATE TABLE $_completions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id INTEGER,
        title TEXT NOT NULL,
        list_id INTEGER NOT NULL DEFAULT 1,
        style_id TEXT,
        done_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_completions_at ON $_completions (done_at)',
    );
  }

  // ---- Lists --------------------------------------------------------------

  Future<List<TaskList>> getLists() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT l.*,
        (SELECT COUNT(*) FROM $_tasks t WHERE t.list_id = l.id) AS task_count,
        (SELECT COUNT(*) FROM $_tasks t WHERE t.list_id = l.id AND t.done = 0)
          AS open_count
      FROM $_lists l
      ORDER BY l.created_at ASC
    ''');
    return rows.map(TaskList.fromMap).toList();
  }

  Future<TaskList> insertList(TaskList list) async {
    final db = await database;
    final id = await db.insert(_lists, list.toMap()..remove('id'));
    return list.copyWith(id: id);
  }

  // ---- Tags ---------------------------------------------------------------

  /// Every tag a task carries, each with how many open tasks carry it, the
  /// most used first. Written as it was first met: "Uni" and "uni" are one
  /// tag, and it keeps whichever spelling the oldest task has.
  Future<Map<String, int>> getTags() async {
    final db = await database;
    final rows = await db.query(
      _tasks,
      columns: ['tags', 'done'],
      where: "tags != '[]'",
      orderBy: 'created_at ASC',
    );
    final names = <String, String>{};
    final open = <String, int>{};
    for (final row in rows) {
      final done = row['done'] == 1;
      for (final tag in Task.tagsFrom(row['tags'] as String?)) {
        final key = tag.toLowerCase();
        names.putIfAbsent(key, () => tag);
        open[key] = (open[key] ?? 0) + (done ? 0 : 1);
      }
    }
    final keys = names.keys.toList()
      ..sort((a, b) {
        final byUse = open[b]!.compareTo(open[a]!);
        return byUse != 0 ? byUse : a.compareTo(b);
      });
    return {for (final key in keys) names[key]!: open[key]!};
  }

  // ---- Tasks --------------------------------------------------------------

  /// Every task, which is what the search screen asks for. [query] matches
  /// the title, the notes, a subtask or a tag; when [includeDone] is false only open
  /// tasks come back.
  Future<List<Task>> getTasks({
    String query = '',
    bool includeDone = true,
  }) async {
    final db = await database;
    final where = StringBuffer('1 = 1');
    final args = <Object?>[];
    if (!includeDone) where.write(' AND done = 0');
    if (query.isNotEmpty) {
      where.write(
        ' AND (title LIKE ? OR notes LIKE ? OR subtasks LIKE ? OR tags LIKE ?)',
      );
      args
        ..addAll(List.filled(3, '%$query%'))
        ..add('%${Task.tagOf(query) ?? query}%');
    }
    final rows = await db.query(
      _tasks,
      where: where.toString(),
      whereArgs: args,
      orderBy: _order,
    );
    final tasks = rows.map(Task.fromMap).toList();
    if (query.isEmpty) return tasks;
    // The checklist is stored as JSON, so a search for "done" or "title"
    // matches every task that has one. Those are let through the query and
    // only kept here if a subtask's own title has the words in it.
    // A # in front finds the tag, as it is written on a card.
    final needle = query.toLowerCase();
    final tag = Task.tagOf(query)?.toLowerCase();
    bool has(String text) => text.toLowerCase().contains(needle);
    return [
      for (final t in tasks)
        if (has(t.title) ||
            has(t.notes) ||
            t.subtasks.any((s) => has(s.title)) ||
            (tag != null && t.tags.any((g) => g.toLowerCase().contains(tag))))
          t,
    ];
  }

  /// Every dated task falling inside `[fromMs, toMs)` — the calendar's window.
  Future<List<Task>> getTasksInRange(int fromMs, int toMs) async {
    final db = await database;
    final rows = await db.query(
      _tasks,
      where: 'due_at IS NOT NULL AND due_at >= ? AND due_at < ?',
      whereArgs: [fromMs, toMs],
      orderBy: _order,
    );
    return rows.map(Task.fromMap).toList();
  }

  /// Tasks with no due date at all — they belong to their list only.
  Future<List<Task>> getUndated() async {
    final db = await database;
    final rows = await db.query(
      _tasks,
      where: 'due_at IS NULL',
      orderBy: _order,
    );
    return rows.map(Task.fromMap).toList();
  }

  /// Open tasks that were due before [beforeMs] — the overdue backlog.
  Future<List<Task>> getOverdue(int beforeMs) async {
    final db = await database;
    final rows = await db.query(
      _tasks,
      where: 'done = 0 AND due_at IS NOT NULL AND due_at < ?',
      whereArgs: [beforeMs],
      // However late each one is, unless the backlog has been dragged into
      // an order of its own.
      orderBy: '(sort_order IS NULL) ASC, sort_order ASC, due_at ASC',
    );
    return rows.map(Task.fromMap).toList();
  }

  /// The task with [id], or null if there is none any more — what a
  /// notification's button or the widget asks for, holding only an id.
  Future<Task?> getTask(int id) async {
    final db = await database;
    final rows = await db.query(_tasks, where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Task.fromMap(rows.first);
  }

  Future<Task> insert(Task task) async {
    final db = await database;
    final id = await db.insert(_tasks, task.toMap()..remove('id'));
    return task.copyWith(id: id);
  }

  Future<void> update(Task task) async {
    final db = await database;
    await db.update(
      _tasks,
      task.toMap(),
      where: 'id = ?',
      whereArgs: [task.id],
    );
  }

  Future<void> delete(int id) async {
    final db = await database;
    await db.delete(_tasks, where: 'id = ?', whereArgs: [id]);
  }

  // ---- Ticks ---------------------------------------------------------------

  /// Ticks [task] off at [now] — written back as `Task.completed` makes it —
  /// and logs the tick. Every way a task is ticked comes through here, so
  /// the log and the task cannot disagree.
  Future<Task> complete(Task task, int now) async {
    final written = task.completed(now);
    final db = await database;
    await db.transaction((txn) async {
      await txn.update(
        _tasks,
        written.toMap(),
        where: 'id = ?',
        whereArgs: [task.id],
      );
      await txn.insert(_completions, {
        'task_id': task.id,
        'title': task.title,
        'list_id': task.listId,
        'style_id': task.styleId,
        'done_at': now,
      });
    });
    return written;
  }

  /// Writes [task] back as it is given — not ticked, or as it was before a
  /// tick — and takes that tick out of the log. For a tick taken back and
  /// for Undo, both of which say the tick never happened.
  Future<void> untick(Task task) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update(
        _tasks,
        task.toMap(),
        where: 'id = ?',
        whereArgs: [task.id],
      );
      await txn.rawDelete(
        'DELETE FROM $_completions WHERE id = '
        '(SELECT MAX(id) FROM $_completions WHERE task_id = ?)',
        [task.id],
      );
    });
  }

  /// The ticks made since [sinceMs], latest first.
  Future<List<Completion>> getCompletions(int sinceMs) async {
    final db = await database;
    final rows = await db.query(
      _completions,
      where: 'done_at >= ?',
      whereArgs: [sinceMs],
      orderBy: 'done_at DESC, id DESC',
    );
    return rows.map(Completion.fromMap).toList();
  }

  /// Removes every completed task.
  Future<int> clearCompleted() async {
    final db = await database;
    return db.delete(_tasks, where: 'done = 1');
  }

  /// Closes the connection, so the next access reopens the file. Used by
  /// tests, which start each case from a fresh database.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Open first, then by due date (undated last), then newest first.
  /// A hand-placed task goes where it was put; one that has never been
  /// dragged falls through to the ordinary rules, after the placed ones.
  ///
  /// The placement is read before the date, not after it. A run the user has
  /// arranged by hand — the overdue backlog, the undated tail — is made of
  /// tasks from different days, and sorting by date first would quietly undo
  /// the arranging. A day's own tasks share a date anyway, so nothing changes
  /// for them.
  ///
  /// Done tasks are in the order they were ticked, the latest last — see
  /// `TaskProvider._compare`. For open tasks the `CASE` is null throughout
  /// and changes nothing.
  static const _order =
      'done ASC, CASE WHEN done = 1 THEN completed_at END ASC, '
      '(sort_order IS NULL) ASC, sort_order ASC, '
      '(due_at IS NULL) ASC, due_at ASC, created_at DESC';

  /// Writes the order a day was dragged into: the position of each id in
  /// [ids] becomes its `sort_order`. Every task of the day is written, not
  /// only the one that moved, so the day is left with a complete order rather
  /// than one task holding a number and the rest guessing.
  Future<void> setOrder(List<int> ids) async {
    final db = await database;
    final batch = db.batch();
    for (var i = 0; i < ids.length; i++) {
      batch.update(
        _tasks,
        {'sort_order': i},
        where: 'id = ?',
        whereArgs: [ids[i]],
      );
    }
    await batch.commit(noResult: true);
  }
}

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/task.dart';
import '../models/task_list.dart';

/// Thin wrapper around the local sqflite database that stores task lists and
/// the tasks they contain.
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  static const _dbName = 'caldo.db';
  static const _dbVersion = 2;
  static const _lists = 'lists';
  static const _tasks = 'tasks';

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
            completed_at INTEGER
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_tasks_due ON $_tasks (due_at)');
        await db.execute(
            'CREATE INDEX idx_tasks_list ON $_tasks (list_id)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // v1 -> a task can override the colour it takes from its list.
          await db.execute('ALTER TABLE $_tasks ADD COLUMN style_id TEXT');
        }
      },
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

  Future<void> updateList(TaskList list) async {
    final db = await database;
    await db.update(_lists, list.toMap(),
        where: 'id = ?', whereArgs: [list.id]);
  }

  /// Deletes a list and all of its tasks.
  Future<void> deleteList(int id) async {
    final db = await database;
    await db.delete(_tasks, where: 'list_id = ?', whereArgs: [id]);
    await db.delete(_lists, where: 'id = ?', whereArgs: [id]);
  }

  // ---- Tasks --------------------------------------------------------------

  /// Tasks of one list. [query] matches the title or notes; when [includeDone]
  /// is false only open tasks come back.
  Future<List<Task>> getTasks({
    required int listId,
    String query = '',
    bool includeDone = true,
  }) async {
    final db = await database;
    final where = StringBuffer('list_id = ?');
    final args = <Object?>[listId];
    if (!includeDone) where.write(' AND done = 0');
    if (query.isNotEmpty) {
      where.write(' AND (title LIKE ? OR notes LIKE ?)');
      args..add('%$query%')..add('%$query%');
    }
    final rows = await db.query(
      _tasks,
      where: where.toString(),
      whereArgs: args,
      orderBy: _order,
    );
    return rows.map(Task.fromMap).toList();
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
    final rows = await db.query(_tasks, where: 'due_at IS NULL',
        orderBy: _order);
    return rows.map(Task.fromMap).toList();
  }

  /// Open tasks that were due before [beforeMs] — the overdue backlog.
  Future<List<Task>> getOverdue(int beforeMs) async {
    final db = await database;
    final rows = await db.query(
      _tasks,
      where: 'done = 0 AND due_at IS NOT NULL AND due_at < ?',
      whereArgs: [beforeMs],
      orderBy: 'due_at ASC',
    );
    return rows.map(Task.fromMap).toList();
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

  /// Removes every completed task of a list, or of all lists when null.
  Future<int> clearCompleted({int? listId}) async {
    final db = await database;
    return listId == null
        ? db.delete(_tasks, where: 'done = 1')
        : db.delete(_tasks,
            where: 'done = 1 AND list_id = ?', whereArgs: [listId]);
  }

  /// Closes the connection, so the next access reopens the file. Used by
  /// tests, which start each case from a fresh database.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Open first, then by due date (undated last), then newest first.
  static const _order =
      'done ASC, (due_at IS NULL) ASC, due_at ASC, created_at DESC';
}

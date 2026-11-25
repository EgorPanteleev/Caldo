import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/completion.dart';
import '../models/special_day.dart';
import '../models/task.dart';
import '../models/task_list.dart';

/// Thin wrapper around the local sqflite database that stores task lists and
/// the tasks they contain.
class AppDatabase {
  AppDatabase._(this._dbName);
  static final AppDatabase instance = AppDatabase._('caldo.db');

  /// A database of its own under [name], for a test that needs two devices
  /// at once — a sync's two ends.
  @visibleForTesting
  factory AppDatabase.named(String name) => AppDatabase._(name);

  final String _dbName;
  static const _dbVersion = 16;
  static const _lists = 'lists';
  static const _tasks = 'tasks';
  static const _completions = 'completions';
  static const _vaultKeys = 'vault_keys';
  static const _secrets = 'secrets';
  static const _specialDays = 'special_days';
  static const _syncState = 'sync_state';
  static const _tombstones = 'tombstones';

  /// The uuid the default group has on every device. Each one makes its own
  /// "Personal" on first run; sharing a uuid, they are one group to a sync
  /// rather than a second "Personal" turning up beside the first.
  static const defaultListUuid = '00000000-0000-4000-8000-000000000001';

  /// Columns that say how a row stands with the sync rather than what it
  /// holds. A backup leaves them out: a restore is a change of its own, and
  /// is stamped as one.
  static const _bookkeeping = {'updated_at', 'dirty'};

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
            created_at INTEGER NOT NULL,
            sort_order INTEGER
          )
        ''');
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
            attachments TEXT NOT NULL DEFAULT '[]',
            remind_before INTEGER,
            snoozed_until INTEGER,
            started_at INTEGER,
            duration INTEGER,
            claude TEXT,
            agent TEXT,
            agent_state TEXT
          )
        ''');
        await db.execute('CREATE INDEX idx_tasks_due ON $_tasks (due_at)');
        await db.execute('CREATE INDEX idx_tasks_list ON $_tasks (list_id)');
        await _createCompletions(db);
        // The same steps an upgrade takes, so a new install and an old one
        // cannot come out with different triggers.
        await _addSync(db);
        await _addVault(db);
        await _addSpecialDays(db);
        await db.insert(_lists, {
          'name': 'Personal',
          'style_id': 'violet',
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'uuid': defaultListUuid,
        });
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
          // v6 -> a task can be put in progress on the board. Null for every
          // task there already is: none of them has been.
          await db.execute('ALTER TABLE $_tasks ADD COLUMN started_at INTEGER');
        }
        if (oldVersion < 8) {
          // v7 -> a timed task can have a length, and so an end. Null for
          // every task there already is: each only ever had a start.
          await db.execute('ALTER TABLE $_tasks ADD COLUMN duration INTEGER');
        }
        if (oldVersion < 9) {
          // v8 -> the groups can be put in an order of the user's own. Null
          // until they are, so they stay in the order they were made.
          await db.execute('ALTER TABLE $_lists ADD COLUMN sort_order INTEGER');
        }
        if (oldVersion < 10) {
          // v9 -> a task can carry files and photos, as JSON beside it.
          await db.execute(
            "ALTER TABLE $_tasks ADD COLUMN attachments TEXT NOT NULL DEFAULT '[]'",
          );
        }
        if (oldVersion < 11) {
          // v10 -> every row is ready to be synced: a uuid, a stamp, and a
          // note of what has changed since. Everything there is counts as
          // changed, since no server has seen any of it.
          await _addSync(db);
          await _claimDefault(db);
        }
        if (oldVersion < 12) {
          // v11 -> the vault: its keys and the secrets they seal.
          await _addVault(db);
        }
        if (oldVersion < 13) {
          // v12 -> birthdays and other days of the user's own.
          await _addSpecialDays(db);
        }
        if (oldVersion < 14) {
          // v13 -> a task can be handed to Claude, with the model to use.
          await db.execute('ALTER TABLE $_tasks ADD COLUMN claude TEXT');
        }
        if (oldVersion < 15) {
          // v14 -> what a task was sent to from Schedule or the calendar.
          await db.execute('ALTER TABLE $_tasks ADD COLUMN agent TEXT');
        }
        if (oldVersion < 16) {
          // v15 -> where the agent a task was sent to stands with it.
          await db.execute('ALTER TABLE $_tasks ADD COLUMN agent_state TEXT');
        }
      },
    );
  }

  /// Now in epoch millis, in SQL. `unixepoch('subsec')` would say it more
  /// plainly but needs SQLite 3.42, newer than older Androids carry.
  static const _nowMs =
      "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)";

  /// A random (version 4) uuid, in SQL, made afresh for each row.
  static const _newUuid =
      "lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' "
      "|| substr(lower(hex(randomblob(2))), 2) || '-' "
      "|| substr('89ab', 1 + (random() & 3), 1) "
      "|| substr(lower(hex(randomblob(2))), 2) || '-' "
      '|| lower(hex(randomblob(6)))';

  /// Makes every table syncable (schema v11).
  ///
  /// Rows keep their integer ids, which the alarms, the widget and every
  /// screen go by; a uuid beside each is what devices know a row by, since
  /// two of them offline would both hand out the next integer. Ids that
  /// point at other rows (a task's group, a tick's task) are put into uuids
  /// only on the way to the server.
  ///
  /// The stamping is done by triggers rather than by each write: a write
  /// comes from a screen, a reminder's button, the widget's tick on an
  /// isolate of its own, or a restore, and a path that forgot to stamp would
  /// be a change no other device ever hears of. A deletion leaves a
  /// tombstone, or a device could not tell a row deleted here from one it
  /// has not been sent yet. While `sync_state.applying` is set — a sync
  /// writing what it pulled — none of them fire, so what came from the
  /// server is not sent straight back to it.
  static Future<void> _addSync(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE $_syncState (
        id INTEGER PRIMARY KEY CHECK (id = 0),
        applying INTEGER NOT NULL DEFAULT 0,
        cursor INTEGER NOT NULL DEFAULT 0,
        account TEXT
      )
    ''');
    await db.insert(_syncState, {'id': 0});
    await db.execute('''
      CREATE TABLE $_tombstones (
        table_name TEXT NOT NULL,
        uuid TEXT NOT NULL,
        deleted_at INTEGER NOT NULL,
        PRIMARY KEY (table_name, uuid)
      )
    ''');
    for (final table in const [_lists, _tasks, _completions]) {
      await db.execute('ALTER TABLE $table ADD COLUMN uuid TEXT');
      await db.execute(
        'ALTER TABLE $table ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE $table ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1',
      );
      await db.execute(
        'UPDATE $table SET uuid = $_newUuid, updated_at = $_nowMs',
      );
      await _stamp(db, table);
    }
  }

  /// The columns a table made after v11 is born with, for the sync.
  static const _syncColumns =
      'uuid TEXT, updated_at INTEGER NOT NULL DEFAULT 0, '
      'dirty INTEGER NOT NULL DEFAULT 1';

  /// Gives [table] — one with the sync's columns — the triggers that stamp
  /// its changes and bury its deletions.
  static Future<void> _stamp(DatabaseExecutor db, String table) async {
    const quiet = '(SELECT applying FROM $_syncState) = 0';
    await db.execute('CREATE UNIQUE INDEX idx_${table}_uuid ON $table (uuid)');
    // A row given a uuid keeps it: a restore, and later a sync, write
    // rows that already have one.
    await db.execute('''
      CREATE TRIGGER ${table}_inserted AFTER INSERT ON $table WHEN $quiet
      BEGIN
        UPDATE $table
          SET uuid = COALESCE(NEW.uuid, $_newUuid),
              updated_at = $_nowMs, dirty = 1
          WHERE id = NEW.id;
        DELETE FROM $_tombstones
          WHERE table_name = '$table' AND uuid = NEW.uuid;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER ${table}_updated AFTER UPDATE ON $table WHEN $quiet
      BEGIN
        UPDATE $table SET updated_at = $_nowMs, dirty = 1 WHERE id = NEW.id;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER ${table}_deleted AFTER DELETE ON $table
        WHEN OLD.uuid IS NOT NULL AND $quiet
      BEGIN
        INSERT OR REPLACE INTO $_tombstones (table_name, uuid, deleted_at)
          VALUES ('$table', OLD.uuid, $_nowMs);
      END
    ''');
  }

  /// The vault (schema v12): the keys secrets are sealed with, each sealed
  /// in turn with the master password, and the secrets.
  ///
  /// Nothing here can be read without the password. A key's row holds the
  /// salt and the setting the password is made into a key with, the vault's
  /// key sealed with that, and a box (`proof`) that only the vault's key
  /// opens — how a key handed back by the fingerprint is known to be the
  /// right one. A secret's row holds the uuid of the key it is sealed with
  /// and the box; even its name is inside.
  ///
  /// Synced and backed up like every other table: what leaves the device is
  /// what is here, already sealed.
  static Future<void> _addVault(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE $_vaultKeys (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        salt TEXT NOT NULL,
        kdf TEXT NOT NULL,
        wrapped TEXT NOT NULL,
        proof TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        $_syncColumns
      )
    ''');
    await db.execute('''
      CREATE TABLE $_secrets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        key_id TEXT NOT NULL,
        sealed TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        $_syncColumns
      )
    ''');
    await _stamp(db, _vaultKeys);
    await _stamp(db, _secrets);
  }

  /// Birthdays, anniversaries and other days that come back every year
  /// (schema v13): a month and a day, the year it began when known.
  static Future<void> _addSpecialDays(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE $_specialDays (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'birthday',
        month INTEGER NOT NULL,
        day INTEGER NOT NULL,
        year INTEGER,
        style_id TEXT NOT NULL DEFAULT 'pink',
        remind INTEGER NOT NULL DEFAULT 1,
        created_at INTEGER NOT NULL,
        $_syncColumns
      )
    ''');
    await _stamp(db, _specialDays);
  }

  /// Gives the oldest group — the default, which cannot be deleted — the
  /// uuid every device's default has, unless one already has it.
  static Future<void> _claimDefault(DatabaseExecutor db) async {
    final held = await db.query(
      _lists,
      where: 'uuid = ?',
      whereArgs: [defaultListUuid],
    );
    if (held.isNotEmpty) return;
    await db.rawUpdate(
      'UPDATE $_lists SET uuid = ? WHERE id = '
      '(SELECT id FROM $_lists ORDER BY created_at ASC, id ASC LIMIT 1)',
      [defaultListUuid],
    );
    await db.delete(
      _tombstones,
      where: 'table_name = ? AND uuid = ?',
      whereArgs: [_lists, defaultListUuid],
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
      ORDER BY (l.sort_order IS NULL) ASC, l.sort_order ASC, l.created_at ASC
    ''');
    return rows.map(TaskList.fromMap).toList();
  }

  /// Writes the order the groups were dragged into: the position of each id
  /// in [ids] becomes its `sort_order`. A group made after that has none and
  /// goes after the lot, at the end of the row where its plus was.
  Future<void> reorderLists(List<int> ids) async {
    final db = await database;
    final batch = db.batch();
    for (var i = 0; i < ids.length; i++) {
      batch.update(
        _lists,
        {'sort_order': i},
        where: 'id = ?',
        whereArgs: [ids[i]],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<TaskList> insertList(TaskList list) async {
    final db = await database;
    final id = await db.insert(_lists, list.toMap()..remove('id'));
    return list.copyWith(id: id);
  }

  /// Writes back a group's name and colour.
  Future<void> updateList(TaskList list) async {
    final db = await database;
    await db.update(
      _lists,
      list.toMap()..remove('id'),
      where: 'id = ?',
      whereArgs: [list.id],
    );
  }

  /// Deletes the group [id], moving its tasks into [into] rather than
  /// deleting them with it: a group is a way of looking at tasks, and taking
  /// one away should not take away what was in it.
  Future<void> deleteList(int id, {required int into}) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update(
        _tasks,
        {'list_id': into},
        where: 'list_id = ?',
        whereArgs: [id],
      );
      await txn.delete(_lists, where: 'id = ?', whereArgs: [id]);
    });
  }

  // ---- Tasks --------------------------------------------------------------

  /// Every task, which is what the search screen asks for. [query] matches
  /// the title, the notes, a subtask or an attachment's name; when [includeDone] is false only open
  /// tasks come back.
  Future<List<Task>> getTasks({
    String query = '',
    bool includeDone = true,
  }) async {
    final db = await database;
    final rows = await db.query(
      _tasks,
      where: includeDone ? null : 'done = 0',
      orderBy: _order,
    );
    final tasks = rows.map(Task.fromMap).toList();
    if (query.isEmpty) return tasks;
    // Matched here rather than with LIKE, which SQLite folds case for in
    // ASCII alone: "задача" never found "Задача", and the LIKE ran ahead of
    // the match here and threw it away. The checklist and the attachments
    // are JSON besides, which a LIKE for "done" or "mime" matched in every
    // task that had either. A LIKE over four columns read every row anyway.
    final needle = query.toLowerCase();
    bool has(String text) => text.toLowerCase().contains(needle);
    return [
      for (final t in tasks)
        if (has(t.title) ||
            has(t.notes) ||
            t.subtasks.any((s) => has(s.title)) ||
            t.attachments.any((a) => has(a.name)))
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

  /// What the board sorts into its columns: every open task, and every done
  /// one that is still kept. A repeating task is never among the done ones —
  /// ticked, it rolls on to its next round, which has not been started.
  Future<List<Task>> getBoard() async {
    final db = await database;
    final rows = await db.query(_tasks);
    return rows.map(Task.fromMap).toList();
  }

  /// Open tasks that were due before [beforeMs] — the overdue backlog.
  Future<List<Task>> getOverdue(int beforeMs) async {
    final db = await database;
    final rows = await db.query(
      _tasks,
      where: 'done = 0 AND due_at IS NOT NULL AND due_at < ?',
      whereArgs: [beforeMs],
      // High priority first and then however late each one is, unless the
      // backlog has been dragged into an order of its own — the rule a day
      // nobody has arranged follows (`TaskProvider._compare`).
      orderBy:
          '(sort_order IS NULL) ASC, sort_order ASC, priority DESC, '
          'due_at ASC',
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

  /// The uuid a task goes by on the server: the Agents tab's chats name
  /// their task by it.
  Future<String?> taskUuid(int id) async {
    final db = await database;
    final rows = await db.query(
      _tasks,
      columns: ['uuid'],
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : rows.first['uuid'] as String?;
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

  /// Writes back every one of [tasks] in one transaction — for what is
  /// done to several picked out at once, which should not be left half done
  /// or cost a round trip each.
  Future<void> updateAll(List<Task> tasks) async {
    if (tasks.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final task in tasks) {
      batch.update(_tasks, task.toMap(), where: 'id = ?', whereArgs: [task.id]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteAll(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    await db.delete(
      _tasks,
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
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

  // ---- The vault ----------------------------------------------------------

  /// Every key the vault has been sealed with, oldest first. Usually one; a
  /// second comes of two devices each making a vault before either had
  /// heard of the other's, until one of them is unlocked with both.
  Future<List<Map<String, Object?>>> getVaultKeys() async {
    final db = await database;
    return db.query(_vaultKeys, orderBy: 'created_at ASC, uuid ASC');
  }

  Future<void> insertVaultKey(Map<String, Object?> key) async {
    final db = await database;
    await db.insert(_vaultKeys, key);
  }

  /// Writes back the key [uuid] sealed afresh, as a new master password
  /// does.
  Future<void> updateVaultKey(String uuid, Map<String, Object?> key) async {
    final db = await database;
    await db.update(_vaultKeys, key, where: 'uuid = ?', whereArgs: [uuid]);
  }

  /// Every secret, still sealed.
  Future<List<Map<String, Object?>>> getSecrets() async {
    final db = await database;
    return db.query(_secrets);
  }

  /// Writes a sealed secret under its own [uuid], over the one of that uuid
  /// if there is one.
  Future<void> putSecret({
    required String uuid,
    required String keyId,
    required String sealed,
    required int createdAt,
  }) async {
    final db = await database;
    final values = {'key_id': keyId, 'sealed': sealed};
    final written = await db.update(
      _secrets,
      values,
      where: 'uuid = ?',
      whereArgs: [uuid],
    );
    if (written == 0) {
      await db.insert(_secrets, {
        ...values,
        'uuid': uuid,
        'created_at': createdAt,
      });
    }
  }

  Future<void> deleteSecret(String uuid) async {
    final db = await database;
    await db.delete(_secrets, where: 'uuid = ?', whereArgs: [uuid]);
  }

  /// Moves the secrets sealed with the keys [from] over to [into], written
  /// with each one's box sealed afresh, and lets those keys go — all at
  /// once, so no secret is ever left sealed with a key that has gone.
  Future<void> mergeVaultKeys({
    required Set<String> from,
    required String into,
    required Map<String, String> resealed,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      for (final MapEntry(key: uuid, value: sealed) in resealed.entries) {
        await txn.update(
          _secrets,
          {'key_id': into, 'sealed': sealed},
          where: 'uuid = ?',
          whereArgs: [uuid],
        );
      }
      for (final key in from) {
        await txn.delete(_vaultKeys, where: 'uuid = ?', whereArgs: [key]);
      }
    });
  }

  /// Deletes the vault: every key and every secret, here and — through the
  /// tombstones — on every device that syncs with this one.
  Future<void> deleteVault() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(_secrets);
      await txn.delete(_vaultKeys);
    });
  }

  // ---- Special days -------------------------------------------------------

  /// Every special day, in the order of the year: January's first.
  Future<List<SpecialDay>> getSpecialDays() async {
    final db = await database;
    final rows = await db.query(
      _specialDays,
      orderBy: 'month ASC, day ASC, created_at ASC',
    );
    return rows.map(SpecialDay.fromMap).toList();
  }

  Future<SpecialDay> insertSpecialDay(SpecialDay day) async {
    final db = await database;
    final id = await db.insert(_specialDays, day.toMap()..remove('id'));
    return day.copyWith(id: id);
  }

  Future<void> updateSpecialDay(SpecialDay day) async {
    final db = await database;
    await db.update(
      _specialDays,
      day.toMap()..remove('id'),
      where: 'id = ?',
      whereArgs: [day.id],
    );
  }

  Future<void> deleteSpecialDay(int id) async {
    final db = await database;
    await db.delete(_specialDays, where: 'id = ?', whereArgs: [id]);
  }

  // ---- Backups ------------------------------------------------------------

  /// The tables a backup carries, in the order they are written back: a
  /// task names its group and a tick names its task.
  ///
  /// The vault's go too, as sealed as they are here: a backup is a file
  /// left lying about, and opens no secret without the master password.
  static const backedUp = [
    _lists,
    _tasks,
    _completions,
    _vaultKeys,
    _secrets,
    _specialDays,
  ];

  /// The tables made after backups were, which a backup from before them
  /// does not have.
  static const _laterTables = {_vaultKeys, _secrets, _specialDays};

  static int get schema => _dbVersion;

  /// Every row of every table, as the database holds it. Rows rather than
  /// models, so a column added later is carried without anyone remembering
  /// to add it here.
  Future<Map<String, List<Map<String, Object?>>>> dump() async {
    final db = await database;
    return {
      for (final table in backedUp)
        table: [
          for (final row in await db.query(table))
            {
              for (final MapEntry(:key, :value) in row.entries)
                if (!_bookkeeping.contains(key)) key: value,
            },
        ],
    };
  }

  /// Replaces everything with [tables], in one transaction: a restore that
  /// fails halfway leaves what was there, not half of each.
  ///
  /// Only the columns this schema has are written. A backup from before a
  /// column existed leaves it to its default, which is what the migration
  /// that added it would have done.
  Future<void> replaceAll(
    Map<String, List<Map<String, Object?>>> tables,
  ) async {
    final db = await database;
    // A backup made before there was a vault leaves the vault as it is
    // rather than emptying it: restoring last month's tasks should not cost
    // every password. Nor every birthday, made since.
    final restored = [
      for (final table in backedUp)
        if (!_laterTables.contains(table) || tables.containsKey(table)) table,
    ];
    await db.transaction((txn) async {
      for (final table in restored.reversed) {
        await txn.delete(table);
      }
      for (final table in restored) {
        final columns = {
          for (final c in await txn.rawQuery('PRAGMA table_info($table)'))
            c['name'] as String,
        };
        for (final row in tables[table] ?? const []) {
          await txn.insert(table, {
            for (final MapEntry(:key, :value) in row.entries)
              if (columns.contains(key) && !_bookkeeping.contains(key))
                key: value,
          });
        }
      }
      // A backup from before v11 has no uuids, and its rows were given
      // fresh ones as they went in.
      await _claimDefault(txn);
    });
  }

  /// Closes the connection, so the next access reopens the file. Used by
  /// tests, which start each case from a fresh database.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Open first, then by priority, highest first, then by due date (undated
  /// last), then newest first. A hand-placed task goes where it was put;
  /// one that has never been dragged falls through to the ordinary rules,
  /// after the placed ones.
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
      '(sort_order IS NULL) ASC, sort_order ASC, priority DESC, '
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

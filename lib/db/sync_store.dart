import 'package:sqflite/sqflite.dart';

import 'database.dart';

/// One row as the server keeps it: the device's row without its local id,
/// and with the ids that point at other rows turned into their uuids.
class SyncRow {
  final String table;
  final String uuid;

  /// Null for a deletion.
  final Map<String, Object?>? data;

  /// When the device that wrote it last changed it, in epoch millis.
  final int updatedAt;
  final bool deleted;

  /// The server's count when it was written; 0 on the way up.
  final int seq;

  const SyncRow({
    required this.table,
    required this.uuid,
    this.data,
    required this.updatedAt,
    this.deleted = false,
    this.seq = 0,
  });

  Map<String, Object?> toJson() => {
    'tbl': table,
    'uuid': uuid,
    if (!deleted) 'data': data,
    'updated_at': updatedAt,
    'deleted': deleted,
  };

  factory SyncRow.fromJson(Map<String, Object?> json) => SyncRow(
    table: json['tbl'] as String,
    uuid: json['uuid'] as String,
    data: (json['data'] as Map?)?.cast<String, Object?>(),
    updatedAt: (json['updated_at'] as num).toInt(),
    deleted: json['deleted'] as bool? ?? false,
    seq: (json['seq'] as num?)?.toInt() ?? 0,
  );
}

/// The local side of a sync: what has changed here since the server last
/// heard, and what the server has that this device has not.
///
/// The app goes by integer ids and the server by uuids, so this is where one
/// is put into the other — a task's group, a tick's task and group. Nothing
/// else in the app knows a sync exists.
class SyncStore {
  final AppDatabase db;

  SyncStore([AppDatabase? db]) : db = db ?? AppDatabase.instance;

  /// The tasks a pull has written or deleted since this was last cleared,
  /// by id: what a round run with the app closed has to set alarms for.
  final touchedTasks = <int>{};

  /// In the order a pull writes them: a group before its tasks, a task
  /// before its ticks. The vault's are sealed already, and travel as they
  /// are kept; a secret names its key by uuid, not by id, so it needs no
  /// link put into one.
  static const _tables = [
    'lists',
    'tasks',
    'completions',
    'vault_keys',
    'secrets',
    'special_days',
  ];

  /// What a row carries that is this device's alone, or put into a uuid.
  static const _local = {'id', 'uuid', 'updated_at', 'dirty'};
  static const _links = {
    'tasks': {'list_id': ('lists', 'list_uuid')},
    'completions': {
      'list_id': ('lists', 'list_uuid'),
      'task_id': ('tasks', 'task_uuid'),
    },
  };

  /// The account this device's rows were last synced with, and the server's
  /// count it has seen up to.
  Future<(String?, int)> state() async {
    final d = await db.database;
    final row = (await d.query('sync_state')).single;
    return (row['account'] as String?, row['cursor'] as int);
  }

  /// Takes up [account]. Signed in to a different one than last time — or
  /// for the first time — every row here is to be sent and everything there
  /// read from the start. The rows keep their stamps, so a group both sides
  /// have (the default) goes by whichever was really changed last.
  Future<void> adopt(String account) async {
    final d = await db.database;
    final (held, _) = await state();
    if (held == account) return;
    await d.transaction((txn) async {
      await _quiet(txn, () async {
        for (final t in _tables) {
          await txn.update(t, {'dirty': 1});
        }
        await txn.update('sync_state', {'account': account, 'cursor': 0});
      });
    });
  }

  /// Every row changed here since it was last sent, deletions last.
  Future<List<SyncRow>> outgoing() async {
    final d = await db.database;
    final rows = <SyncRow>[];
    for (final t in _tables) {
      final links = _links[t] ?? const {};
      final joins = StringBuffer();
      final picks = StringBuffer();
      var n = 0;
      for (final MapEntry(key: column, value: (target, name))
          in links.entries) {
        final alias = 'j${n++}';
        joins.write(' LEFT JOIN $target $alias ON $alias.id = r.$column');
        picks.write(', $alias.uuid AS $name');
      }
      for (final r in await d.rawQuery(
        'SELECT r.*$picks FROM $t r$joins WHERE r.dirty = 1',
      )) {
        final data = {
          for (final MapEntry(:key, :value) in r.entries)
            if (!_local.contains(key) && !links.containsKey(key)) key: value,
        };
        if (t == 'tasks') _toDay(data);
        rows.add(
          SyncRow(
            table: t,
            uuid: r['uuid'] as String,
            updatedAt: r['updated_at'] as int,
            data: data,
          ),
        );
      }
    }
    for (final r in await d.query('tombstones')) {
      rows.add(
        SyncRow(
          table: r['table_name'] as String,
          uuid: r['uuid'] as String,
          updatedAt: r['deleted_at'] as int,
          deleted: true,
        ),
      );
    }
    return rows;
  }

  /// An all-day task is due on a day, not at an instant, and it travels as
  /// one ("2026-11-16"). Here it is kept as the local midnight that starts
  /// the day, and that instant sent as it is was a different day to a
  /// device in another time zone: filed on the 16th in Moscow, it arrived
  /// as the 15th in London, overdue. Each end turns the day into its own
  /// midnight.
  static void _toDay(Map<String, Object?> data) {
    final due = data['due_at'];
    if (data['has_time'] != 0 || due is! int) return;
    final day = DateTime.fromMillisecondsSinceEpoch(due);
    data['due_at'] =
        '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
  }

  static void _fromDay(Map<String, Object?> values) {
    final due = values['due_at'];
    if (due is! String) return;
    // Parsed without a zone, a date is this device's own midnight.
    values['due_at'] = DateTime.tryParse(due)?.millisecondsSinceEpoch;
  }

  /// Notes that [rows] have reached the server. Only as they were sent: a
  /// row changed again while they were on the way is still to be sent.
  Future<void> sent(List<SyncRow> rows) async {
    final d = await db.database;
    await d.transaction((txn) async {
      await _quiet(txn, () async {
        for (final r in rows) {
          if (r.deleted) {
            await txn.delete(
              'tombstones',
              where: 'table_name = ? AND uuid = ? AND deleted_at = ?',
              whereArgs: [r.table, r.uuid, r.updatedAt],
            );
          } else {
            await txn.update(
              r.table,
              {'dirty': 0},
              where: 'uuid = ? AND updated_at = ?',
              whereArgs: [r.uuid, r.updatedAt],
            );
          }
        }
      });
    });
  }

  /// Writes what the server sent, and the count it reached, in one go; says
  /// whether anything here changed.
  ///
  /// A row changed here later than the server's copy — not yet sent, or sent
  /// after this pull was asked for — is left alone; it goes up next time and
  /// wins there. The rows are written with the triggers quiet, so what came
  /// down is not sent straight back up.
  Future<bool> apply(List<SyncRow> rows, int cursor) async {
    final d = await db.database;
    var changed = false;
    await d.transaction((txn) async {
      final columns = {
        for (final t in _tables)
          t: {
            for (final c in await txn.rawQuery('PRAGMA table_info($t)'))
              c['name'] as String,
          },
      };
      // A group before the tasks in it, and a task before its ticks, so each
      // finds the row it points at.
      final ordered = [
        for (final t in _tables) ...rows.where((r) => r.table == t),
      ];
      await _quiet(txn, () async {
        for (final r in ordered) {
          try {
            if (await _applyOne(txn, r, columns[r.table]!)) changed = true;
          } on DatabaseException {
            // A row this version cannot hold (a column it has no default
            // for, missing) is passed over rather than holding up the rest
            // for good.
          }
        }
        await txn.update('sync_state', {'cursor': cursor});
      });
      // A group deleted elsewhere while this device still had tasks in it:
      // they go into the default group, as a deletion here would put them,
      // and that is a change of this device's to send.
      final home = await _defaultList(txn);
      if (home != null) {
        final moved = await txn.rawUpdate(
          'UPDATE tasks SET list_id = ? '
          'WHERE list_id NOT IN (SELECT id FROM lists)',
          [home],
        );
        if (moved > 0) changed = true;
      }
    });
    return changed;
  }

  Future<bool> _applyOne(
    Transaction txn,
    SyncRow r,
    Set<String> columns,
  ) async {
    if (!_tables.contains(r.table)) return false;
    final here = (await txn.query(
      r.table,
      columns: ['id', 'updated_at', 'dirty'],
      where: 'uuid = ?',
      whereArgs: [r.uuid],
    )).firstOrNull;
    final buried = (await txn.query(
      'tombstones',
      columns: ['deleted_at'],
      where: 'table_name = ? AND uuid = ?',
      whereArgs: [r.table, r.uuid],
    )).firstOrNull;
    // Changed or deleted here since: this device's is the later word.
    if (here != null &&
        here['dirty'] == 1 &&
        (here['updated_at'] as int) > r.updatedAt) {
      return false;
    }
    if (buried != null && (buried['deleted_at'] as int) > r.updatedAt) {
      return false;
    }
    if (buried != null) {
      await txn.delete(
        'tombstones',
        where: 'table_name = ? AND uuid = ?',
        whereArgs: [r.table, r.uuid],
      );
    }
    if (r.deleted) {
      if (here == null) return false;
      await txn.delete(r.table, where: 'id = ?', whereArgs: [here['id']]);
      if (r.table == 'tasks') touchedTasks.add(here['id'] as int);
      return true;
    }
    // This device's own row, come back: nothing to write.
    if (here != null &&
        here['dirty'] == 0 &&
        here['updated_at'] == r.updatedAt) {
      return false;
    }
    final values = <String, Object?>{
      for (final MapEntry(:key, :value) in (r.data ?? const {}).entries)
        if (columns.contains(key) && !_local.contains(key)) key: value,
      'uuid': r.uuid,
      'updated_at': r.updatedAt,
      'dirty': 0,
    };
    if (r.table == 'tasks') _fromDay(values);
    for (final MapEntry(key: column, value: (target, name))
        in (_links[r.table] ?? const {}).entries) {
      final linked = r.data?[name] as String?;
      var id = linked == null ? null : await _idOf(txn, target, linked);
      // A task needs a group; a tick may outlive its task.
      if (id == null && target == 'lists') id = await _defaultList(txn);
      values[column] = id;
    }
    final int written;
    if (here == null) {
      written = await txn.insert(r.table, values);
    } else {
      written = here['id'] as int;
      await txn.update(r.table, values, where: 'id = ?', whereArgs: [written]);
    }
    if (r.table == 'tasks') touchedTasks.add(written);
    return true;
  }

  static Future<int?> _idOf(Transaction txn, String table, String uuid) async =>
      (await txn.query(
            table,
            columns: ['id'],
            where: 'uuid = ?',
            whereArgs: [uuid],
          )).firstOrNull?['id']
          as int?;

  static Future<int?> _defaultList(Transaction txn) async =>
      await _idOf(txn, 'lists', AppDatabase.defaultListUuid) ??
      (await txn.query(
            'lists',
            columns: ['id'],
            orderBy: 'created_at ASC, id ASC',
            limit: 1,
          )).firstOrNull?['id']
          as int?;

  /// Runs [body] with the triggers silenced, inside a transaction already
  /// open, so no other connection ever sees them silent.
  static Future<void> _quiet(
    Transaction txn,
    Future<void> Function() body,
  ) async {
    await txn.update('sync_state', {'applying': 1});
    try {
      await body();
    } finally {
      await txn.update('sync_state', {'applying': 0});
    }
  }
}

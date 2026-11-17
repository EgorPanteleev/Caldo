import 'package:caldo/db/database.dart';
import 'package:caldo/models/task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/test_db.dart';

void main() {
  setUpAll(initTestDatabase);
  setUp(resetTestDatabase);

  Future<Database> db() => AppDatabase.instance.database;

  Future<Map<String, Object?>> row(String table, int id) async =>
      (await (await db()).query(
        table,
        where: 'id = ?',
        whereArgs: [id],
      )).single;

  Future<List<Map<String, Object?>>> tombstones() async =>
      (await db()).query('tombstones');

  Task task(String title) => Task(
    listId: 1,
    title: title,
    createdAt: DateTime.now().millisecondsSinceEpoch,
  );

  test('a new install\'s default group has the shared uuid', () async {
    final lists = await (await db()).query('lists');
    expect(lists.single['uuid'], AppDatabase.defaultListUuid);
  });

  test('a new task is given a uuid and marked as changed', () async {
    final before = DateTime.now().millisecondsSinceEpoch;
    final saved = await AppDatabase.instance.insert(task('Ship'));
    final r = await row('tasks', saved.id!);
    expect(
      r['uuid'],
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
          r'[0-9a-f]{12}$',
        ),
      ),
    );
    expect(r['dirty'], 1);
    expect(r['updated_at'] as int, greaterThanOrEqualTo(before - 1));
  });

  test('a write marks its row changed again and keeps its uuid', () async {
    final saved = await AppDatabase.instance.insert(task('Ship'));
    final uuid = (await row('tasks', saved.id!))['uuid'];
    // As a sync would leave it: sent, and stamped long ago.
    await (await db()).execute('UPDATE sync_state SET applying = 1');
    await (await db()).update('tasks', {'dirty': 0, 'updated_at': 5});
    await (await db()).execute('UPDATE sync_state SET applying = 0');
    expect((await row('tasks', saved.id!))['dirty'], 0);

    await AppDatabase.instance.update(saved.copyWith(title: 'Ship it'));
    final r = await row('tasks', saved.id!);
    expect(r['dirty'], 1);
    expect(r['updated_at'] as int, greaterThan(5));
    expect(r['uuid'], uuid);
  });

  test(
    'a deletion leaves a tombstone, and a row put back takes it away',
    () async {
      final saved = await AppDatabase.instance.insert(task('Ship'));
      final uuid = (await row('tasks', saved.id!))['uuid'];
      await AppDatabase.instance.delete(saved.id!);
      expect(
        (await tombstones()).single,
        allOf(containsPair('table_name', 'tasks'), containsPair('uuid', uuid)),
      );

      await (await db()).insert('tasks', {
        ...task('Ship').toMap()..remove('id'),
        'uuid': uuid,
      });
      expect(await tombstones(), isEmpty);
    },
  );

  test('a tick and its taking back leave the log as a tombstone', () async {
    final saved = await AppDatabase.instance.insert(task('Ship'));
    await AppDatabase.instance.complete(saved, 1000);
    final tick = (await (await db()).query('completions')).single;
    expect(tick['uuid'], isNotNull);
    await AppDatabase.instance.untick(saved);
    expect(
      (await tombstones()).single,
      allOf(
        containsPair('table_name', 'completions'),
        containsPair('uuid', tick['uuid']),
      ),
    );
  });

  test('while a sync applies what it pulled, nothing is stamped', () async {
    final d = await db();
    await d.execute('UPDATE sync_state SET applying = 1');
    final id = await d.insert('tasks', {
      ...task('From elsewhere').toMap()..remove('id'),
      'uuid': 'aaaaaaaa-0000-4000-8000-000000000000',
      'updated_at': 7,
      'dirty': 0,
    });
    await d.update('tasks', {'title': 'Renamed elsewhere'});
    await d.delete('tasks', where: 'id = ?', whereArgs: [id]);
    await d.execute('UPDATE sync_state SET applying = 0');
    expect(await tombstones(), isEmpty);
  });

  test('a backup carries uuids but not how rows stand with the sync', () async {
    await AppDatabase.instance.insert(task('Ship'));
    final dump = await AppDatabase.instance.dump();
    final row = dump['tasks']!.single;
    expect(row['uuid'], isNotNull);
    expect(row.containsKey('dirty'), isFalse);
    expect(row.containsKey('updated_at'), isFalse);
  });

  test('a backup from before uuids still gives the default its own', () async {
    await AppDatabase.instance.replaceAll({
      'lists': [
        {'id': 3, 'name': 'Later', 'created_at': 9},
        {'id': 1, 'name': 'Home', 'created_at': 1},
      ],
      'tasks': [
        {'id': 1, 'list_id': 1, 'title': 'Old', 'created_at': 1},
      ],
    });
    expect((await row('lists', 1))['uuid'], AppDatabase.defaultListUuid);
    expect((await row('lists', 3))['uuid'], isNot(AppDatabase.defaultListUuid));
    expect((await row('tasks', 1))['dirty'], 1);
    // The old default's tombstone is gone: the same group is back.
    expect(
      (await tombstones()).where(
        (t) => t['uuid'] == AppDatabase.defaultListUuid,
      ),
      isEmpty,
    );
  });

  test(
    'an upgrade from v10 gives every row a uuid and claims the default',
    () async {
      await AppDatabase.instance.close();
      final path = '${await databaseFactory.getDatabasesPath()}/caldo.db';
      final old = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 10,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE lists (id INTEGER PRIMARY KEY AUTOINCREMENT, '
              "name TEXT NOT NULL, style_id TEXT NOT NULL DEFAULT 'violet', "
              'created_at INTEGER NOT NULL, sort_order INTEGER)',
            );
            await db.execute(
              'CREATE TABLE tasks (id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'list_id INTEGER NOT NULL DEFAULT 1, title TEXT NOT NULL, '
              "notes TEXT NOT NULL DEFAULT '', due_at INTEGER, "
              'has_time INTEGER NOT NULL DEFAULT 0, '
              'done INTEGER NOT NULL DEFAULT 0, '
              'priority INTEGER NOT NULL DEFAULT 0, '
              "repeat_rule TEXT NOT NULL DEFAULT 'none', style_id TEXT, "
              'created_at INTEGER NOT NULL, completed_at INTEGER, '
              "sort_order INTEGER, subtasks TEXT NOT NULL DEFAULT '[]', "
              "attachments TEXT NOT NULL DEFAULT '[]', remind_before INTEGER, "
              'snoozed_until INTEGER, started_at INTEGER, duration INTEGER)',
            );
            await db.execute(
              'CREATE TABLE completions (id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'task_id INTEGER, title TEXT NOT NULL, '
              'list_id INTEGER NOT NULL DEFAULT 1, style_id TEXT, '
              'done_at INTEGER NOT NULL)',
            );
            await db.insert('lists', {'name': 'Uni', 'created_at': 5});
            await db.insert('lists', {'name': 'Personal', 'created_at': 2});
            for (final title in ['A', 'B']) {
              await db.insert('tasks', {'title': title, 'created_at': 1});
            }
            await db.insert('completions', {
              'task_id': 1,
              'title': 'A',
              'done_at': 3,
            });
          },
        ),
      );
      await old.close();

      final lists = await (await db()).query('lists', orderBy: 'id');
      expect(lists.map((l) => l['uuid']).toList(), [
        isNot(AppDatabase.defaultListUuid),
        AppDatabase.defaultListUuid,
      ]);
      final uuids = {
        for (final t in ['lists', 'tasks', 'completions'])
          for (final r in await (await db()).query(t)) r['uuid'],
      };
      expect(uuids, hasLength(5));
      expect(uuids, isNot(contains(null)));
      expect(
        (await (await db()).query('tasks')).map((t) => t['dirty']).toSet(),
        {1},
      );
      expect(await tombstones(), isEmpty);
    },
  );
}

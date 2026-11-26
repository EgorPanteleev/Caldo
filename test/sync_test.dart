import 'dart:io';

import 'package:caldo/db/database.dart';
import 'package:caldo/db/sync_store.dart';
import 'package:caldo/models/task.dart';
import 'package:caldo/models/task_list.dart';
import 'package:caldo/services/file_sync.dart';
import 'package:caldo/services/sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_server.dart';
import 'support/test_db.dart';

/// One phone: its own database and attachments, synced with [server].
class Device {
  final AppDatabase db;
  final Directory files = Directory.systemTemp.createTempSync('caldo_files');
  late final Sync sync;

  Device(String name, SyncServer server) : db = AppDatabase.named(name) {
    sync = Sync(
      SyncStore(db),
      server: server,
      files: FileSync(db, dir: () => files.path),
    );
  }

  /// A task with a file attached, its copy written here.
  Future<Task> attach(String title, String folder, String text) async {
    final copy = File('${files.path}/$folder/note.txt');
    await copy.parent.create();
    await copy.writeAsString(text);
    return db.insert(
      Task(
        listId: 1,
        title: title,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        attachments: [
          Attachment(
            file: '$folder/note.txt',
            name: 'note.txt',
            mime: 'text/plain',
          ),
        ],
      ),
    );
  }

  File copyOf(String folder) => File('${files.path}/$folder/note.txt');

  /// A round, and the files it set going.
  Future<void> round() async {
    await sync.run();
    await sync.carried;
  }

  Future<Database> get raw => db.database;

  Future<Task?> named(String title) async {
    final rows = await (await raw).query(
      'tasks',
      where: 'title = ?',
      whereArgs: [title],
    );
    return rows.isEmpty ? null : Task.fromMap(rows.single);
  }

  Future<String> uuidOf(String table, int id) async =>
      (await (await raw).query(
            table,
            where: 'id = ?',
            whereArgs: [id],
          )).single['uuid']
          as String;

  Future<int> count(String sql) async =>
      (await (await raw).rawQuery(sql)).single.values.single as int;

  Future<int> dirty() async {
    var n = await count('SELECT COUNT(*) FROM tombstones');
    for (final t in ['lists', 'tasks', 'completions']) {
      n += await count('SELECT COUNT(*) FROM $t WHERE dirty = 1');
    }
    return n;
  }

  Future<Task> add(String title, {int listId = 1}) => db.insert(
    Task(
      listId: listId,
      title: title,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ),
  );
}

/// The stamps are the clock's milliseconds; two edits a test means to be one
/// after the other must not land in the same one.
Future<void> tick() => Future.delayed(const Duration(milliseconds: 5));

void main() {
  setUpAll(initTestDatabase);

  late FakeServer server;
  late Device a;
  late Device b;

  setUp(() async {
    final dir = await databaseFactory.getDatabasesPath();
    for (final name in ['a.db', 'b.db']) {
      await databaseFactory.deleteDatabase('$dir/$name');
    }
    server = FakeServer();
    a = Device('a.db', server);
    b = Device('b.db', server);
  });

  tearDown(() async {
    await a.db.close();
    await b.db.close();
    await a.files.delete(recursive: true);
    await b.files.delete(recursive: true);
  });

  test('a task made on one phone turns up on the other', () async {
    final made = await a.add('Ship');
    await a.sync.run();
    expect(await b.sync.run(), isTrue);

    final there = await b.named('Ship');
    expect(there, isNotNull);
    expect(
      await b.uuidOf('tasks', there!.id!),
      await a.uuidOf('tasks', made.id!),
    );
    // Both phones' Personal is one group, so it lands in B's own.
    final lists = await (await b.raw).query('lists');
    expect(lists, hasLength(1));
    expect(there.listId, lists.single['id']);
    expect(await a.dirty(), 0);
    expect(await b.dirty(), 0);
  });

  test('a subtask finds its parent, even one that comes after it', () async {
    final parent = await a.add('Ship');
    final child = await a.db.insert(
      Task(
        listId: 1,
        title: 'Write the notes',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        parentId: parent.id,
      ),
    );
    await a.sync.run();
    expect(
      server.dataOf(
        'tasks',
        await a.uuidOf('tasks', child.id!),
      )?['parent_uuid'],
      await a.uuidOf('tasks', parent.id!),
    );
    expect(
      server.dataOf('tasks', await a.uuidOf('tasks', child.id!)),
      isNot(contains('parent_id')),
      reason: 'a device\'s own id means nothing to another',
    );
    // Changed after its subtask was made, the parent comes down after it.
    await tick();
    await a.db.update(parent.copyWith(title: 'Ship it'));
    await a.sync.run();

    await b.sync.run();
    final there = (await b.named('Write the notes'))!;
    expect(there.parentId, (await b.named('Ship it'))!.id);

    // Deleted with its parent, on the other phone too.
    await a.db.delete(parent.id!);
    expect(await a.named('Write the notes'), isNull);
    await a.sync.run();
    await b.sync.run();
    expect(await b.named('Write the notes'), isNull);
    expect(await b.named('Ship it'), isNull);
  });

  test('a round with nothing new changes nothing', () async {
    await a.add('Ship');
    await a.sync.run();
    expect(await a.sync.run(), isFalse, reason: 'its own rows come back');
    expect(await a.dirty(), 0);
  });

  test('an edit and a deletion travel, and leave nothing to send', () async {
    await a.add('Ship');
    await a.sync.run();
    await b.sync.run();

    await tick();
    final there = (await b.named('Ship'))!;
    await b.db.update(there.copyWith(title: 'Ship it'));
    await b.sync.run();
    await a.sync.run();
    expect(await a.named('Ship it'), isNotNull);
    expect(await a.dirty(), 0);

    await tick();
    await a.db.delete((await a.named('Ship it'))!.id!);
    await a.sync.run();
    await b.sync.run();
    expect(await b.named('Ship it'), isNull);
    expect(
      await b.dirty(),
      0,
      reason: 'a deletion from elsewhere is no tombstone',
    );
  });

  test(
    'a pull notes the tasks it wrote or deleted, for their alarms',
    () async {
      final kept = await a.add('Ship');
      final dropped = await a.add('Drop');
      await a.sync.run();
      await b.sync.run();
      final there = (await b.named('Ship'))!.id!;
      final gone = (await b.named('Drop'))!.id!;
      expect(b.sync.store.touchedTasks, {there, gone});

      b.sync.store.touchedTasks.clear();
      await tick();
      await a.db.update(kept.copyWith(title: 'Ship it'));
      await a.db.delete(dropped.id!);
      await a.sync.run();
      await b.sync.run();
      expect(b.sync.store.touchedTasks, {there, gone});
      expect(
        a.sync.store.touchedTasks,
        isEmpty,
        reason: 'its own rows coming back write nothing',
      );
    },
  );

  test('of two edits made apart, the later wins on both phones', () async {
    await a.add('Ship');
    await a.sync.run();
    await b.sync.run();

    final onA = (await a.named('Ship'))!;
    final onB = (await b.named('Ship'))!;
    await b.db.update(onB.copyWith(title: 'From B'));
    await tick();
    await a.db.update(onA.copyWith(title: 'From A'));

    await b.sync.run();
    await a.sync.run();
    await b.sync.run();
    expect(await a.named('From A'), isNotNull);
    expect(await b.named('From A'), isNotNull);
    expect(await b.named('From B'), isNull);
  });

  test('an older copy pulled does not overwrite a newer edit here', () async {
    await a.add('Ship');
    await a.sync.run();
    await b.sync.run();
    await a.db.update((await a.named('Ship'))!.copyWith(title: 'A first'));
    await a.sync.run();
    await tick();
    // B changes it after A did, but pulls before it pushes.
    await b.db.update((await b.named('Ship'))!.copyWith(title: 'B later'));
    final store = SyncStore(b.db);
    final (_, since) = await store.state();
    await store.apply(await server.pull(since, 500), 99);
    expect(await b.named('B later'), isNotNull);
    expect(await b.dirty(), 1);
  });

  test('a new group and its tasks arrive together', () async {
    final uni = await a.db.insertList(
      TaskList(name: 'Uni', styleId: 'blue', createdAt: 5),
    );
    await a.add('Essay', listId: uni.id!);
    await a.sync.run();
    await b.sync.run();

    final group = (await (await b.raw).query(
      'lists',
      where: 'name = ?',
      whereArgs: ['Uni'],
    )).single;
    expect((await b.named('Essay'))!.listId, group['id']);
  });

  test('a tick and its log entry travel, pointing at the right task', () async {
    final made = await a.add('Ship');
    await a.db.complete(made, 1000);
    await a.sync.run();
    await b.sync.run();

    final there = (await b.named('Ship'))!;
    expect(there.done, isTrue);
    final log = await b.db.getCompletions(0);
    expect(log.single.taskId, there.id);
  });

  test('a group deleted elsewhere hands its tasks to the default', () async {
    final uni = await a.db.insertList(
      TaskList(name: 'Uni', styleId: 'blue', createdAt: 5),
    );
    await a.sync.run();
    await b.sync.run();
    final uniOnB =
        (await (await b.raw).query(
              'lists',
              where: 'name = ?',
              whereArgs: ['Uni'],
            )).single['id']
            as int;
    // B files a task in it before hearing that A deleted the group.
    await a.db.deleteList(uni.id!, into: 1);
    await a.sync.run();
    await b.add('Essay', listId: uniOnB);
    await b.sync.run();
    expect((await b.named('Essay'))!.listId, 1);
    await a.sync.run();
    expect((await a.named('Essay'))!.listId, 1);
  });

  test(
    'a column the server has and this version does not is passed by',
    () async {
      final made = await a.add('Ship');
      await a.sync.run();
      final uuid = await a.uuidOf('tasks', made.id!);
      await server.push([
        SyncRow(
          table: 'tasks',
          uuid: uuid,
          updatedAt: DateTime.now().millisecondsSinceEpoch + 1000,
          data: {'title': 'Ship v2', 'from_the_future': 1},
        ),
      ]);
      await a.sync.run();
      expect(await a.named('Ship v2'), isNotNull);
      // And sending it back up does not wipe what this version cannot see.
      await tick();
      await a.db.update((await a.named('Ship v2'))!.copyWith(notes: 'n'));
      await a.sync.run();
      expect(server.dataOf('tasks', uuid)?['from_the_future'], 1);
    },
  );

  test('an all-day task travels as a day, a timed one as an instant', () async {
    final day = DateTime(2026, 11, 16);
    await a.db.insert(
      Task(
        listId: 1,
        title: 'All day',
        dueAt: day.millisecondsSinceEpoch,
        createdAt: 1,
      ),
    );
    final at = DateTime(2026, 11, 16, 15, 30).millisecondsSinceEpoch;
    await a.db.insert(
      Task(listId: 1, title: 'Timed', dueAt: at, hasTime: true, createdAt: 1),
    );
    final sent = {
      for (final r in await SyncStore(a.db).outgoing())
        if (r.table == 'tasks') r.data!['title']: r.data!['due_at'],
    };
    expect(sent, {'All day': '2026-11-16', 'Timed': at});

    await a.sync.run();
    await b.sync.run();
    expect((await b.named('All day'))!.dueAt, day.millisecondsSinceEpoch);
    expect((await b.named('Timed'))!.dueAt, at);
  });

  test('signing in to another account sends everything here to it', () async {
    await a.add('Ship');
    await a.sync.run();
    expect(await a.dirty(), 0);

    server.account = 'other';
    await a.sync.run();
    expect(await a.dirty(), 0);
    expect((await server.pull(0, 500)).map((r) => r.table), contains('tasks'));
  });

  test('nothing is sent without an account', () async {
    await a.add('Ship');
    server.account = null;
    expect(await a.sync.run(), isFalse);
    expect(await a.dirty(), greaterThan(0));
  });

  group('attachments', () {
    const folder = '0a89f043-be94-4c3e-9d2b-5f1e2a3b4c5d';

    setUp(() => server.kept = FakeFiles());

    test('a file attached on one phone turns up on the other', () async {
      await a.attach('Receipt', folder, 'paid');
      await a.round();
      expect(server.kept!.kept.keys, [folder]);

      await b.round();
      expect(await b.copyOf(folder).readAsString(), 'paid');
      expect(
        b.files
            .listSync(recursive: true)
            .where((f) => f.path.endsWith('.part')),
        isEmpty,
      );
    });

    test('a file goes up once, and only after its row', () async {
      await a.attach('Receipt', folder, 'paid');
      expect(await server.pull(0, 500), isEmpty);
      await a.round();
      final made = server.kept!.kept[folder]!.$2;
      server.kept!.now = made.add(const Duration(minutes: 1));
      await a.round();
      expect(server.kept!.kept[folder]!.$2, made, reason: 'not sent again');
    });

    test('a file no task names goes from the server after a day', () async {
      final task = await a.attach('Receipt', folder, 'paid');
      await a.round();
      await a.db.update(task.copyWith(attachments: const []));
      await a.round();
      expect(server.kept!.kept, contains(folder), reason: 'a day to be named');

      final store = server.kept!;
      await a.sync.files.carry(
        store,
        now: DateTime.now().add(const Duration(days: 1, minutes: 1)),
      );
      expect(store.kept, isEmpty);
    });

    test('a file named anywhere but its own folder is left alone', () {
      Attachment named(String file) =>
          Attachment(file: file, name: 'x', mime: 'text/plain');
      expect(FileSync.keyOf(named('$folder/note.txt')), folder);
      expect(FileSync.keyOf(named('../databases/caldo.db')), isNull);
      expect(FileSync.keyOf(named('$folder/..')), isNull);
      expect(FileSync.keyOf(named('$folder/a/b')), isNull);
    });
  });
}

import 'dart:io';

import 'package:caldo/db/database.dart';
import 'package:caldo/db/sync_store.dart';
import 'package:caldo/mcp/book.dart';
import 'package:caldo/mcp/remote.dart';
import 'package:caldo/models/task.dart';
import 'package:caldo/services/file_sync.dart';
import 'package:caldo/services/sync.dart';

import 'fake_server.dart';

/// The MCP server's way into [server]: the same rows, as it sends them.
class FakeRemote implements Remote {
  final FakeServer server;

  /// Run inside the next push, as another device's write landing meanwhile.
  Future<void> Function()? meanwhile;

  FakeRemote(this.server);

  @override
  Future<void> push(List<ServerRow> rows) async {
    await server.push([for (final r in rows) SyncRow.fromJson(r.toJson())]);
    final then = meanwhile;
    meanwhile = null;
    await then?.call();
  }

  @override
  Future<List<ServerRow>> pull(int since, int page) async => [
    for (final r in await server.pull(since, page))
      ServerRow.fromJson({...r.toJson(), 'seq': r.seq}),
  ];
}

/// A phone, with its own database, synced with the same server.
class Phone {
  final AppDatabase db;
  late final Sync sync;

  Phone(String name, SyncServer server) : db = AppDatabase.named(name) {
    final files = Directory.systemTemp.createTempSync('caldo_mcp_files');
    sync = Sync(
      SyncStore(db),
      server: server,
      files: FileSync(db, dir: () => files.path),
    );
  }

  Future<void> round() => sync.run();

  Future<Task> named(String title) async {
    final rows = await (await db.database).query(
      'tasks',
      where: 'title = ?',
      whereArgs: [title],
    );
    return Task.fromMap(rows.single);
  }

  Future<int> count(String sql) async =>
      (await (await db.database).rawQuery(sql)).single.values.single as int;
}

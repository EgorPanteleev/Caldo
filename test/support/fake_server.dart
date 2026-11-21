import 'dart:io';
import 'dart:typed_data';

import 'package:caldo/db/sync_store.dart';
import 'package:caldo/services/file_sync.dart';
import 'package:caldo/services/sync.dart';

/// The server as `supabase/migrations/…_sync.sql` makes it, in memory: the
/// later edit of a row wins and is laid over it, and the edit that lost has
/// the winner handed back on the next pull.
class FakeServer extends SyncServer {
  @override
  String? account = 'me';

  /// Kept files, once a test gives the server somewhere to keep them.
  FakeFiles? kept;

  @override
  FileStore? get files => kept;

  final _rows =
      <String, ({Map<String, Object?>? data, int at, bool gone, int seq})>{};
  final _of = <String, ({String table, String uuid})>{};
  var _seq = 0;

  @override
  Future<void> push(List<SyncRow> rows) async {
    for (final r in rows) {
      final key = '$account/${r.table}/${r.uuid}';
      final held = _rows[key];
      _of[key] = (table: r.table, uuid: r.uuid);
      if (held == null || r.updatedAt >= held.at) {
        _rows[key] = (
          data: r.deleted ? null : {...?held?.data, ...?r.data},
          at: r.updatedAt,
          gone: r.deleted,
          seq: ++_seq,
        );
      } else {
        _rows[key] = (
          data: held.data,
          at: held.at,
          gone: held.gone,
          seq: ++_seq,
        );
      }
    }
  }

  @override
  Future<List<SyncRow>> pull(int since, int page) async {
    final mine =
        _rows.entries
            .where((e) => e.key.startsWith('$account/') && e.value.seq > since)
            .toList()
          ..sort((a, b) => a.value.seq.compareTo(b.value.seq));
    return [
      for (final e in mine.take(page))
        SyncRow(
          table: _of[e.key]!.table,
          uuid: _of[e.key]!.uuid,
          data: e.value.data,
          updatedAt: e.value.at,
          deleted: e.value.gone,
          seq: e.value.seq,
        ),
    ];
  }

  Map<String, Object?>? dataOf(String table, String uuid) =>
      _rows['$account/$table/$uuid']?.data;
}

/// The account's files, in memory, each with when it was put there.
class FakeFiles implements FileStore {
  final kept = <String, (Uint8List, DateTime)>{};
  var now = DateTime.now();

  @override
  Future<Map<String, DateTime>> list() async => {
    for (final MapEntry(:key, value: (_, made)) in kept.entries) key: made,
  };

  @override
  Future<void> put(String key, File file, String mime) async =>
      kept[key] = (await file.readAsBytes(), now);

  @override
  Future<Uint8List?> get(String key) async => kept[key]?.$1;

  @override
  Future<void> remove(List<String> keys) async => keys.forEach(kept.remove);
}

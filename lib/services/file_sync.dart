import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../db/database.dart';
import '../models/task.dart';
import 'attachments.dart';

/// The server turning one file down, as against not being reached: the
/// pass goes on to the next file.
class FileRefused implements Exception {
  final Object reason;

  const FileRefused(this.reason);

  @override
  String toString() => 'File refused: $reason';
}

/// Where the account's attachment files are kept on the server, each under
/// its key ([FileSync.keyOf]). Throws [FileRefused] for a file turned down.
abstract class FileStore {
  /// Every file kept, by key, with when it was put there.
  Future<Map<String, DateTime>> list();

  Future<void> put(String key, File file, String mime);

  /// The file under [key], or null when there is none.
  Future<Uint8List?> get(String key);

  Future<void> remove(List<String> keys);
}

/// The files attached to tasks, carried beside the rows that name them.
///
/// A row says which files a task has, and travels with the rest; the files
/// follow once the rows have gone, in a pass of their own: what is here and
/// not there goes up, what is named here and is there comes down. So a
/// file is never on the server before a row naming it, and nothing has to
/// be remembered of what was sent — the server's list says.
///
/// A file no task here names any more is taken off the server a day after
/// it was put there. Any device that had a row naming it has had a day to
/// send it; and one let go by mistake comes back — a task undone, or a
/// backup restored, names it again, and its copy here goes up anew.
class FileSync {
  final AppDatabase db;
  final String? Function() _dir;

  FileSync(this.db, {String? Function()? dir})
    : _dir = dir ?? (() => Attachments.instance.dir);

  /// The free tier's ceiling. A bigger file stays on the device it was
  /// attached on, and shows as missing elsewhere.
  static const largest = 50 * 1024 * 1024;

  static const _grace = Duration(days: 1);

  /// A file is the folder its copy sits in — a uuid made when it was
  /// attached — and the name it has in that folder. The uuid is the key.
  static final _shape = RegExp(
    r'^([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})/([^/\\]+)$',
  );

  /// The key [a] is kept under, or null for a file named in any other way
  /// — which, come from another device, could point anywhere on this one.
  static String? keyOf(Attachment a) {
    final m = _shape.firstMatch(a.file);
    if (m == null || m[2] == '.' || m[2] == '..') return null;
    return m[1];
  }

  /// Carries across what one side has and the other has not. Says whether
  /// anything came down. A file the server turns down is passed over and
  /// tried again next time; one too big is not tried at all.
  Future<bool> carry(FileStore store, {DateTime? now}) async {
    final dir = _dir();
    if (dir == null) return false;
    final named = <String, Attachment>{
      for (final task in await db.getBoard())
        for (final a in task.attachments) ?keyOf(a): a,
    };
    final there = await store.list();
    var fetched = false;
    for (final MapEntry(:key, value: a) in named.entries) {
      final file = File(p.join(dir, a.file));
      final here = await file.exists();
      try {
        if (here && !there.containsKey(key)) {
          if (await file.length() <= largest) {
            await store.put(key, file, a.mime);
          }
        } else if (!here && there.containsKey(key)) {
          final bytes = await store.get(key);
          if (bytes == null) continue;
          // Whole or not at all: a copy half written would show as there.
          await file.parent.create(recursive: true);
          final part = File('${file.path}.part');
          await part.writeAsBytes(bytes, flush: true);
          await part.rename(file.path);
          fetched = true;
        }
      } on FileSystemException {
        // Deleted from under the pass, or the disk is full; next time.
      } on FileRefused {
        // Next time too. Anything else — offline — ends the pass.
      }
    }
    final cutoff = (now ?? DateTime.now()).subtract(_grace);
    final unnamed = [
      for (final MapEntry(:key, value: made) in there.entries)
        if (!named.containsKey(key) && made.isBefore(cutoff)) key,
    ];
    if (unnamed.isNotEmpty) await store.remove(unnamed);
    return fetched;
  }
}

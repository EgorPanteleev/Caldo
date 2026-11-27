import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../db/database.dart';
import '../models/task.dart';
import '../utils/platform.dart';
import 'desktop.dart';

/// Where an attachment is taken from.
enum AttachFrom { photos, camera, files }

/// What a pick came back with: the copies made, and the names of any left
/// out for being too big.
class Picked {
  final List<Attachment> attached;
  final List<String> tooBig;
  final int unreadable;

  const Picked(this.attached, [this.tooBig = const [], this.unreadable = 0]);

  static const none = Picked([]);

  factory Picked.fromPlatform(Map<Object?, Object?>? answer) {
    if (answer == null) return none;
    return Picked(
      [
        for (final item in answer['attached'] as List? ?? const [])
          ?Attachment.fromJson(item),
      ],
      [for (final name in answer['tooBig'] as List? ?? const []) '$name'],
      answer['unreadable'] as int? ?? 0,
    );
  }
}

enum GalleryAccess { unsupported, none, partial, full }

typedef GalleryPhoto = ({String id, String name});
typedef GalleryPage = ({
  GalleryAccess access,
  List<GalleryPhoto> photos,
  bool more,
});

/// The files and photos attached to tasks: picked through Android's own
/// pickers or taken with the camera, copied into Caldo's own storage, and
/// opened in whatever app on the phone reads them (the `caldo/attachments`
/// channel, `Attachments.kt`). On a desktop the same is done from here
/// (`Desktop`), with the system's file dialog for a picker and no camera.
///
/// A copy is kept rather than a link to the original. A picked document's
/// link lasts only as long as the grant that came with it, the photo
/// picker's for the life of the app that asked, and an original can be
/// moved or deleted from under it; the copy is the task's own.
///
/// Nothing deletes a copy when a task lets go of it. Undo writes a task back
/// as it was, attachments and all, and a task closed with its form cancelled
/// leaves copies nothing will ever refer to; the ones no task refers to are
/// swept up on the next start instead ([sweep]), as the alarms are rebuilt
/// from the agenda rather than kept in step by hand.
class Attachments {
  Attachments._();
  static final Attachments instance = Attachments._();

  static const _channel = MethodChannel('caldo/attachments');

  /// The directory the copies are kept in, once Android has said where that
  /// is ([enable]) or a test has.
  String? dir;

  /// Asks Android where the copies are kept. Called from `main` and nowhere
  /// else, so a widget test, which nothing on the platform side answers,
  /// draws every attachment as missing rather than throwing.
  Future<void> enable() async {
    dir = onDesktop
        ? Desktop.attachments
        : await _channel.invokeMethod<String>('dir');
  }

  /// The copy of [a], or null when there is nowhere to look.
  File? fileOf(Attachment a) {
    final d = dir;
    return d == null ? null : File(p.join(d, a.file));
  }

  /// Whether [a]'s copy is on this phone. A task restored from a backup
  /// made elsewhere names files that never came with it.
  bool has(Attachment a) => fileOf(a)?.existsSync() ?? false;

  /// Has the user pick photos or files, or take a photo, and copies them in.
  /// Nothing comes back when they back out.
  Future<Picked> pick(AttachFrom from) async {
    if (onDesktop) {
      // The system's file dialog, and the copying done here: a path on a
      // desktop needs no grant to be read.
      final paths = await Desktop.pickFiles(images: from == AttachFrom.photos);
      final copied = await Desktop.attach(paths, into: dir);
      return Picked(copied.attached, copied.tooBig);
    }
    return Picked.fromPlatform(
      await _ask<Map<Object?, Object?>>('pick', {'from': from.name}),
    );
  }

  Future<GalleryPage?> galleryPage(int offset) async {
    final page = await _ask<Map<Object?, Object?>>('galleryPage', {
      'offset': offset,
    });
    if (page == null) return null;
    return (
      access: GalleryAccess.values.byName(page['access'] as String),
      photos: [
        for (final photo in page['photos'] as List)
          (id: photo['id'] as String, name: photo['name'] as String),
      ],
      more: page['more'] as bool,
    );
  }

  Future<void> requestGalleryAccess() => _ask<void>('galleryAccess');

  Future<Uint8List?> thumbnailOf(GalleryPhoto photo, int side) =>
      _ask<Uint8List>('galleryThumbnail', {'id': photo.id, 'side': side});

  Future<Picked> pickFromGallery(List<String> ids) async => Picked.fromPlatform(
    await _ask<Map<Object?, Object?>>('galleryPick', {'ids': ids}),
  );

  Future<T?> _ask<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Opens [a] in whatever app on the phone reads its type. False when
  /// there is none, or the copy is not here.
  Future<bool> open(Attachment a) async {
    if (onDesktop) {
      final file = fileOf(a);
      return file != null && file.existsSync() && await Desktop.open(file.path);
    }
    try {
      return await _channel.invokeMethod<bool>('open', {
            'file': a.file,
            'mime': a.mime,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Deletes every copy no task refers to.
  Future<void> sweep() async {
    if (dir == null) return;
    await sweepAgainst(await AppDatabase.instance.getBoard());
  }

  /// Deletes the copies in [dir] that none of [tasks] refers to, unless
  /// made within the last hour: one picked into a form still open — or
  /// open when Android put the app away to show the picker or the camera —
  /// belongs to no task yet.
  Future<void> sweepAgainst(Iterable<Task> tasks, {DateTime? now}) async {
    final d = dir;
    if (d == null) return;
    final folder = Directory(d);
    if (!await folder.exists()) return;
    final kept = {
      for (final t in tasks)
        for (final a in t.attachments) a.file,
    };
    final cutoff = (now ?? DateTime.now()).subtract(const Duration(hours: 1));
    // Each copy is in a folder of its own (see `Attachments.kt`), which
    // goes with it.
    final folders = <Directory>[];
    await for (final entry in folder.list(recursive: true)) {
      if (entry is Directory) folders.add(entry);
      if (entry is! File || kept.contains(p.relative(entry.path, from: d))) {
        continue;
      }
      try {
        if ((await entry.lastModified()).isBefore(cutoff)) {
          await entry.delete();
        }
      } on FileSystemException {
        // Gone already, or not ours to delete; the next start tries again.
      }
    }
    for (final emptied in folders.reversed) {
      try {
        if (await emptied.list().isEmpty) await emptied.delete();
      } on FileSystemException {
        // As above.
      }
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_selector_linux/file_selector_linux.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_linux/path_provider_linux.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/task.dart';

/// What the activity does for the app on a phone, done on a desktop by the
/// app itself: where its files are kept, the system's dialogs for picking
/// and saving one, and handing a file to whatever program reads it.
///
/// On Android each of these is a channel answered in Kotlin, because each
/// needs an activity — a picker's result comes back to one, a file is
/// served to another app through a provider. A desktop has none of that in
/// the way: a path is a path, so the services ask here instead
/// (`onDesktop`), and the Linux runner stays the template's but for its
/// window.
class Desktop {
  Desktop._();

  /// Where Caldo keeps what it holds: the database, the attachments and,
  /// through `shared_preferences`, the settings — `~/.local/share/` and the
  /// application's id, unless XDG says otherwise.
  static String? _data;
  static String? _cache;

  static final _dialogs = FileSelectorLinux();

  /// Finds the directories and points sqflite at them. Before anything
  /// reads a task: sqflite has no Linux side of its own, and without this
  /// the first read has nothing to answer it.
  static Future<void> start() async {
    final paths = PathProviderLinux();
    _data = await paths.getApplicationSupportPath();
    _cache = await paths.getApplicationCachePath();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.setDatabasesPath(_data!);
  }

  /// The directory the attachments' copies are kept in.
  static String get attachments => p.join(_data!, 'attachments');

  /// Where an update is downloaded to.
  static String get updates => p.join(_cache!, 'updates');

  /// The directory the program was installed as: the executable, and
  /// beside it the libraries and data it was built with.
  static String get bundle => p.dirname(Platform.resolvedExecutable);

  /// The version this build was labelled with, which Flutter writes beside
  /// the app's assets; null if it cannot be read.
  static Future<String?> version() async {
    try {
      final file = File(p.join(bundle, 'data/flutter_assets/version.json'));
      final json = jsonDecode(await file.readAsString());
      return json is Map ? json['version'] as String? : null;
    } on Object {
      return null;
    }
  }

  /// The icon installed beside the program, for a notification to wear;
  /// null when it is not there, as under `flutter run`.
  static String? get icon {
    final file = File(p.join(bundle, 'data/caldo.png'));
    return file.existsSync() ? file.path : null;
  }

  static const _images = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'];

  /// Has the user pick files — images only for [images] — and gives back
  /// where they are. Empty when they back out.
  static Future<List<String>> pickFiles({required bool images}) async {
    final picked = await _dialogs.openFiles(
      acceptedTypeGroups: [
        if (images) const XTypeGroup(label: 'Images', extensions: _images),
      ],
    );
    return [for (final file in picked) file.path];
  }

  /// The largest file an attachment may be, as on a phone.
  static const attachmentLimit = 100 * 1024 * 1024;

  /// Copies the files at [paths] into the attachments, each into a folder
  /// of its own under the name it came with, and says which were left out
  /// for being too big. One that cannot be read is left out without a
  /// word; the rest go in.
  static Future<({List<Attachment> attached, List<String> tooBig})> attach(
    List<String> paths, {
    String? into,
    int limit = attachmentLimit,
  }) async {
    final dir = into ?? attachments;
    final attached = <Attachment>[];
    final tooBig = <String>[];
    for (final path in paths) {
      final name = p.basename(path);
      try {
        final source = File(path);
        final size = await source.length();
        if (size > limit) {
          tooBig.add(name);
          continue;
        }
        final folder = Directory(p.join(dir, _uuid()));
        await folder.create(recursive: true);
        final copy = await source.copy(p.join(folder.path, _safe(name)));
        attached.add(
          Attachment(
            file: p.relative(copy.path, from: dir),
            name: name,
            mime: mimeOf(name),
            size: size,
          ),
        );
      } on FileSystemException {
        // Gone, or not ours to read.
      }
    }
    return (attached: attached, tooBig: tooBig);
  }

  /// A name a copy can be kept under: "." and ".." would name the folder
  /// itself, or the one above it.
  static String _safe(String name) {
    final safe = name.replaceAll(RegExp(r'[/\\\x00]'), '_').trim();
    final cut = safe.length > 120 ? safe.substring(0, 120) : safe;
    return cut.isEmpty || cut == '.' || cut == '..' ? 'file' : cut;
  }

  static String _uuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')];
    return [
      hex.sublist(0, 4).join(),
      hex.sublist(4, 6).join(),
      hex.sublist(6, 8).join(),
      hex.sublist(8, 10).join(),
      hex.sublist(10).join(),
    ].join('-');
  }

  /// A file's type, from its name. Only the images Flutter can draw are
  /// called images: the form draws those as thumbnails, and one it could
  /// not decode would be a broken tile rather than a file with a name.
  static String mimeOf(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' || 'gif' || 'webp' || 'bmp' => 'image/$ext',
      'pdf' => 'application/pdf',
      'txt' || 'log' => 'text/plain',
      'md' => 'text/markdown',
      'html' || 'htm' => 'text/html',
      'csv' => 'text/csv',
      'json' => 'application/json',
      'zip' => 'application/zip',
      'mp3' => 'audio/mpeg',
      'mp4' => 'video/mp4',
      _ => 'application/octet-stream',
    };
  }

  /// Opens the file or address at [target] in whatever program the desktop
  /// has for it. False when there is none, or nothing to ask.
  ///
  /// `xdg-open` answers once it has handed the file on, on every desktop
  /// that has a way to; where it has none of its own it runs the program
  /// itself and only returns when that is closed, so it is given a moment
  /// and then taken to have worked.
  static Future<bool> open(String target) async {
    try {
      final process = await Process.start('xdg-open', [target]);
      // Nothing reads what it prints; left unread, a full pipe would stop it.
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      final code = await process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () => 0,
      );
      return code == 0;
    } on ProcessException {
      return false;
    }
  }

  static const _json = XTypeGroup(label: 'JSON', extensions: ['json']);

  /// Has the user say where [text] is saved, offering [name], and saves it
  /// there. False if they back out.
  static Future<bool> saveText(String name, String text) async {
    final place = await _dialogs.getSaveLocation(
      acceptedTypeGroups: const [_json],
      options: SaveDialogOptions(suggestedName: name),
    );
    if (place == null) return false;
    await File(place.path).writeAsString(text, flush: true);
    return true;
  }

  /// The most a file picked to be read back may hold, as on a phone.
  static const readLimit = 64 * 1024 * 1024;

  /// Has the user pick a file and reads it as text, or null if they back
  /// out.
  static Future<String?> openText() async {
    final picked = await _dialogs.openFile(
      acceptedTypeGroups: const [
        _json,
        XTypeGroup(label: '*'),
      ],
    );
    if (picked == null) return null;
    final file = File(picked.path);
    if (await file.length() > readLimit) {
      throw FileSystemException('too large to be a backup', picked.path);
    }
    // Whatever it holds: a file that is not text reads as nonsense, and is
    // then said to be no backup, which is truer than "could not be read".
    return utf8.decode(await file.readAsBytes(), allowMalformed: true);
  }

  /// Has the user pick a folder, or null if they back out.
  static Future<String?> pickFolder() => _dialogs.getDirectoryPath();

  /// A path as it is written for someone to read: from `~` where it is
  /// under their home. A folder's own name, which is what a phone shows,
  /// says too little here — every other one is called "Backups".
  static String shown(String path, {String? home}) {
    home ??= Platform.environment['HOME'];
    if (home == null || home.isEmpty) return path;
    if (path == home) return '~';
    return p.isWithin(home, path)
        ? p.join('~', p.relative(path, from: home))
        : path;
  }

  /// Writes [text] into [folder] as [name], and then deletes all but the
  /// latest [keep] of the files there starting with [prefix]. Their names
  /// carry the date, so the latest sort last; a file of any other name is
  /// never touched. A folder that has gone is not made again: the user
  /// chose a place, and one made in its stead is not it.
  static Future<void> writeInto(
    String folder,
    String name,
    String prefix,
    String text,
    int keep,
  ) async {
    final dir = Directory(folder);
    if (!await dir.exists()) {
      throw FileSystemException('no such folder', folder);
    }
    await File(p.join(folder, name)).writeAsString(text, flush: true);
    final ours = <String>[];
    await for (final entry in dir.list()) {
      final child = p.basename(entry.path);
      if (entry is File &&
          child.startsWith(prefix) &&
          child.endsWith('.json')) {
        ours.add(child);
      }
    }
    ours.sort();
    for (final old in ours.take(max(0, ours.length - keep))) {
      await File(p.join(folder, old)).delete();
    }
  }

  /// Whether the installed program can be replaced by the user it runs as:
  /// one unpacked under their home can, one a package manager put under
  /// `/usr` or `/opt` cannot.
  static bool get replaceable {
    final parent = Directory(bundle).parent.path;
    final probe = File(p.join(parent, '.caldo-${pid}_probe'));
    try {
      probe.createSync();
      probe.deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Unpacks the release in [archive] over the installed program and
  /// starts the new one in this one's place.
  ///
  /// The new program is unpacked beside the old and the two swapped by
  /// name, so there is no moment with half of each: the directory the
  /// running program was started from goes on existing under its old name
  /// until it is deleted, which Linux allows of files in use.
  static Future<void> replaceWith(String archive) async {
    final installed = Directory(bundle);
    final parent = installed.parent.path;
    final staging = Directory(p.join(parent, '.caldo-update-$pid'));
    final old = Directory(p.join(parent, '.caldo-old-$pid'));
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create();
    try {
      final unpack = await Process.run('tar', [
        '-xzf',
        archive,
        '-C',
        staging.path,
      ]);
      // The archive holds one directory, the program's.
      final fresh = Directory(p.join(staging.path, 'caldo'));
      if (unpack.exitCode != 0 ||
          !await File(p.join(fresh.path, 'caldo')).exists()) {
        throw FileSystemException('not a release of Caldo', archive);
      }
      await installed.rename(old.path);
      try {
        await fresh.rename(installed.path);
      } on FileSystemException {
        await old.rename(installed.path);
        rethrow;
      }
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
    await old.delete(recursive: true);
    // Unpacked, the download is twenty megabytes of what is now installed.
    try {
      await File(archive).delete();
    } on FileSystemException {
      // Left for the next update to clear out.
    }
    // A beat after this one has gone, not at once: only one Caldo runs at
    // a time, and one started while this is still here would hand over to
    // it and leave, and then this would leave too.
    await Process.start('sh', [
      '-c',
      'sleep 1; exec "\$0"',
      Platform.resolvedExecutable,
    ], mode: ProcessStartMode.detached);
    exit(0);
  }
}

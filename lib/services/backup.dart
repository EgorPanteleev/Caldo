import 'dart:convert';

import 'package:flutter/services.dart';

import '../db/database.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';

/// Why a file could not be restored.
enum BackupProblem {
  /// Not a backup of Caldo's at all, or one cut short.
  notCaldo,

  /// Written by a Caldo whose database has columns this one does not know.
  newer,

  /// Android could not read or write the file.
  unreadable,
}

class BackupException implements Exception {
  final BackupProblem problem;
  const BackupException(this.problem);

  @override
  String toString() => 'BackupException(${problem.name})';
}

/// A copy of everything Caldo holds — the groups, the tasks, the log of
/// ticks and the settings — as one file the user keeps somewhere else.
///
/// Caldo keeps nothing anywhere but the phone, so without this a lost phone,
/// or an update that has to be installed by uninstalling first, takes every
/// task with it. The file is JSON of the database's own rows rather than of
/// the models, so a column added later is carried without anyone remembering
/// to add it here, and an older file restores into a newer schema by leaving
/// the new columns to their defaults.
///
/// It is written and read through Android's own document picker (the
/// `caldo/backup` channel in `MainActivity`), which can put it on Drive or
/// in Downloads and needs no storage permission. The automatic ones go
/// into a folder picked the same way once, which Caldo is let keep writing
/// into ([autoIfDue]).
class Backup {
  /// When the backup was taken.
  final DateTime savedAt;

  /// The database version the rows were written under.
  final int schema;
  final Map<String, List<Map<String, Object?>>> tables;
  final Map<String, Object?> settings;

  const Backup({
    required this.savedAt,
    required this.schema,
    required this.tables,
    required this.settings,
  });

  /// The shape of the file itself, apart from the rows in it.
  static const format = 1;

  static const _channel = MethodChannel('caldo/backup');

  int get taskCount => tables['tasks']?.length ?? 0;
  int get groupCount => tables['lists']?.length ?? 0;

  /// What is in Caldo now.
  static Future<Backup> take({DateTime? now}) async => Backup(
    savedAt: now ?? DateTime.now(),
    schema: AppDatabase.schema,
    tables: await AppDatabase.instance.dump(),
    settings: await SettingsProvider.exported(),
  );

  String encode() => jsonEncode({
    'app': 'caldo',
    'format': format,
    'schema': schema,
    'savedAt': savedAt.millisecondsSinceEpoch,
    'tables': tables,
    'settings': settings,
  });

  /// Reads a backup back from [text], or says why it cannot be restored.
  static Backup decode(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const BackupException(BackupProblem.notCaldo);
    }
    if (json is! Map ||
        json['app'] != 'caldo' ||
        json['schema'] is! int ||
        json['savedAt'] is! int ||
        json['tables'] is! Map) {
      throw const BackupException(BackupProblem.notCaldo);
    }
    final schema = json['schema'] as int;
    if (schema > AppDatabase.schema || (json['format'] as int? ?? 0) > format) {
      throw const BackupException(BackupProblem.newer);
    }
    final tables = <String, List<Map<String, Object?>>>{};
    for (final table in AppDatabase.backedUp) {
      final rows = (json['tables'] as Map)[table];
      if (rows == null) continue;
      if (rows is! List || rows.any((r) => r is! Map)) {
        throw const BackupException(BackupProblem.notCaldo);
      }
      tables[table] = [
        for (final row in rows) Map<String, Object?>.from(row as Map),
      ];
    }
    // Every task names a group and the oldest one is the default; a file
    // with none is not a backup anything could be read back from.
    if (tables['lists']?.isEmpty ?? true) {
      throw const BackupException(BackupProblem.notCaldo);
    }
    return Backup(
      savedAt: DateTime.fromMillisecondsSinceEpoch(json['savedAt'] as int),
      schema: schema,
      tables: tables,
      settings: Map<String, Object?>.from(json['settings'] as Map? ?? const {}),
    );
  }

  /// Takes a backup and has the user put it somewhere. False if they
  /// backed out of choosing where.
  static Future<bool> save(SettingsProvider settings) async {
    final backup = await take();
    final day = backup.savedAt.toIso8601String().substring(0, 10);
    final bool? saved;
    try {
      saved = await _channel.invokeMethod<bool>('save', {
        'name': 'caldo-$day.json',
        'text': backup.encode(),
      });
    } on PlatformException {
      throw const BackupException(BackupProblem.unreadable);
    }
    if (saved != true) return false;
    await settings.backedUp(backup.savedAt);
    return true;
  }

  /// What the automatic backups are called, ahead of their date. Kept apart
  /// from a saved one's name so that clearing out the old ones can never
  /// take a file the user saved by hand into the same folder.
  static const autoPrefix = 'caldo-auto-';

  /// How many automatic backups are left in the folder: a week of them
  /// daily, about two months weekly. Each is a few hundred kilobytes.
  static const autoKept = 7;

  /// One automatic backup at a time: the app can come back to the front
  /// while the last one is still being written.
  static bool _writing = false;

  /// Has the user pick a folder for the automatic backups and lets Caldo
  /// keep writing into it, or null if they backed out.
  static Future<({String uri, String name})?> chooseFolder() async {
    final Map<Object?, Object?>? folder;
    try {
      folder = await _channel.invokeMapMethod<Object?, Object?>('folder');
    } on PlatformException {
      throw const BackupException(BackupProblem.unreadable);
    }
    if (folder == null) return null;
    return (uri: folder['uri'] as String, name: folder['name'] as String);
  }

  /// Whether a backup taken every [every] days, the last at [last], is due
  /// again at [now]. Counted in days on the calendar, so a daily one is
  /// due on the first opening of each day rather than 24 hours after the
  /// last.
  static bool due(int every, DateTime? last, DateTime now) {
    if (every <= 0) return false;
    if (last == null) return true;
    // In UTC, so a clock change between the two is not an hour short of a
    // day.
    final from = DateTime.utc(last.year, last.month, last.day);
    final to = DateTime.utc(now.year, now.month, now.day);
    return to.difference(from).inDays >= every;
  }

  /// Saves a backup into the chosen folder if one is due, or at once when
  /// [now] is asked for — a folder just chosen should have one in it.
  ///
  /// Asked on opening and on every return to the app, rather than by a job
  /// in the background: nothing changes while Caldo is shut but what a
  /// reminder's buttons or the widget's ticks do, and those are in the next
  /// one. A copy that cannot be written is said in Settings and tried again
  /// on the next return.
  static Future<void> autoIfDue(
    SettingsProvider settings, {
    bool now = false,
  }) async {
    if (_writing) return;
    final plan = await SettingsProvider.storedAutoBackup();
    final folder = plan.folder;
    if (folder == null || plan.every <= 0) return;
    if (!now && !due(plan.every, plan.last, DateTime.now())) return;
    _writing = true;
    try {
      final backup = await take();
      final day = backup.savedAt.toIso8601String().substring(0, 10);
      await _channel.invokeMethod<bool>('write', {
        'folder': folder,
        'name': '$autoPrefix$day.json',
        'prefix': autoPrefix,
        'text': backup.encode(),
        'keep': autoKept,
      });
      await settings.autoBackedUp(backup.savedAt);
    } on PlatformException {
      await settings.autoBackupNotSaved();
    } finally {
      _writing = false;
    }
  }

  /// Has the user pick a backup and reads it, or null if they backed out.
  /// Nothing is restored yet: that waits for them to see what is in it.
  static Future<Backup?> open() async {
    final String? text;
    try {
      text = await _channel.invokeMethod<String>('open');
    } on PlatformException {
      throw const BackupException(BackupProblem.unreadable);
    }
    return text == null ? null : decode(text);
  }

  /// Replaces everything in Caldo with this backup and reads it all back,
  /// the alarms and the home-screen widget with it. The settings go first,
  /// so the alarms are set again in the language and on the clock the
  /// backup chose.
  Future<void> restore(SettingsProvider settings, TaskProvider tasks) async {
    await AppDatabase.instance.replaceAll(tables);
    await settings.restore(this.settings);
    tasks.setShowCompleted(settings.showCompleted);
    await tasks.reloadRestored();
  }
}

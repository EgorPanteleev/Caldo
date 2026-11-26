import 'dart:math';

import '../models/task.dart';

/// One row as the server keeps it (`supabase/migrations/…_sync.sql`): a
/// device's row without its local id, ids pointing at other rows turned
/// into uuids. The same JSON as the app's `SyncRow`, which sits beside
/// sqflite and so cannot be used here.
class ServerRow {
  final String table;
  final String uuid;

  /// Null for a deletion.
  final Map<String, Object?>? data;

  /// When whoever wrote it last changed it, in epoch millis.
  final int updatedAt;
  final bool deleted;

  /// The server's count when it was written; 0 on the way up.
  final int seq;

  const ServerRow({
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

  factory ServerRow.fromJson(Map<String, Object?> json) => ServerRow(
    table: json['tbl'] as String,
    uuid: json['uuid'] as String,
    data: (json['data'] as Map?)?.cast<String, Object?>(),
    updatedAt: (json['updated_at'] as num).toInt(),
    deleted: json['deleted'] as bool? ?? false,
    seq: (json['seq'] as num?)?.toInt() ?? 0,
  );
}

/// A group, as the sync carries it.
class Group {
  final String uuid;
  final String name;
  final String styleId;
  final int createdAt;
  final int? sortOrder;

  const Group({
    required this.uuid,
    required this.name,
    required this.styleId,
    required this.createdAt,
    this.sortOrder,
  });
}

/// A task with the uuids it is known by: its own, its group's and its
/// parent's, if it is a subtask ([Task.parentId] is a device's own). The
/// [task] is Caldo's own model, so a tick, a roll-on or a move to the board
/// here is the app's, not a copy that could come to disagree with it.
class Held {
  final String uuid;
  final String group;
  final Task task;
  final String? parent;

  const Held(this.uuid, this.group, this.task, {this.parent});

  /// The short id a task is shown and asked for by.
  String get id => uuid.substring(0, 8);
}

/// A tick in the Done log.
class Tick {
  final String uuid;
  final String? task;
  final String? group;
  final String title;
  final int doneAt;

  const Tick(this.uuid, this.task, this.group, this.title, this.doneAt);
}

/// A birthday, anniversary or other day that comes back every year.
class Yearly {
  final String uuid;
  final String name;
  final String kind;
  final int month;
  final int day;
  final int? year;

  const Yearly(
    this.uuid,
    this.name,
    this.kind,
    this.month,
    this.day,
    this.year,
  );

  String get id => uuid.substring(0, 8);

  /// The day it falls on in [year]; the 29th of February on the 28th when
  /// there is none, as the app has it.
  DateTime inYear(int year) {
    final last = DateTime(year, month + 1, 0).day;
    return DateTime(year, month, day > last ? last : day);
  }
}

/// Everything the account holds on the server, as of the last pull.
///
/// The server's copy is the one to go by: it is what every device has
/// agreed on, each row the latest edit of it. So the book only ever takes
/// rows as they come down, and what is written goes up first and is read
/// back in the next pull — never written here ahead of the server.
class Book {
  /// The uuid the default group has on every device (`AppDatabase`'s
  /// `defaultListUuid`, which sits beside sqflite).
  static const homeUuid = '00000000-0000-4000-8000-000000000001';

  final _rows = <String, Map<String, ServerRow>>{};

  /// The server's count pulled up to.
  int cursor = 0;

  void take(Iterable<ServerRow> rows) {
    for (final r in rows) {
      _rows.putIfAbsent(r.table, () => {})[r.uuid] = r;
      cursor = max(cursor, r.seq);
    }
  }

  ServerRow? row(String table, String uuid) => _rows[table]?[uuid];

  Iterable<ServerRow> _live(String table) =>
      (_rows[table]?.values ?? const <ServerRow>[]).where(
        (r) => !r.deleted && r.data != null,
      );

  /// The groups in the order the chip row shows them: placed by hand
  /// first, the rest as they were made.
  List<Group> get groups {
    final all = [
      for (final r in _live('lists'))
        Group(
          uuid: r.uuid,
          name: r.data!['name'] as String? ?? '',
          styleId: r.data!['style_id'] as String? ?? 'violet',
          createdAt: _int(r.data!['created_at']) ?? 0,
          sortOrder: _int(r.data!['sort_order']),
        ),
    ];
    return all..sort((a, b) {
      final placed = (a.sortOrder == null ? 1 : 0).compareTo(
        b.sortOrder == null ? 1 : 0,
      );
      if (placed != 0) return placed;
      final order = (a.sortOrder ?? 0).compareTo(b.sortOrder ?? 0);
      if (order != 0) return order;
      return a.createdAt.compareTo(b.createdAt);
    });
  }

  /// The default group, where a task with none goes: the one every device
  /// shares, or else the oldest, as `SyncStore` picks it.
  Group? get home {
    final all = groups;
    if (all.isEmpty) return null;
    return all.where((g) => g.uuid == homeUuid).firstOrNull ??
        (all.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt)))
            .first;
  }

  Group? group(String uuid) => groups.where((g) => g.uuid == uuid).firstOrNull;

  List<Held> get tasks => [
    for (final r in _live('tasks'))
      Held(
        r.uuid,
        _groupOf(r.data!),
        taskOf(r.data!),
        parent: r.data!['parent_uuid'] as String?,
      ),
  ];

  /// The tasks [held] sits under, the outermost first; a parent deleted
  /// ends the line there.
  List<Held> parentsOf(Held held) {
    final all = {for (final h in tasks) h.uuid: h};
    final line = <Held>[];
    final seen = {held.uuid};
    var above = all[held.parent];
    while (above != null && seen.add(above.uuid)) {
      line.insert(0, above);
      above = all[above.parent];
    }
    return line;
  }

  /// The tasks right under [held], in the order they were made.
  List<Held> subtasksOf(Held held) => [
    for (final h in tasks)
      if (h.parent == held.uuid) h,
  ]..sort((a, b) => a.task.createdAt.compareTo(b.task.createdAt));

  /// A task's group; one that has gone reads as the default, where a device
  /// pulling it would put it.
  String _groupOf(Map<String, Object?> data) {
    final named = data['list_uuid'] as String?;
    if (named != null && row('lists', named)?.deleted == false) return named;
    return home?.uuid ?? homeUuid;
  }

  List<Tick> get ticks => [
    for (final r in _live('completions'))
      Tick(
        r.uuid,
        r.data!['task_uuid'] as String?,
        r.data!['list_uuid'] as String?,
        r.data!['title'] as String? ?? '',
        _int(r.data!['done_at']) ?? 0,
      ),
  ];

  List<Yearly> get yearly => [
    for (final r in _live('special_days'))
      if (_int(r.data!['month']) case final month?)
        if (_int(r.data!['day']) case final day?)
          Yearly(
            r.uuid,
            r.data!['name'] as String? ?? '',
            r.data!['kind'] as String? ?? 'other',
            month,
            day,
            _int(r.data!['year']),
          ),
  ];

  /// The task a row holds, read the way a device reads it after a pull: an
  /// all-day task's day ("2026-11-16") as this computer's midnight.
  static Task taskOf(Map<String, Object?> data) {
    final due = data['due_at'];
    return Task.fromMap({
      for (final MapEntry(:key, :value) in data.entries) key: _plain(value),
      'id': null,
      'list_id': 0,
      'parent_id': null,
      'due_at': due is String
          ? DateTime.tryParse(due)?.millisecondsSinceEpoch
          : _int(due),
    });
  }

  /// What the server keeps of [task] in [group]: the task's columns but its
  /// local id, its group by uuid, an all-day task's due date as its day.
  static Map<String, Object?> dataOf(Task task, String group) {
    final data = task.toMap()
      ..remove('id')
      ..remove('list_id')
      // A device's own id; the server's link is `parent_uuid`.
      ..remove('parent_id');
    data['list_uuid'] = group;
    final due = data['due_at'];
    if (!task.hasTime && due is int) {
      final day = DateTime.fromMillisecondsSinceEpoch(due);
      data['due_at'] =
          '${day.year.toString().padLeft(4, '0')}-'
          '${day.month.toString().padLeft(2, '0')}-'
          '${day.day.toString().padLeft(2, '0')}';
    }
    return data;
  }

  /// JSON numbers come back as doubles now and then; the models read ints.
  static Object? _plain(Object? value) =>
      value is double && value == value.roundToDouble() ? value.toInt() : value;

  static int? _int(Object? value) => value is num ? value.toInt() : null;
}

/// A random (version 4) uuid, as the app's triggers make them.
String newUuid([Random? random]) {
  final r = random ?? Random.secure();
  final b = [for (var i = 0; i < 16; i++) r.nextInt(256)];
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

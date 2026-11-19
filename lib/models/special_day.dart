import 'package:flutter/material.dart';

import 'task_list.dart';

/// What a special day is, which says what its card calls it and how its
/// years are counted: a birthday turns an age, an anniversary is a number
/// of years, and anything else just comes round again.
enum SpecialKind { birthday, anniversary, other }

/// A day of the user's own that comes back every year — a birthday, an
/// anniversary — shown beside the tasks the way a public holiday is.
///
/// Kept as a month and a day, with the year it began only when it is
/// known: a birthday whose year nobody knows is still a birthday, it just
/// turns no age.
class SpecialDay {
  final int? id;
  final String name;
  final SpecialKind kind;
  final int month;
  final int day;

  /// The year it began, for counting the years; null when not known.
  final int? year;

  /// Its colour, a palette id or `#RRGGBB` as a task's is.
  final String styleId;

  /// Whether it is announced on the day, at the hour all-day tasks are.
  final bool remind;
  final int createdAt;

  const SpecialDay({
    this.id,
    required this.name,
    this.kind = SpecialKind.birthday,
    required this.month,
    required this.day,
    this.year,
    this.styleId = 'pink',
    this.remind = true,
    this.createdAt = 0,
  });

  Color get color => ListStyle.byId(styleId).color;

  IconData get icon => switch (kind) {
    SpecialKind.birthday => Icons.cake_outlined,
    SpecialKind.anniversary => Icons.favorite_outline,
    SpecialKind.other => Icons.star_outline,
  };

  /// The day it falls on in [year]. The 29th of February falls on the
  /// 28th when there is no 29th: a birthday a leap day took is still
  /// kept in the month it belongs to.
  DateTime inYear(int year) {
    final last = DateTime(year, month + 1, 0).day;
    return DateTime(year, month, day > last ? last : day);
  }

  /// The next time it falls, [from] (a day) included.
  DateTime nextFrom(DateTime from) {
    final here = inYear(from.year);
    return here.isBefore(from) ? inYear(from.year + 1) : here;
  }

  /// How many years it has been on its day in [year] — the age turned, or
  /// the anniversary's number. Null with no year, or none yet.
  int? yearsIn(int year) {
    final since = this.year;
    if (since == null || year <= since) return null;
    return year - since;
  }

  SpecialDay copyWith({
    int? id,
    String? name,
    SpecialKind? kind,
    int? month,
    int? day,
    int? year,
    bool clearYear = false,
    String? styleId,
    bool? remind,
  }) => SpecialDay(
    id: id ?? this.id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    month: month ?? this.month,
    day: day ?? this.day,
    year: clearYear ? null : (year ?? this.year),
    styleId: styleId ?? this.styleId,
    remind: remind ?? this.remind,
    createdAt: createdAt,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'month': month,
    'day': day,
    'year': year,
    'style_id': styleId,
    'remind': remind ? 1 : 0,
    'created_at': createdAt,
  };

  /// A kind this version does not know — written by a newer one — reads
  /// as "other" rather than failing the whole list.
  factory SpecialDay.fromMap(Map<String, Object?> map) => SpecialDay(
    id: map['id'] as int?,
    name: map['name'] as String? ?? '',
    kind: SpecialKind.values.asNameMap()[map['kind']] ?? SpecialKind.other,
    month: map['month'] as int,
    day: map['day'] as int,
    year: map['year'] as int?,
    styleId: map['style_id'] as String? ?? 'pink',
    remind: (map['remind'] as int? ?? 1) != 0,
    createdAt: map['created_at'] as int? ?? 0,
  );
}

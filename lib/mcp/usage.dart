/// What a chat has spent and where it stands, in one shape for every
/// agent: kept by the worker as the chat's `usage` (a JSON object) and said
/// on its channel as it changes; drawn by the app over the chat.
///
/// A talk reports two sorts of figure ([merged]): those that are as they
/// are now (the model, how full its context is, the account's limits),
/// laid over what was known; and those of one turn or one request (tokens,
/// cost, time), added to the chat's totals. Its program's own totals start
/// again with each program, and a chat outlives its programs; so the
/// totals are the chat's, and the program only says what it adds.
class ChatUsage {
  final String? model;

  /// Tokens the latest request took in and gave out: how full the context
  /// is.
  final int? context;

  /// How many the model's context holds, when the agent says.
  final int? window;

  /// The chat's tokens: taken in fresh, given out, read from the cache,
  /// written to it.
  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;

  /// In US dollars, at the API's list price, as Claude reckons it; null
  /// for an agent that does not say (Codex).
  final double? cost;

  /// Turns answered, and how long the agent worked on them.
  final int turns;
  final Duration working;

  /// The account's limits, as last heard: the same for every chat with that
  /// agent on that account.
  final List<UsageLimit> limits;

  /// Whether the account may go on: `allowed`, `allowed_warning`,
  /// `rejected` (Claude's words).
  final String? limited;

  /// When the limits were heard.
  final DateTime? limitsAt;

  const ChatUsage({
    this.model,
    this.context,
    this.window,
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.cost,
    this.turns = 0,
    this.working = Duration.zero,
    this.limits = const [],
    this.limited,
    this.limitsAt,
  });

  /// The share of the context in use, 0–1, when both are known.
  double? get filled {
    final context = this.context, window = this.window;
    if (context == null || window == null || window <= 0) return null;
    return (context / window).clamp(0.0, 1.0);
  }

  int get tokens => input + output + cacheRead + cacheWrite;

  bool get isEmpty =>
      context == null && limits.isEmpty && turns == 0 && tokens == 0;

  /// Null for anything not an object, as a server without the column
  /// gives.
  static ChatUsage? of(Object? json) {
    if (json is! Map) return null;
    int? whole(Object? n) => n is num ? n.round() : null;
    final limits = json['limits'];
    final at = whole(json['limitsAt']);
    return ChatUsage(
      model: json['model'] is String ? json['model'] as String : null,
      context: whole(json['context']),
      window: whole(json['window']),
      input: whole(json['input']) ?? 0,
      output: whole(json['output']) ?? 0,
      cacheRead: whole(json['cacheRead']) ?? 0,
      cacheWrite: whole(json['cacheWrite']) ?? 0,
      cost: json['cost'] is num ? (json['cost'] as num).toDouble() : null,
      turns: whole(json['turns']) ?? 0,
      working: Duration(milliseconds: whole(json['working']) ?? 0),
      limits: [
        if (limits is List)
          for (final l in limits) ?UsageLimit.of(l),
      ],
      limited: json['limited'] is String ? json['limited'] as String : null,
      limitsAt: at == null ? null : DateTime.fromMillisecondsSinceEpoch(at),
    );
  }

  /// The figures [add] sums into the totals.
  static const summed = {
    'input',
    'output',
    'cacheRead',
    'cacheWrite',
    'cost',
    'turns',
    'working',
  };

  /// [was] with [set] laid over it and [add] summed into it: what the
  /// worker keeps.
  static Map<String, Object?> merged(
    Map? was, {
    Map<String, Object?> set = const {},
    Map<String, num> add = const {},
  }) {
    final now = <String, Object?>{
      if (was != null)
        for (final MapEntry(:key, :value) in was.entries) '$key': value,
    };
    for (final MapEntry(:key, :value) in set.entries) {
      if (value == null) continue;
      now[key] = value;
    }
    for (final MapEntry(:key, :value) in add.entries) {
      if (!summed.contains(key) || value == 0) continue;
      final had = now[key];
      now[key] = (had is num ? had : 0) + value;
    }
    return now;
  }
}

/// One of the account's limits: how much of it is used, 0–1, and when it
/// starts again.
class UsageLimit {
  /// `five_hour`, `seven_day`, `seven_day_opus`… as Claude names them;
  /// `primary` or `secondary` for Codex, which says the window's length
  /// instead ([minutes]).
  final String name;
  final double used;
  final DateTime? resets;
  final int? minutes;

  const UsageLimit({
    required this.name,
    required this.used,
    this.resets,
    this.minutes,
  });

  static UsageLimit? of(Object? json) {
    if (json is! Map || json['name'] is! String || json['used'] is! num) {
      return null;
    }
    final resets = json['resets'];
    return UsageLimit(
      name: json['name'] as String,
      used: (json['used'] as num).toDouble(),
      resets: resets is num
          ? DateTime.fromMillisecondsSinceEpoch((resets * 1000).round())
          : null,
      minutes: json['minutes'] is num ? (json['minutes'] as num).round() : null,
    );
  }

  /// How long the window is, by its length or by Claude's name for it.
  int? get span =>
      minutes ??
      switch (name) {
        'five_hour' => 300,
        _ when name.startsWith('seven_day') => 7 * 24 * 60,
        _ => null,
      };

  /// What it is about beyond its window, as Claude names a limit of one
  /// model's: `opus` of `seven_day_opus`.
  String? get only {
    for (final window in const ['seven_day_', 'five_hour_']) {
      if (name.startsWith(window)) return name.substring(window.length);
    }
    return null;
  }
}

/// One limit as it is kept: [used] 0–1, [resets] in seconds since the
/// epoch, as both agents say it.
Map<String, Object?> limitRow(
  String name,
  num used, {
  num? resets,
  num? minutes,
}) => {'name': name, 'used': used, 'resets': ?resets, 'minutes': ?minutes};

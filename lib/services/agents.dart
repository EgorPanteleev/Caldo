import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase/supabase.dart';

import 'account.dart';

/// One kind of agent a worker can run, as it says (`lib/mcp/agents.dart`).
@immutable
class AgentKind {
  final String id;
  final String label;
  final List<String> models;
  final List<String> efforts;
  final List<String> permissions;
  final List<String> plugins;
  final List<String> pluginsOn;
  final List<String> skills;

  /// How a first message reaches it: 'arg', 'type' or 'none'.
  final String prompt;

  const AgentKind({
    required this.id,
    required this.label,
    this.models = const [],
    this.efforts = const [],
    this.permissions = const [],
    this.plugins = const [],
    this.pluginsOn = const [],
    this.skills = const [],
    this.prompt = 'arg',
  });

  factory AgentKind.fromJson(Map json) => AgentKind(
    id: json['id'] as String,
    label: json['label'] as String? ?? json['id'] as String,
    models: _strings(json['models']),
    efforts: _strings(json['efforts']),
    permissions: _strings(json['permissions']),
    plugins: _strings(json['plugins']),
    pluginsOn: _strings(json['plugins_on']),
    skills: _strings(json['skills']),
    prompt: json['prompt'] as String? ?? 'arg',
  );
}

/// A computer that runs agents: one running `caldo-mcp watch`.
@immutable
class AgentWorker {
  final String id;
  final String name;
  final String? home;
  final List<AgentKind> agents;
  final List<String> dirs;
  final DateTime seenAt;

  const AgentWorker({
    required this.id,
    required this.name,
    required this.agents,
    required this.dirs,
    required this.seenAt,
    this.home,
  });

  /// It says it is there every half minute.
  bool get online =>
      DateTime.now().difference(seenAt) < const Duration(seconds: 90);

  factory AgentWorker.fromJson(Map json) => AgentWorker(
    id: json['id'] as String,
    name: json['name'] as String,
    home: json['home'] as String?,
    agents: [
      for (final a in json['agents'] as List? ?? const [])
        AgentKind.fromJson(a as Map),
    ],
    dirs: _strings(json['dirs']),
    seenAt: DateTime.parse(json['seen_at'] as String).toLocal(),
  );
}

enum ChatState { asked, running, asking, idle, ended, failed }

@immutable
class Chat {
  final String id;
  final String? workerId;
  final String agent;
  final String title;
  final String? model;
  final String? effort;
  final String? dir;
  final String? permission;
  final String prompt;
  final String? taskUuid;
  final ChatState state;
  final String? note;
  final int cols;
  final int rows;
  final String? session;
  final DateTime updatedAt;

  const Chat({
    required this.id,
    required this.agent,
    required this.state,
    required this.updatedAt,
    this.workerId,
    this.title = '',
    this.model,
    this.effort,
    this.dir,
    this.permission,
    this.prompt = '',
    this.taskUuid,
    this.note,
    this.cols = 80,
    this.rows = 24,
    this.session,
  });

  /// Its program is running: it takes keys.
  bool get live =>
      state == ChatState.running ||
      state == ChatState.asking ||
      state == ChatState.idle;

  /// What to call it: its title, else its first message's first line.
  String get name {
    if (title.trim().isNotEmpty) return title.trim();
    final line = prompt.trim().split('\n').first;
    return line;
  }

  static ChatState _stateOf(String? s) => switch (s) {
    'running' => ChatState.running,
    'asking' => ChatState.asking,
    'idle' => ChatState.idle,
    'ended' => ChatState.ended,
    'failed' => ChatState.failed,
    _ => ChatState.asked,
  };

  factory Chat.fromJson(Map json) => Chat(
    id: json['id'] as String,
    workerId: json['worker_id'] as String?,
    agent: json['agent'] as String,
    title: json['title'] as String? ?? '',
    model: json['model'] as String?,
    effort: json['effort'] as String?,
    dir: json['dir'] as String?,
    permission: json['permission'] as String?,
    prompt: json['prompt'] as String? ?? '',
    taskUuid: json['task_uuid'] as String?,
    state: _stateOf(json['state'] as String?),
    note: json['note'] as String?,
    cols: json['cols'] as int? ?? 80,
    rows: json['rows'] as int? ?? 24,
    session: json['session'] as String?,
    updatedAt: DateTime.parse(json['updated_at'] as String).toLocal(),
  );
}

List<String> _strings(Object? list) => [
  for (final s in list as List? ?? const []) '$s',
];

/// The account's workers and chats, read from the server while the Agents
/// tab is on show and kept up by realtime; nothing of it is stored here.
class Agents extends ChangeNotifier {
  Agents._();
  static final instance = Agents._();

  List<AgentWorker> workers = const [];
  List<Chat> chats = const [];
  bool loaded = false;
  Object? error;

  SupabaseClient? get _client => Account.instance.client;

  bool get signedIn => _client != null;

  RealtimeChannel? _channel;
  Timer? _every;
  int _watching = 0;

  /// Kept up to date while anything is looking: the tab, an open chat.
  void watch() {
    if (_watching++ > 0) return;
    unawaited(load());
    final client = _client;
    if (client == null) return;
    _channel = client
        .channel('caldo-agents')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chats',
          callback: (_) => _soon(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'workers',
          callback: (_) => _soon(),
        )
        .subscribe();
    // Whether a worker is there is told by time passing, not by a change.
    _every = Timer.periodic(const Duration(seconds: 30), (_) => load());
  }

  void unwatch() {
    if (--_watching > 0) return;
    _every?.cancel();
    _every = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) unawaited(_client?.removeChannel(channel));
  }

  Timer? _later;

  /// A few changes at once — a worker setting a chat's state as it starts
  /// — make one read.
  void _soon() {
    _later?.cancel();
    _later = Timer(const Duration(milliseconds: 250), load);
  }

  Future<void> load() async {
    final client = _client;
    if (client == null) {
      loaded = true;
      notifyListeners();
      return;
    }
    try {
      final w = await client
          .from('workers')
          .select()
          .order('name', ascending: true);
      final c = await client
          .from('chats')
          .select()
          .order('updated_at', ascending: false)
          .limit(200);
      workers = [for (final r in w) AgentWorker.fromJson(r)];
      chats = [for (final r in c) Chat.fromJson(r)];
      error = null;
    } catch (e) {
      error = e;
    }
    loaded = true;
    notifyListeners();
  }

  /// The latest chat a task was done in, if any.
  Future<String?> chatOfTask(String taskUuid) async {
    final rows = await _client
        ?.from('chats')
        .select('id')
        .eq('task_uuid', taskUuid)
        .order('created_at', ascending: false)
        .limit(1);
    return rows == null || rows.isEmpty ? null : rows.first['id'] as String;
  }

  Chat? chat(String id) => chats.where((c) => c.id == id).firstOrNull;

  AgentWorker? worker(String? id) =>
      workers.where((w) => w.id == id).firstOrNull;

  Future<Chat> start({
    required String worker,
    required String agent,
    String title = '',
    String? model,
    String? effort,
    String? dir,
    String? permission,
    List<String>? plugins,
    List<String> skills = const [],
    String prompt = '',
    int cols = 80,
    int rows = 24,
  }) async {
    final row = await _client!
        .from('chats')
        .insert({
          'worker_id': worker,
          'agent': agent,
          'title': title,
          'model': model,
          'effort': effort,
          'dir': dir,
          'permission': permission,
          'plugins': plugins,
          'skills': skills,
          'prompt': prompt,
          'cols': cols.clamp(10, 500),
          'rows': rows.clamp(5, 300),
        })
        .select()
        .single();
    final chat = Chat.fromJson(row);
    chats = [chat, ...chats];
    notifyListeners();
    return chat;
  }

  /// Keys as the terminal puts them out.
  Future<void> keys(String chat, String data) => _in(chat, 'keys', data: data);

  /// A message: pasted, then Enter.
  Future<void> line(String chat, String text) => _in(chat, 'line', data: text);

  Future<void> resize(String chat, int cols, int rows) =>
      _in(chat, 'size', cols: cols.clamp(10, 500), rows: rows.clamp(5, 300));

  Future<void> stop(String chat) => _in(chat, 'stop');

  Future<void> again(String chat) => _in(chat, 'start');

  Future<void> remove(String chat) async {
    await _client!.from('chats').delete().eq('id', chat);
    chats = [
      for (final c in chats)
        if (c.id != chat) c,
    ];
    notifyListeners();
  }

  Future<void> _in(
    String chat,
    String kind, {
    String? data,
    int? cols,
    int? rows,
  }) async {
    await _client!.from('chat_in').insert({
      'chat_id': chat,
      'kind': kind,
      'data': ?data,
      'cols': ?cols,
      'rows': ?rows,
    });
  }

  /// What [chat]'s terminal has written, from its latest snapshot on, then
  /// each piece as it comes. A piece is handed over once, in order; a
  /// snapshot after the first is the screen as it already is, and skipped.
  ChatFeed feed(String chat, void Function(String data) onData) =>
      ChatFeed._(_client!, chat, onData);
}

/// A chat's output as it is read back and comes in.
class ChatFeed {
  final SupabaseClient _client;
  final String chat;
  final void Function(String data) onData;

  RealtimeChannel? _channel;

  /// The seq handed over last; pieces heard while the past is read wait in
  /// [_early].
  int _last = -1;
  bool _caughtUp = false;
  final _early = <Map<String, dynamic>>[];
  bool _closed = false;
  Timer? _poll;

  ChatFeed._(this._client, this.chat, this.onData) {
    _channel = _client
        .channel('caldo-chat-$chat')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'chat_out',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'chat_id',
            value: chat,
          ),
          callback: (change) => _heard(change.newRecord),
        )
        .subscribe();
    unawaited(_catchUp());
    // Realtime can drop a piece, or the channel; a read now and then
    // fills the gap.
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _fill());
  }

  Future<void> _catchUp() async {
    final snaps = await _client
        .from('chat_out')
        .select('seq')
        .eq('chat_id', chat)
        .eq('snap', true)
        .order('seq', ascending: false)
        .limit(1);
    final from = snaps.isEmpty ? 0 : snaps.first['seq'] as int;
    await _read(from, snapsToo: true);
    _caughtUp = true;
    final early = [..._early]..sort((a, b) => _seq(a).compareTo(_seq(b)));
    _early.clear();
    for (final row in early) {
      _heard(row);
    }
  }

  Future<void> _read(int from, {bool snapsToo = false}) async {
    var next = from;
    while (!_closed) {
      final rows = await _client
          .from('chat_out')
          .select('seq, data, snap')
          .eq('chat_id', chat)
          .gte('seq', next)
          .order('seq', ascending: true)
          .limit(200);
      for (final row in rows) {
        _hand(row, snapsToo: snapsToo && _last < 0);
      }
      if (rows.length < 200) break;
      next = _seq(rows.last) + 1;
    }
  }

  void _heard(Map<String, dynamic> row) {
    if (_closed) return;
    if (!_caughtUp) {
      _early.add(row);
      return;
    }
    if (_seq(row) > _last + 1) {
      // One missed: read from where it was, which brings this one too.
      unawaited(_fill());
      return;
    }
    _hand(row);
  }

  bool _filling = false;

  Future<void> _fill() async {
    if (!_caughtUp || _filling || _closed) return;
    _filling = true;
    try {
      await _read(_last + 1);
    } catch (_) {
      // Offline; the next poll tries again.
    } finally {
      _filling = false;
    }
  }

  void _hand(Map<String, dynamic> row, {bool snapsToo = false}) {
    final seq = _seq(row);
    if (seq <= _last || _closed) return;
    _last = seq;
    // The first piece read may be a snapshot, which draws the screen from
    // nothing; one after it is a picture of what is already drawn.
    if (row['snap'] == true && !snapsToo) return;
    onData(row['data'] as String);
  }

  static int _seq(Map row) => row['seq'] as int;

  void close() {
    _closed = true;
    _poll?.cancel();
    final channel = _channel;
    if (channel != null) unawaited(_client.removeChannel(channel));
  }
}

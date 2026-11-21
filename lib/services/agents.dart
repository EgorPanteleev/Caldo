import 'dart:async';
import 'dart:collection';
import 'dart:math';

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

  /// Whether it can be a chat drawn here, not only a terminal.
  final bool talks;

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
    this.talks = false,
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
    talks: json['talks'] == true,
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

  /// Whether it is in its chat, spoken to in messages, or in its terminal.
  final bool inChat;

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
    this.inChat = false,
  });

  /// Whether it can be a chat at all: one begun as one, wherever it is now.
  bool get talks => agent == 'claude' || agent == 'codex';

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

  /// [c] as it is once moved: said here at once, so the screen follows the
  /// tap, not the worker's word on it.
  Chat._moved(Chat c, bool toChat)
    : this(
        id: c.id,
        workerId: c.workerId,
        agent: c.agent,
        title: c.title,
        model: c.model,
        effort: c.effort,
        dir: c.dir,
        permission: c.permission,
        prompt: c.prompt,
        taskUuid: c.taskUuid,
        state: c.state,
        note: c.note,
        cols: c.cols,
        rows: c.rows,
        session: c.session,
        updatedAt: c.updatedAt,
        inChat: toChat,
      );

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
    inChat: json['mode'] == 'chat',
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
    bool inChat = false,
  }) async {
    final row = await _client!
        .from('chats')
        .insert({
          'mode': inChat ? 'chat' : 'terminal',
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

  /// A message: pasted, then Enter — or, to a chat [over] its feed, said
  /// there at once as well as kept.
  Future<void> line(String chat, String text, {TalkFeed? over}) =>
      _in(chat, 'line', data: text, over: over);

  Future<void> resize(String chat, int cols, int rows) =>
      _in(chat, 'size', cols: cols.clamp(10, 500), rows: rows.clamp(5, 300));

  Future<void> stop(String chat) => _in(chat, 'stop');

  Future<void> again(String chat) => _in(chat, 'start');

  /// [choice] — `allow`, `always` or `deny` — for the question [item].
  Future<void> answer(String chat, String item, String choice) =>
      _in(chat, 'answer', data: '$choice $item');

  /// The turn under way cut short; the chat stays.
  Future<void> interrupt(String chat) => _in(chat, 'interrupt');

  /// The chat moved to its terminal, or back to its chat.
  Future<void> move(String chat, {required bool toChat}) async {
    chats = [
      for (final c in chats)
        if (c.id == chat) Chat._moved(c, toChat) else c,
    ];
    notifyListeners();
    await _in(chat, 'mode', data: toChat ? 'chat' : 'terminal');
  }

  Future<void> remove(String chat) async {
    await _client!.from('chats').delete().eq('id', chat);
    chats = [
      for (final c in chats)
        if (c.id != chat) c,
    ];
    notifyListeners();
  }

  /// Input for the program itself, which it waits on as it is typed.
  static const _typed = {'keys', 'line', 'answer', 'interrupt'};

  /// Input for [chat], kept as a row the worker takes; typed input is also
  /// broadcast on the chat's channel while the chat is open, which the
  /// worker hears a quarter of a second sooner. Their shared key says
  /// which it has taken. A line said [over] a chat's feed shows there at
  /// once.
  Future<void> _in(
    String chat,
    String kind, {
    String? data,
    int? cols,
    int? rows,
    TalkFeed? over,
  }) async {
    final line = _lines[chat];
    final key = line != null && _typed.contains(kind) ? _key() : null;
    if (key != null) {
      if (kind == 'line') over?.said(data ?? '', key);
      line!.cast({'kind': kind, 'data': data, 'key': key});
    }
    await _client!.from('chat_in').insert({
      'chat_id': chat,
      'kind': kind,
      'data': ?data,
      'cols': ?cols,
      'rows': ?rows,
      'key': ?key,
    });
  }

  static final _random = Random();

  static String _key() => [
    for (var i = 0; i < 12; i++)
      'abcdefghijklmnopqrstuvwxyz0123456789'[_random.nextInt(36)],
  ].join();

  /// What [chat]'s terminal has written, from its latest snapshot on, then
  /// each piece as it comes. A piece is handed over once, in order; a
  /// snapshot after the first is the screen as it already is, and skipped.
  ChatFeed feed(String chat, void Function(String data) onData) =>
      ChatFeed._(_client!, chat, onData, _hold(chat), () => _release(chat));

  /// What [chat] has said as a chat, kept up as it says more.
  TalkFeed talk(String chat) =>
      TalkFeed._(_client!, chat, _hold(chat), () => _release(chat));

  /// Each open chat's private channel, shared by its feeds: of two joins
  /// to one topic from one socket, the server keeps only the later.
  final _lines = <String, _ChatLine>{};

  RealtimeChannel _hold(String chat) {
    final line = _lines[chat] ??= _ChatLine(_client!, chat);
    line.holders++;
    return line.channel;
  }

  void _release(String chat) {
    final line = _lines[chat];
    if (line == null || --line.holders > 0) return;
    _lines.remove(chat);
    unawaited(line.client.removeChannel(line.channel));
  }
}

/// A chat's private channel, `chat:<id>`: what the worker says as it
/// happens comes on it, and typed input goes on it ahead of its row.
class _ChatLine {
  final SupabaseClient client;
  final RealtimeChannel channel;
  int holders = 0;

  // Joined at once: broadcasts need no binding at the join, so the feeds
  // holding it add theirs after.
  _ChatLine(this.client, String chat)
    : channel = client.channel(
        'chat:$chat',
        opts: const RealtimeChannelConfig(private: true),
      )..subscribe();

  /// Input heard by the worker at once — a copy: the client writes its own
  /// keys into the map it is given.
  void cast(Map<String, dynamic> input) => unawaited(
    channel
        .sendBroadcastMessage(event: 'in', payload: {...input})
        .then((_) {}, onError: (Object _) {}),
  );
}

/// A broadcast's own payload, whether or not it comes wrapped.
Map<String, dynamic> _payloadOf(Map<String, dynamic> message) =>
    message['payload'] is Map
    ? Map<String, dynamic>.from(message['payload'] as Map)
    : message;

/// A chat's output as it is read back and comes in.
class ChatFeed {
  final SupabaseClient _client;
  final String chat;
  final TermOrder _order;
  final VoidCallback _release;

  RealtimeChannel? _channel;

  /// Rows heard while the past is read wait in [_early].
  bool _caughtUp = false;
  final _early = <Map<String, dynamic>>[];
  bool _closed = false;
  Timer? _poll;

  ChatFeed._(
    this._client,
    this.chat,
    void Function(String data) onData,
    RealtimeChannel line,
    this._release,
  ) : _order = TermOrder(onData) {
    line.onBroadcast(
      event: 'out',
      callback: (message) {
        if (!_closed) _order.piece(_payloadOf(message));
      },
    );
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
        _hand(row, snapsToo: snapsToo && _order.last < 0);
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
    if (_seq(row) > _order.last + 1) {
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
      await _read(_order.last + 1);
    } catch (_) {
      // Offline; the next poll tries again.
    } finally {
      _filling = false;
    }
  }

  void _hand(Map<String, dynamic> row, {bool snapsToo = false}) {
    if (_closed) return;
    _order.row(
      _seq(row),
      row['data'] as String,
      snap: row['snap'] == true,
      snapsToo: snapsToo,
    );
  }

  static int _seq(Map row) => row['seq'] as int;

  void close() {
    if (_closed) return;
    _closed = true;
    _poll?.cancel();
    final channel = _channel;
    if (channel != null) unawaited(_client.removeChannel(channel));
    _release();
  }
}

/// A terminal's output put in order from the two ways it comes: rows of
/// `chat_out`, the record, a few times a second and heard through Postgres
/// changes a quarter of a second or so late; and pieces broadcast as the
/// worker reads them, heard within milliseconds. A piece says where in
/// the worker's run of output it starts and where its row does, so
/// whichever brings a stretch first draws it and the other is passed over.
class TermOrder {
  final void Function(String data) onData;

  TermOrder(this.onData);

  /// The last row taken.
  int last = -1;

  /// The worker's run the places below count in: a worker started again
  /// counts from nothing.
  Object? _life;

  /// Where rows not yet taken start in the run, as pieces and rows tell.
  final _starts = <int, int>{};

  /// How far into the run is drawn; null until a piece has placed it.
  int? _drawn;

  /// Pieces not drawn yet, by where they start.
  final _held = SplayTreeMap<int, String>();

  /// A row, in order. The first may be a snapshot, which draws the screen
  /// from nothing ([snapsToo]); one after it is a picture of what is drawn
  /// already.
  void row(int seq, String data, {bool snap = false, bool snapsToo = false}) {
    if (seq <= last) return;
    final start = seq == last + 1 ? _starts[seq] : null;
    last = seq;
    _starts.removeWhere((s, _) => s <= seq);
    if (snap) {
      // A worker taken up again snaps first, counting afresh.
      _forget();
      if (snapsToo) onData(data);
      return;
    }
    final drawn = _drawn;
    if (start == null || drawn == null) {
      onData(data);
    } else if (start + data.length > drawn) {
      onData(data.substring(max(0, drawn - start)));
    }
    if (start == null) {
      _drawn = null;
    } else {
      _drawn = max(drawn ?? 0, start + data.length);
      _starts[seq + 1] = start + data.length;
    }
    _drain();
  }

  /// A broadcast piece: `life`, `seq` and `start` of its row, `at` where
  /// it starts itself, and its `data`.
  void piece(Map<String, dynamic> p) {
    final seq = p['seq'], start = p['start'], at = p['at'], data = p['data'];
    if (seq is! int || start is! int || at is! int || data is! String) return;
    if (p['life'] != _life) {
      _forget();
      _life = p['life'];
    }
    if (seq > last) _starts[seq] ??= start;
    if (data.isNotEmpty) {
      _held.update(
        at,
        (had) => had.length >= data.length ? had : data,
        ifAbsent: () => data,
      );
    }
    _drain();
  }

  /// Draws the held pieces that carry on from what is drawn. Until a piece
  /// has said where the next row starts, there is nothing to carry on from.
  void _drain() {
    final placed = _drawn ??= _starts[last + 1];
    if (placed == null) {
      while (_held.length > 500) {
        _held.remove(_held.firstKey());
      }
      return;
    }
    var drawn = placed;
    while (_held.isNotEmpty && _held.firstKey()! <= drawn) {
      final at = _held.firstKey()!;
      final data = _held.remove(at)!;
      if (at + data.length > drawn) {
        onData(data.substring(drawn - at));
        drawn = at + data.length;
      }
    }
    _drawn = drawn;
  }

  void _forget() {
    _drawn = null;
    _starts.clear();
    _held.clear();
  }
}

/// One thing said in a chat: the user's words, the agent's, its thinking, a
/// tool it used (and what came of it), a question for the user, a note.
@immutable
class ChatItem {
  final String id;
  final int seq;
  final String kind;
  final Map<String, dynamic> body;

  const ChatItem({
    required this.id,
    required this.seq,
    required this.kind,
    required this.body,
  });

  String get text => body['text'] as String? ?? '';

  factory ChatItem.fromJson(Map json) => ChatItem(
    id: json['id'] as String,
    seq: json['seq'] as int,
    kind: json['kind'] as String,
    body: Map<String, dynamic>.from(json['body'] as Map? ?? const {}),
  );
}

/// A chat's items, read whole on opening and kept up by realtime; and the
/// words of an answer as they are written, heard on the chat's private
/// channel before the item that ends them is.
class TalkFeed extends ChangeNotifier {
  final SupabaseClient? _client;
  final String chat;

  final _byId = <String, ChatItem>{};
  List<ChatItem> items = const [];
  bool loaded = false;

  /// Answers being written, by item: their words so far. Told apart from
  /// [items] so a word arriving redraws only the answer it is in.
  final pieces = ValueNotifier<Map<String, String>>(const {});

  /// The chat's state as last broadcast — sooner than its row, which the
  /// list of chats is read from; null once the row has caught up.
  final state = ValueNotifier<String?>(null);

  RealtimeChannel? _rows;
  final VoidCallback? _release;
  Timer? _poll;
  bool _closed = false;

  /// [items] as they are, heard from nothing: for tests.
  @visibleForTesting
  TalkFeed.held(this.chat, List<ChatItem> items)
    : _client = null,
      _release = null {
    _take([
      for (final i in items)
        {'id': i.id, 'seq': i.seq, 'kind': i.kind, 'body': i.body},
    ]);
    loaded = true;
  }

  /// Words of an answer as the channel brings them: for tests.
  @visibleForTesting
  void hear(Map<String, dynamic> message) => _piece(message);

  TalkFeed._(
    SupabaseClient client,
    this.chat,
    RealtimeChannel line,
    VoidCallback release,
  ) : _client = client,
      _release = release {
    _rows = client
        .channel('caldo-talk-$chat')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chat_items',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'chat_id',
            value: chat,
          ),
          callback: (change) {
            if (change.eventType != PostgresChangeEvent.delete) {
              _take([change.newRecord]);
            }
          },
        )
        .subscribe();
    line
        .onBroadcast(event: 'delta', callback: _piece)
        .onBroadcast(
          event: 'item',
          callback: (message) => _take([_payloadOf(message)]),
        )
        .onBroadcast(
          event: 'state',
          callback: (message) {
            if (!_closed) state.value = _payloadOf(message)['state'] as String?;
          },
        );
    unawaited(_read());
    // Realtime can drop a change; the last few are read again now and then.
    _poll = Timer.periodic(const Duration(seconds: 6), (_) => _read(late: 40));
  }

  /// Everything, or with [late] only the last that many — enough to catch
  /// a tool's output or an answer a dropped change left out.
  Future<void> _read({int? late}) async {
    final client = _client;
    if (client == null) return;
    try {
      var from = 0;
      if (late != null) {
        if (!loaded) return;
        from = items.isEmpty ? 0 : items.last.seq - late;
      }
      while (!_closed) {
        final rows = await client
            .from('chat_items')
            .select('id, seq, kind, body')
            .eq('chat_id', chat)
            .gte('seq', from)
            .order('seq', ascending: true)
            .limit(500);
        _take(rows);
        if (rows.length < 500) break;
        from = (rows.last['seq'] as int) + 1;
      }
      if (!loaded) {
        loaded = true;
        if (!_closed) notifyListeners();
      }
    } catch (_) {
      // Offline: the next look tries again.
    }
  }

  void _take(List<Map<String, dynamic>> rows) {
    if (_closed || rows.isEmpty) return;
    var changed = false;
    var moved = false;
    var writing = pieces.value;
    for (final row in rows) {
      final item = ChatItem.fromJson(row);
      final was = _byId[item.id];
      if (was != null && mapEquals(was.body, item.body)) continue;
      _byId[item.id] = item;
      changed = true;
      moved |= was == null || was.seq != item.seq;
      if (item.kind == 'text' && writing.containsKey(item.id)) {
        writing = {...writing}..remove(item.id);
      }
    }
    if (!changed) return;
    if (moved) {
      items = _byId.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));
    } else {
      items = [for (final i in items) _byId[i.id]!];
    }
    if (writing != pieces.value) pieces.value = writing;
    notifyListeners();
  }

  /// The user's words shown at once, before the worker has said them back;
  /// its item, when it comes by the same id, takes their place.
  void said(String text, String key) {
    if (text.trim().isEmpty) return;
    _take([
      {
        'id': 'u$key',
        'seq': (items.isEmpty ? 0 : items.last.seq) + 1,
        'kind': 'user',
        'body': {'text': text},
      },
    ]);
  }

  void _piece(Map<String, dynamic> message) {
    if (_closed) return;
    final p = _payloadOf(message);
    final id = p['id'], at = p['at'], text = p['text'];
    if (id is! String || at is! int || text is! String) return;
    if (_byId[id]?.kind == 'text') return;
    final now = pieces.value[id] ?? '';
    // Pieces come in order on one channel; one heard twice, or after a
    // gap, is left for the whole answer to set right.
    if (at > now.length || at + text.length <= now.length) return;
    pieces.value = {...pieces.value, id: now + text.substring(now.length - at)};
  }

  @override
  void dispose() {
    _closed = true;
    _poll?.cancel();
    final rows = _rows;
    if (rows != null) unawaited(_client?.removeChannel(rows));
    _release?.call();
    pieces.dispose();
    state.dispose();
    super.dispose();
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:supabase/supabase.dart';

import 'agents.dart';
import 'kept.dart';
import 'remote.dart';
import 'talk.dart';
import 'terminal.dart';
import 'watch.dart';

/// Who this worker is, kept beside the session so it is the same worker
/// each time it starts, and where each chat it runs had got to.
class WorkerState {
  final File file;
  late String id;
  String? name;

  /// Per chat: how far into its output file has been sent, the seq the next
  /// piece is sent as, the last two snapshots' seqs, and how far into its
  /// events file has been read.
  final Map<String, Map<String, int>> chats = {};

  /// Per chat moved from its chat to its terminal: when, so what was said
  /// there is read back into the chat from its transcript on the way back.
  final Map<String, int> marks = {};

  /// Per chat spoken to in messages: how far into its program's output has
  /// been handed on, for a worker started again to read on from.
  final Map<String, int> talks = {};

  WorkerState(this.file) {
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map;
      id = json['id'] as String;
      name = json['name'] as String?;
      for (final MapEntry(:key, :value)
          in (json['chats'] as Map? ?? const {}).entries) {
        chats[key as String] = (value as Map).cast<String, int>();
      }
      marks.addAll((json['marks'] as Map? ?? const {}).cast<String, int>());
      talks.addAll((json['talks'] as Map? ?? const {}).cast<String, int>());
    } catch (_) {
      id = _uuid();
    }
  }

  void save() {
    file.parent.createSync(recursive: true);
    final next = File('${file.path}.next')
      ..writeAsStringSync(
        jsonEncode({
          'id': id,
          'name': name,
          'chats': chats,
          'marks': marks,
          'talks': talks,
        }),
      );
    next.renameSync(file.path);
  }

  static String _uuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}'
        '-${h.substring(16, 20)}-${h.substring(20)}';
  }
}

/// How a turn of Claude's ended, for a task waiting on its answer.
typedef _Turn = ({bool answered, String text});

/// One chat running here.
class _Live {
  final ChatAsk ask;
  final AgentSpec spec;

  /// Where its output file has been read to, and its events file.
  int offset;
  int events;

  /// The seq the next piece goes up as, and the last two snapshots'.
  int seq;
  int snap;
  int lastSnap;

  /// Read, not yet sent; a UTF-8 character cut across two reads is held by
  /// the decoder until the rest comes.
  final pending = StringBuffer();
  late final ByteConversionSink decoder;

  /// The chat's private channel, on which what is read goes out at once.
  final RealtimeChannel line;

  /// Where [pending] starts in this run's output, and how far into it has
  /// been broadcast; [life] tells this run from one before, which counted
  /// from nothing too.
  int at = 0;
  int cast = 0;
  final life = DateTime.now().microsecondsSinceEpoch;

  DateTime sentAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime wroteAt = DateTime.now();
  bool sending = false;
  int sinceSnap = 0;
  String state = 'running';
  String? session;

  /// Keys are put in one after another, in the order they were sent.
  Future<void> typing = Future.value();

  /// Completed with the first turn's end, for a task waiting on it.
  Completer<_Turn>? turn;

  _Live(
    this.ask,
    this.spec, {
    required this.offset,
    required this.events,
    required this.seq,
    required this.snap,
    required this.lastSnap,
    required this.line,
  }) {
    decoder = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(StringConversionSink.fromStringSink(pending));
  }

  Map<String, int> get kept => {
    'offset': offset,
    'events': events,
    'seq': seq,
    'snap': snap,
    'last_snap': lastSnap,
  };
}

/// Runs the agents the app asks this computer for, each in a terminal of
/// its own ([Tmux]), and is the way between them and the app: what the
/// terminal writes goes up as `chat_out`, a few times a second at most;
/// what the app types comes down as `chat_in` and is put in as keys.
///
/// Realtime says the moment something is asked; a look every so often
/// catches what it dropped.
class Worker {
  final SupabaseRemote remote;
  final Tmux tmux;
  final AgentBook book;
  final WorkerState state;
  final String home;
  final void Function(String line) log;

  final Map<String, _Live> _live = {};

  /// The chats spoken to in messages, by id: their programs, while up.
  final Map<String, _Talker> _talks = {};

  /// The input rows already put in, by id, so one heard and then read
  /// again is not typed twice.
  int _applied = 0;

  Worker({
    required this.remote,
    required this.tmux,
    required this.book,
    required this.state,
    required this.home,
    void Function(String line)? log,
  }) : log = log ?? print;

  /// At most this often a chat's output goes up: a spinner redrawn every
  /// tenth of a second would otherwise be ten rows a second.
  static const _gap = Duration(milliseconds: 200);

  /// A snapshot after this many pieces, once the terminal is quiet.
  static const _snapEvery = 300;

  Future<SupabaseClient> get _db => remote.signedIn();

  String get name => state.name ?? Platform.localHostname;

  Future<Never> run() async {
    // Nothing goes on until the server has heard of this worker: a chat
    // can only be asked of one it knows.
    for (var wait = 5; ; wait = min(wait * 2, 300)) {
      try {
        await _hello();
        await _adopt();
        break;
      } catch (e) {
        log('worker: $e; trying again in ${wait}s');
        await Future<void>.delayed(Duration(seconds: wait));
      }
    }
    _listen();
    Timer.periodic(const Duration(milliseconds: 50), (_) => _pump());
    Timer.periodic(const Duration(seconds: 1), (_) => _guard(_check));
    Timer.periodic(const Duration(seconds: 30), (_) => _guard(_hello));
    while (true) {
      await _guard(_look);
      await Future.any([
        _wake.future,
        Future<void>.delayed(const Duration(seconds: 15)),
      ]);
      if (_wake.isCompleted) _wake = Completer<void>();
    }
  }

  var _wake = Completer<void>();
  String? _failing;

  Future<void> _guard(Future<void> Function() body) async {
    try {
      await body();
      _failing = null;
    } catch (e) {
      if ('$e' != _failing) log('worker: $e');
      _failing = '$e';
    }
  }

  /// Says this worker is here, and what it can run.
  Future<void> _hello() async {
    final db = await _db;
    await db.from('workers').upsert({
      'id': state.id,
      'name': name,
      'home': home,
      'agents': [for (final a in book.read()) a.toJson()],
      'dirs': book.dirs(),
      'seen_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Takes up the chats still running in tmux from before this worker
  /// started, and says the rest have ended.
  Future<void> _adopt() async {
    final db = await _db;
    final panes = await tmux.panes();
    final mine = await db
        .from('chats')
        .select()
        .eq('worker_id', state.id)
        .inFilter('state', ['running', 'asking', 'idle']);
    for (final row in mine) {
      final ask = ChatAsk.fromJson(row);
      if (ask.mode == 'chat') {
        final spec = _specOf(ask.agent);
        if (spec == null) {
          await _set(ask.id, 'ended', 'There is no ${ask.agent} on $name.');
          continue;
        }
        final talker = _talks[ask.id] = await _Talker.make(this, ask, spec)
          ..state = row['state'] as String;
        if (talker.takeUp()) {
          log('[${_short(ask.id)}] taken up again (chat)');
          continue;
        }
        // Its program is gone (or was the last worker's child, and went
        // with it): its session is taken up again with the next message.
        if (row['state'] != 'idle') {
          await _set(
            ask.id,
            'idle',
            'Cut off when the worker on $name started again.',
          );
        }
        continue;
      }
      final kept = state.chats[ask.id];
      final pane = panes[Tmux.nameOf(ask.id)];
      final spec = _specOf(ask.agent);
      if (pane != null && kept != null && spec != null) {
        final live = _live[ask.id] =
            _Live(
                ask,
                spec,
                // Skipped to the end of its files: what was read but not
                // sent went with the last worker, and the snapshot below
                // draws the screen whole instead.
                offset: _lengthOf(tmux.outOf(ask.id)),
                events: _lengthOf(tmux.eventsOf(ask.id)),
                seq: await _seqAfter(ask.id, kept),
                snap: kept['snap'] ?? -1,
                lastSnap: kept['last_snap'] ?? -1,
                line: _lineOf(ask.id),
              )
              ..state = row['state'] as String
              ..session = row['session'] as String?;
        await _snapshot(ask.id, live);
        log('[${_short(ask.id)}] taken up again');
      } else {
        state.chats.remove(ask.id);
        if (pane != null) await tmux.kill(ask.id);
        await _set(
          ask.id,
          'ended',
          'Its terminal was gone when the worker '
              'on $name started again.',
        );
      }
    }
  }

  void _listen() {
    remote.client
        .channel('caldo-worker')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'chat_in',
          callback: (change) => _heard(change.newRecord),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chats',
          callback: (change) {
            final gone = change.eventType == PostgresChangeEvent.delete;
            final id = (gone ? change.oldRecord : change.newRecord)['id'];
            if (gone && (_live.containsKey(id) || _talks.containsKey(id))) {
              unawaited(_guard(() => _drop(id as String)));
            }
            if (!_wake.isCompleted) _wake.complete();
          },
        )
        .subscribe();
  }

  /// [chat]'s private channel: input heard on it is put in at once, ahead
  /// of its row. A chat has one here at a time, its [_Talker]'s or its
  /// [_Live]'s: of two joins to one topic, the server keeps the later.
  RealtimeChannel _lineOf(String chat) =>
      remote.client
          .channel(
            'chat:$chat',
            opts: const RealtimeChannelConfig(private: true),
          )
          .onBroadcast(
            event: 'in',
            callback: (message) => _cast(chat, _Talker._payloadOf(message)),
          )
        ..subscribe();

  /// A row of input heard by realtime: put in at once, not after a look.
  void _heard(Map<String, dynamic> row) {
    final chat = row['chat_id'] as String?;
    if (chat == null) return;
    final mine = _live.containsKey(chat) || _talks.containsKey(chat);
    if (!mine) {
      // Perhaps an ended chat of this worker's, asked to start again.
      if (!_wake.isCompleted) _wake.complete();
      return;
    }
    unawaited(_guard(() => _take([row])));
  }

  /// Starts the chats asked of this worker, and puts in what was typed.
  Future<void> _look() async {
    final db = await _db;
    final asked = await db
        .from('chats')
        .select()
        .eq('worker_id', state.id)
        .eq('state', 'new');
    for (final row in asked) {
      // Taken, so a second worker started with the same id — or this one
      // looking twice — cannot start it again.
      final taken = await db
          .from('chats')
          .update({'state': 'running'})
          .eq('id', row['id'])
          .eq('state', 'new')
          .select();
      if (taken.isEmpty) continue;
      final ask = ChatAsk.fromJson(row);
      await _guard(
        () async =>
            ask.mode == 'chat' ? await _startTalk(ask) : await _start(ask),
      );
    }
    final typed = await db
        .from('chat_in')
        .select('*, chats!inner(worker_id)')
        .eq('chats.worker_id', state.id)
        .order('id', ascending: true)
        .limit(500);
    await _take(typed);
  }

  /// Puts in rows of input, each once, and deletes them.
  Future<void> _take(List<Map<String, dynamic>> rows) async {
    final done = <int>[];
    for (final row in rows) {
      final id = row['id'] as int;
      done.add(id);
      if (id <= _applied) continue;
      _applied = id;
      await _apply(row['chat_id'] as String, row);
    }
    if (done.isNotEmpty) {
      final db = await _db;
      await db.from('chat_in').delete().inFilter('id', done);
    }
  }

  /// The keys of input already put in, heard broadcast or read as a row:
  /// whichever comes second is not put in again.
  final _keys = <String>{};

  /// Input broadcast on a chat's channel, put in at once; its row, come
  /// later, is passed over.
  void _cast(String chat, Map payload) =>
      unawaited(_guard(() => _apply(chat, payload)));

  /// One piece of input for [chat]: as a row of `chat_in`, or broadcast.
  Future<void> _apply(String chat, Map row) async {
    final key = row['key'];
    if (key is String) {
      if (!_keys.add(key)) return;
      if (_keys.length > 2000) _keys.remove(_keys.first);
    }
    final live = _live[chat];
    final talker = _talks[chat];
    switch (row['kind']) {
      case 'line' when talker != null:
        _name(talker.ask, row['data'] as String? ?? '');
        await talker.say(
          row['data'] as String? ?? '',
          id: key is String ? 'u$key' : null,
        );
      case 'answer' when talker != null:
        // "<choice> <item>".
        final data = row['data'] as String? ?? '';
        final cut = data.indexOf(' ');
        if (cut > 0) {
          talker.answer(data.substring(cut + 1), data.substring(0, cut));
        }
      case 'interrupt' when talker != null:
        talker.interrupt();
      case 'stop' when talker != null:
        _talks.remove(chat);
        await talker.close();
        await _set(chat, 'ended', null);
      case 'mode':
        await _move(chat, row['data'] as String? ?? '');
      case 'start' when live == null && talker == null:
        await _restart(chat);
      case 'start' when talker != null && talker.talk == null:
        await talker.wake();
      case 'stop' when live != null:
        await tmux.kill(chat);
      case 'size':
        final cols = row['cols'] as int?;
        final rows = row['rows'] as int?;
        if (cols == null || rows == null) break;
        if (live != null) {
          live.typing = live.typing.then((_) => tmux.resize(chat, cols, rows));
        }
        // Kept, so the chat starts again at the app's size.
        unawaited(
          _db.then(
            (db) => db
                .from('chats')
                .update({'cols': cols, 'rows': rows})
                .eq('id', chat),
          ),
        );
      case 'keys' when live != null:
        final bytes = utf8.encode(row['data'] as String? ?? '');
        live.typing = live.typing.then((_) => tmux.keys(chat, bytes));
      case 'line' when live != null:
        final text = row['data'] as String? ?? '';
        _name(live.ask, text);
        live.typing = live.typing.then((_) => tmux.line(chat, text));
    }
  }

  AgentSpec? _specOf(String agent) =>
      book.read().where((a) => a.id == agent).firstOrNull;

  String _expand(String dir) => dir == '~'
      ? home
      : dir.startsWith('~/')
      ? '$home${dir.substring(1)}'
      : dir;

  /// Starts [ask] in a terminal: fresh, or with Claude's [resume] taken up
  /// and [prompt] in place of the chat's own first message.
  Future<_Live?> _start(ChatAsk ask, {String? resume, String? prompt}) async {
    final place = await _placeOf(ask);
    if (place == null) return null;
    final (spec, dir) = place;
    resume = resumable(spec, home, dir, resume);
    final first = prompt ?? (resume != null ? '' : ask.prompt);
    final argv = launchOf(
      spec,
      ask,
      resume: resume,
      prompt: first,
      events: tmux.eventsOf(ask.id),
    );
    final kept = state.chats[ask.id];
    final out = File(tmux.outOf(ask.id));
    final events = File(tmux.eventsOf(ask.id));
    final live = _Live(
      ask,
      spec,
      // What is already in the files is from before, and sent or lost.
      offset: out.existsSync() ? out.lengthSync() : 0,
      events: events.existsSync() ? events.lengthSync() : 0,
      seq: await _seqAfter(ask.id, kept),
      snap: kept?['snap'] ?? -1,
      lastSnap: kept?['last_snap'] ?? -1,
      line: _lineOf(ask.id),
    )..session = resume ?? ask.session;
    if (live.seq > 0) {
      // Taken up again in the same chat: the old screen is put by, so the
      // new program's first screen is not drawn over its last.
      live.pending.write('\x1b[0m\r\n\x1b[2m── started again ──\x1b[0m\r\n');
    }
    _live[ask.id] = live;
    state.chats[ask.id] = live.kept;
    state.save();
    try {
      await tmux.start(ask.id, argv, cwd: dir, cols: ask.cols, rows: ask.rows);
    } catch (e) {
      _live.remove(ask.id);
      await remote.client.removeChannel(live.line);
      await _set(ask.id, 'failed', '$e');
      return null;
    }
    // Claude taken up with nothing to say waits for the user from the
    // start; it says nothing until a turn has begun.
    live.state = spec.isClaude && first.isEmpty ? 'idle' : 'running';
    await _set(ask.id, live.state, null);
    log('[${_short(ask.id)}] ${spec.label} in $dir');
    _name(ask, first);
    if (spec.prompt == 'type' && first.isNotEmpty) {
      live.typing = Future<void>.delayed(
        const Duration(milliseconds: 600),
      ).then((_) => tmux.line(ask.id, first));
    }
    return live;
  }

  /// An ended chat of this worker's started again: Claude takes up its own
  /// session; any other agent starts afresh in the same chat.
  Future<void> _restart(String chat) async {
    final db = await _db;
    final row = await db
        .from('chats')
        .select()
        .eq('id', chat)
        .eq('worker_id', state.id)
        .maybeSingle();
    if (row == null) return;
    final ask = ChatAsk.fromJson(row);
    if (ask.mode == 'chat') {
      await _startTalk(ask, resume: ask.session);
      return;
    }
    await _start(ask, resume: ask.agent == 'claude' ? ask.session : null);
  }

  /// Where [ask] is to run, or null — the chat marked failed — if this
  /// computer has not got the agent or the folder.
  Future<(AgentSpec, String)?> _placeOf(ChatAsk ask) async {
    final spec = _specOf(ask.agent);
    if (spec == null) {
      await _set(ask.id, 'failed', 'There is no ${ask.agent} on $name.');
      return null;
    }
    final dir = _expand(ask.dir ?? home);
    if (!Directory(dir).existsSync()) {
      await _set(ask.id, 'failed', 'There is no folder $dir on $name.');
      return null;
    }
    return (spec, dir);
  }

  /// Starts [ask] spoken to in messages ([Talk]): fresh, or carrying on
  /// [resume], with [prompt] — else the chat's own first message — said
  /// once it is up.
  Future<_Talker?> _startTalk(
    ChatAsk ask, {
    String? resume,
    String? prompt,
  }) async {
    final place = await _placeOf(ask);
    if (place == null) return null;
    final (spec, dir) = place;
    final talker = _talks[ask.id] = await _Talker.make(
      this,
      ask,
      spec,
      session: resume,
      dir: dir,
    );
    try {
      await talker.wake();
    } catch (e) {
      _talks.remove(ask.id);
      await talker.close();
      await _set(ask.id, 'failed', '$e');
      return null;
    }
    final first = prompt ?? (resume != null ? '' : ask.prompt);
    log('[${_short(ask.id)}] ${spec.label} in $dir (chat)');
    if (first.isNotEmpty) {
      _name(ask, first);
      await talker.say(first);
    } else {
      await _set(ask.id, 'idle', null);
    }
    return talker;
  }

  /// A chat moved between its chat and its terminal: one program at a
  /// time has its session. Into the terminal, Claude or Codex is taken up
  /// there in its own screen; back, what was said there is read from the
  /// session's transcript into the chat.
  Future<void> _move(String chat, String to) async {
    final db = await _db;
    final row = await db
        .from('chats')
        .select()
        .eq('id', chat)
        .eq('worker_id', state.id)
        .maybeSingle();
    if (row == null) return;
    final ask = ChatAsk.fromJson(row);
    if (to == 'terminal') {
      final talker = _talks.remove(chat);
      if (talker == null) return;
      await talker.close();
      state.marks[chat] = DateTime.now().millisecondsSinceEpoch;
      state.save();
      await db.from('chats').update({'mode': 'terminal'}).eq('id', chat);
      await _start(ask, resume: talker.session, prompt: '');
      return;
    }
    if (to != 'chat' || _talks.containsKey(chat)) return;
    final live = _live.remove(chat);
    var session = ask.session;
    if (live != null) {
      session = live.session ?? session;
      await _putAway(chat, live);
    }
    await db
        .from('chats')
        .update({'mode': 'chat', 'session': session})
        .eq('id', chat);
    final place = await _placeOf(ask);
    if (place == null) return;
    final (spec, dir) = place;
    final talker = _talks[chat] = await _Talker.make(
      this,
      ask,
      spec,
      session: session,
      dir: dir,
    );
    final since = state.marks.remove(chat);
    state.save();
    if (since != null && session != null) talker.readBack(since);
    try {
      await talker.wake();
      await _set(chat, 'idle', null);
    } catch (e) {
      await _set(chat, 'idle', '$e');
    }
  }

  /// The seq [chat]'s next piece goes up as: past what was [kept] here and
  /// past what the server has — a worker ended hard last saved its seq up
  /// to a second before it sent more, and every piece after went up as one
  /// the server already had, and was refused.
  Future<int> _seqAfter(String chat, Map<String, int>? kept) async =>
      max(kept?['seq'] ?? 0, await _nextSeq(chat));

  static int _lengthOf(String path) {
    final file = File(path);
    return file.existsSync() ? file.lengthSync() : 0;
  }

  Future<int> _nextSeq(String chat) async {
    final db = await _db;
    final last = await db
        .from('chat_out')
        .select('seq')
        .eq('chat_id', chat)
        .order('seq', ascending: false)
        .limit(1);
    return last.isEmpty ? 0 : (last.first['seq'] as int) + 1;
  }

  /// The chats named while this worker runs, or being named: each once.
  final _named = <String>{};

  /// [ask] named from [said], the first thing it was told, as Claude's own
  /// app names its chats — unless it has a title, is a shell (a command
  /// says nothing of what the chat is for), or there is no Claude here to
  /// name it. The title goes in only while the chat still has none.
  void _name(ChatAsk ask, String said) {
    final text = said.trim();
    if (ask.title.isNotEmpty || ask.agent == 'shell') return;
    if (_named.contains(ask.id)) return;
    // A command to Claude's terminal, `/model` say: the next line may say.
    if (text.isEmpty || text.startsWith('/')) return;
    // Read once a chat: the book reads Claude's plugins and skills anew.
    final claude = _specOf('claude');
    _named.add(ask.id);
    if (claude == null) return;
    unawaited(
      _guard(() async {
        final title = await nameChat(text, command: '${claude.command.first}');
        if (title == null) return;
        final db = await _db;
        await db
            .from('chats')
            .update({'title': title})
            .eq('id', ask.id)
            .eq('title', '');
      }),
    );
  }

  Future<void> _set(String chat, String to, String? note) async {
    final db = await _db;
    await db.from('chats').update({'state': to, 'note': note}).eq('id', chat);
  }

  /// Reads on in every chat's files, and sends what has come if it is time.
  void _pump() {
    final now = DateTime.now();
    for (final MapEntry(key: chat, value: live) in _live.entries.toList()) {
      if (_readOut(chat, live)) {
        live.wroteAt = now;
        _castOut(live);
      }
      _readEvents(chat, live);
      if (!live.sending &&
          live.pending.isNotEmpty &&
          now.difference(live.sentAt) >= _gap) {
        unawaited(_guard(() => _send(chat, live)));
      }
    }
  }

  bool _readOut(String chat, _Live live) {
    final file = File(tmux.outOf(chat));
    if (!file.existsSync()) return false;
    final length = file.lengthSync();
    if (length <= live.offset) return false;
    final raf = file.openSync();
    try {
      raf.setPositionSync(live.offset);
      // At most a megabyte a read; the rest the next time round.
      final bytes = raf.readSync(min(length - live.offset, 1 << 20));
      live.offset += bytes.length;
      live.decoder.add(bytes);
    } finally {
      raf.closeSync();
    }
    return true;
  }

  /// What has been read since the last piece, broadcast at once: a row
  /// goes up a few times a second at most, and is heard through Postgres
  /// changes a quarter of a second or so later; a broadcast is heard in a
  /// few milliseconds. The rows stay the record, and fill any gap.
  void _castOut(_Live live) {
    final text = live.pending.toString();
    final from = max(live.cast, live.at);
    final to = live.at + text.length;
    if (to <= from) return;
    live.cast = to;
    final piece = text.substring(from - live.at);
    // Too big for a broadcast: its row brings it.
    if (piece.length > 100000) return;
    unawaited(
      live.line
          .sendBroadcastMessage(
            event: 'out',
            payload: {
              'life': live.life,
              'seq': live.seq,
              'start': live.at,
              'at': from,
              'data': piece,
            },
          )
          .then((_) {}, onError: (Object _) {}),
    );
  }

  /// Claude's hooks, one line each: its session, a turn begun or done, a
  /// question for whoever is at the keys.
  void _readEvents(String chat, _Live live) {
    final file = File(tmux.eventsOf(chat));
    if (!file.existsSync()) return;
    final length = file.lengthSync();
    if (length <= live.events) return;
    final raf = file.openSync();
    final String text;
    try {
      raf.setPositionSync(live.events);
      text = utf8.decode(
        raf.readSync(length - live.events),
        allowMalformed: true,
      );
    } finally {
      raf.closeSync();
    }
    // A line not yet ended is read again whole next time.
    final end = text.lastIndexOf('\n');
    if (end < 0) return;
    live.events += utf8.encode(text.substring(0, end + 1)).length;
    for (final line in LineSplitter.split(text.substring(0, end))) {
      if (line.trim().isEmpty) continue;
      try {
        _event(chat, live, jsonDecode(line) as Map);
      } on FormatException {
        // A hook's line cut by a crash: nothing to go on.
      }
    }
  }

  void _event(String chat, _Live live, Map event) {
    String? to;
    String? note;
    switch (event['hook_event_name']) {
      case 'SessionStart':
        final session = event['session_id'] as String?;
        if (session != null && session != live.session) {
          live.session = session;
          unawaited(
            _guard(
              () async => (await _db)
                  .from('chats')
                  .update({'session': session})
                  .eq('id', chat),
            ),
          );
        }
      case 'UserPromptSubmit':
        to = 'running';
      case 'PostToolUse' when live.state == 'asking':
        to = 'running';
      case 'Notification':
        to = 'asking';
        note = event['message'] as String?;
      case 'Stop':
        to = 'idle';
        final turn = live.turn;
        if (turn != null && !turn.isCompleted) {
          turn.complete((
            answered: true,
            text: event['last_assistant_message'] as String? ?? '',
          ));
        }
    }
    if (to != null && (to != live.state || note != null)) {
      live.state = to;
      unawaited(_guard(() => _set(chat, to!, note)));
    }
  }

  Future<void> _send(String chat, _Live live) =>
      _alone(live, () => _flush(chat, live, all: false));

  /// Runs [body] with nothing else sending for [live]: two pieces sent at
  /// once would both go up as the same seq.
  Future<void> _alone(_Live live, Future<void> Function() body) async {
    while (live.sending) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    live.sending = true;
    try {
      await body();
    } finally {
      live.sending = false;
    }
  }

  /// Sends what is pending, as one piece, or with [all] until nothing is.
  Future<void> _flush(String chat, _Live live, {bool all = true}) async {
    while (live.pending.isNotEmpty) {
      final data = live.pending.toString();
      final db = await _db;
      await db.from('chat_out').insert({
        'chat_id': chat,
        'seq': live.seq,
        'data': data,
      });
      // Only what was sent: more may have been read meanwhile.
      final rest = live.pending.toString().substring(data.length);
      live.pending
        ..clear()
        ..write(rest);
      live.at += data.length;
      live.seq++;
      live.sinceSnap++;
      live.sentAt = DateTime.now();
      state.chats[chat] = live.kept;
      if (!all) break;
    }
  }

  /// Once a second: chats whose program ended, snapshots due, and how far
  /// each chat's program has been read.
  Future<void> _check() async {
    var read = false;
    for (final MapEntry(key: chat, value: talker) in _talks.entries) {
      final offset = talker.talk?.offset;
      if (offset != null && state.talks[chat] != offset) {
        state.talks[chat] = offset;
        read = true;
      }
    }
    if (read && _live.isEmpty) state.save();
    if (_live.isEmpty) return;
    final panes = await tmux.panes();
    var changed = false;
    for (final MapEntry(key: chat, value: live) in _live.entries.toList()) {
      final pane = panes[Tmux.nameOf(chat)];
      if (pane == null || pane.dead) {
        await _end(chat, live, pane?.status);
        changed = true;
        continue;
      }
      final quiet = DateTime.now().difference(live.wroteAt).inSeconds >= 1;
      if (live.sinceSnap >= _snapEvery && quiet && !live.sending) {
        await _snapshot(chat, live);
        changed = true;
      }
    }
    if (changed || _live.isNotEmpty) state.save();
  }

  /// The screen as it stands, so the app can start from here; and what came
  /// before the snapshot ahead of it let go.
  Future<void> _snapshot(String chat, _Live live) => _alone(live, () async {
    _readOut(chat, live);
    await _flush(chat, live);
    await _snap(chat, live);
  });

  Future<void> _snap(String chat, _Live live) async {
    final shot = await tmux.snapshot(chat);
    if (shot == null) return;
    final db = await _db;
    await db.from('chat_out').insert({
      'chat_id': chat,
      'seq': live.seq,
      'data': shot,
      'snap': true,
    });
    final before = live.snap;
    live
      ..lastSnap = before
      ..snap = live.seq
      ..seq = live.seq + 1
      ..sinceSnap = 0;
    if (before >= 0) {
      await db.from('chat_out').delete().eq('chat_id', chat).lt('seq', before);
    }
  }

  /// A chat whose program has ended: the last of it sent, its terminal put
  /// away.
  Future<void> _end(String chat, _Live live, int? status) async {
    // Once: the check each second may find it ended while it is ended here.
    if (_live[chat] != live) return;
    _live.remove(chat);
    await _putAway(chat, live);
    final failed = status != null && status != 0;
    await _set(
      chat,
      failed ? 'failed' : 'ended',
      failed ? '${live.spec.label} exited with $status.' : null,
    );
    final turn = live.turn;
    if (turn != null && !turn.isCompleted) {
      turn.complete((answered: false, text: ''));
    }
    log('[${_short(chat)}] ended${failed ? ' ($status)' : ''}');
  }

  /// A terminal done with, already out of [_live]: the last of it sent, its
  /// tmux session and files put away.
  Future<void> _putAway(String chat, _Live live) async {
    _readOut(chat, live);
    _readEvents(chat, live);
    live.decoder.close();
    await _alone(live, () => _flush(chat, live));
    await remote.client.removeChannel(live.line);
    await tmux.kill(chat);
    tmux.forget(chat);
    state.chats.remove(chat);
    state.save();
  }

  /// A chat deleted in the app: its terminal goes with it.
  Future<void> _drop(String chat) async {
    final talker = _talks.remove(chat);
    if (talker != null) {
      talker.forgotten = true;
      await talker.close();
      talker.turn?.complete((answered: false, text: ''));
      talker.turn = null;
    }
    final live = _live.remove(chat);
    if (live != null) await remote.client.removeChannel(live.line);
    await tmux.kill(chat);
    tmux.forget(chat);
    state.chats.remove(chat);
    state.save();
    final turn = live?.turn;
    if (turn != null && !turn.isCompleted) {
      turn.complete((answered: false, text: ''));
    }
  }

  /// A task's errand, done as a chat of this worker's, so the app can watch
  /// it and talk to it: Claude spoken to in messages, the answer its first
  /// turn's last. Handed back, the task's chat carries on Claude's session.
  Future<Answer> errand(
    Errand errand, {
    required String permission,
    required Duration timeout,
  }) async {
    final db = await _db;
    String? chat;
    if (errand.resume != null && errand.task != null) {
      final row = await db
          .from('chats')
          .select('id')
          .eq('task_uuid', errand.task!)
          .eq('worker_id', state.id)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      chat = row?['id'] as String?;
    }
    if (chat != null) {
      final old = _live[chat];
      if (old != null) {
        await tmux.kill(chat);
        await _end(chat, old, 0);
      }
      await _talks.remove(chat)?.close();
      await db
          .from('chats')
          .update({'model': errand.model, 'state': 'running', 'mode': 'chat'})
          .eq('id', chat);
    } else {
      final made = await db
          .from('chats')
          .insert({
            'worker_id': state.id,
            'agent': 'claude',
            'title': errand.title ?? '',
            'model': errand.model,
            'dir': errand.dir,
            'permission': permission,
            'prompt': errand.prompt,
            'task_uuid': errand.task,
            'state': 'running',
            'mode': 'chat',
          })
          .select()
          .single();
      chat = made['id'] as String;
    }
    final row = await db.from('chats').select().eq('id', chat).single();
    final turn = Completer<_Turn>();
    _waiting[chat] = turn;
    final talker = await _startTalk(
      ChatAsk.fromJson(row),
      resume: errand.resume,
      prompt: errand.prompt,
    );
    _waiting.remove(chat);
    if (talker == null) {
      final failed = await db
          .from('chats')
          .select('note')
          .eq('id', chat)
          .single();
      return Answer(false, '${failed['note'] ?? 'Not started.'}');
    }
    final _Turn ended;
    try {
      ended = await turn.future.timeout(timeout);
    } on TimeoutException {
      return Answer(
        false,
        'Still at work after ${timeout.inMinutes} minutes; it goes on in its '
        'chat in Caldo\'s Agents tab.',
        session: talker.session,
      );
    } finally {
      if (talker.turn == turn) talker.turn = null;
    }
    return ended.answered
        ? Answer(true, ended.text.trim(), session: talker.session)
        : Answer(
            false,
            'Claude ended before it answered.',
            session: talker.session,
          );
  }

  /// A turn an errand waits on, handed to its chat's talker as it is made:
  /// a quick turn could end before the talker were given it after.
  final Map<String, Completer<_Turn>> _waiting = {};
}

/// One chat spoken to in messages here: its [Talk] while its program is
/// up, and the way what it says reaches the app — each item as a row of
/// `chat_items`, said again as it changes; an answer's words as they are
/// written as a broadcast on the chat's private channel, a few times a
/// second, which a row would be too slow and too heavy for.
class _Talker implements TalkSink {
  final Worker worker;
  final ChatAsk ask;
  final AgentSpec spec;
  final String dir;
  Talk? talk;
  String? session;
  String state = 'idle';
  Completer<_Turn>? turn;

  /// Deleted in the app: nothing more is written for it.
  bool forgotten = false;
  bool _closing = false;

  /// The seq the next new item goes up as, and each item's own.
  int _seq;
  final _seqs = <String, int>{};
  final _queue = <String, Map<String, Object?>>{};
  bool _posting = false;

  final _pieces = <String, StringBuffer>{};
  final _sent = <String, int>{};
  final _whole = <String>{};
  Timer? _piecing;
  final RealtimeChannel _channel;

  /// What a resumed Codex thread said after this, shown when it is up.
  int? _since;

  _Talker._(
    this.worker,
    this.ask,
    this.spec,
    this._seq, {
    required this.dir,
    this.session,
  }) : _channel = worker._lineOf(ask.id);

  /// A broadcast's own payload, whether or not it comes wrapped.
  static Map _payloadOf(Map message) =>
      message['payload'] is Map ? message['payload'] as Map : message;

  /// [payload] sent on the chat's channel — a copy: the client writes its
  /// own keys into the map it is given, and a row queued to be kept would
  /// go up with them.
  void _broadcast(String event, Map<String, dynamic> payload) => unawaited(
    _channel
        .sendBroadcastMessage(event: event, payload: {...payload})
        .then((_) {}, onError: (Object _) {}),
  );

  static Future<_Talker> make(
    Worker worker,
    ChatAsk ask,
    AgentSpec spec, {
    String? session,
    String? dir,
  }) async {
    final db = await worker._db;
    // Each item's place, so one said again — a tool's output come after
    // the worker started again — keeps it rather than going to the end.
    final items = await db
        .from('chat_items')
        .select('id, seq')
        .eq('chat_id', ask.id);
    final seqs = {for (final i in items) i['id'] as String: i['seq'] as int};
    return _Talker._(
        worker,
        ask,
        spec,
        seqs.values.fold(-1, max) + 1,
        dir: dir ?? worker._expand(ask.dir ?? worker.home),
        session: session ?? ask.session,
      )
      .._seqs.addAll(seqs)
      ..turn = worker._waiting[ask.id];
  }

  /// Where its program's files are kept, beside the terminals'.
  String get _files => '${worker.tmux.dir}/${ask.id}.talk';

  /// Its program gone: nothing to read on from.
  void _forgetOffset() {
    if (worker.state.talks.remove(ask.id) != null) worker.state.save();
  }

  /// Its program as the worker before this one left it, taken up again if
  /// there is one: true if there was.
  bool takeUp() {
    final offset = worker.state.talks[ask.id];
    // Read from its start, unheard, if where the last worker got to was
    // never saved: what was said is on the server already.
    final kept = Kept.find(_files, offset ?? 1 << 62);
    if (kept == null) return false;
    final made = Talk.of(spec, ask, this, dir);
    if (made == null) return false;
    talk = made..takeUp(kept, session: session);
    return true;
  }

  /// Its program started, if it is not up: carrying on its session. Asked
  /// twice at once — two messages heard together — it starts once, and
  /// neither is said before it is up.
  Future<void> wake() => talk != null && _waking == null
      ? Future.value()
      : _waking ??= _wake().whenComplete(() => _waking = null);

  Future<void>? _waking;

  Future<void> _wake() async {
    if (talk != null) return;
    final made = Talk.of(spec, ask, this, dir);
    if (made == null) {
      throw StateError('${spec.label} has no chat, only a terminal.');
    }
    if (made is CodexTalk) made.since = _since;
    _since = null;
    _closing = false;
    talk = made;
    try {
      await made.start(
        files: _files,
        resume: resumable(spec, worker.home, dir, session),
      );
    } catch (e) {
      talk = null;
      await made.close();
      rethrow;
    }
  }

  Future<void> say(String text, {String? id}) async {
    if (text.trim().isEmpty) return;
    await wake();
    talk!.say(text, id: id);
  }

  void answer(String item, String choice) => talk?.answer(item, choice);

  void interrupt() => talk?.interrupt();

  Future<void> close() async {
    _closing = true;
    await talk?.close();
    talk = null;
    _forgetOffset();
    _piecing?.cancel();
    await worker.remote.client.removeChannel(_channel);
  }

  /// What was said in the chat's terminal since [since]: read from
  /// Claude's transcript now, or from Codex's thread as it is taken up.
  void readBack(int since) {
    if (spec.id == 'codex') {
      _since = since;
      return;
    }
    final file = File(claudeTranscript(worker.home, dir, session!));
    if (!file.existsSync()) return;
    final reader = ClaudeTalk(spec, ask, this, dir: dir);
    for (final line in file.readAsLinesSync()) {
      try {
        final json = jsonDecode(line) as Map;
        final at = DateTime.tryParse('${json['timestamp']}');
        if (at == null || at.millisecondsSinceEpoch <= since) continue;
        if (json['type'] == 'assistant' || json['type'] == 'user') {
          reader.take(json);
        }
      } on FormatException {
        // A line cut short: the program was ended as it wrote it.
      }
    }
  }

  @override
  void item(String id, String kind, Map<String, Object?> body) {
    if (forgotten) return;
    if (kind == 'text') {
      _whole.add(id);
      _pieces.remove(id);
    }
    final seq = _seqs[id] ??= _seq++;
    final row = {
      'chat_id': ask.id,
      'id': id,
      'seq': seq,
      'kind': kind,
      'body': body,
    };
    _queue[id] = row;
    // Heard at once on the channel; the row, a quarter of a second behind,
    // is what is kept. One too big for a broadcast comes by the row alone.
    if (jsonEncode(body).length < 100000) _broadcast('item', row);
    unawaited(_post());
  }

  /// The rows waiting, sent together, in turn: one item said twice quickly
  /// goes up once, as it last stood.
  Future<void> _post() async {
    if (_posting) return;
    _posting = true;
    try {
      while (_queue.isNotEmpty && !forgotten) {
        final rows = _queue.values.toList();
        _queue.clear();
        try {
          final db = await worker._db;
          await db.from('chat_items').upsert(rows);
        } catch (e) {
          worker.log('[${_short(ask.id)}] items not sent: $e');
          for (final row in rows) {
            _queue.putIfAbsent(row['id'] as String, () => row);
          }
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
    } finally {
      _posting = false;
    }
  }

  @override
  void delta(String id, String text) {
    if (forgotten || _whole.contains(id) || text.isEmpty) return;
    (_pieces[id] ??= StringBuffer()).write(text);
    _piecing ??= Timer(const Duration(milliseconds: 40), _sendPieces);
  }

  void _sendPieces() {
    _piecing = null;
    for (final MapEntry(key: id, value: text) in _pieces.entries) {
      if (text.isEmpty) continue;
      final at = _sent[id] ?? 0;
      _sent[id] = at + text.length;
      unawaited(
        _channel
            .sendBroadcastMessage(
              event: 'delta',
              payload: {'id': id, 'at': at, 'text': text.toString()},
            )
            .then((_) {}, onError: (Object _) {}),
      );
      text.clear();
    }
  }

  @override
  void stands(String to, {String? note}) {
    if (forgotten || (to == state && note == null)) return;
    state = to;
    _broadcast('state', {'state': to, 'note': note});
    unawaited(worker._guard(() => worker._set(ask.id, to, note)));
  }

  @override
  void inSession(String id) {
    if (id == session || forgotten) return;
    session = id;
    unawaited(
      worker._guard(
        () async => (await worker._db)
            .from('chats')
            .update({'session': id})
            .eq('id', ask.id),
      ),
    );
  }

  @override
  void turnEnded(String answer, {bool failed = false}) {
    final waiting = turn;
    turn = null;
    if (waiting != null && !waiting.isCompleted) {
      waiting.complete((answered: !failed, text: answer));
    }
  }

  @override
  void exited(int code, String why) {
    talk = null;
    _forgetOffset();
    if (_closing || forgotten) return;
    // Ended by itself: the chat waits to be taken up again with the next
    // message, unless it never began.
    final failed = code != 0;
    if (failed) {
      item('x${DateTime.now().millisecondsSinceEpoch}', 'note', {
        'text': why.isEmpty ? '${spec.label} exited with $code.' : why,
        'error': true,
      });
    }
    stands(session == null && failed ? 'failed' : 'idle');
    turnEnded('', failed: true);
    worker.log('[${_short(ask.id)}] ${spec.label} exited ($code)');
  }
}

String _short(String id) => id.substring(0, 8);

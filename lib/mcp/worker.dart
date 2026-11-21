import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:supabase/supabase.dart';

import 'agents.dart';
import 'remote.dart';
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

  WorkerState(this.file) {
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map;
      id = json['id'] as String;
      name = json['name'] as String?;
      for (final MapEntry(:key, :value)
          in (json['chats'] as Map? ?? const {}).entries) {
        chats[key as String] = (value as Map).cast<String, int>();
      }
    } catch (_) {
      id = _uuid();
    }
  }

  void save() {
    file.parent.createSync(recursive: true);
    final next = File('${file.path}.next')
      ..writeAsStringSync(jsonEncode({'id': id, 'name': name, 'chats': chats}));
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
      final kept = state.chats[ask.id];
      final pane = panes[Tmux.nameOf(ask.id)];
      final spec = _specOf(ask.agent);
      if (pane != null && kept != null && spec != null) {
        _live[ask.id] =
            _Live(
                ask,
                spec,
                offset: kept['offset'] ?? 0,
                events: kept['events'] ?? 0,
                seq: kept['seq'] ?? 0,
                snap: kept['snap'] ?? -1,
                lastSnap: kept['last_snap'] ?? -1,
              )
              ..state = row['state'] as String
              ..session = row['session'] as String?;
        log('[${_short(ask.id)}] taken up again');
      } else {
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
            if (gone && _live.containsKey(id)) {
              unawaited(_guard(() => _drop(id as String)));
            }
            if (!_wake.isCompleted) _wake.complete();
          },
        )
        .subscribe();
  }

  /// A row of input heard by realtime: put in at once, not after a look.
  void _heard(Map<String, dynamic> row) {
    final chat = row['chat_id'] as String?;
    if (chat == null) return;
    final mine = _live.containsKey(chat);
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
      await _guard(() => _start(ChatAsk.fromJson(row)));
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
      if (id <= _applied) {
        done.add(id);
        continue;
      }
      _applied = id;
      done.add(id);
      final chat = row['chat_id'] as String;
      final live = _live[chat];
      switch (row['kind']) {
        case 'start' when live == null:
          await _restart(chat);
        case 'stop' when live != null:
          await tmux.kill(chat);
        case 'size':
          final cols = row['cols'] as int?;
          final rows = row['rows'] as int?;
          if (cols == null || rows == null) break;
          if (live != null) {
            live.typing = live.typing.then(
              (_) => tmux.resize(chat, cols, rows),
            );
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
          live.typing = live.typing.then((_) => tmux.line(chat, text));
      }
    }
    if (done.isNotEmpty) {
      final db = await _db;
      await db.from('chat_in').delete().inFilter('id', done);
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
      seq: kept?['seq'] ?? await _nextSeq(ask.id),
      snap: kept?['snap'] ?? -1,
      lastSnap: kept?['last_snap'] ?? -1,
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
      await _set(ask.id, 'failed', '$e');
      return null;
    }
    // Claude taken up with nothing to say waits for the user from the
    // start; it says nothing until a turn has begun.
    live.state = spec.isClaude && first.isEmpty ? 'idle' : 'running';
    await _set(ask.id, live.state, null);
    log('[${_short(ask.id)}] ${spec.label} in $dir');
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
    await _start(ask, resume: ask.agent == 'claude' ? ask.session : null);
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

  Future<void> _set(String chat, String to, String? note) async {
    final db = await _db;
    await db.from('chats').update({'state': to, 'note': note}).eq('id', chat);
  }

  /// Reads on in every chat's files, and sends what has come if it is time.
  void _pump() {
    final now = DateTime.now();
    for (final MapEntry(key: chat, value: live) in _live.entries.toList()) {
      final grew = _readOut(chat, live);
      if (grew) live.wroteAt = now;
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
      live.seq++;
      live.sinceSnap++;
      live.sentAt = DateTime.now();
      state.chats[chat] = live.kept;
      if (!all) break;
    }
  }

  /// Once a second: chats whose program ended, and snapshots due.
  Future<void> _check() async {
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
    _readOut(chat, live);
    _readEvents(chat, live);
    live.decoder.close();
    await _alone(live, () => _flush(chat, live));
    await tmux.kill(chat);
    tmux.forget(chat);
    state.chats.remove(chat);
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

  /// A chat deleted in the app: its terminal goes with it.
  Future<void> _drop(String chat) async {
    final live = _live.remove(chat);
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
  /// it and talk to it: Claude in a terminal, the answer its first turn's
  /// last message. Handed back, the task's chat is taken up again in
  /// Claude's same session.
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
      await db
          .from('chats')
          .update({'model': errand.model, 'state': 'running'})
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
          })
          .select()
          .single();
      chat = made['id'] as String;
    }
    final row = await db.from('chats').select().eq('id', chat).single();
    final live = await _start(
      ChatAsk.fromJson(row),
      resume: errand.resume,
      prompt: errand.prompt,
    );
    if (live == null) {
      final failed = await db
          .from('chats')
          .select('note')
          .eq('id', chat)
          .single();
      return Answer(false, '${failed['note'] ?? 'Not started.'}');
    }
    final turn = live.turn = Completer<_Turn>();
    final _Turn ended;
    try {
      ended = await turn.future.timeout(timeout);
    } on TimeoutException {
      return Answer(
        false,
        'Still at work after ${timeout.inMinutes} minutes; it goes on in its '
        'chat in Caldo\'s Agents tab.',
        session: live.session,
      );
    }
    return ended.answered
        ? Answer(true, ended.text.trim(), session: live.session)
        : Answer(
            false,
            'Claude ended before it answered.',
            session: live.session,
          );
  }
}

String _short(String id) => id.substring(0, 8);

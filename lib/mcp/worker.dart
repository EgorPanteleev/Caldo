import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:supabase/supabase.dart';

import '../models/task.dart';
import 'accounts.dart';
import 'agents.dart';
import 'asks_back.dart';
import 'kept.dart';
import 'notices.dart';
import 'remote.dart';
import 'subscriptions.dart';
import 'talk.dart';
import 'terminal.dart';
import 'tools.dart';
import 'usage.dart';
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

  /// Its settings changed while it was at work: started again with them
  /// once its turn is done.
  bool retune = false;

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
    this.caldo,
    void Function(String line)? log,
    GitHub? github,
  }) : log = log ?? print,
       github = github ?? GitHub();

  /// The account's tasks, for those its chats were sent from: where each
  /// stands and the answer written back to it, and one left to start when
  /// due started then. Without it a task's chat is only a chat.
  final Caldo? caldo;

  /// Reads the pull requests its chats are subscribed to.
  final GitHub github;

  /// At most this often a chat's output goes up: a spinner redrawn every
  /// tenth of a second would otherwise be ten rows a second.
  static const _gap = Duration(milliseconds: 200);

  /// A snapshot after this many pieces, once the terminal is quiet.
  static const _snapEvery = 300;

  Future<SupabaseClient> get _db => remote.signedIn();

  /// The accounts chats may run under, beside the worker's own.
  late final logins = AgentLogins(home: home, root: '${book.config}/accounts');

  String get name => state.name ?? Platform.localHostname;

  Future<Never> run() async {
    // Nothing goes on until the server has heard of this worker: a chat
    // can only be asked of one it knows.
    for (var wait = 5; ; wait = min(wait * 2, 300)) {
      try {
        await _hello();
        // Read before any chat is taken up, so each starts under its own.
        await _guard(_tendAccounts);
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
    Timer.periodic(_watchEvery, (_) => _watchSoon(Duration.zero));
    _watchSoon(const Duration(seconds: 5));
    _tendSoon(const Duration(seconds: 20));
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
        .inFilter('state', [
          'running',
          'asking',
          'idle',
          'finished',
          'your_turn',
          'limited',
        ]);
    for (final row in mine) {
      final ask = ChatAsk.fromJson(row);
      _know(ask);
      // Answered before: its task has the answer already.
      if (_ready(row['state'])) _answered.add(ask.id);
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
        if (!_ready(row['state'])) {
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
    // A message left for later, or taken back: the next one's time is
    // looked at again. A channel of its own, so a server without the table
    // yet costs only this.
    remote.client
        .channel('caldo-worker-later')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chat_later',
          callback: (_) {
            if (!_wake.isCompleted) _wake.complete();
          },
        )
        .subscribe();
    // A subscription made: looked at soon, so the first round of what it
    // watches is seen before anything is told. One changed or put away is
    // read at the next round; its worker's own writes, of what it has
    // seen, come back as changes too.
    remote.client
        .channel('caldo-worker-subscriptions')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'chat_subscriptions',
          callback: (_) => _watchSoon(const Duration(seconds: 1)),
        )
        .subscribe();
    // An account asked for, a code handed back, one removed: seen to at
    // once.
    remote.client
        .channel('caldo-worker-accounts')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'agent_accounts',
          callback: (change) {
            // Its own writes come back too: a limit read is no news.
            final row = change.newRecord;
            if (change.eventType == PostgresChangeEvent.update &&
                row['state'] == 'ready' &&
                _accounts[row['id']]?.state == 'ready') {
              return;
            }
            _tendSoon(const Duration(milliseconds: 300));
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
      await _takeAsked(row, 'new');
    }
    await _startDue();
    final typed = await db
        .from('chat_in')
        .select('*, chats!inner(worker_id)')
        .eq('chats.worker_id', state.id)
        .order('id', ascending: true)
        .limit(500);
    await _take(typed);
    await _sayLater();
  }

  /// Starts the chat [row] asks for, once taken from [from]: a second
  /// worker started with the same id — or this one looking twice — finds
  /// it taken and leaves it. A task's chat sent with words of its own
  /// ([ChatAsk] `preface`) is told its task as the task is now.
  Future<void> _takeAsked(Map<String, dynamic> row, String from) async {
    final db = await _db;
    final taken = await db
        .from('chats')
        .update({'state': 'running'})
        .eq('id', row['id'])
        .eq('state', from)
        .select();
    if (taken.isEmpty) return;
    var ask = ChatAsk.fromJson(row);
    _know(ask);
    _tellTask(ask.id, AgentState.working);
    final told = await _toldNow(row);
    if (told != null && told != ask.prompt) {
      await db.from('chats').update({'prompt': told}).eq('id', ask.id);
      ask = ChatAsk.fromJson({...row, 'prompt': told});
    }
    await _guard(
      () async =>
          ask.mode == 'chat' ? await _startTalk(ask) : await _start(ask),
    );
  }

  /// What a task's chat sent with a preface is told first, from its task
  /// as it is now — notes added since it was sent, say — or null to keep
  /// the words it was sent with.
  Future<String?> _toldNow(Map row) async {
    final preface = row['preface'] as String?;
    final task = row['task_uuid'] as String?;
    final caldo = this.caldo;
    if (preface == null || task == null || caldo == null) return null;
    try {
      await caldo.refresh();
    } catch (_) {
      return null;
    }
    final h = caldo.book.tasks.where((t) => t.uuid == task).firstOrNull;
    return h == null ? null : taskMessage(h.task, preface);
  }

  DateTime _dueLookedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Starts the chats left to wait for their tasks whose day or time has
  /// come — read from the task each time, so one moved to another day
  /// waits for that day — and ends those whose task went meanwhile.
  Future<void> _startDue() async {
    final caldo = this.caldo;
    if (caldo == null) return;
    // Every write to a chat wakes the look, its worker's own among them:
    // the tasks are pulled for this a few times a minute at most.
    final now = DateTime.now();
    if (now.difference(_dueLookedAt) < const Duration(seconds: 10)) return;
    _dueLookedAt = now;
    final db = await _db;
    final rows = await db
        .from('chats')
        .select()
        .eq('worker_id', state.id)
        .eq('state', 'waiting');
    // One with no task waits for the user to start it, whenever.
    final waiting = [...rows.where((r) => r['task_uuid'] != null)];
    if (waiting.isEmpty) return;
    await caldo.refresh();
    for (final row in waiting) {
      final uuid = row['task_uuid'] as String?;
      final h = uuid == null
          ? null
          : caldo.book.tasks.where((t) => t.uuid == uuid).firstOrNull;
      if (h == null || h.task.done) {
        await _set(
          row['id'] as String,
          'ended',
          h == null
              ? 'Its task was deleted before it was due.'
              : 'Its task was ticked off before it was due.',
        );
        continue;
      }
      if (!h.task.isDueBy(now)) continue;
      log('[${_short(row['id'] as String)}] its task is due');
      await _takeAsked(row, 'waiting');
    }
  }

  /// Wakes [_look] when the next message left for later is due.
  Timer? _nextLater;

  /// Says the messages left for later whose time has come, each as if
  /// typed then, and wakes for the next. One to a chat not running here
  /// waits for it to be started again.
  Future<void> _sayLater() async {
    final db = await _db;
    final rows = await db
        .from('chat_later')
        .select('id, chat_id, data, key, send_at, chats!inner(worker_id)')
        .eq('chats.worker_id', state.id)
        .order('send_at', ascending: true)
        .limit(200);
    final now = DateTime.now();
    DateTime? next;
    for (final row in rows) {
      final chat = row['chat_id'] as String;
      final at = DateTime.parse(row['send_at'] as String);
      if (at.isAfter(now)) {
        next ??= at;
        continue;
      }
      if (!_live.containsKey(chat) && !_talks.containsKey(chat)) continue;
      // Deleted first: one taken back from the app meanwhile is not said.
      final taken = await db
          .from('chat_later')
          .delete()
          .eq('id', row['id'])
          .select('id');
      if (taken.isEmpty) continue;
      log('[${_short(chat)}] said what was left for later');
      await _apply(chat, {
        'kind': 'line',
        'data': row['data'],
        'key': row['key'],
      });
    }
    _nextLater?.cancel();
    if (next != null) {
      _nextLater = Timer(next.difference(DateTime.now()), () {
        if (!_wake.isCompleted) _wake.complete();
      });
    }
  }

  /// How often what chats are subscribed to is looked at: a minute late
  /// at most, a call to GitHub a repository a minute — far inside its
  /// limit of 5000 an hour.
  static const _watchEvery = Duration(minutes: 1);

  Timer? _watchTimer;
  Future<void>? _watching;

  void _watchSoon(Duration wait) {
    _watchTimer?.cancel();
    _watchTimer = Timer(wait, () {
      // One round at a time: a slow `gh` must not be asked twice.
      _watching ??= _guard(_watch).whenComplete(() => _watching = null);
    });
  }

  /// Looks at what this worker's chats are subscribed to and tells each
  /// chat what has happened since the last look, as one message. What a
  /// chat has seen is written before it is told — a write that keeps
  /// failing must not tell it the same every minute. One for a chat not
  /// running here is left as it was, and told once it is started again.
  Future<void> _watch() async {
    final db = await _db;
    final rows = await db
        .from('chat_subscriptions')
        .select('*, chats!inner(worker_id, dir, agent)')
        .eq('chats.worker_id', state.id)
        .order('id', ascending: true);
    if (rows.isEmpty) return;
    final read = <String, Future<List<Pull>>>{};
    for (final row in rows) {
      var sub = Subscription.fromJson(row);
      final chat = sub.chat;
      final of = row['chats'] as Map? ?? const {};
      // A shell would run the words as a command.
      if (_specOf('${of['agent']}')?.talks != true) continue;
      final dir = _expand(of['dir'] as String? ?? home);
      Future<void> fail(Object e) async {
        if (sub.error == '$e') return;
        log('[${_short(chat)}] cannot watch ${sub.label}: $e');
        await db
            .from('chat_subscriptions')
            .update({'error': '$e'})
            .eq('id', sub.id);
      }

      if (sub.target == null) {
        try {
          final repo = await github.repoIn(dir);
          await db
              .from('chat_subscriptions')
              .update({'target': repo, 'error': null})
              .eq('id', sub.id);
          sub = Subscription.fromJson({...row, 'target': repo, 'error': null});
        } catch (e) {
          await fail(e);
          continue;
        }
      }
      final List<Pull> pulls;
      try {
        pulls = await (read[sub.target!] ??= github.pulls(sub.target!));
      } catch (e) {
        await fail(e);
        continue;
      }
      var (:told, :seen) = pullEvents(sub, pulls);
      final live = _live.containsKey(chat) || _talks.containsKey(chat);
      if (told.isNotEmpty && !live) continue;
      final known = jsonEncode(seen) == jsonEncode(sub.seen ?? const {});
      if (!known || sub.error != null) {
        await db
            .from('chat_subscriptions')
            .update({'seen': seen, 'error': null})
            .eq('id', sub.id);
      }
      if (told.isEmpty) continue;
      final by = await _openers(sub, pulls);
      if (by.isNotEmpty) told = pullEvents(sub, pulls, by: by).told;
      log('[${_short(chat)}] told of ${told.length} in ${sub.label}');
      await _apply(chat, {
        'kind': 'line',
        'data': pullsMessage(sub, told),
        'key': 'e${sub.id}-${DateTime.now().microsecondsSinceEpoch}',
        'sender': eventSender(sub),
      });
    }
  }

  /// Which of the account's chats opened [pulls], by number, as [sub]'s
  /// events name them. None if it can't be read: the events go as before.
  Future<Map<int, String>> _openers(Subscription sub, List<Pull> pulls) async {
    try {
      final db = await _db;
      final rows = await db
          .from('chat_pulls')
          .select('number, chat_id, chats(title, prompt)')
          .eq('repo', sub.target!)
          .inFilter('number', [for (final p in pulls) p.number]);
      return {
        for (final row in rows)
          row['number'] as int: openerLabel(
            row['chat_id'] as String,
            _chatTitle(row['chats'] as Map? ?? const {}),
            told: sub.chat,
          ),
      };
    } catch (e) {
      log('[${_short(sub.chat)}] cannot tell who opened pull requests: $e');
      return const {};
    }
  }

  static String _chatTitle(Map chat) {
    final title = '${chat['title'] ?? ''}'.trim();
    if (title.isNotEmpty) return title;
    return clip('${chat['prompt'] ?? ''}'.trim().split('\n').first, 60);
  }

  /// Notes the pull requests one of [chat]'s tool calls opened
  /// (`chat_pulls`), so a chat told of them knows whom to talk to. The
  /// first chat to show one keeps it: a second `gh pr create` on the same
  /// branch only prints the link to the one already there.
  void _notePulls(String chat, String tool, String command, String output) {
    final made = pullsOpened(tool, command, output);
    if (made.isEmpty) return;
    unawaited(
      _guard(() async {
        final db = await _db;
        // Only the rows new here come back: one shown again isn't told
        // again.
        final kept = await db
            .from('chat_pulls')
            .upsert(
              [
                for (final p in made)
                  {
                    'chat_id': chat,
                    'repo': p.repo,
                    'number': p.number,
                    'url': p.url,
                  },
              ],
              onConflict: 'user_id,repo,number',
              ignoreDuplicates: true,
            )
            .select('repo, number');
        log(
          '[${_short(chat)}] opened '
          '${made.map((p) => '${p.repo}#${p.number}').join(', ')}',
        );
        for (final row in kept) {
          notices.opened(chat, '${row['repo']}#${row['number']}');
        }
      }),
    );
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
        final text = row['data'] as String? ?? '';
        if (!_isEvent(row)) _name(talker.ask, text);
        notices.heard(chat, row['sender'] is Map ? row['sender'] as Map : null);
        await _inTurn(chat, () async {
          await talker.say(
            text,
            id: key is String ? 'u$key' : null,
            files: await _fetch(chat, row['files']),
            sender: row['sender'] is Map ? row['sender'] as Map : null,
          );
        });
      case 'answer' when talker != null:
        final (item, choice, answers) = answerOf(row['data'] as String?);
        if (item != null) talker.answer(item, choice, answers: answers);
      case 'interrupt' when talker != null:
        talker.interrupt();
      case 'clear' when talker != null:
        await talker.clear();
      case 'stop' when talker != null:
        _talks.remove(chat);
        await talker.close();
        await _set(chat, 'ended', null);
      case 'mode':
        await _move(chat, row['data'] as String? ?? '');
      case 'settings':
        await _retune(chat);
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
        notices.typed(chat);
        final bytes = utf8.encode(row['data'] as String? ?? '');
        live.typing = live.typing.then((_) => tmux.keys(chat, bytes));
      case 'line' when live != null:
        final text = row['data'] as String? ?? '';
        if (!_isEvent(row)) _name(live.ask, text);
        final files = row['files'];
        final sender = row['sender'] is Map ? row['sender'] as Map : null;
        notices.heard(chat, sender);
        live.typing = live.typing.then(
          (_) async => tmux.line(
            chat,
            withSender(withFiles(text, await _fetch(chat, files)), sender),
          ),
        );
    }
  }

  /// Whether [row] tells of what the chat is subscribed to: not words a
  /// chat is named by.
  static bool _isEvent(Map row) =>
      row['sender'] is Map && (row['sender'] as Map)['event'] != null;

  /// Each chat's messages, said one after another: one sent with files
  /// waits on their taking down, and one typed after it, heard meanwhile,
  /// must not go first.
  final _saying = <String, Future<void>>{};

  Future<void> _inTurn(String chat, Future<void> Function() say) {
    final said = (_saying[chat] ?? Future.value()).then((_) => say());
    _saying[chat] = said.then((_) {}, onError: (_) {});
    return said;
  }

  /// The files sent with a message to [chat], taken down from the server
  /// into the chat's own folder on this computer and deleted there; the
  /// agent is told where each is. One not taken down is told as such.
  Future<List<Given>> _fetch(String chat, Object? files) async {
    if (files is! List || files.isEmpty) return const [];
    // Offline, or the session not renewed: the files are told as not
    // fetched and the words still go. Thrown, they would be lost, and in
    // a terminal every line after them too (`typing` stays failed).
    SupabaseClient? db;
    String? given;
    try {
      db = await _db;
      given = tmux.givenOf(chat);
    } catch (e) {
      log('[${_short(chat)}] could not take its files down: $e');
    }
    final bucket = db?.storage.from('chat-files');
    final user = db?.auth.currentUser?.id;
    final out = <Given>[];
    for (final f in files.whereType<Map>()) {
      final key = '${f['key'] ?? ''}';
      final name = '${f['name'] ?? key.split('/').last}';
      final mime = '${f['mime'] ?? 'application/octet-stream'}';
      final size = f['size'] is int ? f['size'] as int : 0;
      // "<chat>/<uuid>": the server takes no key in other letters than
      // Latin, so the name comes beside it — and, being the app's, is
      // kept from leaving the chat's folder here.
      final parts = key.split('/');
      final safe = name
          .replaceAll(RegExp(r'[/\\\x00]'), '_')
          .replaceFirst(RegExp(r'^\.+'), '');
      String? path;
      if (bucket != null &&
          given != null &&
          user != null &&
          parts.length == 2 &&
          parts.first == chat &&
          RegExp(r'^[\w-]+$').hasMatch(parts.last)) {
        try {
          final bytes = await bucket.download('$user/$key');
          final file = File(
            '$given/${parts.last}/${safe.isEmpty ? 'file' : safe}',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes, flush: true);
          path = file.path;
        } catch (e) {
          log('[${_short(chat)}] could not take $name down: $e');
        }
        if (path != null) {
          // Left there, it is only the server's room spent.
          await bucket.remove(['$user/$key']).then((_) {}, onError: (_) {});
        }
      }
      out.add(Given(path: path, name: name, mime: mime, size: size));
    }
    return out;
  }

  AgentSpec? _specOf(String agent) =>
      book.read().where((a) => a.id == agent).firstOrNull;

  String _expand(String dir) => dir == '~'
      ? home
      : dir.startsWith('~/')
      ? '$home${dir.substring(1)}'
      : dir;

  // ---- Accounts ------------------------------------------------------------

  /// This worker's accounts as last read, by id.
  Map<String, LoginRow> _accounts = {};

  /// When each account's limits were last read here, and when who it is.
  final _limitsRead = <String, DateTime>{};
  final _statusRead = <String, DateTime>{};

  /// When each sign-in under way began here.
  final _signing = <String, DateTime>{};

  Timer? _tendTimer;
  bool _tending = false;
  bool _tendAgain = false;

  /// The accounts seen to again after [wait]: soon after a change, else
  /// every few seconds while a sign-in waits and every 20s otherwise.
  void _tendSoon(Duration wait) {
    _tendTimer?.cancel();
    _tendTimer = Timer(wait, () async {
      await _guard(_tendAccounts);
      _tendSoon(Duration(seconds: _signing.isNotEmpty ? 3 : 20));
    });
  }

  /// How often an account's limits are read without a turn: Claude's is
  /// one small request; Codex's starts its app server.
  static Duration _limitsEvery(String agent) => agent == 'claude'
      ? const Duration(minutes: 2)
      : const Duration(minutes: 5);

  /// The words a chat's program is started after to run under its account;
  /// none for the worker's own, or an account not here. Its folder is
  /// known by its id, so a chat taken up before the accounts are read
  /// still runs under its own.
  List<String> _envOf(ChatAsk ask) {
    final id = ask.account;
    if (id == null || _accounts[id]?.main == true) return const [];
    final agent = _accounts[id]?.agent ?? ask.agent;
    final folder = logins.folderOf(id);
    if (agent != ask.agent || !Directory(folder).existsSync()) return const [];
    logins.mirror(agent, folder);
    return AgentLogins.envOf(agent, folder);
  }

  /// Every account of this worker's seen to: its own login of each agent
  /// here said, sign-ins begun and followed, limits read, folders of
  /// accounts removed put away.
  Future<void> _tendAccounts() async {
    if (_tending) {
      _tendAgain = true;
      return;
    }
    _tending = true;
    try {
      do {
        _tendAgain = false;
        await _tendOnce();
      } while (_tendAgain);
    } finally {
      _tending = false;
    }
  }

  Future<void> _tendOnce() async {
    final db = await _db;
    List<Map<String, dynamic>> rows;
    try {
      rows = await db.from('agent_accounts').select().eq('worker_id', state.id);
    } on PostgrestException {
      // A server without the table yet: chats run under the worker's own.
      return;
    }
    final have = [for (final r in rows) LoginRow.fromJson(r)];
    for (final spec in book.read()) {
      if (spec.id != 'claude' && spec.id != 'codex') continue;
      if (have.any((a) => a.main && a.agent == spec.id)) continue;
      final status = await logins.status(spec.id, null);
      final made = await db
          .from('agent_accounts')
          .insert({
            'worker_id': state.id,
            'agent': spec.id,
            'main': true,
            'state': status.signedIn ? 'ready' : 'signed_out',
            'email': status.email,
            'plan': status.plan,
          })
          .select()
          .single();
      have.add(LoginRow.fromJson(made));
      _statusRead[made['id'] as String] = DateTime.now();
    }
    _accounts = {for (final a in have) a.id: a};
    for (final account in have) {
      await _guard(() => _tend(account));
    }
    // Removed in the app: its sign-in ended, its folder put away.
    for (final id in [..._signing.keys]) {
      if (_accounts.containsKey(id)) continue;
      _signing.remove(id);
      await tmux.kill(_loginOf(id));
      tmux.forget(_loginOf(id));
    }
    for (final id in logins.strays(_accounts.keys)) {
      log('account ${_short(id)} removed');
      await logins.remove(logins.folderOf(id));
    }
  }

  /// The terminal an account is signed in in.
  static String _loginOf(String account) => 'login-$account';

  Future<void> _tend(LoginRow a) async {
    switch (a.state) {
      case 'new':
        await _beginLogin(a);
      case 'signing_in':
        await _followLogin(a);
      // The worker's own may be signed into again on the computer.
      case 'ready' || 'signed_out' when a.state == 'ready' || a.main:
        final now = DateTime.now();
        final asked = _statusRead[a.id];
        if (asked == null || now.difference(asked).inMinutes >= 30) {
          _statusRead[a.id] = now;
          final status = await logins.status(a.agent, logins.placeOf(a));
          if (status.signedIn != (a.state == 'ready')) {
            await _account(a.id, {
              'state': status.signedIn ? 'ready' : 'signed_out',
              'email': status.email ?? a.email,
              'plan': status.plan ?? a.plan,
            });
            log(
              'account ${_short(a.id)} is ${status.signedIn ? 'signed in' : 'signed out'}',
            );
            return;
          }
          if (status.signedIn &&
              (status.email != a.email || status.plan != a.plan)) {
            await _account(a.id, {'email': status.email, 'plan': status.plan});
          }
        }
        if (a.state != 'ready') return;
        final read = _limitsRead[a.id];
        if (read == null || now.difference(read) >= _limitsEvery(a.agent)) {
          _limitsRead[a.id] = now;
          final limits = await logins.limits(a.agent, logins.placeOf(a));
          if (limits != null) await _keepLimits(a.id, limits);
        }
    }
  }

  /// A sign-in begun in a terminal of its own; the app is shown the page
  /// it prints once it does.
  Future<void> _beginLogin(LoginRow a) async {
    final folder = logins.placeOf(a);
    if (folder != null) logins.mirror(a.agent, folder);
    final name = _loginOf(a.id);
    await tmux.kill(name);
    tmux.forget(name);
    _signing[a.id] = DateTime.now();
    await _account(a.id, {
      'state': 'signing_in',
      'note': null,
      'login_url': null,
      'login_hint': null,
      'login_code': null,
    });
    try {
      // Wide, so the page's long address is never wrapped.
      await tmux.start(
        name,
        logins.loginArgv(a.agent, folder),
        cwd: home,
        cols: 500,
        rows: 40,
      );
    } catch (e) {
      _signing.remove(a.id);
      await _account(a.id, {'state': 'failed', 'note': '$e'});
      return;
    }
    log('account ${_short(a.id)}: signing in to ${a.agent}');
  }

  Future<void> _followLogin(LoginRow a) async {
    final name = _loginOf(a.id);
    final began = _signing[a.id];
    final pane = (await tmux.panes())[Tmux.nameOf(name)];
    if (began == null || pane == null) {
      // Begun by a worker before this one, whose terminal went with it.
      await _beginLogin(a);
      return;
    }
    final text = await tmux.text(name) ?? '';
    final shown = AgentLogins.loginScreen(a.agent, text);
    if (shown.url != null && shown.url != a.loginUrl) {
      await _account(a.id, {'login_url': shown.url, 'login_hint': shown.hint});
    }
    if (a.loginCode case final code?
        when code.trim().isNotEmpty && !pane.dead) {
      await _account(a.id, {'login_code': null});
      await tmux.line(name, code.trim());
      return;
    }
    final status = await (pane.dead || a.agent == 'codex'
        ? logins.status(a.agent, logins.placeOf(a))
        : Future.value((signedIn: false, email: null, plan: null)));
    if (status.signedIn && (pane.dead || a.agent == 'codex')) {
      _signing.remove(a.id);
      await tmux.kill(name);
      tmux.forget(name);
      _statusRead[a.id] = DateTime.now();
      _limitsRead.remove(a.id);
      await _account(a.id, {
        'state': 'ready',
        'email': status.email,
        'plan': status.plan,
        'note': null,
        'login_url': null,
        'login_hint': null,
      });
      log('account ${_short(a.id)}: signed in as ${status.email ?? '?'}');
      return;
    }
    final late = DateTime.now().difference(began) > const Duration(minutes: 20);
    if (pane.dead || late) {
      _signing.remove(a.id);
      await tmux.kill(name);
      tmux.forget(name);
      await _account(a.id, {
        'state': 'failed',
        'note': late
            ? 'The sign-in was not finished within 20 minutes.'
            : AgentLogins.lastWords(text),
        'login_url': null,
        'login_hint': null,
      });
    }
  }

  Future<void> _account(String id, Map<String, Object?> fields) async {
    final db = await _db;
    await db.from('agent_accounts').update(fields).eq('id', id);
  }

  /// [limits] kept as the account's, if they say anything new.
  Future<void> _keepLimits(String id, Map<String, Object?> limits) async {
    final had = _accounts[id]?.usage;
    String said(Map? m) => jsonEncode({...?m}..remove('limitsAt'));
    if (had != null &&
        said(had) == said(limits) &&
        DateTime.now().millisecondsSinceEpoch -
                ((had['limitsAt'] as num?) ?? 0) <
            const Duration(minutes: 10).inMilliseconds) {
      return;
    }
    await _account(id, {
      'usage': limits,
      'usage_at': DateTime.now().toUtc().toIso8601String(),
    });
    final a = _accounts[id];
    if (a != null) {
      _accounts[id] = LoginRow(
        id: a.id,
        agent: a.agent,
        main: a.main,
        state: a.state,
        created: a.created,
        email: a.email,
        plan: a.plan,
        usage: limits,
      );
    }
  }

  /// Limits a chat heard, the newest there are of its account's: kept as
  /// the account's a few seconds on, the last of several heard together.
  final _limitsHeard = <String, Map<String, Object?>>{};
  Timer? _keepingHeard;

  void _heardLimits(ChatAsk ask, Map<String, Object?> set) {
    final id =
        ask.account ??
        _accounts.values
            .where((a) => a.main && a.agent == ask.agent)
            .firstOrNull
            ?.id;
    if (id == null) return;
    // A chat may hear of one window only: laid over the others known.
    final known =
        _limitsHeard[id]?['limits'] ?? _accounts[id]?.usage?['limits'];
    final limits = {
      for (final l in [
        if (known is List) ...known,
        if (set['limits'] case final List heard) ...heard,
      ])
        if (l is Map) l['name']: l,
    };
    _limitsHeard[id] = {
      'limits': limits.values.toList(),
      'limitsAt': set['limitsAt'] ?? DateTime.now().millisecondsSinceEpoch,
      if (set['limited'] != null) 'limited': set['limited'],
    };
    _limitsRead[id] = DateTime.now();
    _keepingHeard ??= Timer(const Duration(seconds: 5), () {
      _keepingHeard = null;
      final heard = {..._limitsHeard};
      _limitsHeard.clear();
      for (final MapEntry(:key, :value) in heard.entries) {
        unawaited(_guard(() => _keepLimits(key, value)));
      }
    });
  }

  /// Starts [ask] in a terminal: fresh, or with Claude's [resume] taken up
  /// and [prompt] in place of the chat's own first message.
  Future<_Live?> _start(ChatAsk ask, {String? resume, String? prompt}) async {
    _know(ask);
    final place = await _placeOf(ask);
    if (place == null) return null;
    final (spec, dir) = place;
    resume = resumable(spec, home, dir, resume);
    final first = prompt ?? (resume != null ? '' : ask.prompt);
    final argv = [
      ..._envOf(ask),
      ...launchOf(
        spec,
        ask,
        resume: resume,
        prompt: first,
        events: tmux.eventsOf(ask.id),
        given: tmux.givenOf(ask.id),
      ),
    ];
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

  /// [chat]'s settings changed in the app — its model, effort,
  /// permissions, plugins, skills or rules: its program is started again
  /// with them, carrying on its session. A chat's waits for the turn
  /// under way and then for the next message; a terminal is started again
  /// at once if idle, Claude's after its turn. A terminal with no session
  /// to carry on (a shell, a Codex begun there) keeps what it has until it
  /// is started again.
  Future<void> _retune(String chat) async {
    final db = await _db;
    final row = await db
        .from('chats')
        .select()
        .eq('id', chat)
        .eq('worker_id', state.id)
        .maybeSingle();
    if (row == null) return;
    final ask = ChatAsk.fromJson(row);
    final talker = _talks[chat];
    if (talker != null) {
      await talker.retune(ask);
      return;
    }
    final live = _live[chat];
    if (live == null) return;
    final session = live.session ?? ask.session;
    if (session == null || !(live.spec.isClaude || live.spec.id == 'codex')) {
      return;
    }
    if (live.spec.isClaude && !_ready(live.state)) {
      live.retune = true;
      return;
    }
    if (_live[chat] != live) return;
    _live.remove(chat);
    await _putAway(chat, live);
    log('[${_short(chat)}] started again with new settings');
    await _start(ask, resume: session, prompt: '');
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
    _know(ask);
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
        final title = await nameChat(
          text,
          command: '${claude.command.first}',
          language: ask.language,
        );
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

  /// Whether a chat in [state] waits for the user's word: `idle` before it
  /// has done anything, `finished` once a turn has ended, `your_turn` once
  /// one has ended asking or offering something ([asksBack]), `limited`
  /// once the account's limit refused one — told apart so the app can say
  /// what became of a chat, all taking a message alike.
  static bool _ready(Object? state) =>
      state == 'idle' ||
      state == 'finished' ||
      state == 'your_turn' ||
      state == 'limited';

  /// Where a chat stands once a turn has ended with [said].
  static String _ended(String said) =>
      asksBack(said) ? 'your_turn' : 'finished';

  Future<void> _set(String chat, String to, String? note, {String? said}) {
    notices.stands(chat, to, note: note, said: said);
    return _setRow(chat, to, note);
  }

  Future<void> _setRow(String chat, String to, String? note) async {
    final db = await _db;
    await db.from('chats').update({'state': to, 'note': note}).eq('id', chat);
    _follow(chat, to, note);
  }

  // ---- The tasks chats were sent from ---------------------------------

  /// Each chat's task, by chat id, for those sent from one.
  final Map<String, String> _taskOf = {};

  /// The watcher's errands: it writes their answers itself ([Watcher]),
  /// so only where they stand on the way is said here.
  final Set<String> _errands = {};

  /// The chats whose answer is in their task's notes already: only a
  /// task's first answer goes there; what is said after is in the chat.
  final Set<String> _answered = {};

  /// What was last said of each chat's task, so a state said again is not
  /// written again.
  final Map<String, String> _toldTask = {};

  /// The task writes one after another: each reads the task afresh.
  Future<void> _taskWrites = Future.value();

  void _know(ChatAsk ask) {
    if (ask.taskUuid case final task?) _taskOf[ask.id] = task;
  }

  /// [chat] standing at [to], said of its task.
  void _follow(String chat, String to, String? note) {
    final stand = AgentState.ofChat(to);
    if (stand == null) return;
    // A failed errand is the watcher's to tell, with its reason.
    if (stand == AgentState.failed && _errands.contains(chat)) return;
    // Exited after answering: the answer stands.
    if (stand == AgentState.failed && _toldTask[chat] == AgentState.review) {
      return;
    }
    _tellTask(
      chat,
      stand,
      note: stand == AgentState.failed
          ? 'Not done: ${note ?? 'it stopped.'}'
          : null,
    );
  }

  /// A turn of [chat]'s done: its task is to be looked over, with the
  /// first answer in its notes; or, failed, says so — unless it had
  /// answered already, an ending that says nothing of the answer.
  void _turnDone(
    String chat,
    String answer,
    String who, {
    bool failed = false,
  }) {
    if (_errands.contains(chat)) return;
    if (failed) {
      if (_toldTask[chat] == AgentState.review || answer.trim().isEmpty) {
        return;
      }
      _tellTask(chat, AgentState.failed, note: answer, who: who);
      return;
    }
    final first = _answered.add(chat);
    _tellTask(
      chat,
      AgentState.review,
      note: first
          ? _cut(answer.trim().isEmpty ? '(Nothing said.)' : answer)
          : null,
      who: who,
    );
  }

  void _tellTask(String chat, String stand, {String? note, String? who}) {
    final task = _taskOf[chat];
    final caldo = this.caldo;
    if (task == null || caldo == null) return;
    if (_toldTask[chat] == stand && note == null) return;
    _toldTask[chat] = stand;
    _taskWrites = _taskWrites.then(
      (_) => _guard(
        () => caldo.agentSays(
          task,
          state: stand,
          note: note,
          who: who ?? 'Agent',
        ),
      ),
    );
  }

  /// Most of an answer a task's notes take; the rest is in its chat.
  static String _cut(String text) => text.length <= 6000
      ? text
      : '${text.substring(0, 6000)}…\n(The rest is in its chat.)';

  /// The user's phones told of a chat waiting on them.
  late final notices = Notices(
    tell: (chat, kind, text) => unawaited(
      _guard(() async {
        final db = await _db;
        var words = text;
        if (words.isEmpty && kind == 'waiting') {
          // A terminal's turn may end without its words: the chat's last.
          final last = await db
              .from('chat_items')
              .select('body')
              .eq('chat_id', chat)
              .eq('kind', 'text')
              .order('seq', ascending: false)
              .limit(1);
          final body = last.firstOrNull?['body'];
          if (body is Map) words = '${body['text'] ?? ''}';
        }
        await db.functions.invoke(
          'push',
          body: {'chat': chat, 'kind': kind, 'text': clip(words.trim(), 1000)},
        );
      }),
    ),
  );

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
    if (event['hook_event_name'] == 'PostToolUse') {
      final input = event['tool_input'] as Map? ?? const {};
      final response = event['tool_response'];
      _notePulls(
        chat,
        '${event['tool_name'] ?? ''}',
        '${input['command'] ?? ''}',
        response is Map
            ? '${response['stdout'] ?? ''}\n${response['stderr'] ?? ''}'
            : '$response',
      );
    }
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
        to = _ended(event['last_assistant_message'] as String? ?? '');
        _turnDone(
          chat,
          event['last_assistant_message'] as String? ?? '',
          live.spec.label,
        );
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
      final said = event['last_assistant_message'] as String?;
      unawaited(_guard(() => _set(chat, to!, note, said: said)));
    }
    if (_ready(to) && live.retune) {
      live.retune = false;
      unawaited(_guard(() => _retune(chat)));
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
    notices.forget(chat);
    final live = _live.remove(chat);
    if (live != null) await remote.client.removeChannel(live.line);
    await tmux.kill(chat);
    tmux.forget(chat);
    tmux.forgetGiven(chat);
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
    _errands.add(chat);
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

  /// The chat as last read: changed in the app, the next program is
  /// started with it ([retune]).
  ChatAsk ask;
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

  /// The last turn's answer, for the phones told it is over.
  String _said = '';

  /// What the chat has spent (`ChatUsage`), as last said; and the row's
  /// copy of it, to be written.
  Map<String, Object?>? _usage;
  String? _usageSaid;
  Timer? _keeping;

  _Talker._(
    this.worker,
    this.ask,
    this.spec,
    this._seq, {
    required this.dir,
    this.session,
  }) : _channel = worker._lineOf(ask.id),
       _usage = ask.usage == null ? null : ChatUsage.merged(ask.usage);

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
    final made = Talk.of(
      spec,
      ask,
      this,
      dir,
      given: worker.tmux.givenOf(ask.id),
    );
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
    // One being put by for new settings is ended first: two programs on
    // one session would both write to it.
    await _sleeping;
    if (talk != null) return;
    final made = Talk.of(
      spec,
      ask,
      this,
      dir,
      given: worker.tmux.givenOf(ask.id),
    );
    if (made == null) {
      throw StateError('${spec.label} has no chat, only a terminal.');
    }
    if (made is CodexTalk) made.since = _since;
    made.env = worker._envOf(ask);
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

  Future<void> say(
    String text, {
    String? id,
    List<Given> files = const [],
    Map? sender,
  }) async {
    if (text.trim().isEmpty && files.isEmpty) return;
    await wake();
    talk!.say(text, id: id, files: files, sender: sender);
    _owed++;
  }

  /// Messages handed to its program and not yet answered: one said during
  /// a turn waits behind it, and is answered by a turn of its own.
  int _owed = 0;

  /// [now], the chat's settings as changed in the app: its program is
  /// put by — once the turn under way is done — and the next message
  /// starts one with them, carrying on the session.
  Future<void> retune(ChatAsk now) async {
    final before = _before ?? ask;
    ask = now;
    // Only its title, say: its program runs on as it is.
    if (settingsChanged(before, now) == null) {
      _before = null;
      _retuning = false;
      return;
    }
    _before = before;
    if (talk == null) {
      _sayChanged();
      return;
    }
    if (turn != null || state == 'running' || state == 'asking') {
      _retuning = true;
      return;
    }
    await _putBy();
  }

  /// What the program now put by was started with, while it finishes its
  /// turn: the note says what changed from it, where it changed.
  ChatAsk? _before;
  bool _retuning = false;
  Future<void>? _sleeping;

  void _sayChanged() {
    final before = _before;
    _before = null;
    final said = before == null ? null : settingsChanged(before, ask);
    if (said == null) return;
    item('s${DateTime.now().millisecondsSinceEpoch}', 'note', {'text': said});
  }

  Future<void> _putBy() {
    _sayChanged();
    final was = talk;
    talk = null;
    _forgetOffset();
    if (was == null) return Future.value();
    worker.log('[${_short(ask.id)}] put by for new settings');
    return _sleeping = was.close().whenComplete(() => _sleeping = null);
  }

  void answer(
    String item,
    String choice, {
    Map<String, String> answers = const {},
  }) => talk?.answer(item, choice, answers: answers);

  void interrupt() => talk?.interrupt();

  /// Asked to clear its context while a turn is under way: done once the
  /// turn ends, so its last words — the agent's own, asking for it — are
  /// said and kept.
  bool _clearing = false;

  /// Its context cleared, as Claude's `/clear` does: its program put by
  /// and its session forgotten, so the next message starts one afresh.
  /// The chat's rules, skills and subscriptions stay, as each program is
  /// started with them; what was said stays on the chat's screen.
  Future<void> clear() async {
    if (turn != null || _owed > 0 || state == 'running' || state == 'asking') {
      _clearing = true;
      return;
    }
    await _forget();
  }

  Future<void> _forget() async {
    _clearing = false;
    _retuning = false;
    // Settings changed meanwhile are told too: the next program has them.
    _sayChanged();
    final was = talk;
    talk = null;
    _forgetOffset();
    session = null;
    _since = null;
    // How full the context was is no longer so; the chat's totals stay.
    final usage = _usage;
    if (usage != null && usage.containsKey('context')) {
      _usage = {...usage}..remove('context');
      _usageSaid = jsonEncode(_usage);
      _broadcast('usage', _usage!);
    }
    item('c${DateTime.now().millisecondsSinceEpoch}', 'note', {
      'text': 'Context cleared: the next message starts afresh.',
    });
    worker.log('[${_short(ask.id)}] context cleared');
    await worker._guard(
      () async => (await worker._db)
          .from('chats')
          .update({'session': null, 'usage': ?_usage})
          .eq('id', ask.id),
    );
    if (was != null) {
      await (_sleeping = was.close().whenComplete(() => _sleeping = null));
    }
  }

  Future<void> close() async {
    _closing = true;
    await talk?.close();
    talk = null;
    _forgetOffset();
    _piecing?.cancel();
    if (_keeping != null) _keepUsage();
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
    if (kind == 'tool' && body['done'] == true) {
      worker._notePulls(
        ask.id,
        '${body['name'] ?? ''}',
        '${body['line'] ?? ''}\n${body['detail'] ?? ''}',
        '${body['output'] ?? ''}',
      );
    }
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
          // A row the server will never take (a kind it doesn't know):
          // each tried alone and the refused one dropped, or it would hold
          // back every item of the chat after it for ever.
          if (_never(e)) {
            await _postEach(rows);
            continue;
          }
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

  /// Refused for what the row is (a check or a key broken), not for the
  /// way to the server: sent again, it would be refused again.
  static bool _never(Object e) =>
      e is PostgrestException && (e.code?.startsWith('23') ?? false);

  /// [rows] sent one at a time, those the server refuses dropped; the
  /// rest put back for the next try if the way to it fails meanwhile.
  Future<void> _postEach(List<Map<String, Object?>> rows) async {
    final db = await worker._db;
    for (final (i, row) in rows.indexed) {
      try {
        await db.from('chat_items').upsert(row);
      } catch (e) {
        if (_never(e)) {
          worker.log('[${_short(ask.id)}] item ${row['id']} refused: $e');
          continue;
        }
        worker.log('[${_short(ask.id)}] items not sent: $e');
        for (final left in rows.skip(i)) {
          _queue.putIfAbsent(left['id'] as String, () => left);
        }
        await Future<void>.delayed(const Duration(seconds: 2));
        return;
      }
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
    // A turn ended by the agent, not by the limit: its last words may ask.
    if (to == 'finished' && note == null) to = Worker._ended(_said);
    if (forgotten || (to == state && note == null)) return;
    state = to;
    _broadcast('state', {'state': to, 'note': note});
    unawaited(worker._guard(() => worker._set(ask.id, to, note, said: _said)));
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
  void usage({
    Map<String, Object?> set = const {},
    Map<String, num> add = const {},
  }) {
    if (forgotten) return;
    if (set['limits'] != null) worker._heardLimits(ask, set);
    final now = ChatUsage.merged(_usage, set: set, add: add);
    final said = jsonEncode(now);
    if (said == _usageSaid) return;
    _usage = now;
    _usageSaid = said;
    // Heard at once by an open chat; its row is for one opened later.
    _broadcast('usage', now);
    _keeping ??= Timer(const Duration(seconds: 20), _keepUsage);
  }

  /// The chat's figures written to its row: when a turn ends, or a while
  /// into a long one. Not on every change: every write to a chat's row has
  /// each app watching read the list of chats again.
  void _keepUsage() {
    _keeping?.cancel();
    _keeping = null;
    final usage = _usage;
    if (usage == null || forgotten) return;
    unawaited(
      worker._guard(
        () async => (await worker._db)
            .from('chats')
            .update({'usage': usage})
            .eq('id', ask.id),
      ),
    );
  }

  @override
  void turnEnded(
    String answer, {
    bool failed = false,
    bool limited = false,
    DateTime? resets,
  }) {
    if (_keeping != null) _keepUsage();
    // Stopped by the limit, it carries on once lifted: its task is still
    // under way.
    if (!limited && !forgotten) {
      worker._turnDone(ask.id, answer, spec.label, failed: failed);
    }
    _said = answer;
    final waiting = turn;
    turn = null;
    if (waiting != null && !waiting.isCompleted) {
      waiting.complete((answered: !failed, text: answer));
    }
    _owed = max(0, _owed - 1);
    // Cleared only once nothing said waits behind this turn: a pull
    // request told during the reviewer's round would go unanswered.
    final clearing = _clearing && _owed == 0;
    if (clearing || _retuning) {
      _retuning = false;
      // After the turn's last words are handed on: its program is ended
      // once this returns.
      scheduleMicrotask(() => unawaited(clearing ? _forget() : _putBy()));
    }
    if (limited) {
      unawaited(worker._guard(() => _atLimit(resets)));
    } else if (!failed) {
      if (_booked ?? true) unawaited(worker._guard(_unbook));
    }
  }

  /// Whether a carrying on is left for later: not known once the user
  /// may have ticked one in the app, or for a chat taken up by a worker
  /// started again, which looks.
  bool? _booked;

  /// A turn refused for the account's limit: said in the chat, with a box
  /// the user may tick to have it carry on by itself once the limit is
  /// lifted ([CarryOn]). Never carried on unasked. One asked for already
  /// (the user wrote meanwhile, and was refused too) is moved to the new
  /// end, not doubled.
  Future<void> _atLimit(DateTime? resets) async {
    if (forgotten) return;
    final now = DateTime.now();
    final told = resets != null && resets.isAfter(now);
    final db = await worker._db;
    final left = await db
        .from('chat_later')
        .select('id')
        .eq('chat_id', ask.id)
        .like('key', '${CarryOn.key}%');
    if (left.isNotEmpty) {
      final at = CarryOn.at(told ? resets : null, now);
      await db
          .from('chat_later')
          .update({'send_at': at.toUtc().toIso8601String()})
          .inFilter('id', [for (final row in left) row['id']]);
    }
    _booked = null;
    item('l${now.microsecondsSinceEpoch}', 'note', {
      'text': 'Stopped at the usage limit.',
      'limit': true,
      if (told) 'resets': resets.millisecondsSinceEpoch,
    });
    // A state of its own: the app says it apart from a turn finished, and
    // the phones are told of it whoever began the turn.
    stands(
      'limited',
      note: told
          ? 'Out of usage: the limit resets ${_at(resets)}.'
          : 'Out of usage: stopped at the limit.',
    );
    worker.log('[${_short(ask.id)}] at the limit');
  }

  /// A turn gone through: a carrying on still left would come after the
  /// user went on themselves, and is taken back.
  Future<void> _unbook() async {
    _booked = false;
    if (forgotten) return;
    final db = await worker._db;
    await db
        .from('chat_later')
        .delete()
        .eq('chat_id', ask.id)
        .like('key', '${CarryOn.key}%');
  }

  /// [at] as this computer tells it: the time, and the day if not today.
  static String _at(DateTime at) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final time = 'at ${two(at.hour)}:${two(at.minute)}';
    final today =
        at.year == now.year && at.month == now.month && at.day == now.day;
    return today ? time : 'on ${at.day}.${two(at.month)} $time';
  }

  @override
  void exited(int code, String why) {
    talk = null;
    _owed = 0;
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

/// An answer as the app writes it: "choice item", and after them, to
/// questions asked of the user, the answers as JSON by each question's
/// words. An app from before answers were sent writes the first two only,
/// and a worker from before reads the item as all after the first space,
/// which then names no question and is let be.
(String?, String, Map<String, String>) answerOf(String? data) {
  final parts = (data ?? '').split(' ');
  if (parts.length < 2 || parts[0].isEmpty || parts[1].isEmpty) {
    return (null, '', const {});
  }
  var answers = const <String, String>{};
  if (parts.length > 2) {
    try {
      final json = jsonDecode(parts.skip(2).join(' '));
      if (json is Map) {
        answers = {
          for (final MapEntry(:key, :value) in json.entries) '$key': '$value',
        };
      }
    } on FormatException {
      // Cut short: no answers, which Claude is told.
    }
  }
  return (parts[1], parts[0], answers);
}

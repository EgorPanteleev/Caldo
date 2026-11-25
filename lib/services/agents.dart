import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:supabase/supabase.dart';

import '../l10n/strings.dart';
import '../mcp/subscriptions.dart' show Subscription;
import '../mcp/usage.dart';
import '../models/task.dart';
import '../utils/platform.dart';
import 'account.dart';
import 'attachments.dart';
import 'desktop.dart';

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

  /// Whether the rules chosen for a chat reach it.
  final bool rules;

  /// Whether its worker says messages left for later.
  final bool later;

  /// Whether its worker takes files sent with a message.
  final bool files;

  /// Whether its worker starts a chat again with settings changed here.
  final bool settings;

  /// Whether its worker signs in to accounts asked for here, and runs a
  /// chat under the one chosen.
  final bool accounts;

  /// Whether its worker watches what a chat is subscribed to and tells it
  /// (`chat_subscriptions`).
  final bool events;

  /// Whether its worker clears a chat's context when asked (`clear`).
  final bool clears;

  /// Whether its worker starts a task's chat left to wait for the task,
  /// and says on the task where its chat stands.
  final bool tasks;

  /// Whether its worker leaves a chat made waiting with no task until it
  /// is started by hand.
  final bool held;

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
    this.rules = false,
    this.later = false,
    this.files = false,
    this.settings = false,
    this.accounts = false,
    this.events = false,
    this.clears = false,
    this.tasks = false,
    this.held = false,
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
    rules: json['rules'] == true,
    later: json['later'] == true,
    files: json['files'] == true,
    settings: json['settings'] == true,
    accounts: json['accounts'] == true,
    events: json['events'] == true,
    clears: json['clears'] == true,
    tasks: json['tasks'] == true,
    held: json['held'] == true,
  );
}

enum AccountState { asked, signingIn, ready, signedOut, failed }

/// A Claude or Codex login a worker runs chats under: its own (`main`),
/// or one signed into from here, each kept on the worker in a folder of
/// its own. Its limits are the worker's last look at them, every few
/// minutes and whenever a chat on it hears them.
@immutable
class AgentAccount {
  final String id;
  final String workerId;
  final String agent;
  final bool main;
  final String name;
  final String? email;
  final String? plan;
  final AccountState state;
  final String? note;

  /// While signing in: the page to sign in on, and Codex's code to type
  /// there.
  final String? loginUrl;
  final String? loginHint;

  /// Its limits (`ChatUsage` with only those set); null before they are
  /// first read.
  final ChatUsage? usage;
  final DateTime created;

  const AgentAccount({
    required this.id,
    required this.workerId,
    required this.agent,
    required this.state,
    required this.created,
    this.main = false,
    this.name = '',
    this.email,
    this.plan,
    this.note,
    this.loginUrl,
    this.loginHint,
    this.usage,
  });

  bool get ready => state == AccountState.ready;

  static AccountState _stateOf(String? s) => switch (s) {
    'signing_in' => AccountState.signingIn,
    'ready' => AccountState.ready,
    'signed_out' => AccountState.signedOut,
    'failed' => AccountState.failed,
    _ => AccountState.asked,
  };

  factory AgentAccount.fromJson(Map json) => AgentAccount(
    id: json['id'] as String,
    workerId: json['worker_id'] as String,
    agent: json['agent'] as String,
    main: json['main'] == true,
    name: json['name'] as String? ?? '',
    email: json['email'] as String?,
    plan: json['plan'] as String?,
    state: _stateOf(json['state'] as String?),
    note: json['note'] as String?,
    loginUrl: json['login_url'] as String?,
    loginHint: json['login_hint'] as String?,
    usage: ChatUsage.of(json['usage']),
    created:
        DateTime.tryParse(json['created_at'] as String? ?? '')?.toLocal() ??
        DateTime.now(),
  );
}

/// Standing instructions for agents, written here once and chosen for each
/// chat as it starts; the chat keeps its own copy of their words.
@immutable
class AgentRule {
  final String id;
  final String name;
  final String body;

  /// Said as a chat's first message when none is written on the form, so
  /// a rule that holds the whole errand starts the chat by itself; empty
  /// for most.
  final String opening;

  const AgentRule({
    required this.id,
    required this.name,
    required this.body,
    this.opening = '',
  });

  factory AgentRule.fromJson(Map json) => AgentRule(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    body: json['body'] as String? ?? '',
    opening: json['opening'] as String? ?? '',
  );
}

/// A new chat's first message: what was [written], else the openings of
/// the chosen [rules], one after another.
String firstMessage(String written, Iterable<AgentRule> rules) {
  if (written.trim().isNotEmpty) return written.trim();
  return [
    for (final r in rules)
      if (r.opening.trim().isNotEmpty) r.opening.trim(),
  ].join('\n\n');
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

/// `idle` is ready, nothing done yet; `finished`, a turn has ended;
/// `limited`, the account's usage limit refused a turn. All wait for the
/// user's next message.
enum ChatState {
  asked,

  /// A task's chat left to start when its task is due.
  waiting,
  running,
  asking,
  idle,
  finished,
  limited,
  ended,
  failed,
}

/// A rule as a chat keeps it: its words when it was chosen for the chat.
typedef ChatRule = ({String name, String body});

/// A message left for a chat to be told at [at]: kept on the server until
/// the chat's worker says it, so it goes while the phone is away.
@immutable
class LaterLine {
  final int id;
  final String text;
  final DateTime at;
  final String key;

  const LaterLine({
    required this.id,
    required this.text,
    required this.at,
    this.key = '',
  });

  /// The chat carrying on after the usage limit, as the user asked.
  bool get carriesOn => key.startsWith(CarryOn.key);

  factory LaterLine.fromJson(Map json) => LaterLine(
    id: json['id'] as int,
    text: json['data'] as String? ?? '',
    at: DateTime.parse(json['send_at'] as String).toLocal(),
    key: json['key'] as String? ?? '',
  );
}

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

  /// The plugins it runs with; null for Claude's own choice.
  final List<String>? plugins;
  final List<String> skills;

  /// The rules it was told, as it keeps their words.
  final List<ChatRule> rules;
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

  /// What it has spent and where it stands, as its worker last kept it;
  /// null before its first turn, or from a server without the column.
  final ChatUsage? usage;

  /// The account it runs under; null for its worker's own.
  final String? account;

  /// When it was pinned to the top of the list; null if it is not.
  final DateTime? pinnedAt;

  /// Its phones aren't told when it waits (`push`); its agent's own
  /// `notify` still gets through.
  final bool muted;

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
    this.plugins,
    this.skills = const [],
    this.rules = const [],
    this.prompt = '',
    this.taskUuid,
    this.note,
    this.cols = 80,
    this.rows = 24,
    this.session,
    this.inChat = false,
    this.usage,
    this.account,
    this.pinnedAt,
    this.muted = false,
  });

  bool get pinned => pinnedAt != null;

  /// Whether it can be a chat at all: one begun as one, wherever it is now.
  bool get talks => agent == 'claude' || agent == 'codex';

  /// Its program is running: it takes keys.
  bool get live =>
      state == ChatState.running ||
      state == ChatState.asking ||
      state == ChatState.idle ||
      state == ChatState.finished ||
      state == ChatState.limited;

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
        plugins: c.plugins,
        skills: c.skills,
        rules: c.rules,
        prompt: c.prompt,
        taskUuid: c.taskUuid,
        state: c.state,
        note: c.note,
        cols: c.cols,
        rows: c.rows,
        session: c.session,
        updatedAt: c.updatedAt,
        inChat: toChat,
        usage: c.usage,
        account: c.account,
        pinnedAt: c.pinnedAt,
        muted: c.muted,
      );

  /// [c] pinned [at], or unpinned for null: said here at once, as a move.
  Chat._pinned(Chat c, DateTime? at)
    : this(
        id: c.id,
        workerId: c.workerId,
        agent: c.agent,
        title: c.title,
        model: c.model,
        effort: c.effort,
        dir: c.dir,
        permission: c.permission,
        plugins: c.plugins,
        skills: c.skills,
        rules: c.rules,
        prompt: c.prompt,
        taskUuid: c.taskUuid,
        state: c.state,
        note: c.note,
        cols: c.cols,
        rows: c.rows,
        session: c.session,
        updatedAt: c.updatedAt,
        inChat: c.inChat,
        usage: c.usage,
        account: c.account,
        pinnedAt: at,
        muted: c.muted,
      );

  /// [c] muted or not: said here at once, as a pin.
  Chat._muted(Chat c, bool muted)
    : this(
        id: c.id,
        workerId: c.workerId,
        agent: c.agent,
        title: c.title,
        model: c.model,
        effort: c.effort,
        dir: c.dir,
        permission: c.permission,
        plugins: c.plugins,
        skills: c.skills,
        rules: c.rules,
        prompt: c.prompt,
        taskUuid: c.taskUuid,
        state: c.state,
        note: c.note,
        cols: c.cols,
        rows: c.rows,
        session: c.session,
        updatedAt: c.updatedAt,
        inChat: c.inChat,
        usage: c.usage,
        account: c.account,
        pinnedAt: c.pinnedAt,
        muted: muted,
      );

  static ChatState _stateOf(String? s) => switch (s) {
    'waiting' => ChatState.waiting,
    'running' => ChatState.running,
    'asking' => ChatState.asking,
    'idle' => ChatState.idle,
    'finished' => ChatState.finished,
    'limited' => ChatState.limited,
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
    plugins: json['plugins'] == null ? null : _strings(json['plugins']),
    skills: _strings(json['skills']),
    rules: [
      for (final r in json['rules'] as List? ?? const [])
        if (r is Map) (name: '${r['name'] ?? ''}', body: '${r['body'] ?? ''}'),
    ],
    prompt: json['prompt'] as String? ?? '',
    taskUuid: json['task_uuid'] as String?,
    state: _stateOf(json['state'] as String?),
    note: json['note'] as String?,
    cols: json['cols'] as int? ?? 80,
    rows: json['rows'] as int? ?? 24,
    session: json['session'] as String?,
    updatedAt: DateTime.parse(json['updated_at'] as String).toLocal(),
    inChat: json['mode'] == 'chat',
    usage: ChatUsage.of(json['usage']),
    account: json['account'] as String?,
    pinnedAt: switch (json['pinned_at']) {
      final String at => DateTime.parse(at).toLocal(),
      _ => null,
    },
    muted: json['muted'] == true,
  );

  /// [chats] as the list shows them: the pinned on top, the last pinned
  /// first, then the rest as they came (the latest news first).
  static List<Chat> pinnedFirst(Iterable<Chat> chats) => [
    ...chats.where((c) => c.pinned).toList()
      ..sort((a, b) => b.pinnedAt!.compareTo(a.pinnedAt!)),
    ...chats.where((c) => !c.pinned),
  ];
}

/// [url] opened in the browser: the page an account is signed in on.
/// False if nothing would open it.
Future<bool> openPage(String url) async {
  if (onDesktop) return Desktop.open(url);
  try {
    return await const MethodChannel(
          'caldo/updates',
        ).invokeMethod<bool>('open', {'url': url}) ??
        false;
  } on PlatformException {
    return false;
  }
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
  List<AgentRule> rules = const [];
  List<AgentAccount> accounts = const [];
  bool loaded = false;
  Object? error;

  SupabaseClient? get _client => Account.instance.client;

  bool get signedIn => signedInForTest ?? _client != null;

  /// Lets a test draw the list of chats without a server to sign in to.
  @visibleForTesting
  bool? signedInForTest;

  RealtimeChannel? _channel;
  RealtimeChannel? _accountsChannel;
  Timer? _every;
  int _watching = 0;

  /// Kept up to date while anything is looking: the tab, an open chat.
  void watch() {
    if (_watching++ > 0) return;
    unawaited(load());
    unawaited(loadRules());
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
    // A channel of its own, so a server without the table yet costs only
    // this.
    _accountsChannel = client
        .channel('caldo-agent-accounts')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'agent_accounts',
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
    for (final channel in [_channel, _accountsChannel]) {
      if (channel != null) unawaited(_client?.removeChannel(channel));
    }
    _channel = null;
    _accountsChannel = null;
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
      chats = Chat.pinnedFirst([for (final r in c) Chat.fromJson(r)]);
      accounts = await _readAccounts(client);
      error = null;
    } catch (e) {
      error = e;
    }
    loaded = true;
    notifyListeners();
  }

  /// The accounts, the workers' own first, then as they were added; none
  /// from a server without the table.
  Future<List<AgentAccount>> _readAccounts(SupabaseClient client) async {
    try {
      final rows = await client
          .from('agent_accounts')
          .select()
          .order('main', ascending: false)
          .order('created_at', ascending: true);
      return [for (final r in rows) AgentAccount.fromJson(r)];
    } on PostgrestException {
      return const [];
    }
  }

  AgentAccount? account(String? id) =>
      accounts.where((a) => a.id == id).firstOrNull;

  /// The accounts [worker] runs [agent] under, its own first.
  List<AgentAccount> accountsOf(String? worker, String agent) => [
    for (final a in accounts)
      if (a.workerId == worker && a.agent == agent) a,
  ];

  /// The account [chat] runs under: the one chosen, else its worker's
  /// own.
  AgentAccount? accountOf(Chat chat) =>
      account(chat.account) ??
      accountsOf(chat.workerId, chat.agent).where((a) => a.main).firstOrNull;

  /// A new account of [agent] on [worker], signed into there: the worker
  /// begins at once, and the row says where to sign in.
  Future<AgentAccount> addAccount({
    required String worker,
    required String agent,
    String name = '',
  }) async {
    final row = await _client!
        .from('agent_accounts')
        .insert({'worker_id': worker, 'agent': agent, 'name': name.trim()})
        .select()
        .single();
    final made = AgentAccount.fromJson(row);
    accounts = [...accounts, made];
    notifyListeners();
    return made;
  }

  Future<void> _changeAccount(String id, Map<String, Object?> fields) async {
    final row = await _client!
        .from('agent_accounts')
        .update(fields)
        .eq('id', id)
        .select()
        .single();
    final changed = AgentAccount.fromJson(row);
    accounts = [
      for (final a in accounts)
        if (a.id == id) changed else a,
    ];
    notifyListeners();
  }

  Future<void> renameAccount(String id, String name) =>
      _changeAccount(id, {'name': name.trim()});

  /// Claude's code from the sign-in page, for its worker to type in.
  Future<void> loginCode(String id, String code) =>
      _changeAccount(id, {'login_code': code.trim()});

  /// Signed into afresh: after a failure, or once signed out.
  Future<void> signInAgain(String id) => _changeAccount(id, {
    'state': 'new',
    'note': null,
    'login_url': null,
    'login_hint': null,
  });

  /// Gone here and, signed out of, from its worker; its chats go on under
  /// the worker's own.
  Future<void> removeAccount(String id) async {
    await _client!.from('agent_accounts').delete().eq('id', id);
    accounts = [
      for (final a in accounts)
        if (a.id != id) a,
    ];
    notifyListeners();
  }

  /// Read when watching begins and kept by this device's own edits: rules
  /// change seldom, and never on their own.
  Future<void> loadRules() async {
    final client = _client;
    if (client == null) return;
    try {
      final r = await client
          .from('agent_rules')
          .select()
          .order('name', ascending: true);
      rules = [for (final row in r) AgentRule.fromJson(row)];
      notifyListeners();
    } catch (_) {
      // Kept as they were; the next watch reads them again.
    }
  }

  AgentRule? rule(String id) => rules.where((r) => r.id == id).firstOrNull;

  /// [name] and [body] as rule [id], or as a new rule without one.
  Future<void> saveRule({
    String? id,
    required String name,
    required String body,
    String opening = '',
  }) async {
    final fields = {
      'name': name,
      'body': body,
      // Left out unless there is or was one, so a server without the
      // column still keeps rules that have none.
      if (opening.isNotEmpty || (rule(id ?? '')?.opening ?? '').isNotEmpty)
        'opening': opening,
    };
    final query = id == null
        ? _client!.from('agent_rules').insert(fields)
        : _client!.from('agent_rules').update(fields).eq('id', id);
    final saved = AgentRule.fromJson(await query.select().single());
    rules = [
      for (final r in rules)
        if (r.id != saved.id) r,
      saved,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    notifyListeners();
  }

  Future<void> removeRule(String id) async {
    await _client!.from('agent_rules').delete().eq('id', id);
    rules = [
      for (final r in rules)
        if (r.id != id) r,
    ];
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
    List<AgentRule> rules = const [],
    String prompt = '',
    String? task,
    String? account,
    int cols = 80,
    int rows = 24,
    bool inChat = false,
    bool waiting = false,
    String? preface,
  }) async {
    final made = {
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
      // Left out when none, so a server without the column still
      // starts a chat.
      if (rules.isNotEmpty)
        'rules': [
          for (final r in rules) {'name': r.name, 'body': r.body},
        ],
      'prompt': prompt,
      // A task sent from Schedule or the calendar: the list marks the
      // chat as its task's, and the task's form opens it.
      'task_uuid': ?task,
      // Left to start when the task is due: its worker starts it then,
      // telling it the task as it is by then after [preface]. Without a
      // task, left until started by hand ([startNow]).
      if (waiting) 'state': 'waiting',
      'preface': ?preface,
      // Left out for the worker's own, so a server without the column
      // still starts a chat.
      'account': ?account,
      // The worker titles the chat in it, not in the message's.
      'language': S.current.code,
      'cols': cols.clamp(10, 500),
      'rows': rows.clamp(5, 300),
    };
    Future<Map<String, dynamic>> insert(Map<String, Object?> fields) =>
        _client!.from('chats').insert(fields).select().single();
    Map<String, dynamic> row;
    try {
      row = await insert(made);
    } on PostgrestException catch (e) {
      // A server without the column yet (PostgREST's "no such column")
      // still starts the chat, titled in the message's language.
      if (e.code != 'PGRST204' || !e.message.contains('language')) rethrow;
      row = await insert({...made}..remove('language'));
    }
    final chat = Chat.fromJson(row);
    chats = [chat, ...chats];
    notifyListeners();
    return chat;
  }

  /// Keys as the terminal puts them out.
  Future<void> keys(String chat, String data) => _in(chat, 'keys', data: data);

  /// A message: pasted, then Enter — or, to a chat [over] its feed, said
  /// there at once as well as kept. [files] go up first, and the message
  /// only once they are there; if they cannot, nothing is sent.
  Future<void> line(
    String chat,
    String text, {
    TalkFeed? over,
    List<Attachment> files = const [],
  }) async =>
      _in(chat, 'line', data: text, over: over, files: await _put(chat, files));

  /// [files], copies on this device, put on the server for [chat]'s worker
  /// to take down, and named as a message names them. Keyed by each
  /// copy's own folder, a uuid: the server takes no other letters than
  /// Latin in a key, and the name goes beside it.
  Future<List<Map<String, Object?>>> _put(
    String chat,
    List<Attachment> files,
  ) async {
    if (files.isEmpty) return const [];
    final client = _client!;
    final user = client.auth.currentUser!.id;
    final bucket = client.storage.from(chatFiles);
    return [
      for (final a in files)
        if (Attachments.instance.fileOf(a) case final file?)
          await bucket
              .upload(
                '$user/$chat/${p.dirname(a.file)}',
                file,
                fileOptions: FileOptions(contentType: a.mime, upsert: true),
              )
              .then(
                (_) => {
                  'key': '$chat/${p.dirname(a.file)}',
                  'name': a.name,
                  'mime': a.mime,
                  'size': a.size,
                },
              ),
    ];
  }

  /// The bucket the files sent to chats wait in for their workers.
  static const chatFiles = 'chat-files';

  /// The most a file sent to a chat may be: the bucket's own limit.
  static const largestFile = 50 * 1024 * 1024;

  /// [text] left for [chat]'s worker to say at [at]; [carryOn] if it is
  /// the chat carrying on after the usage limit, which its worker takes
  /// back if a turn goes through first.
  Future<LaterLine> later(
    String chat,
    String text,
    DateTime at, {
    bool carryOn = false,
  }) async {
    final row = await _client!
        .from('chat_later')
        .insert({
          'chat_id': chat,
          'data': text,
          'send_at': at.toUtc().toIso8601String(),
          'key': '${carryOn ? CarryOn.key : ''}${_key()}',
        })
        .select('id, data, send_at, key')
        .single();
    return LaterLine.fromJson(row);
  }

  /// What is left for [chat] and not yet said, soonest first.
  Future<List<LaterLine>> laterOf(String chat) async {
    final rows = await _client!
        .from('chat_later')
        .select('id, data, send_at, key')
        .eq('chat_id', chat)
        .order('send_at', ascending: true);
    return [for (final row in rows) LaterLine.fromJson(row)];
  }

  /// [line] taken back; false if the worker has said it already.
  Future<bool> takeBack(LaterLine line) async {
    final gone = await _client!
        .from('chat_later')
        .delete()
        .eq('id', line.id)
        .select('id');
    return gone.isNotEmpty;
  }

  /// What [chat] is subscribed to, oldest first.
  Future<List<Subscription>> subscriptionsOf(String chat) async {
    final rows = await _client!
        .from('chat_subscriptions')
        .select()
        .eq('chat_id', chat)
        .order('id', ascending: true);
    return [for (final row in rows) Subscription.fromJson(row)];
  }

  /// [chat] subscribed to [repo]'s pull requests (null: its folder's), or
  /// subscription [id] changed — its repository with it, which starts
  /// what it has seen afresh.
  Future<void> subscribe(
    String chat, {
    int? id,
    String? repo,
    required List<String> events,
    String? note,
  }) async {
    final fields = {
      'target': repo,
      'events': events,
      'note': note == null || note.trim().isEmpty ? null : note.trim(),
    };
    final table = _client!.from('chat_subscriptions');
    if (id == null) {
      await table.insert({'chat_id': chat, ...fields});
      return;
    }
    final was = await table.select('target').eq('id', id).maybeSingle();
    await table
        .update({
          ...fields,
          if (was != null && was['target'] != repo) ...{
            'seen': null,
            'error': null,
            'created_at': DateTime.now().toUtc().toIso8601String(),
          },
        })
        .eq('id', id);
  }

  Future<void> unsubscribe(int id) async =>
      _client!.from('chat_subscriptions').delete().eq('id', id);

  Future<void> resize(String chat, int cols, int rows) =>
      _in(chat, 'size', cols: cols.clamp(10, 500), rows: rows.clamp(5, 300));

  Future<void> stop(String chat) => _in(chat, 'stop');

  Future<void> again(String chat) => _in(chat, 'start');

  /// A chat left waiting — for its task's day, or for the user — started
  /// now: asked of its worker as a new one is.
  Future<void> startNow(String chat) async {
    await _client!
        .from('chats')
        .update({'state': 'new'})
        .eq('id', chat)
        .eq('state', 'waiting');
  }

  /// [choice] — `allow`, `always` or `deny`, or `answer` with [answers]
  /// by each question's words — for the question [item].
  Future<void> answer(
    String chat,
    String item,
    String choice, {
    Map<String, String> answers = const {},
  }) => _in(
    chat,
    'answer',
    data: answers.isEmpty
        ? '$choice $item'
        : '$choice $item ${jsonEncode(answers)}',
  );

  /// The turn under way cut short; the chat stays.
  Future<void> interrupt(String chat) => _in(chat, 'interrupt');

  /// What the chat's agent was told forgotten, as `/clear` does, once its
  /// turn under way ends; what was said stays on screen.
  Future<void> clear(String chat) => _in(chat, 'clear');

  /// The chat moved to its terminal, or back to its chat.
  Future<void> move(String chat, {required bool toChat}) async {
    chats = [
      for (final c in chats)
        if (c.id == chat) Chat._moved(c, toChat) else c,
    ];
    notifyListeners();
    await _in(chat, 'mode', data: toChat ? 'chat' : 'terminal');
  }

  /// [fields] of [chat]'s row changed — its title, model, effort,
  /// permission, plugins, skills or rules — and, if any but the title,
  /// its worker told to start its program again with them.
  Future<void> change(String chat, Map<String, Object?> fields) async {
    if (fields.isEmpty) return;
    final row = await _client!
        .from('chats')
        .update(fields)
        .eq('id', chat)
        .select()
        .single();
    final changed = Chat.fromJson(row);
    chats = [
      for (final c in chats)
        if (c.id == chat) changed else c,
    ];
    notifyListeners();
    if (fields.keys.every((k) => k == 'title')) return;
    try {
      await _in(chat, 'settings');
    } on PostgrestException catch (e) {
      // A server not yet taking the word (its check refuses it): the row
      // is changed, and the chat starts with it when it starts again.
      if (e.code != '23514') rethrow;
    }
  }

  Future<void> remove(String chat) => removeAll([chat]);

  /// [ids] deleted in one go, from a selection in the list.
  Future<void> removeAll(Iterable<String> ids) async {
    final gone = ids.toSet();
    if (gone.isEmpty) return;
    await _client!.from('chats').delete().inFilter('id', [...gone]);
    for (final chat in gone) {
      unawaited(_unput(chat));
    }
    chats = [
      for (final c in chats)
        if (!gone.contains(c.id)) c,
    ];
    notifyListeners();
  }

  /// [ids] pinned to the top of the list, or let go of. A pin is the
  /// row's, so every device lists them alike; it doesn't move the chat's
  /// `updated_at` (`chats_touch` stamps only news).
  Future<void> pin(Iterable<String> ids, {required bool pinned}) async {
    final picked = ids.toSet();
    if (picked.isEmpty) return;
    final at = pinned ? DateTime.now() : null;
    await _client!
        .from('chats')
        .update({'pinned_at': at?.toUtc().toIso8601String()})
        .inFilter('id', [...picked]);
    chats = Chat.pinnedFirst([
      for (final c in chats)
        if (picked.contains(c.id) && c.pinned != pinned)
          Chat._pinned(c, at)
        else
          c,
    ]);
    notifyListeners();
  }

  /// [ids] muted, or heard again: the row's, so the push function, which
  /// tells every phone, reads it.
  Future<void> mute(Iterable<String> ids, {required bool muted}) async {
    final picked = ids.toSet();
    if (picked.isEmpty) return;
    await _client!.from('chats').update({'muted': muted}).inFilter('id', [
      ...picked,
    ]);
    chats = [
      for (final c in chats)
        if (picked.contains(c.id) && c.muted != muted)
          Chat._muted(c, muted)
        else
          c,
    ];
    notifyListeners();
  }

  /// Every one of [ids] whose program is running told to stop.
  Future<void> stopAll(Iterable<String> ids) async {
    final live = {
      for (final c in chats)
        if (c.live) c.id,
    };
    await Future.wait([
      for (final id in ids)
        if (live.contains(id)) stop(id),
    ]);
  }

  /// The files sent to [chat] and never taken down, gone with it.
  Future<void> _unput(String chat) async {
    try {
      final client = _client!;
      final folder = '${client.auth.currentUser!.id}/$chat';
      final bucket = client.storage.from(chatFiles);
      final left = await bucket.list(path: folder);
      if (left.isEmpty) return;
      await bucket.remove([for (final f in left) '$folder/${f.name}']);
    } catch (_) {
      // Offline, or a server without the bucket: they wait there.
    }
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
    List<Map<String, Object?>> files = const [],
  }) async {
    final line = _lines[chat];
    final key = line != null && _typed.contains(kind) ? _key() : null;
    if (key != null) {
      if (kind == 'line') over?.said(data ?? '', key, files: files);
      line!.cast({
        'kind': kind,
        'data': data,
        'key': key,
        if (files.isNotEmpty) 'files': files,
      });
    }
    await _client!.from('chat_in').insert({
      'chat_id': chat,
      'kind': kind,
      'data': ?data,
      'cols': ?cols,
      'rows': ?rows,
      'key': ?key,
      // Left out when none, so a server without the column still takes
      // the rest.
      if (files.isNotEmpty) 'files': files,
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

  /// When it was first said, in local time: the server's stamp, or until
  /// the row brings one, when this device first heard it. Null for items
  /// from before chats kept times.
  final DateTime? at;

  const ChatItem({
    required this.id,
    required this.seq,
    required this.kind,
    required this.body,
    this.at,
  });

  String get text => body['text'] as String? ?? '';

  factory ChatItem.fromJson(Map json) => ChatItem(
    id: json['id'] as String,
    seq: json['seq'] as int,
    kind: json['kind'] as String,
    body: Map<String, dynamic>.from(json['body'] as Map? ?? const {}),
    at: DateTime.tryParse('${json['at']}')?.toLocal(),
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

  /// What the chat has spent as last broadcast: said on every request, its
  /// row only at a turn's end. Null until one is heard, then always at
  /// least as new as the row.
  final usage = ValueNotifier<ChatUsage?>(null);

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
        {
          'id': i.id,
          'seq': i.seq,
          'kind': i.kind,
          'body': i.body,
          'at': i.at?.toIso8601String(),
        },
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
        )
        .onBroadcast(
          event: 'usage',
          callback: (message) {
            if (!_closed) usage.value = ChatUsage.of(_payloadOf(message));
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
        // Every column, not a list of them: a server yet to have one the
        // app reads (`at`) still answers, rather than the chat never
        // loading.
        final rows = await client
            .from('chat_items')
            .select()
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
      var item = ChatItem.fromJson(row);
      final was = _byId[item.id];
      // A broadcast comes without the server's stamp, ahead of the row
      // that has it: heard now, then set right by the row. One already
      // here keeps what it had — none, if from before chats kept times.
      final at =
          item.at ?? (was != null ? was.at : (loaded ? DateTime.now() : null));
      if (was != null && mapEquals(was.body, item.body) && was.at == at) {
        continue;
      }
      if (at != item.at) {
        item = ChatItem(
          id: item.id,
          seq: item.seq,
          kind: item.kind,
          body: item.body,
          at: at,
        );
      }
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
  void said(
    String text,
    String key, {
    List<Map<String, Object?>> files = const [],
  }) {
    if (text.trim().isEmpty && files.isEmpty) return;
    _take([
      {
        'id': 'u$key',
        'seq': (items.isEmpty ? 0 : items.last.seq) + 1,
        'kind': 'user',
        'body': {
          'text': text,
          if (files.isNotEmpty)
            'files': [
              for (final f in files)
                {'name': f['name'], 'mime': f['mime'], 'size': f['size']},
            ],
        },
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
    usage.dispose();
    super.dispose();
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'usage.dart';

/// An account a worker runs Claude or Codex under, as the server keeps it
/// (`agent_accounts`).
class LoginRow {
  final String id;
  final String agent;

  /// The worker's own login (~/.claude, ~/.codex), not one made in the app.
  final bool main;
  final String state;
  final String? email;
  final String? plan;
  final String? loginUrl;
  final String? loginCode;
  final Map? usage;
  final DateTime created;

  const LoginRow({
    required this.id,
    required this.agent,
    required this.state,
    required this.created,
    this.main = false,
    this.email,
    this.plan,
    this.loginUrl,
    this.loginCode,
    this.usage,
  });

  factory LoginRow.fromJson(Map json) => LoginRow(
    id: json['id'] as String,
    agent: json['agent'] as String,
    main: json['main'] == true,
    state: json['state'] as String? ?? 'new',
    email: json['email'] as String?,
    plan: json['plan'] as String?,
    loginUrl: json['login_url'] as String?,
    loginCode: json['login_code'] as String?,
    usage: json['usage'] is Map ? json['usage'] as Map : null,
    created:
        DateTime.tryParse(json['created_at'] as String? ?? '') ??
        DateTime.now(),
  );
}

/// Who an agent is signed in as in a folder, as far as it says.
typedef LoginStatus = ({bool signedIn, String? email, String? plan});

/// The logins a worker keeps beside its own, each in a folder of its own
/// under [root], and what is learnt of each: who it is, and the account's
/// limits, read without a turn spent.
///
/// A folder stands in for the agent's own (`CLAUDE_CONFIG_DIR`,
/// `CODEX_HOME`) with only the login its own: everything else of the
/// worker's own folder is linked into it ([mirror]), so a chat under
/// another account has the same plugins, skills, settings and MCP servers,
/// and its sessions are kept with the rest — one chat can be carried on
/// under another account, and moved between its chat and its terminal, as
/// before.
class AgentLogins {
  final String home;
  final String root;

  AgentLogins({required this.home, required this.root});

  /// The agent's own folder here.
  String ownOf(String agent) => agent == 'claude'
      ? '$home/.claude'
      : Platform.environment['CODEX_HOME'] ?? '$home/.codex';

  String folderOf(String id) => '$root/$id';

  /// The folder of [account]'s login, or null for the worker's own.
  String? placeOf(LoginRow account) =>
      account.main ? null : folderOf(account.id);

  static String _variable(String agent) =>
      agent == 'claude' ? 'CLAUDE_CONFIG_DIR' : 'CODEX_HOME';

  /// The words a program is started after, to run under the login in
  /// [folder]; none for the worker's own.
  static List<String> envOf(String agent, String? folder) =>
      folder == null ? const [] : ['env', '${_variable(agent)}=$folder'];

  static Map<String, String>? _environment(String agent, String? folder) =>
      folder == null ? null : {_variable(agent): folder};

  /// What a folder keeps of its own: the login, and Claude's file that
  /// says whose it is (a copy, [mirror]).
  static const _own = {
    '.credentials.json',
    'auth.json',
    '.claude.json',
    'backups',
  };

  /// [folder] made to stand in for the agent's own: the agent's own
  /// folder's every entry linked in, but the login. Done before each
  /// program starts, so what the agent's own folder gained meanwhile is
  /// there too. Claude's settings outside its folder (`~/.claude.json`:
  /// MCP servers, folders trusted, its first-run questions answered) are
  /// copied in once, less whose login it was.
  void mirror(String agent, String folder) {
    Directory(folder).createSync(recursive: true);
    final own = Directory(ownOf(agent));
    // Made first, or the account's program would make its own, and its
    // sessions would be apart from the rest.
    Directory(
      '${own.path}/${agent == 'claude' ? 'projects' : 'sessions'}',
    ).createSync(recursive: true);
    if (agent == 'claude') {
      final config = File('$folder/.claude.json');
      if (!config.existsSync()) {
        try {
          final json =
              jsonDecode(File('$home/.claude.json').readAsStringSync()) as Map
                ..remove('oauthAccount');
          config.writeAsStringSync(jsonEncode(json));
        } catch (_) {
          // No Claude of the worker's own: the account starts afresh.
        }
      }
    }
    for (final entry in own.listSync(followLinks: false)) {
      final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (_own.contains(name)) continue;
      final at = '$folder/$name';
      if (FileSystemEntity.typeSync(at, followLinks: false) !=
          FileSystemEntityType.notFound) {
        continue;
      }
      try {
        Link(at).createSync(entry.path);
      } on FileSystemException {
        // Made by the program meanwhile: its own, then.
      }
    }
  }

  /// The command that signs [agent] in, in [folder]: Claude's prints a
  /// page to open and waits for the code it gives; Codex's prints a page
  /// and a code to type there, and waits for that.
  List<String> loginArgv(String agent, String? folder) => [
    ...envOf(agent, folder),
    ...agent == 'claude'
        ? const ['claude', 'auth', 'login']
        : const ['codex', 'login', '--device-auth'],
  ];

  /// What the sign-in shows: the page to open, and Codex's code to type
  /// on it.
  static ({String? url, String? hint}) loginScreen(String agent, String text) {
    final urls = RegExp(r'https://\S+').allMatches(text).map((m) => m[0]!);
    // Claude names the page it opened, then the page to open by hand,
    // which hands back a code to paste: the last.
    final url = agent == 'claude' ? urls.lastOrNull : urls.firstOrNull;
    final hint = agent == 'codex'
        ? RegExp(r'\b[A-Z0-9]{4,5}-[A-Z0-9]{4,5}\b').firstMatch(text)?.group(0)
        : null;
    return (url: url?.replaceAll(RegExp(r'[.,)]+$'), ''), hint: hint);
  }

  /// The last lines a sign-in left, to say why it ended: not the page's
  /// address, its prompt, or tmux's word that it ended.
  static String lastWords(String text) {
    final lines = [
      for (final line in LineSplitter.split(text))
        if (line.replaceAll(RegExp(r'^.*\bprompted\s*>\s*'), '').trim()
            case final said
            when said.isNotEmpty &&
                !said.contains('https://') &&
                !said.startsWith('Pane is dead'))
          said,
    ];
    final tail = lines.skip(lines.length > 3 ? lines.length - 3 : 0).join(' ');
    return tail.length > 300 ? tail.substring(tail.length - 300) : tail;
  }

  /// Whether [agent] is signed in, in [folder] (null: its own), and as
  /// whom.
  Future<LoginStatus> status(String agent, String? folder) async {
    const none = (signedIn: false, email: null, plan: null);
    if (agent == 'codex') return _codexStatus(folder ?? ownOf('codex'));
    try {
      final r = await Process.run('claude', [
        'auth',
        'status',
        '--json',
      ], environment: _environment(agent, folder)).timeout(_patience);
      final json = jsonDecode('${r.stdout}');
      if (json is! Map) return none;
      return (
        signedIn: json['loggedIn'] == true,
        email: json['email'] as String?,
        plan: json['subscriptionType'] as String?,
      );
    } catch (_) {
      return none;
    }
  }

  static const _patience = Duration(seconds: 20);

  /// Codex's login is its `auth.json`: ChatGPT's tokens, whose id token
  /// names the account and its plan, or an API key.
  LoginStatus _codexStatus(String folder) {
    try {
      final json = jsonDecode(File('$folder/auth.json').readAsStringSync());
      if (json is! Map) throw const FormatException();
      final id = (json['tokens'] as Map?)?['id_token'];
      if (id is String) {
        final claims = _claims(id);
        final auth = claims['https://api.openai.com/auth'];
        return (
          signedIn: true,
          email: claims['email'] as String?,
          plan: auth is Map ? auth['chatgpt_plan_type'] as String? : null,
        );
      }
      final key = json['OPENAI_API_KEY'];
      return (
        signedIn: key is String && key.isNotEmpty,
        email: null,
        plan: 'api',
      );
    } catch (_) {
      return (signedIn: false, email: null, plan: null);
    }
  }

  static Map _claims(String jwt) {
    final parts = jwt.split('.');
    if (parts.length < 2) return const {};
    final json = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    return json is Map ? json : const {};
  }

  /// [agent]'s limits in [folder] (null: its own), as `usage` keeps them
  /// (`limits`, `limitsAt`, `limited`); null if they could not be read.
  Future<Map<String, Object?>?> limits(String agent, String? folder) async {
    try {
      final rows = agent == 'claude'
          ? await _claudeLimits(folder ?? ownOf('claude'))
          : await _codexLimits(folder);
      if (rows == null || rows.isEmpty) return null;
      return {
        'limits': rows,
        'limitsAt': DateTime.now().millisecondsSinceEpoch,
        // Said as Claude's chats say it, so the app's word for a limit
        // reached shows for both.
        'limited': rows.any((r) => (r['used'] as num) >= 1)
            ? 'rejected'
            : 'allowed',
      };
    } catch (_) {
      return null;
    }
  }

  /// Asked of Claude's server as its own `/usage` asks, with the login's
  /// token. One run out is left be: Claude renews it as it next runs, and
  /// a token renewed here too would be spent twice.
  Future<List<Map<String, Object?>>?> _claudeLimits(String folder) async {
    final json = jsonDecode(
      File('$folder/.credentials.json').readAsStringSync(),
    );
    final oauth = json is Map ? json['claudeAiOauth'] : null;
    if (oauth is! Map || oauth['accessToken'] is! String) return null;
    final expires = oauth['expiresAt'];
    if (expires is num &&
        expires < DateTime.now().millisecondsSinceEpoch + 60000) {
      return null;
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(
        Uri.parse('https://api.anthropic.com/api/oauth/usage'),
      );
      request.headers
        ..set('Authorization', 'Bearer ${oauth['accessToken']}')
        ..set('anthropic-beta', 'oauth-2025-04-20')
        ..set('Accept', 'application/json');
      final response = await request.close().timeout(_patience);
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) return null;
      final answer = jsonDecode(body);
      return answer is Map ? claudeLimitRows(answer) : null;
    } finally {
      client.close(force: true);
    }
  }

  /// Asked of Codex's app server, started for the one question.
  Future<List<Map<String, Object?>>?> _codexLimits(String? folder) async {
    final process = await Process.start('codex', [
      'app-server',
    ], environment: _environment('codex', folder));
    final answer = Completer<Map?>();
    final lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final json = jsonDecode(line);
            if (json is Map && json['id'] == 2 && !answer.isCompleted) {
              answer.complete(json['result'] as Map?);
            }
          } on FormatException {
            // Not the protocol.
          }
        });
    unawaited(process.stderr.drain<void>());
    void write(Map<String, Object?> message) =>
        process.stdin.writeln(jsonEncode(message));
    try {
      write({
        'id': 1,
        'method': 'initialize',
        'params': {
          'clientInfo': {'name': 'caldo', 'title': 'Caldo', 'version': '1'},
        },
      });
      write({'method': 'initialized'});
      write({'id': 2, 'method': 'account/rateLimits/read'});
      final result = await answer.future.timeout(_patience);
      final limits = result?['rateLimits'];
      return limits is Map ? codexLimitRows(limits) : null;
    } finally {
      await lines.cancel();
      process.kill();
    }
  }

  /// Signs out of the login in [folder] — so it is ended at the agent's
  /// end too — and removes it. Its links go first, so nothing they lead
  /// to is touched. Claude's is told by the file it keeps whose login it is.
  Future<void> remove(String folder) async {
    final dir = Directory(folder);
    if (!dir.existsSync()) return;
    if (File('$folder/.claude.json').existsSync()) {
      try {
        await Process.run('claude', [
          'auth',
          'logout',
        ], environment: _environment('claude', folder)).timeout(_patience);
      } catch (_) {
        // Removed all the same.
      }
    }
    for (final entry in dir.listSync(followLinks: false)) {
      if (entry is Link) entry.deleteSync();
    }
    dir.deleteSync(recursive: true);
  }

  /// The folders here of accounts the server no longer has, by id.
  List<String> strays(Iterable<String> known) {
    final dir = Directory(root);
    if (!dir.existsSync()) return const [];
    final uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-');
    return [
      for (final entry in dir.listSync(followLinks: false))
        if (entry is Directory)
          if (entry.uri.pathSegments.where((s) => s.isNotEmpty).last
              case final id when uuid.hasMatch(id) && !known.contains(id))
            id,
    ];
  }
}

// Caldo's MCP server: the account's tasks as tools for an assistant.
//
//   caldo-mcp                 serve MCP over stdio (what Claude starts)
//   caldo-mcp login [--server URL]
//                             sign in once; the session is kept, not the
//                             password
//   caldo-mcp logout
//   caldo-mcp status
//   caldo-mcp call <tool> ['{"json": "arguments"}']
//                             run one tool from a shell
//   caldo-mcp watch [--dir ~] [--permission-mode auto] [--timeout 30]
//                   [--claude claude] [--name NAME]
//                             be one of the account's workers: run the
//                             agents the app's Agents tab asks for, each in
//                             a terminal (tmux -L caldo), and hand Claude the
//                             tasks the app hands it, writing its answers
//                             back (tool/mcp/watch.sh makes it a service)
//
// Plain Dart, no Flutter: run with `dart`, or installed by
// tool/mcp/install.sh.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:caldo/mcp/agents.dart';
import 'package:caldo/mcp/chat_tools.dart';
import 'package:caldo/mcp/protocol.dart';
import 'package:caldo/mcp/remote.dart';
import 'package:caldo/mcp/tools.dart';
import 'package:caldo/mcp/terminal.dart';
import 'package:caldo/mcp/watch.dart';
import 'package:caldo/mcp/worker.dart';
import 'package:caldo/services/caldo_server.dart';

const _version = '1.0.0';

Future<void> main(List<String> args) async {
  final file = SessionFile.standard();
  switch (args.firstOrNull) {
    case null || 'serve':
      await _serve(file);
    case 'login':
      exitCode = await _login(file, args.skip(1).toList());
    case 'logout':
      exitCode = await _logout(file);
    case 'status':
      exitCode = await _status(file);
    case 'call' when args.length >= 2:
      exitCode = await _call(file, args[1], args.length > 2 ? args[2] : '{}');
    case 'watch':
      exitCode = await _watch(file, args.skip(1).toList());
    default:
      stderr.writeln(
        'Usage: caldo-mcp [serve | login [--server URL] | logout | status | '
        'call <tool> [json] | watch [--dir D] [--permission-mode M] '
        '[--timeout MIN] [--claude PATH] [--name NAME]]',
      );
      exitCode = 64;
  }
  // The client's sockets would keep the process alive otherwise.
  exit(exitCode);
}

/// The tools served: the account's tasks, and its chats with agents.
List<Tool> _tools(SupabaseRemote remote, Caldo caldo) => [
  ...caldo.tools,
  ...ChatTools(SupabaseChatDesk(remote), self: ChatTools.here).tools,
];

const _instructions = Caldo.instructions + ChatTools.instructions;

Future<void> _serve(SessionFile file) async {
  final remote = SupabaseRemote(file);
  final caldo = Caldo(remote);
  // stdout carries the protocol and nothing else.
  await McpServer(
    tools: _tools(remote, caldo),
    name: 'caldo',
    version: _version,
    instructions: _instructions,
    before: caldo.refresh,
  ).serve(stdin, stdout.writeln);
  await stdout.flush();
}

Future<int> _login(SessionFile file, List<String> args) async {
  var server = CaldoServer.url;
  final at = args.indexOf('--server');
  if (at >= 0 && at + 1 < args.length) {
    server = args[at + 1].replaceAll(RegExp(r'/+$'), '');
  }
  stdout.write('Caldo name: ');
  final read = stdin.readLineSync();
  if (read == null) {
    // No input behind it at all: Claude Code's `!`, which has no keyboard,
    // and where a password typed would end up in the conversation.
    stdout.writeln();
    stderr.writeln(
      'caldo-mcp login asks for a password: run it in a terminal of its own.',
    );
    return 1;
  }
  final name = read.trim();
  stdout.write('Password: ');
  final password = _hidden();
  stdout.writeln();
  if (name.isEmpty || password.isEmpty) return 1;
  try {
    final who = await SupabaseRemote.signIn(file, server, name, password);
    stdout.writeln('Signed in as $who. Session kept in ${file.dir}.');
    return 0;
  } catch (e) {
    stderr.writeln('Could not sign in: $e');
    return 1;
  }
}

String _hidden() {
  try {
    stdin.echoMode = false;
    return stdin.readLineSync() ?? '';
  } on StdinException {
    // Not a terminal: piped in.
    return stdin.readLineSync() ?? '';
  } finally {
    try {
      stdin.echoMode = true;
    } on StdinException {
      // As above.
    }
  }
}

Future<int> _logout(SessionFile file) async {
  final remote = SupabaseRemote(file);
  try {
    await remote.ready();
    await remote.signOut();
  } catch (_) {
    // Signed out here whether or not the server heard.
  }
  file.clear();
  stdout.writeln('Signed out.');
  return 0;
}

Future<int> _status(SessionFile file) async {
  final remote = SupabaseRemote(file);
  final caldo = Caldo(remote);
  try {
    await caldo.refresh();
  } catch (e) {
    stderr.writeln('$e');
    return 1;
  }
  final open = caldo.book.tasks.where((h) => !h.task.done).length;
  stdout.writeln(
    'Signed in as ${remote.name} on ${remote.server}: '
    '${caldo.book.groups.length} groups, $open open tasks.',
  );
  return 0;
}

Future<int> _call(SessionFile file, String name, String json) async {
  final remote = SupabaseRemote(file);
  final caldo = Caldo(remote);
  final tools = _tools(remote, caldo);
  final tool = tools.where((t) => t.name == name).firstOrNull;
  if (tool == null) {
    stderr.writeln(
      'No tool $name. Tools: ${tools.map((t) => t.name).join(', ')}',
    );
    return 64;
  }
  final server = McpServer(
    tools: tools,
    name: 'caldo',
    version: _version,
    instructions: _instructions,
    before: caldo.refresh,
  );
  final answer = await server.call(
    tool,
    (jsonDecode(json) as Map).cast<String, Object?>(),
  );
  stdout.writeln(((answer['content'] as List).single as Map)['text']);
  return answer['isError'] == true ? 1 : 0;
}

Future<int> _watch(SessionFile file, List<String> args) async {
  String? option(String name) {
    final at = args.indexOf('--$name');
    return at >= 0 && at + 1 < args.length ? args[at + 1] : null;
  }

  // One watcher per account here, or a task would be handed over twice.
  Directory(file.dir).createSync(recursive: true);
  final lock = await File('${file.dir}/watch.lock').open(mode: FileMode.write);
  try {
    await lock.lock(FileLock.exclusive);
  } on FileSystemException {
    stderr.writeln('Another caldo-mcp watch is running.');
    return 1;
  }

  final home = Platform.environment['HOME'] ?? '/';
  final dir = (option('dir') ?? home).replaceFirst(RegExp(r'^~(?=/|$)'), home);
  final remote = SupabaseRemote(file);
  final permission = option('permission-mode') ?? 'auto';
  final timeout = Duration(
    minutes: int.tryParse(option('timeout') ?? '') ?? 30,
  );
  void log(String line) => stdout.writeln(line);

  // Without tmux there are no terminals to run chats in: tasks are still
  // done, by `claude -p`, with nothing to watch.
  final caldo = Caldo(remote);
  Worker? worker;
  if (Tmux.installed) {
    final state = WorkerState(File('${file.dir}/worker.json'));
    if (option('name') case final name?) state.name = name;
    state.save();
    final cache = Platform.environment['XDG_CACHE_HOME'] ?? '$home/.cache';
    worker = Worker(
      remote: remote,
      tmux: Tmux(dir: '$cache/caldo/chats'),
      book: AgentBook(home: home, config: file.dir),
      state: state,
      home: home,
      caldo: caldo,
      log: log,
    );
  }
  final watcher = Watcher(
    caldo: caldo,
    dir: dir,
    state: WatchState(File('${file.dir}/watch.json')),
    hand: worker != null
        ? (errand) =>
              worker!.errand(errand, permission: permission, timeout: timeout)
        : ClaudeCli(
            command: option('claude') ?? 'claude',
            permissionMode: permission,
            timeout: timeout,
          ).call,
    log: log,
  );
  try {
    await remote.ready();
  } catch (e) {
    stderr.writeln('$e');
    return 1;
  }
  stdout.writeln(
    'Watching for tasks handed to Claude, for ${remote.name}; Claude '
    'works in $dir.',
  );
  if (worker != null) {
    stdout.writeln(
      'Working as ${worker.name}: chats run in tmux -L caldo '
      '(attach with `tmux -L caldo attach -t c<chat id>`).',
    );
    unawaited(worker.run());
  } else {
    stdout.writeln(
      'No tmux here: the Agents tab cannot run chats on this '
      'computer.',
    );
  }
  await watcher.run(heard: remote.changes());
}

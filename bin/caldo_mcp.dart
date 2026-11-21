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
//
// Plain Dart, no Flutter: run with `dart`, or installed by
// tool/mcp/install.sh.

import 'dart:convert';
import 'dart:io';

import 'package:caldo/mcp/protocol.dart';
import 'package:caldo/mcp/remote.dart';
import 'package:caldo/mcp/tools.dart';
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
    default:
      stderr.writeln(
        'Usage: caldo-mcp [serve | login [--server URL] | logout | status | '
        'call <tool> [json]]',
      );
      exitCode = 64;
  }
  // The client's sockets would keep the process alive otherwise.
  exit(exitCode);
}

Future<void> _serve(SessionFile file) async {
  final remote = SupabaseRemote(file);
  final caldo = Caldo(remote);
  // stdout carries the protocol and nothing else.
  await McpServer(
    tools: caldo.tools,
    name: 'caldo',
    version: _version,
    instructions: Caldo.instructions,
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
  final caldo = Caldo(SupabaseRemote(file));
  final tool = caldo.tools.where((t) => t.name == name).firstOrNull;
  if (tool == null) {
    stderr.writeln(
      'No tool $name. Tools: ${caldo.tools.map((t) => t.name).join(', ')}',
    );
    return 64;
  }
  final server = McpServer(
    tools: caldo.tools,
    name: 'caldo',
    version: _version,
    instructions: Caldo.instructions,
    before: caldo.refresh,
  );
  final answer = await server.call(
    tool,
    (jsonDecode(json) as Map).cast<String, Object?>(),
  );
  stdout.writeln(((answer['content'] as List).single as Map)['text']);
  return answer['isError'] == true ? 1 : 0;
}

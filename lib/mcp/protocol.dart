import 'dart:convert';

import 'remote.dart';
import 'tools.dart';

/// The Model Context Protocol over stdio, as far as a server of tools needs
/// it: JSON-RPC, one message a line, answering `initialize`, `ping`,
/// `tools/list` and `tools/call`.
///
/// Written out rather than taken from a package: it is this much, and a
/// dependency here would be one more in the app's resolution.
class McpServer {
  final List<Tool> tools;
  final String name;
  final String version;
  final String instructions;

  /// Run before each tool: the pull that brings the book up to date.
  final Future<void> Function() before;

  McpServer({
    required this.tools,
    required this.name,
    required this.version,
    required this.instructions,
    required this.before,
  });

  static const _versions = ['2025-06-18', '2025-03-26', '2024-11-05'];

  /// Answers every message on [input] through [send], a line each, until
  /// [input] ends. One at a time, so two writes never interleave.
  Future<void> serve(
    Stream<List<int>> input,
    void Function(String line) send,
  ) async {
    await for (final line
        in input.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      Object? message;
      try {
        message = jsonDecode(line);
      } on FormatException {
        send(jsonEncode(_error(null, -32700, 'Parse error')));
        continue;
      }
      final answers = message is List
          ? [for (final m in message) ?await handle(m)]
          : [?await handle(message)];
      if (answers.isEmpty) continue;
      send(jsonEncode(message is List ? answers : answers.single));
    }
  }

  /// The answer to [message], or null for a notification.
  Future<Map<String, Object?>?> handle(Object? message) async {
    if (message is! Map) return _error(null, -32600, 'Invalid request');
    final id = message['id'];
    final method = message['method'];
    // A notification (initialized, cancelled) or an answer: nothing to say.
    if (id == null || method is! String) return null;
    final params = (message['params'] as Map?)?.cast<String, Object?>() ?? {};
    switch (method) {
      case 'initialize':
        final asked = params['protocolVersion'];
        return _result(id, {
          'protocolVersion': _versions.contains(asked)
              ? asked
              : _versions.first,
          'capabilities': {'tools': <String, Object?>{}},
          'serverInfo': {'name': name, 'version': version},
          'instructions': instructions,
        });
      case 'ping':
        return _result(id, <String, Object?>{});
      case 'tools/list':
        return _result(id, {
          'tools': [for (final t in tools) t.toJson()],
        });
      case 'tools/call':
        final tool = tools.where((t) => t.name == params['name']).firstOrNull;
        if (tool == null) {
          return _error(id, -32602, 'Unknown tool ${params['name']}');
        }
        final args =
            (params['arguments'] as Map?)?.cast<String, Object?>() ?? {};
        return _result(id, await call(tool, args));
      default:
        return _error(id, -32601, 'Method not found: $method');
    }
  }

  /// Runs [tool]. What goes wrong is said to the assistant as the tool's
  /// answer, marked as an error, so it can put it right or tell the user.
  Future<Map<String, Object?>> call(
    Tool tool,
    Map<String, Object?> args,
  ) async {
    try {
      await before();
      return _text(await tool.run(args));
    } on Refusal catch (e) {
      return _text(e.message, error: true);
    } on SignedOut catch (e) {
      return _text(e.why, error: true);
    } on TypeError {
      return _text(
        'Some argument is not of the kind ${tool.name} takes; see its '
        'input schema.',
        error: true,
      );
    } catch (e) {
      return _text('Caldo could not do it: $e', error: true);
    }
  }

  static Map<String, Object?> _text(String text, {bool error = false}) => {
    'content': [
      {'type': 'text', 'text': text},
    ],
    'isError': error,
  };

  static Map<String, Object?> _result(Object? id, Object? result) => {
    'jsonrpc': '2.0',
    'id': id,
    'result': result,
  };

  static Map<String, Object?> _error(Object? id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };
}

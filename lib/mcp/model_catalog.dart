import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agents.dart';

/// The worker's model choices, refreshed separately from starting chats.
class ModelCatalog {
  final _labels = <String, Map<String, String>>{};
  DateTime? _nextRefresh;

  Map<String, String> labelsFor(AgentSpec agent) =>
      agent.talks ? _labels[agent.id] ?? const {} : const {};

  Future<void> refresh(List<AgentSpec> agents) async {
    final now = DateTime.now();
    if (_nextRefresh?.isAfter(now) ?? false) return;
    _nextRefresh = now.add(const Duration(minutes: 5));
    await Future.wait([
      for (final agent in agents)
        if (agent.talks && (agent.isClaude || agent.id == 'codex'))
          _read(agent.id),
    ]);
  }

  Future<void> _read(String agent) async {
    final claude = agent == 'claude';
    try {
      final process = await Process.start(
        agent,
        claude
            ? [
                '-p',
                '--input-format',
                'stream-json',
                '--output-format',
                'stream-json',
                '--verbose',
                '--no-session-persistence',
                '--setting-sources',
                '',
                '--strict-mcp-config',
                '--mcp-config',
                '{"mcpServers":{}}',
              ]
            : ['app-server'],
        workingDirectory: Directory.systemTemp.path,
      );
      unawaited(process.stderr.drain<void>());
      unawaited(process.stdin.done.then<void>((_) {}, onError: (Object _) {}));
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      try {
        final labels =
            await (claude
                    ? _claudeModels(process.stdin, lines)
                    : _codexModels(process.stdin, lines))
                .timeout(const Duration(seconds: 8));
        if (labels.isNotEmpty) _labels[agent] = labels;
      } finally {
        process.kill();
        await lines.cancel();
        await process.stdin.close();
      }
    } on Exception {
      // An unavailable CLI or catalog leaves the last good choices in place.
    }
  }
}

Future<Map<String, String>> _claudeModels(
  IOSink input,
  StreamIterator<String> lines,
) async {
  input.writeln(
    jsonEncode({
      'type': 'control_request',
      'request_id': 'models',
      'request': {'subtype': 'initialize'},
    }),
  );
  final response = await _reply(lines, (line) {
    final response = line['response'];
    return response is Map && response['request_id'] == 'models';
  });
  final body = response['response'];
  final payload = body is Map ? body['response'] : null;
  return _labels(payload is Map ? payload['models'] : null, 'value');
}

Future<Map<String, String>> _codexModels(
  IOSink input,
  StreamIterator<String> lines,
) async {
  Future<Object?> request(int id, String method, Map params) async {
    input.writeln(jsonEncode({'id': id, 'method': method, 'params': params}));
    final response = await _reply(lines, (line) => line['id'] == id);
    if (response['error'] != null) {
      throw const FormatException('Codex request failed');
    }
    return response['result'];
  }

  await request(1, 'initialize', {
    'clientInfo': {'name': 'caldo', 'title': 'Caldo', 'version': '1'},
  });
  input.writeln('{"method":"initialized"}');
  final labels = <String, String>{};
  final seen = <String>{};
  String? cursor;
  var id = 2;
  do {
    final page = await request(id++, 'model/list', {
      'limit': 100,
      'cursor': ?cursor,
    });
    if (page is! Map || page['data'] is! List) {
      throw const FormatException('Invalid Codex model catalog');
    }
    labels.addAll(_labels(page['data'], 'model'));
    final next = page['nextCursor'];
    cursor = next is String && next.isNotEmpty && seen.add(next) ? next : null;
  } while (cursor != null);
  return labels;
}

Future<Map> _reply(
  StreamIterator<String> lines,
  bool Function(Map) matches,
) async {
  while (await lines.moveNext()) {
    try {
      final line = jsonDecode(lines.current);
      if (line is Map && matches(line)) return line;
    } on FormatException {
      // Ignore output outside the JSON-line protocol.
    }
  }
  throw const FormatException('Model catalog response missing');
}

Map<String, String> _labels(Object? rows, String key) => {
  for (final row in rows is List ? rows : const [])
    if (row is Map)
      if (row[key] case final String id when id.isNotEmpty && id != 'default')
        id: switch (row['displayName']) {
          final String name when name.isNotEmpty => name,
          _ => id,
        },
};

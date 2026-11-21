import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agents.dart';

/// Where a [Talk] puts what its agent says, in one shape for every agent:
/// the app draws a chat from these and nothing else.
///
/// An item is said again whole whenever it changes (a tool's output come,
/// a question answered); [delta] carries an answer's words as they are
/// written, before the item that ends them.
abstract class TalkSink {
  /// [kind] is `user`, `text`, `thinking`, `tool`, `ask` or `note`.
  void item(String id, String kind, Map<String, Object?> body);
  void delta(String id, String text);

  /// `running`, `asking` or `idle`, with a line to say why.
  void stands(String state, {String? note});
  void inSession(String id);

  /// A turn done: its last words, for a task waiting on them.
  void turnEnded(String answer, {bool failed = false});
  void exited(int code, String why);
}

/// A chat with an agent spoken to in messages, not keys: Claude's
/// `stream-json`, Codex's app server. Sooner and lighter than its terminal
/// — a few hundred bytes a step, not a screen redrawn five times a second —
/// and drawn by the app as a chat that scrolls like one.
abstract class Talk {
  final ChatAsk ask;
  final TalkSink sink;

  /// The folder it works in.
  final String dir;

  Talk(this.ask, this.sink, {required this.dir});

  /// Starts its program; with [resume], carrying on that session.
  Future<void> start({String? resume});

  /// [text] said by the user; [id], the app's own for it, so the words it
  /// showed at once are these.
  void say(String text, {String? id});

  /// [choice] is `allow`, `always` or `deny`.
  void answer(String ask, String choice);
  void interrupt();
  Future<void> close();

  /// The talk for [spec], or null for one only run in a terminal.
  static Talk? of(AgentSpec spec, ChatAsk ask, TalkSink sink, String dir) =>
      switch (spec.id) {
        'claude' => ClaudeTalk(spec, ask, sink, dir: dir),
        'codex' => CodexTalk(ask, sink, dir: dir),
        _ => null,
      };

  Process? _process;
  final _err = <String>[];
  bool _closing = false;

  Future<void> _run(List<String> argv, void Function(Map) onLine) async {
    final process = _process = await Process.start(
      argv.first,
      argv.sublist(1),
      workingDirectory: dir,
    );
    process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          if (line.trim().isEmpty) return;
          try {
            onLine(jsonDecode(line) as Map);
          } on FormatException {
            // Not ours: a line some tool printed past the protocol.
          }
        });
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          // The last few, to say why it ended if it ends badly.
          _err.add(line);
          if (_err.length > 6) _err.removeAt(0);
        });
    unawaited(
      process.exitCode.then((code) {
        if (_process == process) _process = null;
        sink.exited(code, _closing ? '' : _err.join('\n').trim());
      }),
    );
  }

  void _write(Map<String, Object?> message) {
    try {
      _process?.stdin.writeln(jsonEncode(message));
    } catch (_) {
      // Its pipe gone: the exit says so.
    }
  }

  bool get running => _process != null;

  Future<void> _stop() async {
    final process = _process;
    if (process == null) return;
    _closing = true;
    try {
      await process.stdin.close();
    } catch (_) {}
    final ended = await process.exitCode
        .then((_) => true)
        .timeout(const Duration(seconds: 3), onTimeout: () => false);
    if (!ended) process.kill();
  }
}

/// Claude Code with `--input-format stream-json --output-format
/// stream-json`: a user message a line in, its own messages and their
/// pieces out, and every question of permission asked of us
/// (`--permission-prompt-tool stdio`) as a `can_use_tool` request.
class ClaudeTalk extends Talk {
  /// Claude as this computer has it: its plugins, to say which are on.
  final AgentSpec spec;

  ClaudeTalk(this.spec, super.ask, super.sink, {required super.dir});

  /// The command for [ask], taking up [resume] if given; the same choices
  /// as its terminal's (`launchOf`), less the hooks: this talk is told how
  /// it stands in the messages themselves.
  static List<String> argv(AgentSpec spec, ChatAsk ask, {String? resume}) => [
    'claude',
    '-p',
    '--input-format',
    'stream-json',
    '--output-format',
    'stream-json',
    '--verbose',
    '--include-partial-messages',
    '--permission-prompt-tool',
    'stdio',
    ...claudeChoices(spec, ask, resume: resume),
  ];

  @override
  Future<void> start({String? resume}) async {
    await _run(argv(spec, ask, resume: resume), take);
    _write({
      'type': 'control_request',
      'request_id': 'init',
      'request': {'subtype': 'initialize'},
    });
  }

  var _asked = 0;

  @override
  void say(String text, {String? id}) {
    sink.item(id ?? 'u${DateTime.now().microsecondsSinceEpoch}', 'user', {
      'text': text,
    });
    sink.stands('running');
    _write({
      'type': 'user',
      'message': {'role': 'user', 'content': text},
      'parent_tool_use_id': null,
      'session_id': '',
    });
  }

  final _asks = <String, Map>{};

  @override
  void answer(String id, String choice) {
    final request = _asks.remove(id);
    if (request == null) return;
    final body = request['body'] as Map<String, Object?>;
    sink.item(id, 'ask', {...body, 'answer': choice});
    final asked = request['request'] as Map;
    final allow = choice != 'deny';
    _write({
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': request['id'],
        'response': allow
            ? {
                'behavior': 'allow',
                'updatedInput': asked['input'] ?? const {},
                if (choice == 'always' &&
                    asked['permission_suggestions'] is List)
                  'updatedPermissions': asked['permission_suggestions'],
              }
            : {'behavior': 'deny', 'message': 'The user said no.'},
      },
    });
    sink.stands(_asks.isEmpty ? 'running' : 'asking');
  }

  @override
  void interrupt() => _write({
    'type': 'control_request',
    'request_id': 'stop${_asked++}',
    'request': {'subtype': 'interrupt'},
  });

  @override
  Future<void> close() => _stop();

  /// The message the pieces and blocks are of, and how many text blocks
  /// of it have begun and been said: a text block's id is the message's
  /// and its count, which the pieces and the whole block agree on whether
  /// the whole comes a block at a time or all at once (a transcript).
  String _message = '';
  int _begun = 0;
  int _said = 0;
  String? _streaming;
  String _last = '';
  final _tools = <String, Map<String, Object?>>{};

  void _onMessage(String id) {
    if (id == _message) return;
    _message = id;
    _begun = 0;
    _said = 0;
  }

  /// One line of Claude's output — or of a session's transcript, which
  /// holds the same messages, read after the chat was in its terminal.
  void take(Map line) {
    switch (line['type']) {
      case 'system':
        if (line['subtype'] == 'init' && line['session_id'] is String) {
          sink.inSession(line['session_id'] as String);
        } else if (line['subtype'] == 'status' &&
            line['status'] == 'requesting') {
          sink.stands(_asks.isEmpty ? 'running' : 'asking');
        }
      case 'stream_event':
        _piece(line['event'] as Map? ?? const {});
      case 'assistant':
        final message = line['message'] as Map? ?? const {};
        _onMessage('${message['id']}');
        for (final block in message['content'] as List? ?? const []) {
          _block(block as Map);
        }
      case 'user' when line['isMeta'] != true:
        final content = (line['message'] as Map?)?['content'];
        if (content is String) {
          if (!_isCommand(content)) {
            sink.item('${line['uuid']}', 'user', {'text': content});
          }
          return;
        }
        for (final block in content as List? ?? const []) {
          final b = block as Map;
          if (b['type'] == 'tool_result') {
            _toolDone(b);
          } else if (b['type'] == 'text' && !_isCommand('${b['text']}')) {
            sink.item('${line['uuid']}', 'user', {'text': b['text']});
          }
        }
      case 'control_request':
        _request(line);
      case 'result':
        final failed = line['is_error'] == true;
        final said = line['result'] is String ? line['result'] as String : '';
        if (failed && line['subtype'] != 'success') {
          final errors = (line['errors'] as List?)?.join('\n');
          sink.item('r${line['uuid'] ?? _asked++}', 'note', {
            'text': errors?.isNotEmpty == true
                ? errors
                : said.isNotEmpty
                ? said
                : 'The turn ended in an error.',
            'error': true,
          });
        }
        sink.turnEnded(said.isNotEmpty ? said : _last, failed: failed);
        sink.stands('idle');
    }
  }

  /// Claude's own commands and its notes to itself, as a transcript keeps
  /// them: not things the user said.
  static bool _isCommand(String text) {
    final t = text.trimLeft();
    return t.startsWith('<command-') ||
        t.startsWith('<local-command') ||
        t.startsWith('<system-reminder') ||
        t.startsWith('Caveat:');
  }

  void _piece(Map event) {
    switch (event['type']) {
      case 'message_start':
        _onMessage('${(event['message'] as Map?)?['id']}');
      case 'content_block_start':
        final block = event['content_block'] as Map? ?? const {};
        _streaming = block['type'] == 'text' ? '$_message:${_begun++}' : null;
      case 'content_block_delta':
        final delta = event['delta'] as Map? ?? const {};
        final streaming = _streaming;
        if (streaming != null && delta['type'] == 'text_delta') {
          sink.delta(streaming, '${delta['text']}');
        }
    }
  }

  void _block(Map block) {
    switch (block['type']) {
      case 'text':
        final text = '${block['text']}';
        _last = text;
        sink.item('$_message:${_said++}', 'text', {'text': text});
      case 'thinking':
        final text = '${block['thinking'] ?? ''}'.trim();
        if (text.isNotEmpty) {
          sink.item('$_message:k$_said', 'thinking', {'text': text});
        }
      case 'tool_use':
        final id = '${block['id']}';
        final name = '${block['name']}';
        final input = block['input'] as Map? ?? const {};
        final body = _tools[id] = {
          'name': name,
          'line': toolLine(name, input),
          'detail': toolDetail(name, input),
          'done': false,
        };
        sink.item(id, 'tool', body);
    }
  }

  void _toolDone(Map block) {
    final id = '${block['tool_use_id']}';
    final body = {
      ...?_tools.remove(id),
      'output': clip(_textOf(block['content'])),
      'failed': block['is_error'] == true,
      'done': true,
    };
    body['name'] ??= 'Tool';
    sink.item(id, 'tool', body);
  }

  void _request(Map line) {
    final request = line['request'] as Map? ?? const {};
    final rid = '${line['request_id']}';
    if (request['subtype'] != 'can_use_tool') {
      // Nothing else is set up to be asked of us (no hooks, no tools of
      // the app's own): said no to, so Claude does not wait on it.
      _write({
        'type': 'control_response',
        'response': {
          'subtype': 'error',
          'request_id': rid,
          'error': 'Not handled here.',
        },
      });
      return;
    }
    final name = '${request['tool_name']}';
    final input = request['input'] as Map? ?? const {};
    final suggestions = request['permission_suggestions'];
    final body = <String, Object?>{
      'tool': name,
      'line': toolLine(name, input),
      'detail': toolDetail(name, input),
      'choices': [
        'allow',
        if (suggestions is List && suggestions.isNotEmpty) 'always',
        'deny',
      ],
    };
    final id = 'ask:$rid';
    _asks[id] = {'id': rid, 'request': request, 'body': body};
    sink.item(id, 'ask', body);
    sink.stands('asking', note: '$name: ${body['line']}');
  }
}

/// The words a tool's result is, out of Claude's blocks.
String _textOf(Object? content) {
  if (content is String) return content;
  if (content is List) {
    return [
      for (final part in content)
        if (part is Map && part['type'] == 'text') '${part['text']}',
    ].join('\n');
  }
  return content == null ? '' : '$content';
}

/// A tool's output is cut to this: the chat shows what it did, the agent
/// has the rest.
const clipAt = 4000;

String clip(String text, [int at = clipAt]) =>
    text.length <= at ? text : '${text.substring(0, at)}\n…';

/// One line for what a tool is asked to do: the command, the file, the
/// pattern.
String toolLine(String name, Map input) {
  String? of(String key) =>
      input[key] is String && (input[key] as String).trim().isNotEmpty
      ? (input[key] as String).trim().split('\n').first
      : null;
  final line = switch (name) {
    'Bash' => of('command'),
    'Read' ||
    'Write' ||
    'Edit' ||
    'NotebookEdit' => of('file_path') ?? of('notebook_path'),
    'Glob' || 'Grep' => of('pattern'),
    'WebFetch' => of('url'),
    'WebSearch' => of('query'),
    'Task' || 'Agent' => of('description'),
    'Skill' => of('skill'),
    _ => null,
  };
  return line ??
      input.values
          .whereType<String>()
          .map((s) => s.split('\n').first)
          .firstOrNull ??
      '';
}

/// What there is to see under that line, opened: the whole command, the
/// change, the questions.
String toolDetail(String name, Map input) {
  switch (name) {
    case 'Bash':
      final command = '${input['command'] ?? ''}';
      return command.contains('\n') ? command : '';
    case 'Edit':
      return clip(
        '- ${'${input['old_string'] ?? ''}'.replaceAll('\n', '\n- ')}\n'
        '+ ${'${input['new_string'] ?? ''}'.replaceAll('\n', '\n+ ')}',
        1500,
      );
    case 'Write':
      return clip('${input['content'] ?? ''}', 1500);
    case 'Read' || 'Glob' || 'Grep' || 'WebFetch' || 'WebSearch':
      return '';
  }
  final rest = {
    for (final MapEntry(:key, :value) in input.entries)
      if (value is! String || value.contains('\n') || value.length > 60)
        key: value,
  };
  return rest.isEmpty
      ? ''
      : clip(const JsonEncoder.withIndent('  ').convert(rest), 1500);
}

/// Where Claude keeps a session's transcript: under its projects, the
/// folder's path with everything but letters and digits made a dash.
String claudeTranscript(String home, String dir, String session) =>
    '$home/.claude/projects/'
    '${dir.replaceAll(RegExp(r'[^A-Za-z0-9]'), '-')}/$session.jsonl';

/// Codex's app server: JSON-RPC a line each way. A thread is the chat
/// (its id kept as the session), a turn each message; Codex asks before a
/// command or a change as a request of its own, answered `accept`,
/// `acceptForSession` or `decline`.
class CodexTalk extends Talk {
  CodexTalk(super.ask, super.sink, {required super.dir});

  String? _thread;
  String? _turn;
  var _next = 0;
  final _waiting = <int, Completer<Map>>{};
  final _asks = <String, ({Object id, bool legacy, Map body})>{};
  String _last = '';

  /// The times after which what a resumed thread holds is shown: what was
  /// said in its terminal meanwhile.
  int? since;

  /// What the chat's permission choice comes to: when Codex asks, and what
  /// its sandbox lets it touch.
  static (String, String) policyOf(String? permission) => switch (permission) {
    'untrusted' => ('untrusted', 'workspace-write'),
    'never' => ('never', 'workspace-write'),
    'read-only' => ('on-request', 'read-only'),
    'full-access' => ('never', 'danger-full-access'),
    _ => ('on-request', 'workspace-write'),
  };

  @override
  Future<void> start({String? resume}) async {
    await _run(['codex', 'app-server'], take);
    await _call('initialize', {
      'clientInfo': {'name': 'caldo', 'title': 'Caldo', 'version': '1'},
      'capabilities': null,
    });
    _write({'method': 'initialized'});
    final (approval, sandbox) = policyOf(ask.permission);
    final settings = {
      'cwd': dir,
      'approvalPolicy': approval,
      'sandbox': sandbox,
      'model': ?ask.model,
    };
    final Map result;
    if (resume != null) {
      result = await _call('thread/resume', {'threadId': resume, ...settings});
    } else {
      result = await _call('thread/start', settings);
    }
    final thread = result['thread'] as Map? ?? const {};
    _thread = thread['id'] as String?;
    if (_thread != null) sink.inSession(_thread!);
    final since = this.since;
    if (since != null) {
      for (final turn in thread['turns'] as List? ?? const []) {
        final t = turn as Map;
        if (((t['startedAt'] as num?) ?? 0) * 1000 <= since) continue;
        for (final item in t['items'] as List? ?? const []) {
          _done(item as Map, history: true);
        }
      }
    }
  }

  Future<Map> _call(String method, Map<String, Object?> params) {
    final id = _next++;
    final done = _waiting[id] = Completer<Map>();
    _write({'method': method, 'id': id, 'params': params});
    return done.future.timeout(const Duration(seconds: 30));
  }

  @override
  void say(String text, {String? id}) {
    sink.item(id ?? 'u${DateTime.now().microsecondsSinceEpoch}', 'user', {
      'text': text,
    });
    sink.stands('running');
    final thread = _thread;
    if (thread == null) return;
    // Said while a turn is on, it is put into that turn (Codex steers).
    unawaited(
      _call('turn/start', {
        'threadId': thread,
        'input': [
          {'type': 'text', 'text': text, 'text_elements': <Object>[]},
        ],
        'effort': ?ask.effort,
      }).catchError((Object e) {
        sink.item('e${_next++}', 'note', {'text': '$e', 'error': true});
        sink.stands('idle');
        return const <String, Object?>{};
      }),
    );
  }

  @override
  void answer(String id, String choice) {
    final asked = _asks.remove(id);
    if (asked == null) return;
    sink.item(id, 'ask', {...asked.body, 'answer': choice});
    final decision = asked.legacy
        ? switch (choice) {
            'allow' => 'approved',
            'always' => 'approved_for_session',
            _ => 'denied',
          }
        : switch (choice) {
            'allow' => 'accept',
            'always' => 'acceptForSession',
            _ => 'decline',
          };
    _write({
      'id': asked.id,
      'result': {'decision': decision},
    });
    sink.stands(_asks.isEmpty ? 'running' : 'asking');
  }

  @override
  void interrupt() {
    final thread = _thread, turn = _turn;
    if (thread == null || turn == null) return;
    unawaited(
      _call('turn/interrupt', {
        'threadId': thread,
        'turnId': turn,
      }).catchError((_) => const <String, Object?>{}),
    );
  }

  @override
  Future<void> close() => _stop();

  /// The changes a file item will make, kept from its start for the
  /// question asked about it.
  final _changes = <String, String>{};

  void take(Map line) {
    final method = line['method'] as String?;
    final id = line['id'];
    if (method == null) {
      // An answer to a call of ours.
      final waiting = _waiting.remove(id);
      if (waiting == null) return;
      if (line['error'] case final Map error) {
        waiting.completeError(StateError('${error['message']}'));
      } else {
        waiting.complete(line['result'] as Map? ?? const {});
      }
      return;
    }
    final params = line['params'] as Map? ?? const {};
    if (id != null) {
      _request(id, method, params);
      return;
    }
    switch (method) {
      case 'turn/started':
        _turn = (params['turn'] as Map?)?['id'] as String?;
        sink.stands('running');
      case 'item/started':
        _started(params['item'] as Map? ?? const {});
      case 'item/agentMessage/delta':
        sink.delta('${params['itemId']}', '${params['delta'] ?? ''}');
      case 'item/completed':
        _done(params['item'] as Map? ?? const {});
      case 'turn/completed':
        final turn = params['turn'] as Map? ?? const {};
        final failed = turn['status'] == 'failed';
        if (turn['error'] case final Map error when failed) {
          sink.item('${turn['id']}:error', 'note', {
            'text': '${error['message']}',
            'error': true,
          });
        }
        _turn = null;
        sink.turnEnded(_last, failed: failed);
        sink.stands('idle');
      case 'error' when params['willRetry'] != true:
        sink.item('e${_next++}', 'note', {
          'text': '${(params['error'] as Map?)?['message'] ?? 'Error'}',
          'error': true,
        });
      case 'thread/compacted':
        sink.item('c${_next++}', 'note', {'text': 'Context compacted.'});
    }
  }

  void _started(Map item) {
    final id = '${item['id']}';
    switch (item['type']) {
      case 'commandExecution':
        sink.item(id, 'tool', {
          'name': 'Shell',
          'line': '${item['command'] ?? ''}'.split('\n').first,
          'detail': '${item['command'] ?? ''}'.contains('\n')
              ? '${item['command']}'
              : '',
          'done': false,
        });
      case 'fileChange':
        final changes = item['changes'] as List? ?? const [];
        _changes[id] = clip(
          [for (final c in changes) '${(c as Map)['diff'] ?? ''}'].join('\n'),
          1500,
        );
        sink.item(id, 'tool', {
          'name': 'Edit',
          'line': [for (final c in changes) '${(c as Map)['path']}'].join(', '),
          'detail': _changes[id],
          'done': false,
        });
      case 'mcpToolCall':
        sink.item(id, 'tool', {
          'name': '${item['server']}.${item['tool']}',
          'line': toolLine('', item['arguments'] as Map? ?? const {}),
          'done': false,
        });
      case 'webSearch':
        sink.item(id, 'tool', {
          'name': 'Search',
          'line': '${item['query'] ?? ''}',
          'done': false,
        });
    }
  }

  /// A finished item; with [history], one read back from a resumed thread,
  /// the user's words among them.
  void _done(Map item, {bool history = false}) {
    final id = '${item['id']}';
    switch (item['type']) {
      case 'userMessage' when history:
        final text = [
          for (final c in item['content'] as List? ?? const [])
            if (c is Map && c['type'] == 'text') '${c['text']}',
        ].join('\n');
        if (text.isNotEmpty) sink.item(id, 'user', {'text': text});
      case 'agentMessage':
        final text = '${item['text'] ?? ''}';
        _last = text;
        sink.item(id, 'text', {'text': text});
      case 'reasoning':
        final text = [
          ...(item['summary'] as List? ?? const []),
        ].join('\n\n').trim();
        if (text.isNotEmpty) sink.item(id, 'thinking', {'text': text});
      case 'commandExecution':
        final command = '${item['command'] ?? ''}';
        sink.item(id, 'tool', {
          'name': 'Shell',
          'line': command.split('\n').first,
          'detail': command.contains('\n') ? command : '',
          'output': clip('${item['aggregatedOutput'] ?? ''}'),
          'failed': (item['exitCode'] as num? ?? 0) != 0,
          'done': true,
        });
      case 'fileChange':
        final changes = item['changes'] as List? ?? const [];
        sink.item(id, 'tool', {
          'name': 'Edit',
          'line': [for (final c in changes) '${(c as Map)['path']}'].join(', '),
          'detail': clip(
            [for (final c in changes) '${(c as Map)['diff'] ?? ''}'].join('\n'),
            1500,
          ),
          'failed': item['status'] != 'completed',
          'done': true,
        });
        _changes.remove(id);
      case 'mcpToolCall':
        final error = item['error'];
        sink.item(id, 'tool', {
          'name': '${item['server']}.${item['tool']}',
          'line': toolLine('', item['arguments'] as Map? ?? const {}),
          'output': clip(
            error is Map ? '${error['message']}' : _mcpText(item['result']),
          ),
          'failed': error != null,
          'done': true,
        });
      case 'webSearch':
        sink.item(id, 'tool', {
          'name': 'Search',
          'line': '${item['query'] ?? ''}',
          'done': true,
        });
    }
  }

  static String _mcpText(Object? result) => result is Map
      ? _textOf(result['content'])
      : result == null
      ? ''
      : '$result';

  void _request(Object id, String method, Map params) {
    final key = 'ask:$id';
    final Map<String, Object?> body;
    final legacy =
        method == 'execCommandApproval' || method == 'applyPatchApproval';
    switch (method) {
      case 'item/commandExecution/requestApproval' || 'execCommandApproval':
        final command = params['command'];
        final line = command is List ? command.join(' ') : '${command ?? ''}';
        body = {
          'tool': 'Shell',
          'line': line.split('\n').first,
          'detail': params['reason'] ?? '',
          'choices': const ['allow', 'always', 'deny'],
        };
      case 'item/fileChange/requestApproval' || 'applyPatchApproval':
        body = {
          'tool': 'Edit',
          'line': '${params['reason'] ?? 'Change files'}',
          'detail': _changes['${params['itemId']}'] ?? '',
          'choices': const ['allow', 'always', 'deny'],
        };
      default:
        // Questions of a kind not drawn here yet: refused, not left
        // hanging.
        _write({
          'id': id,
          'error': {'code': -32601, 'message': 'Not handled by Caldo.'},
        });
        return;
    }
    _asks[key] = (id: id, legacy: legacy, body: body);
    sink.item(key, 'ask', body);
    sink.stands('asking', note: '${body['tool']}: ${body['line']}');
  }
}

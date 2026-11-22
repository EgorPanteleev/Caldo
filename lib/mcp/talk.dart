import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'agents.dart';
import 'kept.dart';
import 'usage.dart';

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

  /// What the chat has spent and where it stands (`ChatUsage.merged`):
  /// [set] as it is now, [add] what a turn or a request added.
  void usage({
    Map<String, Object?> set = const {},
    Map<String, num> add = const {},
  });

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
  final TalkSink _sink;

  /// The folder it works in.
  final String dir;

  Talk(this.ask, TalkSink sink, {required this.dir}) : _sink = sink;

  /// Where what it says goes: the worker — or nowhere, while what a worker
  /// before this one handed on is read again ([takeUp]).
  TalkSink get sink => _replay ?? _sink;
  _Replay? _replay;

  /// Starts its program, its files at [files]; with [resume], carrying on
  /// that session.
  Future<void> start({required String files, String? resume});

  /// One line of what its program says.
  void take(Map line);

  /// One line written to its program, read again in [takeUp]: what it
  /// shows that its output does not, such as a question answered.
  void _wrote(Map line) {}

  /// Its program as a worker before this one left it, running or ended
  /// meanwhile: what that worker handed on is read again unheard, with
  /// what it wrote, to know what is open (a question waiting, a tool under
  /// way), and the rest goes on as it comes. How the chat stands is the
  /// row's, which that worker kept: its output alone does not say a turn
  /// began, as a turn begins with what was written.
  void takeUp(Kept kept, {String? session}) {
    _replay = const _Replay();
    kept.before().forEach(_line);
    for (final line in kept.written()) {
      try {
        _wrote(jsonDecode(line) as Map);
      } on FormatException {
        // Cut short as it was written.
      }
    }
    _replay = null;
    _takenUp(session);
    _follow(kept);
  }

  /// What a program taken up needs beyond its output: [session], its own.
  void _takenUp(String? session) {}

  /// [text] said by the user, with [files] sent along; [id], the app's own
  /// for it, so the words it showed at once are these.
  void say(String text, {String? id, List<Given> files = const []});

  /// [choice] is `allow`, `always` or `deny`; or `answer` to questions
  /// asked of the user, [answers] by each question's words.
  void answer(
    String ask,
    String choice, {
    Map<String, String> answers = const {},
  });
  void interrupt();
  Future<void> close();

  /// The talk for [spec], or null for one only run in a terminal; [given]
  /// is where the files sent to it are kept.
  static Talk? of(
    AgentSpec spec,
    ChatAsk ask,
    TalkSink sink,
    String dir, {
    String? given,
  }) => switch (spec.id) {
    'claude' => ClaudeTalk(spec, ask, sink, dir: dir, given: given),
    'codex' => CodexTalk(ask, sink, dir: dir),
    _ => null,
  };

  /// Its program, run apart from the worker so it outlives it.
  Kept? _kept;

  /// How far into its program's output has been handed on: kept by the
  /// worker, for one started again to read on from.
  int? get offset => _kept?.offset;

  Future<void> _run(String files, List<String> argv) async =>
      _follow(await Kept.start(files, argv, cwd: dir));

  void _follow(Kept kept) {
    _kept = kept;
    kept.listen(_line, (code, why) {
      if (_kept == kept) _kept = null;
      Kept.clear(kept.base);
      _sink.exited(code, why.trim());
    });
  }

  void _line(String line) {
    if (line.trim().isEmpty) return;
    try {
      take(jsonDecode(line) as Map);
    } on FormatException {
      // Not ours: a line some tool printed past the protocol.
    }
  }

  void _write(Map<String, Object?> message) {
    // Read again, it was answered when it was said.
    if (_replay != null) return;
    _kept?.write(jsonEncode(message));
  }

  Future<void> _stop() async {
    final kept = _kept;
    _kept = null;
    await kept?.stop();
  }
}

/// Where a talk's words go while what was handed on before is read again:
/// nowhere.
class _Replay implements TalkSink {
  const _Replay();

  @override
  void stands(String state, {String? note}) {}
  @override
  void item(String id, String kind, Map<String, Object?> body) {}
  @override
  void delta(String id, String text) {}
  @override
  void inSession(String id) {}
  @override
  void usage({
    Map<String, Object?> set = const {},
    Map<String, num> add = const {},
  }) {}
  @override
  void turnEnded(String answer, {bool failed = false}) {}
  @override
  void exited(int code, String why) {}
}

/// Claude Code with `--input-format stream-json --output-format
/// stream-json`: a user message a line in, its own messages and their
/// pieces out, and every question of permission asked of us
/// (`--permission-prompt-tool stdio`) as a `can_use_tool` request.
class ClaudeTalk extends Talk {
  /// Claude as this computer has it: its plugins, to say which are on.
  final AgentSpec spec;

  /// Where the files sent to it are kept, read without asking.
  final String? given;

  ClaudeTalk(
    this.spec,
    super.ask,
    super.sink, {
    required super.dir,
    this.given,
  });

  /// The command for [ask], taking up [resume] if given; the same choices
  /// as its terminal's (`launchOf`), less the hooks: this talk is told how
  /// it stands in the messages themselves.
  static List<String> argv(
    AgentSpec spec,
    ChatAsk ask, {
    String? resume,
    String? given,
  }) => [
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
    ...claudeChoices(spec, ask, resume: resume, given: given),
  ];

  @override
  Future<void> start({required String files, String? resume}) async {
    await _run(files, argv(spec, ask, resume: resume, given: given));
    _write({
      'type': 'control_request',
      'request_id': 'init',
      'request': {'subtype': 'initialize'},
    });
  }

  var _asked = 0;

  @override
  void say(String text, {String? id, List<Given> files = const []}) {
    sink.item(
      id ?? 'u${DateTime.now().microsecondsSinceEpoch}',
      'user',
      saidBody(text, files),
    );
    sink.stands('running');
    _write({
      'type': 'user',
      'message': {'role': 'user', 'content': withFiles(text, files)},
      'parent_tool_use_id': null,
      'session_id': '',
    });
  }

  final _asks = <String, Map>{};

  @override
  void _wrote(Map line) {
    final response = line['response'];
    if (line['type'] == 'control_response' && response is Map) {
      _asks.remove('ask:${response['request_id']}');
    }
  }

  @override
  void answer(
    String id,
    String choice, {
    Map<String, String> answers = const {},
  }) {
    final request = _asks.remove(id);
    if (request == null) return;
    final body = request['body'] as Map<String, Object?>;
    sink.item(id, 'ask', {
      ...body,
      'answer': choice,
      if (answers.isNotEmpty) 'answers': answers,
    });
    _write({
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': request['id'],
        'response': claudeVerdict(
          request['request'] as Map,
          choice,
          answers: answers,
        ),
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

  /// AskUserQuestion's calls: their question, with its answers, is their
  /// record in the chat, so no tool line says them again.
  final _asking = <String>{};

  void _onMessage(String id) {
    if (id == _message) return;
    _message = id;
    _begun = 0;
    _said = 0;
  }

  /// One line of Claude's output — or of a session's transcript, which
  /// holds the same messages, read after the chat was in its terminal.
  @override
  void take(Map line) {
    switch (line['type']) {
      case 'system':
        if (line['subtype'] == 'init' && line['session_id'] is String) {
          sink.inSession(line['session_id'] as String);
          if (line['model'] case final String model) {
            _model = model;
            sink.usage(set: {'model': model});
          }
        } else if (line['subtype'] == 'status' &&
            line['status'] == 'requesting') {
          sink.stands(_asks.isEmpty ? 'running' : 'asking');
        }
      case 'stream_event':
        final event = line['event'] as Map? ?? const {};
        if (line['parent_tool_use_id'] == null) _filled(event);
        _piece(event);
      case 'assistant':
        final message = line['message'] as Map? ?? const {};
        if (line['parent_tool_use_id'] == null) _filled(message);
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
      case 'rate_limit_event':
        _limits(line['rate_limit_info'] as Map? ?? const {});
      case 'result':
        _spent(line);
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

  /// The model as Claude names it, its cost so far and each model's
  /// tokens so far, as the last result said: a result says the program's
  /// totals, and the chat is told what each adds.
  String? _model;
  double _cost = 0;
  final _counted = <String, Map>{};

  /// How full the context is, from a request's usage: what it took in,
  /// read from the cache or wrote to it, and what it gave out. Said by the
  /// message as it starts, as it ends and whole; a helper's (a line with a
  /// `parent_tool_use_id`) is its own context, not the chat's.
  void _filled(Map event) {
    final usage =
        event['usage'] ?? (event['message'] as Map?)?['usage'] as Object?;
    if (usage is! Map) return;
    var sum = 0;
    for (final key in const [
      'input_tokens',
      'cache_creation_input_tokens',
      'cache_read_input_tokens',
      'output_tokens',
    ]) {
      if (usage[key] case final num n) sum += n.round();
    }
    if (sum > 0) sink.usage(set: {'context': sum});
  }

  /// The account's limits: each window's share used and when it starts
  /// again, as one comes after every request.
  void _limits(Map info) {
    final windows = info['unifiedWindows'];
    final limits = <Map<String, Object?>>[];
    if (windows is Map) {
      for (final MapEntry(:key, :value) in windows.entries) {
        if (value is Map && value['utilization'] is num) {
          limits.add(
            limitRow(
              '$key',
              value['utilization'] as num,
              resets: value['resetsAt'] as num?,
            ),
          );
        }
      }
    } else if (info['utilization'] is num && info['rateLimitType'] is String) {
      limits.add(
        limitRow(
          info['rateLimitType'] as String,
          info['utilization'] as num,
          resets: info['resetsAt'] as num?,
        ),
      );
    }
    sink.usage(
      set: {
        if (limits.isNotEmpty) 'limits': limits,
        if (limits.isNotEmpty)
          'limitsAt': DateTime.now().millisecondsSinceEpoch,
        'limited': info['status'],
      },
    );
  }

  /// A turn's figures: its time, and what its result's totals add to the
  /// last one's — helpers' models among them, as the cost counts them.
  void _spent(Map line) {
    final add = <String, num>{'turns': 1};
    if (line['duration_ms'] case final num ms) add['working'] = ms;
    if (line['total_cost_usd'] case final num total) {
      add['cost'] = max(0, total - _cost);
      _cost = total.toDouble();
    }
    num? window;
    final models = line['modelUsage'];
    if (models is Map) {
      for (final MapEntry(key: name, value: now) in models.entries) {
        if (now is! Map) continue;
        final had = _counted['$name'] ?? const {};
        for (final (theirs, ours) in const [
          ('inputTokens', 'input'),
          ('outputTokens', 'output'),
          ('cacheReadInputTokens', 'cacheRead'),
          ('cacheCreationInputTokens', 'cacheWrite'),
        ]) {
          if (now[theirs] case final num n) {
            final before = had[theirs] is num ? had[theirs] as num : 0;
            add[ours] = (add[ours] ?? 0) + max(0, n - before);
          }
        }
        _counted['$name'] = now;
        final model = _model;
        final ours =
            model != null &&
            ('$name'.startsWith(model) || model.startsWith('$name'));
        if (now['contextWindow'] case final num w when ours || window == null) {
          window = w;
        }
      }
    }
    sink.usage(set: {'window': window}, add: add);
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
        if (questionsOf(name, input) != null) {
          _asking.add(id);
          return;
        }
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
    if (_asking.remove(id)) return;
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
    final questions = questionsOf(name, input);
    final body = <String, Object?>{
      'tool': name,
      if (questions != null) ...{
        'line': questions.map((q) => q['question']).join(' · '),
        'questions': questions,
        'choices': const ['answer', 'deny'],
      } else ...{
        'line': toolLine(name, input),
        'detail': toolDetail(name, input),
        'choices': [
          'allow',
          if (suggestions is List && suggestions.isNotEmpty) 'always',
          'deny',
        ],
      },
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

/// The questions Claude asks the user through AskUserQuestion, each
/// `question`, `header`, `options` (`label`, `description`) and
/// `multiSelect`; null for any other tool. It comes as a question of
/// permission like the rest, but what it waits for is the answers, not a
/// yes: allowed as it came, Claude is told nothing was chosen.
List<Map<String, Object?>>? questionsOf(String tool, Map input) {
  final asked = input['questions'];
  if (tool != 'AskUserQuestion' || asked is! List) return null;
  final questions = [
    for (final q in asked.whereType<Map>())
      if ('${q['question'] ?? ''}'.trim().isNotEmpty)
        {
          'question': '${q['question']}'.trim(),
          'header': '${q['header'] ?? ''}'.trim(),
          'multiSelect': q['multiSelect'] == true,
          'options': [
            for (final o in (q['options'] as List? ?? const []))
              if (o is Map && '${o['label'] ?? ''}'.trim().isNotEmpty)
                {
                  'label': '${o['label']}'.trim(),
                  'description': '${o['description'] ?? ''}'.trim(),
                },
          ],
        },
  ];
  return questions.isEmpty ? null : questions;
}

/// What Claude is told of its question of permission [request] given
/// [choice]: to AskUserQuestion, the [answers] by each question's words,
/// several choices of one joined with ", " (as Claude's own terminal does).
Map<String, Object?> claudeVerdict(
  Map request,
  String choice, {
  Map<String, String> answers = const {},
}) {
  final input = request['input'] as Map? ?? const {};
  if (questionsOf('${request['tool_name']}', input) != null) {
    if (choice == 'answer' && answers.isNotEmpty) {
      return {
        'behavior': 'allow',
        'updatedInput': {...input, 'answers': answers},
      };
    }
    return {
      'behavior': 'deny',
      'message': choice == 'deny'
          ? 'The user chose not to answer.'
          // An app from before questions were drawn has only Allow.
          : 'The user could not answer these questions here; ask them in '
                'plain words instead.',
    };
  }
  if (choice == 'deny') {
    return {'behavior': 'deny', 'message': 'The user said no.'};
  }
  return {
    'behavior': 'allow',
    'updatedInput': input,
    if (choice == 'always' && request['permission_suggestions'] is List)
      'updatedPermissions': request['permission_suggestions'],
  };
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

/// [session] if [spec] can take it up, else null to start afresh. Claude
/// names a session as soon as it starts but writes it down only with its
/// first turn; asked to resume one never spoken in, it says "No
/// conversation found" and exits, and would at every message after.
String? resumable(AgentSpec spec, String home, String dir, String? session) {
  if (session == null || !spec.isClaude) return session;
  return File(claudeTranscript(home, dir, session)).existsSync()
      ? session
      : null;
}

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
  void _wrote(Map line) {
    if (line['method'] == null && line['result'] != null) {
      _asks.removeWhere((_, asked) => asked.id == line['id']);
    }
  }

  @override
  void _takenUp(String? session) {
    _thread ??= session;
    // Past every id the worker before used, for its calls and its notes:
    // a note under one it used would be written over that one.
    _next = DateTime.now().microsecondsSinceEpoch;
  }

  @override
  Future<void> start({required String files, String? resume}) async {
    await _run(files, ['codex', 'app-server']);
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
      // A thread keeps those it began with: a resumed one is not told
      // them again.
      'developerInstructions': ?ask.rules,
    };
    Map? result;
    if (resume != null) {
      try {
        result = await _call('thread/resume', {
          'threadId': resume,
          ...settings,
        });
      } on StateError {
        // A thread never spoken in may not have been kept: begun afresh.
      }
    }
    result ??= await _call('thread/start', settings);
    final model = result['model'] ?? ask.model;
    if (model is String) sink.usage(set: {'model': model});
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
  void say(String text, {String? id, List<Given> files = const []}) {
    sink.item(
      id ?? 'u${DateTime.now().microsecondsSinceEpoch}',
      'user',
      saidBody(text, files),
    );
    sink.stands('running');
    final thread = _thread;
    if (thread == null) return;
    // Said while a turn is on, it is put into that turn (Codex steers).
    unawaited(
      _call('turn/start', {
        'threadId': thread,
        'input': [
          {
            'type': 'text',
            'text': withFiles(text, files),
            'text_elements': <Object>[],
          },
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
  void answer(
    String id,
    String choice, {
    Map<String, String> answers = const {},
  }) {
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

  @override
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
        _began = DateTime.now();
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
        final began = _began;
        _began = null;
        sink.usage(
          add: {
            'turns': 1,
            if (began != null)
              'working': DateTime.now().difference(began).inMilliseconds,
          },
        );
        sink.turnEnded(_last, failed: failed);
        sink.stands('idle');
      case 'error' when params['willRetry'] != true:
        sink.item('e${_next++}', 'note', {
          'text': '${(params['error'] as Map?)?['message'] ?? 'Error'}',
          'error': true,
        });
      case 'thread/compacted':
        sink.item('c${_next++}', 'note', {'text': 'Context compacted.'});
      case 'thread/tokenUsage/updated':
        _tokens(params['tokenUsage'] as Map? ?? const {});
      case 'account/rateLimits/updated':
        _limits(params['rateLimits'] as Map? ?? const {});
    }
  }

  /// When the turn under way began, for how long it worked.
  DateTime? _began;

  /// The thread's tokens as last said, to tell what each saying adds.
  Map? _total;

  /// The thread's tokens: its total, the last request's, and how many its
  /// model holds. Said again with nothing new (as limits change), so what
  /// is added is how far the total went on; the first said by a program,
  /// whose total may hold a resumed thread's past, adds only its last.
  /// Codex counts the cached part in what was taken in.
  void _tokens(Map usage) {
    final total = usage['total'], last = usage['last'];
    if (total is! Map) return;
    num of(Map? m, String key) => m?[key] is num ? m![key] as num : 0;
    final had = _total;
    final from = had == null && last is Map ? last : total;
    num added(String key) =>
        had == null ? of(from, key) : max(0, of(total, key) - of(had, key));
    _total = total;
    final cached = added('cachedInputTokens');
    sink.usage(
      set: {
        if (last is Map) 'context': of(last, 'totalTokens'),
        'window': usage['modelContextWindow'],
      },
      add: {
        'input': max(0, added('inputTokens') - cached),
        'cacheRead': cached,
        'output': added('outputTokens'),
      },
    );
  }

  /// The account's limits: a short window and a long one, each a percent
  /// used and when it starts again.
  void _limits(Map limits) {
    final rows = [
      for (final name in const ['primary', 'secondary'])
        if (limits[name] case final Map window
            when window['usedPercent'] is num)
          limitRow(
            name,
            (window['usedPercent'] as num) / 100,
            resets: window['resetsAt'] as num?,
            minutes: window['windowDurationMins'] as num?,
          ),
    ];
    if (rows.isEmpty) return;
    sink.usage(
      set: {'limits': rows, 'limitsAt': DateTime.now().millisecondsSinceEpoch},
    );
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

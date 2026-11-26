import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:caldo/l10n/strings.dart';
import 'package:caldo/mcp/accounts.dart';
import 'package:caldo/mcp/agents.dart';
import 'package:caldo/mcp/context_files.dart';
import 'package:caldo/mcp/kept.dart';
import 'package:caldo/mcp/project_files.dart';
import 'package:caldo/mcp/talk.dart';
import 'package:caldo/mcp/terminal.dart';
import 'package:caldo/mcp/usage.dart';
import 'package:caldo/mcp/workspace.dart';
import 'package:caldo/mcp/worker.dart' show answerOf, withoutNul;
import 'package:caldo/models/task.dart';
import 'package:caldo/models/task_list.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/screens/agents_screen.dart';
import 'package:caldo/services/agents.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/widgets/chat_usage.dart';
import 'package:caldo/widgets/selection.dart';
import 'package:caldo/widgets/task_card.dart' show ClaudeMark;
import 'package:caldo/utils/dates.dart';
import 'package:caldo/widgets/talk_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase/supabase.dart';
import 'package:xterm/xterm.dart';

/// What a talk said, as the worker would have sent it on.
class _Heard implements TalkSink {
  final items = <String, (String, Map<String, Object?>)>{};
  final order = <String>[];
  final deltas = <String, String>{};
  final states = <String>[];
  String? session;
  String? answer;

  @override
  void item(String id, String kind, Map<String, Object?> body) {
    if (!items.containsKey(id)) order.add(id);
    items[id] = (kind, body);
  }

  @override
  void delta(String id, String text) => deltas[id] = (deltas[id] ?? '') + text;

  @override
  void stands(String state, {String? note}) => states.add(state);

  @override
  void inSession(String id) => session = id;

  /// Whether the last turn was refused for the account's limit, and when
  /// that was said to be lifted.
  bool limited = false;
  DateTime? resets;

  @override
  void turnEnded(
    String answer, {
    bool failed = false,
    bool limited = false,
    DateTime? resets,
  }) {
    this.answer = answer;
    this.limited = limited;
    this.resets = resets;
  }

  /// What the chat has spent, kept as the worker keeps it.
  Map<String, Object?>? spent;

  @override
  void usage({
    Map<String, Object?> set = const {},
    Map<String, num> add = const {},
  }) => spent = ChatUsage.merged(spent, set: set, add: add);

  ChatUsage get counted => ChatUsage.of(spent)!;

  int? code;

  @override
  void exited(int code, String why) => this.code = code;
}

/// Waits, a little at a time, until [done].
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue);
}

/// [ProjectStore] in memory: saves hold only on the version they name.
class _Projects implements ProjectStore {
  final rows = <Map<String, dynamic>>[];
  final saved = <(String, int, String)>[];
  final unmerged = <(String, int, String)>[];
  bool refuse = false;

  @override
  Future<List<Map<String, dynamic>>> projects() async => [
    for (final r in rows) {...r},
  ];

  @override
  Future<int?> save(String id, String text, int expect, String by) async {
    final row = rows.firstWhere((r) => r['id'] == id);
    if (refuse || row['version'] != expect) return null;
    saved.add((text, expect, by));
    row
      ..['context'] = text
      ..['version'] = expect + 1;
    return expect + 1;
  }

  @override
  Future<void> keepUnmerged(
    String id,
    String text,
    int version,
    String by,
  ) async => unmerged.add((text, version, by));
}

void main() {
  group('a talk', () {
    const ask = ChatAsk(id: 'c', agent: 'claude');
    const claude = AgentSpec(
      id: 'claude',
      label: 'Claude',
      command: ['claude'],
    );

    test("reads Claude's stream: words as they come, tools, a question", () {
      final heard = _Heard();
      final talk = ClaudeTalk(claude, ask, heard, dir: '/tmp');
      for (final line in [
        {'type': 'system', 'subtype': 'init', 'session_id': 's1'},
        {'type': 'system', 'subtype': 'status', 'status': 'requesting'},
        {
          'type': 'stream_event',
          'event': {
            'type': 'message_start',
            'message': {'id': 'm1'},
          },
        },
        {
          'type': 'stream_event',
          'event': {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'tool_use', 'id': 't1', 'name': 'Bash'},
          },
        },
        {
          'type': 'assistant',
          'message': {
            'id': 'm1',
            'content': [
              {
                'type': 'tool_use',
                'id': 't1',
                'name': 'Bash',
                'input': {'command': 'ls -A | wc -l'},
              },
            ],
          },
        },
        {
          'type': 'control_request',
          'request_id': 'r1',
          'request': {
            'subtype': 'can_use_tool',
            'tool_name': 'Bash',
            'input': {'command': 'ls -A | wc -l'},
            'permission_suggestions': [
              {'type': 'setMode', 'mode': 'acceptEdits'},
            ],
          },
        },
        {
          'type': 'user',
          'message': {
            'role': 'user',
            'content': [
              {'type': 'tool_result', 'tool_use_id': 't1', 'content': '3'},
            ],
          },
        },
        {
          'type': 'stream_event',
          'event': {
            'type': 'message_start',
            'message': {'id': 'm2'},
          },
        },
        {
          'type': 'stream_event',
          'event': {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'thinking'},
          },
        },
        {
          'type': 'stream_event',
          'event': {
            'type': 'content_block_start',
            'index': 1,
            'content_block': {'type': 'text', 'text': ''},
          },
        },
        for (final piece in ['There are ', '3 files.'])
          {
            'type': 'stream_event',
            'event': {
              'type': 'content_block_delta',
              'index': 1,
              'delta': {'type': 'text_delta', 'text': piece},
            },
          },
        {
          'type': 'assistant',
          'message': {
            'id': 'm2',
            'content': [
              {'type': 'text', 'text': 'There are 3 files.'},
            ],
          },
        },
        {
          'type': 'result',
          'subtype': 'success',
          'result': 'There are 3 files.',
        },
      ]) {
        talk.take(line);
      }
      expect(heard.session, 's1');
      expect(heard.order, ['t1', 'ask:r1', 'm2:0']);
      final (kind, tool) = heard.items['t1']!;
      expect(kind, 'tool');
      expect(tool['line'], 'ls -A | wc -l');
      expect(tool['output'], '3');
      expect(tool['done'], isTrue);
      expect(heard.items['ask:r1']!.$2['choices'], ['allow', 'always', 'deny']);
      // The pieces and the whole block are one item by one id.
      expect(heard.deltas['m2:0'], 'There are 3 files.');
      expect(heard.items['m2:0']!.$2['text'], 'There are 3 files.');
      expect(heard.answer, 'There are 3 files.');
      expect(heard.states, ['running', 'asking', 'finished']);
    });

    test("reads Codex's app server: its thread, a command, its answer", () {
      final heard = _Heard();
      final talk = CodexTalk(
        const ChatAsk(id: 'c', agent: 'codex'),
        heard,
        dir: '/tmp',
      );
      for (final line in [
        {
          'method': 'turn/started',
          'params': {
            'turn': {'id': 'turn1'},
          },
        },
        {
          'method': 'item/started',
          'params': {
            'item': {
              'type': 'commandExecution',
              'id': 'i1',
              'command': 'git status',
            },
          },
        },
        {
          'id': 7,
          'method': 'item/commandExecution/requestApproval',
          'params': {'itemId': 'i1', 'command': 'git status', 'reason': 'Why'},
        },
        {
          'method': 'item/completed',
          'params': {
            'item': {
              'type': 'commandExecution',
              'id': 'i1',
              'command': 'git status',
              'aggregatedOutput': 'clean',
              'exitCode': 0,
            },
          },
        },
        {
          'method': 'item/agentMessage/delta',
          'params': {'itemId': 'i2', 'delta': 'All '},
        },
        {
          'method': 'item/agentMessage/delta',
          'params': {'itemId': 'i2', 'delta': 'clean.'},
        },
        {
          'method': 'item/completed',
          'params': {
            'item': {'type': 'agentMessage', 'id': 'i2', 'text': 'All clean.'},
          },
        },
        {
          'method': 'turn/completed',
          'params': {
            'turn': {'id': 'turn1', 'status': 'completed'},
          },
        },
      ]) {
        talk.take(line);
      }
      expect(heard.order, ['i1', 'ask:7', 'i2']);
      expect(heard.items['i1']!.$2['output'], 'clean');
      expect(heard.items['i1']!.$2['failed'], isFalse);
      expect(heard.items['ask:7']!.$2['line'], 'git status');
      expect(heard.deltas['i2'], 'All clean.');
      expect(heard.answer, 'All clean.');
      expect(heard.states.last, 'finished');
      talk.answer('ask:7', 'always');
      expect(heard.items['ask:7']!.$2['answer'], 'always');
    });

    test('answers Codex with the decisions its question offers', () {
      // As codex-cli 0.172 asks: no decision for the session, no decline.
      const asked = {
        'command': "/usr/bin/bash -lc 'git fetch origin'",
        'proposedExecpolicyAmendment': ['git', 'fetch'],
        'availableDecisions': [
          'accept',
          {
            'acceptWithExecpolicyAmendment': {
              'execpolicy_amendment': ['git', 'fetch'],
            },
          },
          'cancel',
        ],
      };
      const command = 'item/commandExecution/requestApproval';
      expect(codexVerdict(command, asked, 'allow'), {'decision': 'accept'});
      expect(codexVerdict(command, asked, 'always'), {
        'decision': {
          'acceptWithExecpolicyAmendment': {
            'execpolicy_amendment': ['git', 'fetch'],
          },
        },
      });
      expect(codexVerdict(command, asked, 'deny'), {'decision': 'cancel'});
      // A question that lists none takes them all, as before.
      expect(codexVerdict(command, const {}, 'always'), {
        'decision': 'acceptForSession',
      });
      expect(codexVerdict(command, const {}, 'deny'), {'decision': 'decline'});
      expect(codexVerdict('execCommandApproval', const {}, 'always'), {
        'decision': 'approved_for_session',
      });

      const wanted = {
        'permissions': {
          'network': {'enabled': true},
          'fileSystem': null,
        },
      };
      const more = 'item/permissions/requestApproval';
      expect(codexVerdict(more, wanted, 'allow'), {
        'permissions': {
          'network': {'enabled': true},
        },
        'scope': 'turn',
      });
      expect(codexVerdict(more, wanted, 'always')['scope'], 'session');
      expect(codexVerdict(more, wanted, 'deny'), {
        'permissions': const <String, Object?>{},
        'scope': 'turn',
      });
      expect(codexWanted(wanted['permissions']), 'Network');
    });

    test("asks for Codex's wider permissions, and a change answers them", () {
      final heard = _Heard();
      final talk = CodexTalk(
        const ChatAsk(id: 'c', agent: 'codex'),
        heard,
        dir: '/tmp',
      );
      talk.take({
        'id': 3,
        'method': 'item/permissions/requestApproval',
        'params': {
          'reason': 'Fetch packages',
          'permissions': {
            'network': {'enabled': true},
            'fileSystem': {
              'read': null,
              'write': ['/home/a/.pub-cache'],
            },
          },
        },
      });
      talk.take({
        'id': 4,
        'method': 'item/commandExecution/requestApproval',
        'params': {'command': 'git push'},
      });
      expect(heard.items['ask:3']!.$2['line'], 'Fetch packages');
      expect(
        heard.items['ask:3']!.$2['detail'],
        'Network\nWrite /home/a/.pub-cache',
      );
      expect(heard.states.last, 'asking');

      // Full access chosen in the app mid-turn: what waits is allowed, and
      // what Codex asks for the rest of the turn too.
      talk.retuned(
        const ChatAsk(id: 'c', agent: 'codex', permission: 'full-access'),
      );
      expect(heard.items['ask:3']!.$2['answer'], 'allow');
      expect(heard.items['ask:4']!.$2['answer'], 'allow');
      expect(heard.states.last, 'running');
      talk.take({
        'id': 5,
        'method': 'item/fileChange/requestApproval',
        'params': {'itemId': 'f1'},
      });
      expect(heard.items['ask:5']!.$2['answer'], 'allow');
      expect(heard.states.last, 'running');
    });

    test(
      "draws Claude's AskUserQuestion as questions and says the answers",
      () {
        final heard = _Heard();
        final talk = ClaudeTalk(claude, ask, heard, dir: '/tmp');
        final input = {
          'questions': [
            {
              'question': 'Which colour?',
              'header': 'Colour',
              'options': [
                {'label': 'Red', 'description': 'Warm'},
                {'label': 'Blue', 'description': 'Cool'},
              ],
              'multiSelect': false,
            },
            {
              'question': 'Which fruits?',
              'header': 'Fruits',
              'options': [
                {'label': 'Apple', 'description': ''},
                {'label': 'Plum', 'description': ''},
              ],
              'multiSelect': true,
            },
          ],
        };
        final request = {
          'subtype': 'can_use_tool',
          'tool_name': 'AskUserQuestion',
          'input': input,
        };
        for (final line in [
          {'type': 'system', 'subtype': 'init', 'session_id': 's1'},
          {
            'type': 'assistant',
            'message': {
              'id': 'm1',
              'content': [
                {
                  'type': 'tool_use',
                  'id': 't1',
                  'name': 'AskUserQuestion',
                  'input': input,
                },
              ],
            },
          },
          {'type': 'control_request', 'request_id': 'r1', 'request': request},
          {
            'type': 'user',
            'message': {
              'role': 'user',
              'content': [
                {
                  'type': 'tool_result',
                  'tool_use_id': 't1',
                  'content': 'The user answered…',
                },
              ],
            },
          },
        ]) {
          talk.take(line);
        }
        // The question is its record; no tool line says it again.
        expect(heard.order, ['ask:r1']);
        final body = heard.items['ask:r1']!.$2;
        expect(body['choices'], ['answer', 'deny']);
        expect((body['questions'] as List).length, 2);
        expect(heard.states.last, 'asking');

        const answers = {
          'Which colour?': 'Blue',
          'Which fruits?': 'Apple, Plum',
        };
        talk.answer('ask:r1', 'answer', answers: answers);
        expect(heard.items['ask:r1']!.$2['answers'], answers);
        expect(heard.states.last, 'running');

        // What Claude is told, as tried on Claude 2.1: the answers by
        // each question's words, beside the questions.
        expect(claudeVerdict(request, 'answer', answers: answers), {
          'behavior': 'allow',
          'updatedInput': {...input, 'answers': answers},
        });
        expect(claudeVerdict(request, 'deny')['behavior'], 'deny');
        // An app with only Allow can't answer; Claude is told so, not
        // that nothing was chosen.
        expect(claudeVerdict(request, 'allow')['behavior'], 'deny');
        // Other tools are as they were.
        expect(
          claudeVerdict({
            'tool_name': 'Bash',
            'input': {'command': 'ls'},
          }, 'allow'),
          {
            'behavior': 'allow',
            'updatedInput': {'command': 'ls'},
          },
        );
      },
    );

    test('takes NULs out of an item, which Postgres refuses', () {
      final clean = {
        'line': 'ok',
        'n': [1, 'two'],
      };
      expect(identical(withoutNul(clean), clean), isTrue);
      expect(
        withoutNul({
          'line': 'a\u0000b',
          'output': [
            {'x': '\u0000'},
            3,
          ],
          'done': true,
        }),
        {
          'line': 'ab',
          'output': [
            {'x': ''},
            3,
          ],
          'done': true,
        },
      );
    });

    test('reads an answer as the app writes it, old or new', () {
      var (item, choice, answers) = answerOf('allow ask:r1');
      expect((item, choice), ('ask:r1', 'allow'));
      expect(answers, isEmpty);
      (item, choice, answers) = answerOf(
        'answer ask:r1 ${jsonEncode({'Which one?': 'A, B c'})}',
      );
      expect((item, choice), ('ask:r1', 'answer'));
      expect(answers, {'Which one?': 'A, B c'});
      (item, choice, answers) = answerOf('answer ask:r1 {"cut');
      expect((item, choice), ('ask:r1', 'answer'));
      expect(answers, isEmpty);
      expect(answerOf('allow').$1, isNull);
      expect(answerOf(null).$1, isNull);
    });

    test("counts what Claude's turns spend, its context and its limits", () {
      final heard = _Heard();
      final talk = ClaudeTalk(claude, ask, heard, dir: '/tmp');
      Map<String, Object?> result(double cost, int input, int output) => {
        'type': 'result',
        'subtype': 'success',
        'duration_ms': 1000,
        // A result's totals are its program's, from its start.
        'total_cost_usd': cost,
        'modelUsage': {
          'claude-opus-5-5': {
            'inputTokens': input,
            'outputTokens': output,
            'cacheReadInputTokens': input * 10,
            'cacheCreationInputTokens': 5,
            'contextWindow': 200000,
          },
        },
      };
      for (final line in [
        {
          'type': 'system',
          'subtype': 'init',
          'session_id': 's1',
          'model': 'claude-opus-5-5',
        },
        {
          'type': 'stream_event',
          'parent_tool_use_id': null,
          'event': {
            'type': 'message_delta',
            'usage': {
              'input_tokens': 2,
              'cache_creation_input_tokens': 1000,
              'cache_read_input_tokens': 49000,
              'output_tokens': 300,
            },
          },
        },
        // A helper's request is its own context, not the chat's.
        {
          'type': 'stream_event',
          'parent_tool_use_id': 'toolu_1',
          'event': {
            'type': 'message_delta',
            'usage': {'input_tokens': 90000, 'output_tokens': 1},
          },
        },
        {
          'type': 'rate_limit_event',
          'rate_limit_info': {
            'status': 'allowed',
            'unifiedWindows': {
              'five_hour': {'utilization': 0.41, 'resetsAt': 1795341600},
              'seven_day': {'utilization': 0.14, 'resetsAt': 1795374000},
            },
          },
        },
        result(0.25, 10, 100),
        result(0.40, 30, 150),
      ]) {
        talk.take(line);
      }
      final used = heard.counted;
      expect(used.model, 'claude-opus-5-5');
      expect(used.context, 50302);
      expect(used.window, 200000);
      expect(used.filled, closeTo(0.2515, 0.0001));
      expect(used.turns, 2);
      expect(used.working, const Duration(seconds: 2));
      expect(used.cost, closeTo(0.40, 1e-9));
      expect(used.input, 30);
      expect(used.output, 150);
      expect(used.cacheRead, 300);
      expect(used.cacheWrite, 5);
      expect([for (final l in used.limits) l.name], ['five_hour', 'seven_day']);
      expect(used.limits.first.used, 0.41);
      expect(used.limits.first.span, 300);
      expect(
        used.limits.first.resets,
        DateTime.fromMillisecondsSinceEpoch(1795341600 * 1000),
      );

      // Its program started again counts from nothing; the chat goes on.
      final again = ClaudeTalk(claude, ask, heard, dir: '/tmp');
      again.take(result(0.10, 4, 6));
      expect(heard.counted.cost, closeTo(0.50, 1e-9));
      expect(heard.counted.input, 34);
      expect(heard.counted.turns, 3);
    });

    test("counts what Codex's thread spends, once each", () {
      final heard = _Heard();
      final talk = CodexTalk(
        const ChatAsk(id: 'c', agent: 'codex'),
        heard,
        dir: '/tmp',
      );
      Map<String, Object?> tokens(int total, int last) => {
        'method': 'thread/tokenUsage/updated',
        'params': {
          'tokenUsage': {
            'total': {
              'totalTokens': total,
              'inputTokens': total - 10,
              'cachedInputTokens': (total - 10) ~/ 2,
              'outputTokens': 10,
            },
            'last': {
              'totalTokens': last,
              'inputTokens': last - 10,
              'cachedInputTokens': 0,
              'outputTokens': 10,
            },
            'modelContextWindow': 272000,
          },
        },
      };
      for (final line in [
        {
          'method': 'turn/started',
          'params': {
            'turn': {'id': 't1'},
          },
        },
        // A resumed thread's total holds its past: only its last is new.
        tokens(5010, 1010),
        // Said again as the limits change: nothing new.
        tokens(5010, 1010),
        tokens(7010, 2010),
        {
          'method': 'account/rateLimits/updated',
          'params': {
            'rateLimits': {
              'primary': {
                'usedPercent': 12,
                'windowDurationMins': 300,
                'resetsAt': 1795341600,
              },
              'secondary': {'usedPercent': 3, 'windowDurationMins': 10080},
            },
          },
        },
        {
          'method': 'turn/completed',
          'params': {
            'turn': {'id': 't1', 'status': 'completed'},
          },
        },
      ]) {
        talk.take(line);
      }
      final used = heard.counted;
      expect(used.turns, 1);
      expect(used.context, 2010);
      expect(used.window, 272000);
      // 1000 taken in at first, then 2000 more, half of those cached.
      expect(used.input + used.cacheRead, 3000);
      expect(used.cacheRead, 1000);
      expect(used.output, 10);
      expect(used.cost, isNull);
      expect([for (final l in used.limits) l.used], [0.12, 0.03]);
      expect([for (final l in used.limits) l.span], [300, 10080]);
    });

    test("tells a turn Claude's limit refused, and when it is lifted", () {
      final heard = _Heard();
      final talk = ClaudeTalk(claude, ask, heard, dir: '/tmp');
      for (final line in [
        {
          'type': 'rate_limit_event',
          'rate_limit_info': {
            'status': 'rejected',
            'resetsAt': 1795380000,
            'rateLimitType': 'five_hour',
            'unifiedWindows': {
              'five_hour': {'utilization': 1.0, 'resetsAt': 1795380000},
              'seven_day': {'utilization': 0.4, 'resetsAt': 1795374000},
            },
          },
        },
        {
          'type': 'assistant',
          'parent_tool_use_id': null,
          'error': 'rate_limit',
          'message': {
            'id': 'm1',
            'content': [
              {'type': 'text', 'text': "You've hit your limit · resets 11pm"},
            ],
          },
        },
        {
          'type': 'result',
          'subtype': 'success',
          'is_error': true,
          'result': "You've hit your limit · resets 11pm",
        },
      ]) {
        talk.take(line);
      }
      expect(heard.limited, isTrue);
      expect(heard.resets, DateTime.fromMillisecondsSinceEpoch(1795380000000));

      // The next turn, gone through, is not.
      talk.take({'type': 'result', 'subtype': 'success', 'result': 'Done.'});
      expect(heard.limited, isFalse);
      expect(heard.resets, isNull);
    });

    test("tells a turn Codex's limit refused, and when it is lifted", () {
      final heard = _Heard();
      final talk = CodexTalk(
        const ChatAsk(id: 'c', agent: 'codex'),
        heard,
        dir: '/tmp',
      );
      for (final line in [
        {
          'method': 'account/rateLimits/updated',
          'params': {
            'rateLimits': {
              'primary': {'usedPercent': 100, 'resetsAt': 1795341600},
              'secondary': {'usedPercent': 30, 'resetsAt': 1795374000},
            },
          },
        },
        {
          'method': 'turn/completed',
          'params': {
            'turn': {
              'id': 't1',
              'status': 'failed',
              'error': {
                'message': "You've hit your usage limit.",
                'codexErrorInfo': 'usageLimitExceeded',
              },
            },
          },
        },
      ]) {
        talk.take(line);
      }
      expect(heard.limited, isTrue);
      expect(heard.resets, DateTime.fromMillisecondsSinceEpoch(1795341600000));
    });

    test("finds Claude's transcript of a session", () {
      expect(
        claudeTranscript('/home/a', '/home/a/dev/src/Caldo', 's'),
        '/home/a/.claude/projects/-home-a-dev-src-Caldo/s.jsonl',
      );
    });

    test('resumes only a session Claude has written down', () {
      // Named by its first hook but never spoken in, a session has no
      // transcript, and `--resume` on it ends Claude at once.
      final home = Directory.systemTemp.createTempSync('caldo_resume').path;
      addTearDown(() => Directory(home).deleteSync(recursive: true));
      const dir = '/work';
      expect(resumable(claude, home, dir, 's'), isNull);
      File(claudeTranscript(home, dir, 's')).createSync(recursive: true);
      expect(resumable(claude, home, dir, 's'), 's');
      expect(resumable(claude, home, dir, null), isNull);
      const codex = AgentSpec(id: 'codex', label: 'Codex', command: ['codex']);
      expect(resumable(codex, home, dir, 't'), 't');
    });
  });

  test("a snapshot puts back the modes its program turned on", () {
    // Claude's: the mouse's every move in SGR, bracketed paste, the
    // cursor's keys, its cursor hidden.
    expect(
      Tmux.modesOf(['0', '0', '1', '0', '1', '1', '1', '0']),
      '\x1b[?1000l\x1b[?1002l\x1b[?1003h\x1b[?1005l\x1b[?1006h'
      '\x1b[?2004h\x1b[?1h\x1b[?25l',
    );
  });

  test("an answer's words are joined as they come, once each", () {
    final feed = TalkFeed.held('c', const []);
    addTearDown(feed.dispose);
    feed.hear({
      'payload': {'id': 'm:0', 'at': 0, 'text': 'Hel'},
    });
    feed.hear({
      'payload': {'id': 'm:0', 'at': 0, 'text': 'Hel'},
    });
    feed.hear({
      'payload': {'id': 'm:0', 'at': 3, 'text': 'lo'},
    });
    // After a gap: left for the whole answer.
    feed.hear({
      'payload': {'id': 'm:0', 'at': 9, 'text': '!'},
    });
    expect(feed.pieces.value, {'m:0': 'Hello'});
  });

  test('an item keeps the time it was first heard', () {
    final feed = TalkFeed.held('c', [
      const ChatItem(id: 'old', seq: 0, kind: 'text', body: {'text': 'Hi'}),
    ]);
    addTearDown(feed.dispose);
    // From before chats kept times: none, even read again.
    expect(feed.items.single.at, isNull);
    feed.said('Go on', 'k');
    final heard = feed.items.last.at;
    expect(heard, isNotNull);
    // Its echo, without the server's stamp.
    feed.said('Go on', 'k');
    expect(feed.items.last.at, heard);
  });

  testWidgets('opens at the latest page and holds it steady as history loads', (
    tester,
  ) async {
    final agents = Agents.instance;
    final recent = Completer<void>.sync();
    final older = Completer<void>.sync();
    final reopen = Completer<void>.sync();
    final requested = <Map<String, String>>[];
    final client = (await tester.runAsync(() async {
      final client = SupabaseClient(
        'https://example.invalid',
        'anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        realtimeClientOptions: RealtimeClientOptions(
          transport: (_, _) => throw StateError('Realtime unavailable'),
        ),
        httpClient: MockClient((request) async {
          final query = request.url.queryParameters;
          requested.add(query);
          final backfill = query.containsKey('seq');
          await (backfill
              ? older.future
              : requested.length == 1
              ? recent.future
              : reopen.future);
          return http.Response(
            jsonEncode([
              for (
                var seq = backfill ? 49 : 99;
                seq >= (backfill ? 0 : 50);
                seq--
              )
                {
                  'id': 'item-$seq',
                  'seq': seq,
                  'kind': 'user',
                  'body': {'text': 'Message $seq'},
                },
            ]),
            200,
            request: request,
          );
        }),
      );
      await client.auth.recoverSession(
        jsonEncode({
          'access_token': 'token',
          'token_type': 'bearer',
          'user': {'id': 'me'},
        }),
      );
      agents.clientForTest = client;
      return client;
    }))!;
    addTearDown(() async {
      agents.clientForTest = null;
      await client.dispose();
    });

    Future<TalkFeed> open() async =>
        (await tester.runAsync(() async => agents.talk('history')))!;
    Future<void> show(TalkFeed feed) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TalkView(
            key: ObjectKey(feed),
            feed: feed,
            working: false,
            onAnswer: (_, _, _) {},
          ),
        ),
      ),
    );
    Future<void> deliver(TalkFeed feed, Completer<void> page, int count) async {
      page.complete();
      for (var i = 0; i < 100 && feed.items.length < count; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      expect(feed.items.length, count);
    }

    final feed = await open();
    var firstClosed = false;
    addTearDown(() {
      if (!firstClosed) feed.dispose();
    });
    await show(feed);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await deliver(feed, recent, 50);
    await tester.pump();
    expect(requested.first['order'], startsWith('seq.desc'));
    expect(requested.first['limit'], '50');
    expect(feed.items.first.seq, 50);
    final latest = find.text('Message 99').hitTestable();
    expect(latest, findsOneWidget);
    final openingPosition = tester.getTopLeft(latest);
    expect(find.text('Message 0'), findsNothing);

    // Older pages wait for the reader to scroll up towards them.
    expect(requested, hasLength(1));
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(scroll.position.minScrollExtent);
    await tester.pump();
    expect(requested, hasLength(2));
    final earliest = find.text('Message 50').hitTestable();
    expect(earliest, findsOneWidget);
    final earliestPosition = tester.getTopLeft(earliest);
    await deliver(feed, older, 100);
    await tester.pump();
    expect(requested[1]['seq'], 'lt.50');
    expect(feed.items.first.seq, 0);
    // What was read grows above what the reader is looking at.
    expect(tester.getTopLeft(earliest), earliestPosition);
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    expect(tester.getTopLeft(latest), openingPosition);

    scroll.position.jumpTo(-300);
    await tester.pump();
    feed.said('A new message', 'new');
    await tester.pump();
    expect(scroll.position.pixels, -300);
    expect(find.text('A new message').hitTestable(), findsNothing);
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    feed.said('Another message', 'another');
    await tester.pump();
    expect(find.text('Another message').hitTestable(), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    feed.dispose();
    firstClosed = true;
    final cached = await open();
    addTearDown(cached.dispose);
    await show(cached);
    expect(latest, findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(cached.items.length, 50);
    expect(find.text('Another message'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    reopen.complete();
  });

  testWidgets('shows pictures sent and received using private chat storage', (
    tester,
  ) async {
    final portrait = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAABQAAAAoCAIAAABxU02MAAAAJElEQVR4nGMICW8gGzGMah7V'
      'PKp5VPOo5lHNo5pHNY9qJhcBAGZzpo4L92TVAAAAAElFTkSuQmCC',
    );
    final landscape = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAACgAAAAUCAIAAABwJOjsAAAAJElEQVR4nGMICW8YEMQwavGo'
      'xaMWj1o8avGoxaMWj1o8ciwGAOR0po4n7NN/AAAAAElFTkSuQmCC',
    );
    final requested = <String>[];
    final client = (await tester.runAsync(() async {
      final client = SupabaseClient(
        'https://example.invalid',
        'anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requested.add(request.url.path);
          expect(request.headers['authorization'], 'Bearer token');
          return http.Response.bytes(
            request.url.path.endsWith('/reply') ? landscape : portrait,
            200,
          );
        }),
      );
      addTearDown(client.dispose);
      await client.auth.recoverSession(
        jsonEncode({
          'access_token': 'token',
          'token_type': 'bearer',
          'user': {'id': 'me'},
        }),
      );
      return client;
    }))!;
    final now = DateTime.now();
    final at = DateTime(now.year, now.month, now.day, 11, 7);
    final feed = TalkFeed.held('chat', [
      ChatItem(
        id: 'reply',
        seq: 2,
        kind: 'text',
        at: at,
        body: const {
          'text': 'Here it is',
          'files': [
            {'name': 'reply.png', 'mime': 'image/png', 'key': 'chat/reply'},
          ],
        },
      ),
      const ChatItem(
        id: 'legacy',
        seq: 1,
        kind: 'user',
        body: {
          'files': [
            {'name': 'old.png', 'mime': 'image/png'},
          ],
        },
      ),
    ], client: client);
    addTearDown(feed.dispose);
    feed.said(
      '',
      'upload',
      files: const [
        {'name': 'upload.png', 'mime': 'image/png', 'key': 'chat/upload'},
      ],
    );
    tester.view.physicalSize = const Size(411, 731);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TalkView(feed: feed, working: false, onAnswer: (_, _, _) {}),
        ),
      ),
    );
    await tester.runAsync(() async {
      for (
        var i = 0;
        i < 100 && find.byType(Image).evaluate().length < 2;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(
      requested,
      unorderedEquals([
        '/storage/v1/object/chat-files/me/chat/reply',
        '/storage/v1/object/chat-files/me/chat/upload',
      ]),
    );
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.text('old.png'), findsOneWidget);
    Finder photo(String name) => find.byWidgetPredicate(
      (widget) => widget is Image && widget.semanticLabel == name,
    );
    final incoming = tester.getRect(photo('reply.png'));
    final outgoing = tester.getRect(photo('upload.png'));
    expect(incoming.width / incoming.height, closeTo(2, 0.01));
    expect(outgoing.width / outgoing.height, closeTo(0.5, 0.01));
    expect(incoming.left, lessThan(outgoing.left));
    final caption = find.text('Here it is', findRichText: true);
    expect(tester.getTopLeft(caption).dy, closeTo(incoming.bottom + 7, 0.1));
    final sentAt = feed.items.last.at!;
    final time = find.text(Dates.time(sentAt, h24: false));
    expect(
      time.evaluate().any(
        (element) => outgoing.contains(
          tester.getCenter(
            find.byElementPredicate((candidate) => candidate == element),
          ),
        ),
      ),
      isTrue,
    );
    await tester.tap(photo('reply.png'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('reply.png'), findsOneWidget);
    final viewerCaption = find.descendant(
      of: find.byType(Dialog),
      matching: find.text('Here it is'),
    );
    expect(viewerCaption, findsOneWidget);
    await tester.tap(find.byType(InteractiveViewer));
    await tester.pumpAndSettle();
    expect(find.text('reply.png'), findsNothing);
    expect(viewerCaption, findsNothing);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byType(InteractiveViewer));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('chat history can scroll behind the composer and clear it', (
    tester,
  ) async {
    const overlap = 56.0;
    const composerKey = ValueKey('composer');
    final feed = TalkFeed.held('c', [
      for (var i = 0; i < 30; i++)
        ChatItem(id: 'm$i', seq: i, kind: 'user', body: {'text': 'Message $i'}),
    ]);
    addTearDown(feed.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: TalkView(
                  feed: feed,
                  working: false,
                  onAnswer: (_, _, _) {},
                  bottomOverlap: overlap,
                ),
              ),
              const SizedBox(key: composerKey, height: overlap),
            ],
          ),
        ),
      ),
    );

    final latest = find.text('Message 29');
    final composer = tester.getRect(find.byKey(composerKey));
    expect(tester.getBottomLeft(latest).dy, lessThan(composer.top));

    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    final foot = scroll.position.maxScrollExtent;
    scroll.jumpTo(foot - 48);
    await tester.pump();
    expect(tester.getTopLeft(latest).dy, greaterThan(composer.top));
    expect(tester.getBottomLeft(latest).dy, lessThan(composer.bottom));

    scroll.jumpTo(foot);
    await tester.pump();
    expect(tester.getBottomLeft(latest).dy, lessThan(composer.top));
  });

  testWidgets('a chat says when its words were said', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 9, 5);
    final before = DateTime(now.year, now.month, now.day - 3, 14, 30);
    final feed = TalkFeed.held('c', [
      ChatItem(
        id: 'u1',
        seq: 0,
        kind: 'user',
        body: const {'text': 'Make it red'},
        at: before,
      ),
      ChatItem(
        id: 'm1',
        seq: 1,
        kind: 'text',
        body: const {'text': 'Looking.'},
        at: before,
      ),
      ChatItem(
        id: 't1',
        seq: 2,
        kind: 'tool',
        body: const {'name': 'Read', 'line': 'a.dart'},
        at: before,
      ),
      ChatItem(
        id: 'm2',
        seq: 3,
        kind: 'text',
        body: const {'text': 'Made it red.'},
        at: before.add(const Duration(minutes: 1)),
      ),
      ChatItem(
        id: 'u2',
        seq: 4,
        kind: 'user',
        body: const {'text': 'Thanks'},
        at: today,
      ),
      ChatItem(
        id: 'm3',
        seq: 5,
        kind: 'text',
        body: const {'text': 'On it'},
        at: today,
      ),
    ]);
    addTearDown(feed.dispose);
    Future<void> show({required bool working}) => tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(alwaysUse24HourFormat: true),
          child: Scaffold(
            body: TalkView(
              feed: feed,
              working: working,
              onAnswer: (_, _, _) {},
            ),
          ),
        ),
      ),
    );
    await show(working: true);
    final day = Dates.shortDay(before);
    // The user's words, and the agent's last answer to them, not the
    // one between its tools; the turn still going has none yet.
    expect(find.text('$day 14:30'), findsOneWidget);
    expect(find.text('$day 14:31'), findsOneWidget);
    expect(find.text('09:05'), findsOneWidget);
    await show(working: false);
    expect(find.text('09:05'), findsNWidgets(2));
  });

  testWidgets('a chat distinguishes subscription and assistant messages', (
    tester,
  ) async {
    final now = DateTime.now();
    DateTime at(int minute) =>
        DateTime(now.year, now.month, now.day, 9, minute);
    final feed = TalkFeed.held('c', [
      ChatItem(
        id: 'user',
        seq: 0,
        kind: 'user',
        body: const {'text': 'Please review the change.'},
        at: at(1),
      ),
      ChatItem(
        id: 'agent',
        seq: 1,
        kind: 'user',
        body: const {
          'text': 'The checks passed.',
          'sender': {'chat': 'a', 'title': 'Reviewer'},
        },
        at: at(2),
      ),
      ChatItem(
        id: 'event',
        seq: 2,
        kind: 'user',
        body: const {
          'text': 'Pull request #42 opened.',
          'sender': {'event': 'github', 'title': 'egor/Caldo'},
        },
        at: at(3),
      ),
      const ChatItem(
        id: 'outside',
        seq: 3,
        kind: 'user',
        body: {
          'text': CarryOn.words,
          'sender': {'chat': null},
        },
      ),
      const ChatItem(
        id: 'answer',
        seq: 4,
        kind: 'text',
        body: {'text': 'I will take a look.'},
      ),
    ]);
    addTearDown(feed.dispose);
    final s = S.forCode('en');
    for (final theme in [
      AppTheme.light(AppAccent.presets.first),
      AppTheme.dark(AppAccent.presets.first),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: MediaQuery(
            data: const MediaQueryData(alwaysUse24HourFormat: true),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 340,
                  child: TalkView(
                    feed: feed,
                    working: false,
                    onAnswer: (_, _, _) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text(s.chatFrom('Reviewer')), findsOneWidget);
      expect(find.text(s.chatFromEvent('egor/Caldo')), findsOneWidget);
      expect(find.text(s.chatFromOutside), findsOneWidget);
      expect(find.text(CarryOn.words), findsOneWidget);
      expect(find.text('I will take a look.'), findsOneWidget);

      final user = tester.getRect(find.text('Please review the change.'));
      final agent = tester.getRect(find.text('The checks passed.'));
      final event = tester.getRect(find.text('Pull request #42 opened.'));
      expect(agent.left, lessThan(user.left));
      expect(event.width, greaterThan(user.width));
      final eventCard = tester.widget<Container>(
        find
            .ancestor(
              of: find.text(s.chatFromEvent('egor/Caldo')),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = eventCard.decoration! as BoxDecoration;
      expect(decoration.border, isNull);
      expect(decoration.borderRadius, BorderRadius.circular(16));

      final agentTime = tester.getRect(find.text('09:02'));
      final eventTime = tester.getRect(find.text('09:03'));
      final userTime = tester.getRect(find.text('09:01'));
      expect(agentTime.left, eventTime.left);
      expect(userTime.right, greaterThan(eventTime.right));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets("a swipe over Claude's own screen scrolls it", (tester) async {
    final out = <String>[];
    final t = Terminal(maxLines: 1000)
      ..onOutput = (data) => out.add(TermSwipe.wheelFixed(data));
    // Claude's: its own screen, every move of the mouse reported, in SGR.
    t.write('\x1b[?1049h\x1b[?1003h\x1b[?1006h');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TermSwipe(
            terminal: t,
            lineHeight: 12,
            cellWidth: 6,
            padding: Offset.zero,
            enabled: true,
            child: TerminalView(t, readOnly: true),
          ),
        ),
      ),
    );
    final finger = await tester.startGesture(const Offset(100, 100));
    for (var i = 0; i < 6; i++) {
      await finger.moveBy(const Offset(0, 10));
    }
    await finger.up();
    expect(out, isNotEmpty);
    expect(out.every((o) => o.startsWith('\x1b[<64;')), isTrue, reason: '$out');

    // A wheel on a desk: set right on its way out.
    out.clear();
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(100, 100),
        scrollDelta: Offset(0, 40),
      ),
    );
    await tester.pump();
    expect(out, isNotEmpty);
    expect(out.every((o) => o.startsWith('\x1b[<65;')), isTrue, reason: '$out');
  });

  group('a command line', () {
    const llama = AgentSpec(
      id: 'llama',
      label: 'Llama',
      command: [
        'llama-cli',
        ['-m', '{model}'],
        ['--reasoning', '{effort}'],
        '{prompt}',
      ],
    );

    test('leaves out each part naming an empty blank, with its words', () {
      expect(
        llama.argv({'model': '~/q.gguf', 'effort': null, 'prompt': 'hi'}),
        ['llama-cli', '-m', '~/q.gguf', 'hi'],
      );
      expect(llama.argv({}), ['llama-cli']);
    });

    test('is read from agents.json as written', () {
      final spec = AgentSpec.fromJson('llama', {
        'label': 'Local',
        'command': [
          'llama-cli',
          ['-m', '{model}'],
        ],
        'models': ['a.gguf'],
        'prompt': 'type',
      });
      expect(spec.label, 'Local');
      expect(spec.models, ['a.gguf']);
      expect(spec.argv({'model': 'a.gguf'}), ['llama-cli', '-m', 'a.gguf']);
    });
  });

  group("Claude's", () {
    const claude = AgentSpec(
      id: 'claude',
      label: 'Claude',
      command: ['claude'],
      plugins: ['a@market', 'b@market'],
      pluginsOn: ['a@market'],
    );

    test('carries the choices, its hooks, and the first message last', () {
      final argv = launchOf(
        claude,
        const ChatAsk(
          id: 'x',
          agent: 'claude',
          model: 'opus',
          effort: 'high',
          permission: 'auto',
          title: 'Fix it',
          plugins: ['b@market'],
          skills: ['clean-code'],
          prompt: 'Look at the tests',
        ),
        events: "/tmp/it's.events",
      );
      String after(String flag) => argv[argv.indexOf(flag) + 1];
      expect(argv.first, 'claude');
      expect(after('--model'), 'opus');
      expect(after('--effort'), 'high');
      expect(after('--permission-mode'), 'auto');
      expect(after('-n'), 'Fix it');
      expect(after('--append-system-prompt'), contains('clean-code'));
      expect(argv.last, 'Look at the tests');
      expect(argv, isNot(contains('--resume')));

      final settings = jsonDecode(after('--settings')) as Map;
      expect(settings['enabledPlugins'], {'a@market': false, 'b@market': true});
      final stop = settings['hooks']['Stop'][0]['hooks'][0]['command'];
      // Quoted for the shell, an apostrophe and all.
      expect(stop, r"{ cat; echo; } >> '/tmp/it'\''s.events'");
    });

    test("leaves the plugins be when the chat doesn't choose", () {
      final argv = launchOf(
        claude,
        const ChatAsk(id: 'x', agent: 'claude'),
        resume: 'session-1',
      );
      expect(argv, ['claude', '--resume', 'session-1']);
    });

    test('reads the files sent to it without asking, the message kept', () {
      final argv = launchOf(
        claude,
        const ChatAsk(id: 'x', agent: 'claude', prompt: 'Look at this'),
        given: '/tmp/x.files',
      );
      // Joined: the flag takes every word after it up to the next flag.
      expect(argv, contains('--add-dir=/tmp/x.files'));
      expect(argv.last, 'Look at this');
      expect(
        ClaudeTalk.argv(
          claude,
          const ChatAsk(id: 'x', agent: 'claude'),
          given: '/tmp/x.files',
        ),
        contains('--add-dir=/tmp/x.files'),
      );
    });

    test('is told where the files sent with a message are', () {
      const files = [
        Given(
          path: '/tmp/x.files/1/photo.jpg',
          name: 'photo.jpg',
          mime: 'image/jpeg',
          size: 2202010,
          key: 'x/1',
        ),
        Given(path: null, name: 'notes.txt', mime: 'text/plain'),
      ];
      final told = withFiles('What is this?', files);
      expect(told, startsWith('What is this?\n\n'));
      expect(told, contains('- /tmp/x.files/1/photo.jpg (image/jpeg, 2.1 MB)'));
      expect(told, contains('- notes.txt: could not be fetched'));
      expect(withFiles('Just words', const []), 'Just words');
      expect(withFiles('  ', files), startsWith('[The user attached files'));

      final heard = _Heard();
      ClaudeTalk(
        claude,
        const ChatAsk(id: 'x', agent: 'claude'),
        heard,
        dir: '/tmp',
      ).say('What is this?', id: 'u1', files: files);
      // The chat shows the user's words and the files by their own names,
      // not this computer's paths.
      final (kind, body) = heard.items['u1']!;
      expect(kind, 'user');
      expect(body['text'], 'What is this?');
      expect(body['files'], [
        {
          'name': 'photo.jpg',
          'mime': 'image/jpeg',
          'size': 2202010,
          'key': 'x/1',
        },
        {'name': 'notes.txt', 'mime': 'text/plain', 'size': 0},
      ]);
    });

    test("is told another chat's message is not the user's", () {
      const sender = {'chat': 'abcd1234-ffff', 'title': 'Tests', 'waits': true};
      final told = withSender('Do the tests pass?', sender);
      expect(told, endsWith('\n\nDo the tests pass?'));
      expect(told, contains('"Tests" (chat abcd1234)'));
      expect(told, contains('not from the user'));
      expect(told, contains('handed back to it'));
      final later = withSender('FYI', {...sender, 'waits': false});
      expect(later, contains('message_chat tool to chat abcd1234'));
      expect(
        withSender('Hi', const {'chat': null, 'title': null, 'waits': false}),
        contains('outside Caldo'),
      );
      expect(withSender('Hi', null), 'Hi');

      final heard = _Heard();
      ClaudeTalk(
        claude,
        const ChatAsk(id: 'x', agent: 'claude'),
        heard,
        dir: '/tmp',
      ).say('Do the tests pass?', id: 'u1', sender: sender);
      // The app shows the words as sent, and whose they are.
      final (kind, body) = heard.items['u1']!;
      expect(kind, 'user');
      expect(body['text'], 'Do the tests pass?');
      expect(body['sender'], sender);
    });

    test('is told the skills and the rules in one appended prompt', () {
      final ask = ChatAsk.fromJson({
        'id': 'x',
        'agent': 'claude',
        'skills': ['clean-code'],
        'rules': [
          {'name': 'Tests', 'body': 'Run them first.'},
          {'name': 'Empty', 'body': '  '},
        ],
      });
      final argv = launchOf(claude, ask);
      expect(argv.where((w) => w == '--append-system-prompt'), hasLength(1));
      final text = argv[argv.indexOf('--append-system-prompt') + 1];
      expect(text, contains('clean-code'));
      expect(text, contains('## Tests\n\nRun them first.'));
      expect(text, isNot(contains('Empty')));
    });
  });

  group("a chat's program", () {
    const claude = AgentSpec(
      id: 'claude',
      label: 'Claude',
      command: ['claude'],
    );
    late Directory dir;
    late String base;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('kept');
      base = '${dir.path}/c.talk';
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('lives on without its writer, and is read on by another', () async {
      final kept = await Kept.start(base, [
        'sh',
        '-c',
        r'while read l; do echo "$l"; done',
      ], cwd: dir.path);
      // A worker that wrote and went: its end of the pipe closed.
      File('$base.in').openSync(mode: FileMode.write)
        ..writeStringSync('one\n')
        ..closeSync();
      final out = File('$base.out');
      await _until(() => out.readAsStringSync() == 'one\n');

      final again = Kept.find(base, out.lengthSync())!;
      final heard = <String>[];
      again.listen(heard.add, (_, _) {});
      again.write('two');
      await _until(() => heard.isNotEmpty);
      expect(heard, ['two']);
      expect(again.written(), ['two']);

      await kept.stop();
      expect(File('$base.pid').existsSync(), isFalse);
    });

    test('quiet a while, is still heard when written to', () async {
      final kept = await Kept.start(base, [
        'sh',
        '-c',
        r'while read l; do echo "$l"; done',
      ], cwd: dir.path);
      final heard = <String>[];
      kept.listen(heard.add, (_, _) {});
      // Long enough to have slowed to its quietest.
      await Future<void>.delayed(const Duration(seconds: 4));
      kept.write('ping');
      await _until(() => heard.isNotEmpty);
      expect(heard, ['ping']);
      await kept.stop();
    });

    test('given up on, leaves nothing running behind it', () async {
      // A start called failed used to leave its program running, and the
      // next message started a second on the same session.
      final mark = 'kept-abandoned-${DateTime.now().microsecondsSinceEpoch}';
      Kept.startWithin = Duration.zero;
      addTearDown(() => Kept.startWithin = const Duration(seconds: 30));
      await expectLater(
        Kept.start(base, ['sh', '-c', 'sleep 30 # $mark'], cwd: dir.path),
        throwsStateError,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final left = Process.runSync('pgrep', ['-f', mark]);
      expect('${left.stdout}'.trim(), isEmpty);
      expect(File('$base.pid').existsSync(), isFalse);
    });

    test('is taken up where the last worker left it', () async {
      String line(Map json) => '${jsonEncode(json)}\n';
      Map ask(String id) => {
        'type': 'control_request',
        'request_id': id,
        'request': {
          'subtype': 'can_use_tool',
          'tool_name': 'Bash',
          'input': {'command': 'ls'},
        },
      };
      final before = [
        line({'type': 'system', 'subtype': 'init', 'session_id': 's1'}),
        line(ask('r1')),
        line(ask('r2')),
      ].join();
      File('$base.out').writeAsStringSync(
        before +
            line({
              'type': 'result',
              'subtype': 'success',
              'result': 'Done.',
              'is_error': false,
            }),
      );
      // r1 was answered by the last worker; r2 still waits.
      File('$base.written').writeAsStringSync(
        line({
          'type': 'control_response',
          'response': {'subtype': 'success', 'request_id': 'r1'},
        }),
      );
      // Ended while no worker was there.
      File('$base.pid').writeAsStringSync('999999999 999999999');
      File('$base.code').writeAsStringSync('0');

      final heard = _Heard();
      final talk = ClaudeTalk(
        claude,
        const ChatAsk(id: 'c', agent: 'claude'),
        heard,
        dir: dir.path,
      )..takeUp(Kept.find(base, utf8.encode(before).length)!);
      // What was handed on before is not said again.
      expect(heard.items, isEmpty);
      expect(heard.states, isEmpty);
      // The question answered then is not open; the one waiting is.
      talk
        ..answer('ask:r1', 'allow')
        ..answer('ask:r2', 'allow');
      expect(heard.items.keys, ['ask:r2']);

      await _until(() => heard.code != null);
      expect(heard.code, 0);
      expect(heard.answer, 'Done.');
      expect(heard.states.last, 'finished');
      expect(File('$base.out').existsSync(), isFalse);
    });
  });

  group('rules', () {
    test('start a chat left without a message with their openings', () {
      const review = AgentRule(
        id: 'r',
        name: 'Reviewer',
        body: 'Review the open PRs.',
        opening: ' Begin the first round. ',
      );
      const brief = AgentRule(id: 'b', name: 'Brief', body: 'Be brief.');
      const ship = AgentRule(id: 's', name: 'Ship', body: '', opening: 'Go');
      expect(firstMessage('', [review]), 'Begin the first round.');
      expect(firstMessage('  ', [brief]), '');
      expect(
        firstMessage('', [review, brief, ship]),
        'Begin the first round.\n\nGo',
      );
      // What is written wins.
      expect(firstMessage(' Look at #12 ', [review]), 'Look at #12');
      expect(
        AgentRule.fromJson({'id': 'x', 'name': 'n', 'body': 'b'}).opening,
        '',
      );
    });

    test('none, or only empty ones, are no rules', () {
      expect(rulesText(null), isNull);
      expect(rulesText([]), isNull);
      expect(
        rulesText([
          {'name': 'x', 'body': ''},
        ]),
        isNull,
      );
    });

    test("reach Codex as its developer instructions, a shell's not at all", () {
      const codex = AgentSpec(
        id: 'codex',
        label: 'Codex',
        command: [
          'codex',
          ['-c', 'developer_instructions={rules}'],
          '{prompt}',
        ],
      );
      final ask = ChatAsk.fromJson({
        'id': 'x',
        'agent': 'codex',
        'prompt': 'Go',
        'rules': [
          {'name': '', 'body': 'Be brief.'},
        ],
      });
      expect(codex.takesRules, isTrue);
      final argv = launchOf(codex, ask);
      final rules =
          argv[argv.indexWhere(
            (arg) => arg.startsWith('developer_instructions='),
          )];
      expect(rules, endsWith('Be brief."'));
      expect(argv.last, 'Go');
      expect(
        launchOf(codex, ask, resume: 'th1'),
        containsAllInOrder(['resume', '-c', rules, 'th1']),
      );
      expect(
        launchOf(codex, const ChatAsk(id: 'x', agent: 'codex', prompt: 'Go')),
        [
          'codex',
          ...codexInCaldo(null),
          '-c',
          'approval_policy="on-request"',
          '--sandbox',
          'workspace-write',
          'Go',
        ],
      );

      const shell = AgentSpec(id: 'shell', label: 'Shell', command: ['bash']);
      expect(shell.takesRules, isFalse);
      expect(launchOf(shell, ask), ['bash']);
    });

    test('keeps Codex read-only in a fresh and a resumed terminal', () {
      const codex = AgentSpec(id: 'codex', label: 'Codex', command: ['codex']);
      const ask = ChatAsk(id: 'x', agent: 'codex', permission: 'read-only');
      for (final resume in [null, 'thread-id']) {
        expect(
          launchOf(codex, ask, resume: resume),
          containsAllInOrder([
            '-c',
            'approval_policy="on-request"',
            '--sandbox',
            'read-only',
          ]),
        );
      }
    });
  });

  group('projects', () {
    tearDown(() => Agents.instance.projects = const []);

    test('a chat keeps its project\'s name, colour, words and folders', () {
      const caldo = AgentProject(
        id: 'p',
        name: 'Caldo',
        colour: 'teal',
        context: 'A calendar app.',
        sources: ['~/dev/src/Caldo', ' ', '~/dev/src/Caldo'],
      );
      Agents.instance.projects = const [caldo];
      expect(Agents.instance.snapshotOf(caldo), {
        'name': 'Caldo',
        'colour': 'teal',
        'context': [
          {'name': 'Caldo', 'body': 'A calendar app.'},
        ],
        'sources': ['~/dev/src/Caldo'],
      });
      const bare = AgentProject(id: 'q', name: 'Notes');
      expect(Agents.instance.snapshotOf(bare), {
        'name': 'Notes',
        'colour': null,
        'context': <Object>[],
        'sources': <Object>[],
      });
    });

    test('reach the agent after its rules, with its own folder', () {
      final ask = ChatAsk.fromJson({
        'id': 'x',
        'agent': 'claude',
        'rules': [
          {'name': 'Brief', 'body': 'Be brief.'},
        ],
        'project': {
          'name': 'Caldo › Sync',
          'context': [
            {'name': 'Caldo', 'body': 'A calendar app.'},
            {'name': 'Sync', 'body': 'Supabase.'},
          ],
          'sources': ['~/dev/src/Caldo', '~/notes'],
        },
        'workspace': {
          'root': '/w/x',
          'places': [
            {
              'source': '/h/dev/src/Caldo',
              'path': '/w/x/Caldo',
              'branch': 'caldo/x',
            },
            {'source': '/h/notes', 'path': '/h/notes'},
          ],
        },
      });
      expect(ask.ownFolder, isTrue);
      expect(ask.sources, ['~/dev/src/Caldo', '~/notes']);
      // The one worktree is where it starts, so its CLAUDE.md is read.
      expect(ask.dir, '/w/x/Caldo');
      expect(ask.added, ['/h/notes']);
      final rules = ask.rules!;
      expect(
        rules.indexOf('Be brief.'),
        lessThan(rules.indexOf('project="Caldo › Sync"')),
      );
      expect(
        rules.indexOf('A calendar app.'),
        lessThan(rules.indexOf('Supabase.')),
      );
      expect(rules, contains('caldo/x'));
      expect(rules, contains("/h/notes is the user's own folder"));
      const claude = AgentSpec(id: 'claude', label: 'Claude', command: []);
      expect(claudeChoices(claude, ask), contains('--add-dir=/h/notes'));

      // Asked for, not yet made: no folder to start in yet.
      final asked = ChatAsk.fromJson({
        'id': 'x',
        'agent': 'claude',
        'workspace': <String, Object?>{},
      });
      expect(asked.ownFolder, isTrue);
      expect(asked.dir, isNull);
      expect(asked.rules, isNull);
      // A chat from before has none.
      expect(
        ChatAsk.fromJson({
          'id': 'x',
          'agent': 'claude',
          'dir': '~/a',
        }).ownFolder,
        isFalse,
      );
    });

    test('a chat is told its project, its parents and its own context', () {
      final told = contextText(
        {
          'name': 'Caldo',
          'context': [
            {'name': 'Caldo', 'body': 'A calendar app.'},
          ],
        },
        [
          {'id': '11111111-aaaa', 'title': 'Release', 'context': 'Ship it.'},
          {'id': '22222222-bbbb', 'title': '', 'context': '  '},
          {'id': '33333333-cccc', 'title': 'Notes "fix"', 'context': 'Fix.'},
        ],
        'Only the sync.',
      )!;
      expect(told, contains('stands in for CLAUDE.md'));
      expect(told, contains('update_project_info'));
      expect(
        told,
        contains('<project-info project="Caldo">\nA calendar app.\n'),
      );
      expect(
        told,
        contains('<parent-context chat="11111111" title="Release">'),
      );
      // One with nothing written is left out; quotes can't end the title.
      expect(told, isNot(contains('22222222')));
      expect(told, contains('title="Notes \'fix\'"'));
      expect(told, contains('<own-context>\nOnly the sync.\n</own-context>'));
      final order = [
        'A calendar app.',
        'Ship it.',
        'Fix.',
        'Only the sync.',
      ].map(told.indexOf).toList();
      expect(order, orderedEquals([...order]..sort()));
      expect(order.first, greaterThan(0));
      expect(contextText(null, null, ''), isNull);
      expect(contextText({'name': ''}, const [], null), isNull);
      // A project with nothing written is still named.
      expect(contextText({'name': 'Notes'}, null, null), contains('Notes'));

      final ask = ChatAsk.fromJson({
        'id': 'c',
        'agent': 'claude',
        'rules': [
          {'name': 'Brief', 'body': 'Be brief.'},
        ],
        'project': {'name': 'Caldo', 'context': <Object>[]},
        'context': 'Only the sync.',
        'parents': [
          {'id': '11111111', 'title': 'Release', 'context': 'Ship it.'},
        ],
      });
      expect(ask.context, contains('Ship it.'));
      expect(
        ask.rules!.indexOf('Be brief.'),
        lessThan(ask.rules!.indexOf('Only the sync.')),
      );
      final changed = ChatAsk.fromJson({...ask.row!, 'context': 'All of it.'});
      expect(settingsChanged(ask, changed), 'Settings changed: context.');
      final ruled = ChatAsk.fromJson({...ask.row!, 'rules': <Object>[]});
      expect(settingsChanged(ask, ruled), 'Settings changed: no rules.');
    });

    group("a project's file", () {
      late Directory home;
      late Directory repo;
      late _Projects store;
      late ProjectSync sync;
      late List<String> said;
      const id = '3a9fb51c-0000-4000-8000-000000000001';

      String fileText() => File(sync.fileOf(id)).readAsStringSync();
      String body(String file) =>
          file.substring(file.indexOf('-->') + 3).trim();
      Future<void> edit(String path, String text) async {
        // A second later, as an editor's write would be.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final f = File(path);
        final now = f.readAsStringSync();
        f.writeAsStringSync(now.replaceFirst(body(now), text));
      }

      setUp(() async {
        home = Directory.systemTemp.createTempSync('home');
        repo = Directory('${home.path}/dev/Caldo')..createSync(recursive: true);
        await Process.run('git', ['init', '-q'], workingDirectory: repo.path);
        store = _Projects()
          ..rows.add({
            'id': id,
            'name': 'Caldo',
            'context': 'Line one.\n\nLine two.\n\nLine three.',
            'version': 1,
            'sources': ['~/dev/Caldo'],
          });
        said = [];
        sync = ProjectSync(
          home: home.path,
          store: store,
          computer: 'desk',
          log: said.add,
        );
      });
      tearDown(() => home.deleteSync(recursive: true));

      test(
        'is written, linked where Claude and Codex read, out of git',
        () async {
          expect(await sync.run(), isEmpty);
          expect(
            sync.fileOf(id),
            '${home.path}/.local/share/caldo/projects/3a9fb51c.md',
          );
          expect(fileText(), startsWith(ProjectSync.mark));
          expect(body(fileText()), 'Line one.\n\nLine two.\n\nLine three.');
          for (final name in ProjectSync.names) {
            expect(Link('${repo.path}/$name').targetSync(), sync.fileOf(id));
          }
          final status = await Process.run('git', [
            'status',
            '--porcelain',
          ], workingDirectory: repo.path);
          expect('${status.stdout}', isEmpty);
          expect(sync.folders, {
            id: [repo.path],
          });
          // Nothing changed: nothing saved, nothing told.
          expect(await sync.run(), isEmpty);
          expect(store.saved, isEmpty);
        },
      );

      test('an edit of it is saved to Caldo, through a link too', () async {
        await sync.run();
        await edit('${repo.path}/CLAUDE.local.md', 'Line one.\n\nNew two.');
        expect(await sync.run(), {id});
        expect(store.saved, [('Line one.\n\nNew two.', 1, 'computer:desk')]);
        expect(store.rows.single['version'], 2);
        expect(said.last, contains('saved from its file'));
        // Saved once: the next pass finds them agreeing.
        expect(await sync.run(), isEmpty);
        expect(store.saved, hasLength(1));
      });

      test("Caldo's change is written in, a deleted file put back", () async {
        await sync.run();
        store.rows.single
          ..['context'] = 'From the phone.'
          ..['version'] = 2;
        expect(await sync.run(), {id});
        expect(body(fileText()), 'From the phone.');
        File(sync.fileOf(id)).deleteSync();
        await sync.run();
        expect(body(fileText()), 'From the phone.');
        expect(store.saved, isEmpty);
      });

      test('changed in both, apart lines are merged', () async {
        await sync.run();
        await edit(sync.fileOf(id), 'Line one.\n\nLine two.\n\nFile three.');
        store.rows.single
          ..['context'] = 'Phone one.\n\nLine two.\n\nLine three.'
          ..['version'] = 2;
        await sync.run();
        const merged = 'Phone one.\n\nLine two.\n\nFile three.';
        expect(store.saved, [(merged, 2, 'computer:desk')]);
        expect(body(fileText()), merged);
      });

      test("changed in both on one line, Caldo's stands", () async {
        await sync.run();
        await edit(sync.fileOf(id), 'File one.\n\nLine two.\n\nLine three.');
        store.rows.single
          ..['context'] = 'Phone one.\n\nLine two.\n\nLine three.'
          ..['version'] = 2;
        await sync.run();
        expect(store.saved, isEmpty);
        expect(store.unmerged, [
          ('File one.\n\nLine two.\n\nLine three.', 2, 'computer:desk'),
        ]);
        expect(body(fileText()), startsWith('Phone one.'));
      });

      test('a save refused by a change just made waits for it', () async {
        await sync.run();
        await edit(sync.fileOf(id), 'Mine.');
        store.refuse = true;
        expect(await sync.run(), isEmpty);
        expect(body(fileText()), 'Mine.');
        store.refuse = false;
        await sync.run();
        expect(store.saved.single.$1, 'Mine.');
      });

      test(
        "a link written over by an editor is saved and linked again",
        () async {
          await sync.run();
          final place = '${repo.path}/AGENTS.override.md';
          final edited = fileText().replaceFirst('Line three.', 'Codex three.');
          await Future<void>.delayed(const Duration(milliseconds: 20));
          Link(place).deleteSync();
          File(place).writeAsStringSync(edited);
          await sync.run();
          expect(store.saved.single.$1, endsWith('Codex three.'));
          expect(Link(place).targetSync(), sync.fileOf(id));
          expect(body(fileText()), endsWith('Codex three.'));
        },
      );

      test("the user's own files stay; one-way copies become links", () async {
        File('${repo.path}/CLAUDE.local.md').writeAsStringSync('Mine.');
        File('${repo.path}/AGENTS.override.md').writeAsStringSync(
          '<!-- Written by Caldo from the project info of "Caldo". -->\n\n'
          'Line one.\n\nLine two.\n\nLine three.\n',
        );
        await sync.run();
        expect(
          File('${repo.path}/CLAUDE.local.md').readAsStringSync(),
          'Mine.',
        );
        expect(said.single, contains('not Caldo'));
        expect(
          Link('${repo.path}/AGENTS.override.md').targetSync(),
          sync.fileOf(id),
        );
        expect(store.saved, isEmpty);
      });

      test('a folder takes the first project; gone, its links go', () async {
        store.rows.add({
          'id': 'ffff0000-0000-4000-8000-000000000002',
          'name': 'Sync',
          'context': 'Other.',
          'version': 1,
          'sources': ['~/dev/Caldo/'],
        });
        await sync.run();
        expect(
          body(File('${repo.path}/CLAUDE.local.md').readAsStringSync()),
          startsWith('Line one.'),
        );
        expect(said.single, contains('only the first'));
        expect(File(sync.fileOf('ffff0000')).existsSync(), isTrue);

        store.rows.removeAt(0);
        await sync.run();
        expect(File(sync.fileOf(id)).existsSync(), isFalse);
        expect(
          body(File('${repo.path}/CLAUDE.local.md').readAsStringSync()),
          'Other.',
        );
        store.rows.clear();
        await sync.run();
        for (final name in ProjectSync.names) {
          expect(
            FileSystemEntity.typeSync('${repo.path}/$name', followLinks: false),
            FileSystemEntityType.notFound,
          );
        }
      });

      test('a worker started again knows which side changed', () async {
        await sync.run();
        await edit(sync.fileOf(id), 'Edited while it was down.');
        final again = ProjectSync(
          home: home.path,
          store: store,
          computer: 'desk',
          log: said.add,
        );
        await again.run();
        expect(store.saved.single.$1, 'Edited while it was down.');
      });
    });

    test("Caldo's Codex has Caldo's tools, knowing its chat", () {
      final args = codexCaldo();
      if (caldoMcp == null) {
        expect(args, isEmpty);
        return;
      }
      expect(args, [
        '-c',
        'mcp_servers.caldo.command="$caldoMcp"',
        '-c',
        'mcp_servers.caldo.env_vars=["CALDO_CHAT"]',
        '-c',
        'mcp_servers.caldo.tool_timeout_sec=7260',
      ]);
      expect(codexInCaldo(null), containsAllInOrder([...codexQuiet, ...args]));
    });

    test("Caldo's Codex reads no project files", () {
      const codex = AgentSpec(
        id: 'codex',
        label: 'Codex',
        command: ['codex', '{prompt}'],
      );
      final ask = ChatAsk.fromJson({'id': 'c', 'agent': 'codex'});
      for (final argv in [
        launchOf(codex, ask, prompt: 'hi'),
        launchOf(codex, ask, resume: 't1'),
      ]) {
        final at = argv.indexOf('project_doc_max_bytes=0');
        expect(at, greaterThan(0));
        expect(argv[at - 1], '-c');
      }
      // In a project, it may write the project's file, outside its folder.
      final inProject = ChatAsk.fromJson({
        'id': 'c',
        'agent': 'codex',
        'project': {
          'name': 'Caldo',
          'file': '/h/.local/share/caldo/projects/a.md',
        },
      });
      expect(inProject.projectFile, '/h/.local/share/caldo/projects/a.md');
      expect(
        launchOf(codex, inProject, prompt: 'hi'),
        contains(
          'sandbox_workspace_write.writable_roots=["/h/.local/share/caldo/projects"]',
        ),
      );
      const claude = AgentSpec(id: 'claude', label: 'Claude', command: []);
      expect(
        claudeChoices(claude, inProject),
        contains('--add-dir=/h/.local/share/caldo/projects'),
      );
      expect(inProject.rules, contains('edit its file, /h/.local/share'));
      expect(ask.rules, isNull);
    });

    test("Claude is told it from a file, rendered afresh when resumed", () {
      final dir = Directory.systemTemp.createTempSync('prompt');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = '${dir.path}/c.prompt';
      final ask = ChatAsk.fromJson({
        'id': 'c',
        'agent': 'claude',
        'context': 'x' * 200000,
      });
      const old = AgentSpec(id: 'claude', label: 'Claude', command: []);
      const now = AgentSpec(
        id: 'claude',
        label: 'Claude',
        command: [],
        promptFile: true,
        freshPrompt: true,
      );
      // A Claude that knows neither flag is given the words as before.
      final before = claudeChoices(old, ask, promptFile: file);
      expect(before, contains('--append-system-prompt'));
      expect(before, isNot(contains('--system-prompt-snapshot')));
      expect(File(file).existsSync(), isFalse);
      final args = claudeChoices(now, ask, promptFile: file, resume: 's1');
      final at = args.indexOf('--append-system-prompt-file');
      expect(args[at + 1], file);
      expect(args, isNot(contains('--append-system-prompt')));
      expect(File(file).readAsStringSync(), contains('x' * 200000));
      final snapshot = args.indexOf('--system-prompt-snapshot');
      expect(args[snapshot + 1], 'off');
      // Nothing to tell: no file.
      final bare = ChatAsk.fromJson({'id': 'd', 'agent': 'claude'});
      expect(
        claudeChoices(now, bare, promptFile: '${dir.path}/d.prompt'),
        isNot(contains('--append-system-prompt-file')),
      );
      expect(quietEnv['CLAUDE_CODE_DISABLE_CLAUDE_MDS'], '1');
      expect(quietEnv['CLAUDE_CODE_DISABLE_AUTO_MEMORY'], '1');
    });

    group('a workspace', () {
      late String home;
      const chat = '0f1e2d3c-4b5a-4968-8776-655443322110';

      Future<String> git(String dir, List<String> args) async {
        final r = await Process.run('git', [
          '-c',
          'user.name=t',
          '-c',
          'user.email=t@t',
          ...args,
        ], workingDirectory: dir);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        return '${r.stdout}';
      }

      setUp(() async {
        home = Directory.systemTemp.createTempSync('caldo_work').path;
        final repo = Directory('$home/src/app/lib')
          ..createSync(recursive: true);
        File('${repo.path}/a.txt').writeAsStringSync('a');
        await git('$home/src/app', ['init', '-q', '-b', 'main']);
        await git('$home/src/app', ['add', '.']);
        await git('$home/src/app', ['commit', '-qm', 'first']);
        Directory('$home/notes').createSync();
      });
      tearDown(() => Directory(home).deleteSync(recursive: true));

      test('is a worktree per repository, on a branch of its own', () async {
        final made = await Workspace.make(home, chat, [
          '$home/src/app',
          '$home/src/app/lib',
          '$home/notes',
        ]);
        final root = Workspace.rootOf(home, chat);
        expect(made.root, root);
        expect(made.places.map((p) => p.path), [
          '$root/app',
          '$root/app/lib',
          '$home/notes',
        ]);
        expect(made.cwd, '$root/app');
        expect(made.added, ['$home/notes']);
        expect(File('$root/app/lib/a.txt').readAsStringSync(), 'a');
        expect(
          (await git('$root/app', ['branch', '--show-current'])).trim(),
          'caldo/0f1e2d3c',
        );
        // The user's checkout stays where it was.
        expect(
          (await git('$home/src/app', ['branch', '--show-current'])).trim(),
          'main',
        );
        // Made again, it is found again; gone, made again on its branch.
        final again = await Workspace.make(home, chat, [
          '$home/src/app',
          '$home/src/app/lib',
          '$home/notes',
        ]);
        expect(again.toJson(), made.toJson());
        Directory('$root/app').deleteSync(recursive: true);
        await Workspace.make(home, chat, ['$home/src/app']);
        expect(File('$root/app/lib/a.txt').existsSync(), isTrue);

        expect(Workspace.of(made.toJson())!.toJson(), made.toJson());
        expect(Workspace.made(home), [chat]);
      });

      test('two repositories: it starts in its own folder', () async {
        Directory('$home/src/other').createSync(recursive: true);
        File('$home/src/other/b.txt').writeAsStringSync('b');
        await git('$home/src/other', ['init', '-q']);
        await git('$home/src/other', ['add', '.']);
        await git('$home/src/other', ['commit', '-qm', 'first']);
        final made = await Workspace.make(home, chat, [
          '$home/src/app',
          '$home/src/other',
        ]);
        expect(made.cwd, made.root);
        expect(made.added, isEmpty);
        // None at all: its own empty folder.
        final none = await Workspace.make(
          home,
          '${chat.substring(0, 35)}9',
          [],
        );
        expect(none.cwd, none.root);
        expect(Directory(none.root).existsSync(), isTrue);
      });

      test('a folder not there is said', () async {
        expect(
          () => Workspace.make(home, chat, ['$home/nowhere']),
          throwsA(isA<FileSystemException>()),
        );
      });

      test('goes with its chat, keeping a branch with work on it', () async {
        await Workspace.make(home, chat, ['$home/src/app']);
        final root = Workspace.rootOf(home, chat);
        await Workspace.remove(home, chat);
        expect(Directory(root).existsSync(), isFalse);
        expect(await git('$home/src/app', ['branch', '--list', 'caldo/*']), '');
        expect(
          (await git('$home/src/app', ['worktree', 'list'])).trim().split('\n'),
          hasLength(1),
        );

        await Workspace.make(home, chat, ['$home/src/app']);
        File('$root/app/c.txt').writeAsStringSync('c');
        await git('$root/app', ['add', '.']);
        await git('$root/app', ['commit', '-qm', 'work']);
        await Workspace.remove(home, chat);
        expect(Directory(root).existsSync(), isFalse);
        expect(
          (await git('$home/src/app', ['branch', '--list', 'caldo/*'])).trim(),
          'caldo/0f1e2d3c',
        );
      });
    });

    group("a project's files", () {
      late String home;
      late String memory;

      Future<void> git(String dir, List<String> args) async {
        final r = await Process.run('git', [
          '-c',
          'user.name=t',
          '-c',
          'user.email=t@t',
          ...args,
        ], workingDirectory: dir);
        expect(r.exitCode, 0, reason: '${r.stderr}');
      }

      setUp(() async {
        home = Directory.systemTemp.createTempSync('caldo_context').path;
        Directory('$home/src/app/lib').createSync(recursive: true);
        File('$home/src/app/CLAUDE.md').writeAsStringSync('An app.');
        await git('$home/src/app', ['init', '-q', '-b', 'main']);
        await git('$home/src/app', ['add', '.']);
        await git('$home/src/app', ['commit', '-qm', 'first']);
        Directory('$home/notes').createSync();
        File('$home/.claude/CLAUDE.md')
          ..createSync(recursive: true)
          ..writeAsStringSync('Mine.');
        memory = ContextFiles.memoryOf(home, '$home/src/app');
        Directory(memory).createSync(recursive: true);
        File('$memory/b.md').writeAsStringSync('B.');
        File('$memory/MEMORY.md').writeAsStringSync('- [B](b.md)');
      });
      tearDown(() => Directory(home).deleteSync(recursive: true));

      test("are what Claude reads, the user's own first", () async {
        // Claude names a folder's memory by its path.
        expect(
          ContextFiles.memoryOf('/home/a', '/home/a/dev/src/Caldo'),
          '/home/a/.claude/projects/-home-a-dev-src-Caldo/memory',
        );
        final mem = ContextFiles.shorten(home, memory);
        final files = await ContextFiles.read(home, [
          '~/src/app/lib',
          '~/notes',
          '~/nowhere',
        ]);
        expect(
          [for (final f in files) (f.kind, f.path, f.source, f.body)],
          [
            ('user', '~/.claude/CLAUDE.md', null, 'Mine.'),
            ('folder', '~/src/app/CLAUDE.md', '~/src/app/lib', 'An app.'),
            ('memory', '$mem/MEMORY.md', '~/src/app/lib', '- [B](b.md)'),
            ('memory', '$mem/b.md', '~/src/app/lib', 'B.'),
            // None yet: one to write is offered.
            ('folder', '~/notes/CLAUDE.md', '~/notes', null),
          ],
        );
        expect(files.any((f) => f.uncommitted), isFalse);

        // A chat's worktree reads its checkout's memory.
        await git('$home/src/app', ['worktree', 'add', '-q', '$home/tree']);
        final tree = await ContextFiles.read(home, ['~/tree']);
        expect(tree.map((f) => f.path), contains('$mem/b.md'));
      });

      test('are written only over what was read', () async {
        final read = await ContextFiles.read(home, ['~/src/app']);
        final claude = read.firstWhere((f) => f.kind == 'folder');
        final written = await ContextFiles.write(
          home,
          claude.path,
          body: 'An app in Dart.',
          was: claude.body,
        );
        expect(written.body, 'An app in Dart.');
        // Not committed: a chat's worktree doesn't see it yet.
        expect(written.uncommitted, isTrue);
        await expectLater(
          ContextFiles.write(home, claude.path, body: 'x', was: claude.body),
          throwsA(isA<ContextChanged>()),
        );
        expect(
          File('$home/src/app/CLAUDE.md').readAsStringSync(),
          'An app in Dart.',
        );

        // One not there yet is made.
        await ContextFiles.write(
          home,
          '~/notes/CLAUDE.md',
          body: 'Notes.',
          was: null,
        );
        expect(File('$home/notes/CLAUDE.md').readAsStringSync(), 'Notes.');

        // A memory is taken away; a CLAUDE.md is not.
        final mem = ContextFiles.shorten(home, '$memory/b.md');
        await ContextFiles.write(home, mem, body: null, was: 'B.');
        expect(File('$memory/b.md').existsSync(), isFalse);
        expect(
          () => ContextFiles.write(
            home,
            '~/notes/CLAUDE.md',
            body: null,
            was: 'Notes.',
          ),
          throwsArgumentError,
        );

        // Nothing else is written.
        for (final path in [
          '~/src/app/lib/a.dart',
          '~/.bashrc',
          '~/src/../.claude/CLAUDE.md',
          '/etc/CLAUDE.md',
          '~/.claude/projects/x/memory/../../../.bashrc',
        ]) {
          expect(
            () => ContextFiles.write(home, path, body: 'x', was: null),
            throwsArgumentError,
            reason: path,
          );
        }
      });
    });
  });

  group("a chat's settings", () {
    test('are read back as the chat keeps them', () {
      final chat = Chat.fromJson({
        'id': 'c',
        'agent': 'claude',
        'updated_at': '2026-11-22T10:00:00Z',
        'model': 'opus',
        'plugins': ['a@b'],
        'skills': ['clean-code'],
        'rules': [
          {'name': 'Brief', 'body': 'Be brief.'},
          'not a rule',
        ],
      });
      expect(chat.plugins, ['a@b']);
      expect(chat.skills, ['clean-code']);
      expect(chat.rules, [(name: 'Brief', body: 'Be brief.')]);
      final plain = Chat.fromJson({
        'id': 'c',
        'agent': 'shell',
        'updated_at': '2026-11-22T10:00:00Z',
      });
      expect(plain.plugins, isNull);
      expect(plain.rules, isEmpty);
      expect(
        AgentKind.fromJson({'id': 'claude', 'settings': true}).settings,
        isTrue,
      );
      expect(AgentKind.fromJson({'id': 'claude'}).settings, isFalse);
      expect(
        Chat.fromJson({
          'id': 'c',
          'agent': 'claude',
          'updated_at': '2026-11-22T10:00:00Z',
          'account': 'a1',
        }).account,
        'a1',
      );
    });

    test('changed are said in the chat, once each', () {
      final was = ChatAsk.fromJson({
        'id': 'c',
        'agent': 'claude',
        'model': 'opus',
        'effort': 'high',
        'skills': ['clean-code'],
        'rules': [
          {'name': 'Brief', 'body': 'Be brief.'},
        ],
      });
      expect(settingsChanged(was, was), isNull);
      // The title and the size are not what it runs with.
      expect(
        settingsChanged(
          was,
          ChatAsk.fromJson({
            'id': 'c',
            'agent': 'claude',
            'title': 'New',
            'cols': 120,
            'model': 'opus',
            'effort': 'high',
            'skills': ['clean-code'],
            'rules': [
              {'name': 'Brief', 'body': 'Be brief.'},
            ],
          }),
        ),
        isNull,
      );
      expect(
        settingsChanged(
          was,
          ChatAsk.fromJson({
            'id': 'c',
            'agent': 'claude',
            'model': 'sonnet',
            'permission': 'plan',
            'plugins': ['a@b'],
          }),
        ),
        'Settings changed: model sonnet, effort default, permissions plan, '
        'plugins, no skills, no rules.',
      );
      // Another account carries the session on: the program starts again.
      expect(
        settingsChanged(
          was,
          ChatAsk.fromJson({
            'id': 'c',
            'agent': 'claude',
            'model': 'opus',
            'effort': 'high',
            'skills': ['clean-code'],
            'rules': [
              {'name': 'Brief', 'body': 'Be brief.'},
            ],
            'account': 'a1',
          }),
        ),
        'Settings changed: account.',
      );
    });
  });

  group('accounts', () {
    test("Claude's usage answer is read for its windows only", () {
      final rows = claudeLimitRows({
        'five_hour': {
          'utilization': 65.0,
          'resets_at': '2026-11-23T01:40:00.716195+00:00',
        },
        'seven_day': {'utilization': 6.0, 'resets_at': null},
        'seven_day_opus': null,
        'seven_day_cowork': {'utilization': 50.0},
        'limits': [],
      });
      expect(rows.map((r) => r['name']), ['five_hour', 'seven_day']);
      expect(rows.first['used'], 0.65);
      expect(
        rows.first['resets'],
        DateTime.utc(2026, 11, 23, 1, 40, 0, 716, 195).millisecondsSinceEpoch /
            1000,
      );
      expect(rows.last.containsKey('resets'), isFalse);
      final limit = UsageLimit.of(rows.first)!;
      expect(limit.span, 300);
    });

    test("Codex's limits are read as its chats read them", () {
      final rows = codexLimitRows({
        'primary': {
          'usedPercent': 40,
          'windowDurationMins': 300,
          'resetsAt': 1795400000,
        },
        'secondary': {'usedPercent': 'x'},
      });
      expect(rows, [
        limitRow('primary', 0.4, resets: 1795400000, minutes: 300),
      ]);
    });

    test('a limit whose window started again reads as used up to nothing', () {
      final past = DateTime.now().subtract(const Duration(minutes: 1));
      final ahead = DateTime.now().add(const Duration(hours: 1));
      final gone = UsageLimit.of(
        limitRow('five_hour', 0.9, resets: past.millisecondsSinceEpoch / 1000),
      )!;
      final still = UsageLimit.of(
        limitRow('five_hour', 0.9, resets: ahead.millisecondsSinceEpoch / 1000),
      )!;
      expect((gone.passed, gone.usedNow), (true, 0));
      expect((still.passed, still.usedNow), (false, 0.9));
    });

    test("a chat's figures take its account's limits, newer than its own", () {
      final own = ChatUsage.of({
        'turns': 3,
        'cost': 1.5,
        'limits': [limitRow('five_hour', 0.2)],
        'limitsAt': 1,
      })!;
      final account = ChatUsage.of({
        'limits': [limitRow('five_hour', 0.7), limitRow('seven_day', 0.1)],
        'limitsAt': 2,
      })!;
      final both = own.withLimitsOf(account);
      expect(both.turns, 3);
      expect(both.cost, 1.5);
      expect(both.limits.map((l) => l.used), [0.7, 0.1]);
      expect(own.withLimitsOf(null), same(own));
      expect(own.withLimitsOf(const ChatUsage()), same(own));
    });

    test('the sign-in page is read off the screen', () {
      const claude =
          'Opening browser to sign in…\n'
          'If the browser didn\'t open, visit: '
          'https://claude.com/cai/oauth/authorize?code=true&client_id=x&state=y\n'
          'Paste code here if prompted >';
      expect(AgentLogins.loginScreen('claude', claude), (
        url:
            'https://claude.com/cai/oauth/authorize?code=true&client_id=x&state=y',
        hint: null,
      ));
      const codex =
          '1. Open this link in your browser and sign in to your account\n'
          '   https://auth.openai.com/codex/device\n'
          '2. Enter this one-time code (expires in 15 minutes)\n'
          '   AB12-CD3EF\n';
      expect(AgentLogins.loginScreen('codex', codex), (
        url: 'https://auth.openai.com/codex/device',
        hint: 'AB12-CD3EF',
      ));
      expect(
        AgentLogins.lastWords(
          'Opening browser to sign in…\n'
          'If the browser didn\'t open, visit: https://claude.com/x\n'
          'Paste code here if prompted > Login failed: Request failed with '
          'status code 400\n\n'
          'Pane is dead (status 1, Mon Nov 23 21:36:04 2026)\n',
        ),
        'Opening browser to sign in… '
        'Login failed: Request failed with status code 400',
      );
      expect(AgentLogins.loginScreen('claude', 'Starting…'), (
        url: null,
        hint: null,
      ));
    });

    test("an account's folder shares all of the agent's own but the login", () {
      final home = Directory.systemTemp.createTempSync('caldo-logins');
      addTearDown(() => home.deleteSync(recursive: true));
      final own = Directory('${home.path}/.claude')..createSync();
      File('${own.path}/settings.json').writeAsStringSync('{}');
      File('${own.path}/.credentials.json').writeAsStringSync('mine');
      Directory('${own.path}/plugins').createSync();
      File('${home.path}/.claude.json').writeAsStringSync(
        jsonEncode({
          'oauthAccount': {'emailAddress': 'me@x'},
          'mcpServers': {'caldo': {}},
        }),
      );
      final logins = AgentLogins(
        home: home.path,
        root: '${home.path}/accounts',
      );
      final folder = logins.folderOf('11111111-2222-4333-8444-555555555555');
      logins.mirror('claude', folder);
      expect(
        Link('$folder/settings.json').targetSync(),
        '${own.path}/settings.json',
      );
      expect(Link('$folder/plugins').existsSync(), isTrue);
      // Sessions are kept with the rest, made first if there were none.
      expect(Link('$folder/projects').targetSync(), '${own.path}/projects');
      expect(File('$folder/.credentials.json').existsSync(), isFalse);
      final config = jsonDecode(
        File('$folder/.claude.json').readAsStringSync(),
      );
      expect(config, {
        'mcpServers': {'caldo': {}},
      });
      expect(AgentLogins.envOf('claude', folder), [
        'env',
        'CLAUDE_CONFIG_DIR=$folder',
      ]);
      expect(AgentLogins.envOf('codex', null), isEmpty);

      // Removed on the server: its folder goes, and nothing it linked to.
      expect(logins.strays(const []), ['11111111-2222-4333-8444-555555555555']);
      expect(
        logins.strays(const ['11111111-2222-4333-8444-555555555555']),
        isEmpty,
      );
    });

    test('removing a folder leaves what it linked to', () async {
      final home = Directory.systemTemp.createTempSync('caldo-logins');
      addTearDown(() => home.deleteSync(recursive: true));
      final own = Directory('${home.path}/.codex')..createSync();
      File('${own.path}/config.toml').writeAsStringSync('x');
      File('${own.path}/auth.json').writeAsStringSync('{}');
      final logins = AgentLogins(
        home: home.path,
        root: '${home.path}/accounts',
      );
      final folder = logins.folderOf('11111111-2222-4333-8444-555555555555');
      logins.mirror('codex', folder);
      expect(Link('$folder/sessions').existsSync(), isTrue);
      expect(File('$folder/auth.json').existsSync(), isFalse);
      await logins.remove(folder);
      expect(Directory(folder).existsSync(), isFalse);
      expect(File('${own.path}/config.toml').existsSync(), isTrue);
      expect(File('${own.path}/auth.json').existsSync(), isTrue);
      expect(Directory('${own.path}/sessions').existsSync(), isTrue);
    });
  });

  group("a chat's title", () {
    String said(Object? title, {bool error = false}) => jsonEncode({
      'type': 'result',
      'is_error': error,
      'result': 'not this',
      'structured_output': {'title': title},
    });

    test('is the structured title, tidied', () {
      expect(
        titleIn(said('Gradle build running out of memory')),
        'Gradle build running out of memory',
      );
      expect(
        titleIn(said('"Падение приложения."\nmore')),
        'Падение приложения',
      );
      expect(titleIn(said('**Poem about cats**')), 'Poem about cats');
      final long = titleIn(said('word ' * 30))!;
      expect(long.length, lessThanOrEqualTo(60));
      expect(long, endsWith('word'));
    });

    test('is none when Claude gave none', () {
      expect(titleIn(said('  ')), isNull);
      expect(titleIn(said(null)), isNull);
      expect(titleIn(said('Fine', error: true)), isNull);
      expect(titleIn('{"result": "Fine"}'), isNull);
      expect(titleIn('claude: not logged in'), isNull);
    });

    test('is asked of Haiku with the message shown, not addressed', () {
      final args = namingArgs();
      expect(args, containsAllInOrder(['--model', 'haiku']));
      expect(args, contains('--no-session-persistence'));
      expect(args, containsAllInOrder(['--tools', '']));
      expect(args.join(' '), contains('the language the message is written'));
      final shown = namingInput('  help me ${'x' * 3000}');
      expect(shown, contains('<message>\nhelp me x'));
      expect(shown.length, lessThan(2100));
    });

    test("is written in the app's language when the chat says it", () {
      final ask = ChatAsk.fromJson({
        'id': 'x',
        'agent': 'claude',
        'language': 'ru',
      });
      expect(ask.language, 'ru');
      expect(namingArgs(ask.language).join(' '), contains('in Russian,'));
      expect(namingArgs('xx').join(' '), contains('in xx,'));
      expect(ChatAsk.fromJson({'id': 'x', 'agent': 'claude'}).language, isNull);
    });

    test("comes from Claude's own program", () async {
      final dir = Directory.systemTemp.createTempSync('naming');
      addTearDown(() => dir.deleteSync(recursive: true));
      final claude = File('${dir.path}/claude')
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'cat > "${dir.path}/in"\n'
          'printf \'{"structured_output":{"title":"Asked by %s"}}\' "\$3"\n',
        );
      Process.runSync('chmod', ['+x', claude.path]);
      expect(
        await nameChat('Tidy the repo', command: claude.path),
        'Asked by haiku',
      );
      expect(
        File('${dir.path}/in').readAsStringSync(),
        contains('Tidy the repo'),
      );

      File('${dir.path}/fails').writeAsStringSync('#!/bin/sh\nexit 1\n');
      Process.runSync('chmod', ['+x', '${dir.path}/fails']);
      expect(await nameChat('Tidy', command: '${dir.path}/fails'), isNull);
    });
  });

  group("a terminal's output", () {
    late StringBuffer drawn;
    late TermOrder order;
    setUp(() {
      drawn = StringBuffer();
      order = TermOrder(drawn.write);
    });

    Map<String, dynamic> piece(int seq, int start, int at, String data) => {
      'life': 1,
      'seq': seq,
      'start': start,
      'at': at,
      'data': data,
    };

    test('is drawn from pieces before their row comes', () {
      order.row(0, 'hello ');
      order.piece(piece(1, 6, 6, 'wor'));
      order.piece(piece(1, 6, 9, 'ld'));
      expect('$drawn', 'hello world');
      // The row brings what the pieces did, and is passed over.
      order.row(1, 'world');
      expect('$drawn', 'hello world');
    });

    test('takes the rest of a row the pieces left out', () {
      order.row(0, 'ab');
      order.piece(piece(1, 2, 2, 'cd'));
      order.row(1, 'cdef');
      expect('$drawn', 'abcdef');
    });

    test('carries on past a row not heard yet', () {
      order.row(0, 'a');
      order.piece(piece(1, 1, 1, 'bc'));
      // Row 1 went up; the next row's piece comes before it is heard.
      order.piece(piece(2, 3, 3, 'de'));
      order.row(1, 'bc');
      order.row(2, 'def');
      expect('$drawn', 'abcdef');
    });

    test('holds a piece after a gap until the gap is filled', () {
      order.row(0, 'a');
      order.piece(piece(1, 1, 1, 'b'));
      order.piece(piece(1, 1, 3, 'd'));
      expect('$drawn', 'ab');
      order.row(1, 'bcd');
      expect('$drawn', 'abcd');
    });

    test('draws rows whole when no pieces come', () {
      order.row(0, 'a');
      order.row(1, 'b');
      expect('$drawn', 'ab');
    });

    test('counts afresh for a worker started again', () {
      order.row(0, 'abc');
      order.piece(piece(1, 3, 3, 'd'));
      order.row(1, 'd');
      order.piece({...piece(2, 0, 0, 'x'), 'life': 2});
      order.row(2, 'xy');
      expect('$drawn', 'abcdxy');
    });

    test('passes over a snapshot after the first', () {
      order.row(4, 'SCREEN', snap: true, snapsToo: true);
      order.row(5, 'a');
      order.row(6, 'ALSO', snap: true);
      order.piece(piece(7, 9, 9, 'b'));
      order.row(7, 'b');
      expect('$drawn', 'SCREENab');
    });
  });

  test("the terminal is spared Claude's private requests", () {
    final clean = TermCleaner();
    expect(clean.add('a\x1b[>4;2mb\x1b[<uc'), 'abc');
    // Cut across two pieces: held, then dropped whole.
    expect(clean.add('d\x1b[>4'), 'd');
    expect(clean.add(';2me\x1b[1mf'), 'e\x1b[1mf');
    expect(clean.add('\x1b[?2004h'), '\x1b[?2004h');

    // An ended chat's last screen stays where Claude drew it.
    final ended = TermCleaner(keepAlternate: () => true);
    expect(ended.add('\x1b[?1049hhi\x1b[?1049l'), '\x1b[?1049hhi');
  });

  test("a sent task's mark names the model, as the watcher's do", () {
    const claude = AgentKind(id: 'claude', label: 'Claude');
    const codex = AgentKind(id: 'codex', label: 'Codex');
    expect(agentMark(claude, 'opus'), 'Opus');
    expect(agentMark(claude, null), 'Claude');
    expect(agentMark(codex, 'gpt-5'), 'Codex · gpt-5');
    expect(agentMark(codex, null), 'Codex');
    // The watcher's model first, then what it was sent to.
    const task = Task(listId: 1, title: 'x', createdAt: 0, agent: 'Codex');
    expect(ClaudeMark.of(task), 'Codex');
    expect(ClaudeMark.of(task.copyWith(claude: 'haiku')), 'Haiku');
    expect(ClaudeMark.of(task.copyWith(clearAgent: true)), isNull);
  });

  test("a task's chat is told what is written, then the task", () {
    final task = Task(
      listId: 1,
      title: 'Tidy the downloads',
      notes: 'Keep the PDFs.',
      dueAt: DateTime(2026, 11, 23).millisecondsSinceEpoch,
      createdAt: 0,
      subtasks: const [Subtask('Sort', done: true), Subtask('Delete')],
    );
    final told = taskMessage(task, '  Be careful.  ');
    expect(
      told,
      startsWith('Be careful.\n\nTask from Caldo: Tidy the downloads\n'),
    );
    expect(told, contains('Due: '));
    expect(told, contains('Notes:\nKeep the PDFs.'));
    expect(told, endsWith('Checklist:\n- [x] Sort\n- [ ] Delete'));
    expect(
      taskMessage(Task(listId: 1, title: 'Call', createdAt: 0), ''),
      'Task from Caldo: Call',
    );
  });

  test('editing a task preface preserves the supplied task details', () {
    const task = Task(
      listId: 1,
      title: 'Call',
      notes: 'Ask about Monday.',
      createdAt: 0,
    );
    Chat chat(String? preface) => Chat.fromJson({
      'id': 'chat',
      'agent': 'claude',
      'state': 'waiting',
      'updated_at': '2026-11-25T12:00:00Z',
      'task_uuid': 'task',
      'preface': preface,
      'prompt': taskMessage(task, preface ?? 'Original instructions'),
    });

    expect(
      chat('Old\nmessage').taskPromptWith('  New\nmessage  '),
      taskMessage(task, 'New\nmessage'),
    );
    expect(chat('Old').taskPromptWith('  '), taskMessage(task, ''));
    expect(chat('').taskPromptWith('New'), taskMessage(task, 'New'));
    expect(chat(null).taskPromptWith('Replacement'), 'Replacement');
  });

  group('the tab', () {
    test('groups chats by priority and promotes a newly finished turn', () {
      final now = DateTime.utc(2026, 11, 25);
      Chat chat(String id, ChatState state, int minutes, {int? pinned}) => Chat(
        id: id,
        agent: 'codex',
        state: state,
        updatedAt: now.add(Duration(minutes: minutes)),
        pinnedAt: pinned == null ? null : now.add(Duration(minutes: pinned)),
      );

      final chats = [
        chat('finished', ChatState.finished, 5),
        chat('limited', ChatState.limited, 4),
        chat('working', ChatState.running, 3),
        chat('your turn', ChatState.yourTurn, 1),
        chat('question', ChatState.asking, 2),
        chat('pinned earlier', ChatState.asking, 7, pinned: 0),
        chat('pinned later', ChatState.finished, 0, pinned: 1),
        chat('ready', ChatState.idle, 8),
      ];
      List<String> ids(Iterable<Chat> chats) => [
        for (final chat in Chat.listOrder(chats)) chat.id,
      ];

      expect(ids(chats), [
        'pinned later',
        'pinned earlier',
        'question',
        'your turn',
        'working',
        'limited',
        'ready',
        'finished',
      ]);
      expect(
        ids([
          for (final current in chats)
            if (current.id == 'working')
              chat('working', ChatState.finished, 9)
            else
              current,
        ]),
        [
          'pinned later',
          'pinned earlier',
          'question',
          'your turn',
          'limited',
          'ready',
          'working',
          'finished',
        ],
      );
    });

    setUp(() => SharedPreferences.setMockInitialValues({}));
    tearDown(() {
      S.use('en');
      Agents.instance.workers = const [];
      Agents.instance.rules = const [];
      Agents.instance.projects = const [];
      Agents.instance.accounts = const [];
    });

    Future<void> pump(
      WidgetTester tester,
      String code,
      Widget home, {
      ThemeData? theme,
    }) async {
      tester.view.physicalSize = const Size(960, 1920);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(code),
          supportedLocales: S.supported,
          localizationsDelegates: const [
            S.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: theme ?? AppTheme.dark(AppAccent.presets.first),
          home: home,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    for (final dark in [false, true]) {
      testWidgets('shows project color in ${dark ? 'dark' : 'light'} mode', (
        tester,
      ) async {
        final agents = Agents.instance;
        final now = DateTime.now();
        const colour = 'teal';
        agents
          ..signedInForTest = true
          ..workers = [
            AgentWorker(
              id: 'worker',
              name: 'Desk',
              home: '/home/someone',
              seenAt: now,
              dirs: const [],
              agents: const [AgentKind(id: 'shell', label: 'Shell')],
            ),
          ]
          ..projects = const [
            AgentProject(id: 'caldo', name: 'Caldo', colour: colour),
          ]
          ..chats = [
            Chat(
              id: 'a',
              title: 'Grouped chat',
              agent: 'shell',
              state: ChatState.ended,
              updatedAt: now,
              projectId: 'caldo',
            ),
            Chat(
              id: 'b',
              title: 'Ungrouped chat',
              agent: 'shell',
              state: ChatState.ended,
              updatedAt: now,
            ),
          ];
        addTearDown(() {
          agents
            ..signedInForTest = null
            ..chats = const [];
        });

        final accent = AppAccent.presets.first;
        await pump(
          tester,
          'en',
          const AgentsScreen(),
          theme: dark ? AppTheme.dark(accent) : AppTheme.light(accent),
        );
        final grouped = find.text('Grouped chat');
        final ungrouped = find.text('Ungrouped chat');
        Color? background(Finder title) => tester
            .element(title)
            .findAncestorWidgetOfExactType<Material>()!
            .color;

        final palette = AppTheme.of(tester.element(grouped));
        final gray = dark ? palette.panel : palette.panelHi;
        expect(background(grouped), gray);
        expect(background(ungrouped), gray);
        final projectColour = ListStyle.byId(colour).color;
        final status = tester.widget<Text>(find.textContaining('Caldo'));
        final spans = (status.textSpan! as TextSpan).children!;
        expect(spans, hasLength(2));
        final project = spans.first as TextSpan;
        expect(project.text, 'Caldo · ');
        expect(
          project.style?.color,
          Color.lerp(projectColour, palette.text, 0.35),
        );

        Color? bar(Finder title) {
          final card = find.ancestor(of: title, matching: find.byType(InkWell));
          final bars = find.descendant(
            of: card,
            matching: find.byKey(const ValueKey('projectBar')),
          );
          if (bars.evaluate().isEmpty) return null;
          final box = tester.widget<DecoratedBox>(bars);
          return (box.decoration as BoxDecoration).color;
        }

        double timeRight(Finder title) => tester
            .getTopRight(
              find.descendant(
                of: find.ancestor(of: title, matching: find.byType(InkWell)),
                matching: find.text(Dates.time(now)),
              ),
            )
            .dx;

        expect(bar(grouped), projectColour);
        expect(bar(ungrouped), isNull);
        // The state mark stands on the title's line.
        final mark = tester.getCenter(
          find
              .descendant(
                of: find.ancestor(of: grouped, matching: find.byType(InkWell)),
                matching: find.byType(DecoratedBox),
              )
              .at(1),
        );
        final line = tester.getRect(grouped);
        expect(mark.dy, inInclusiveRange(line.top, line.bottom));
        // Times line up whether a card has a bar or not.
        expect(timeRight(grouped), timeRight(ungrouped));

        await tester.longPress(grouped);
        await tester.pump();
        expect(background(grouped), dark ? palette.panelHi : palette.field);
        expect(background(ungrouped), gray);
        expect(bar(grouped), projectColour);
      });
    }

    testWidgets('names the computer only when there are two', (tester) async {
      final agents = Agents.instance;
      final now = DateTime.now();
      AgentWorker worker(String id, String name) => AgentWorker(
        id: id,
        name: name,
        home: '/home/someone',
        seenAt: now,
        dirs: const [],
        agents: const [AgentKind(id: 'shell', label: 'Shell')],
      );
      agents
        ..signedInForTest = true
        ..workers = [worker('w', 'Desk')]
        ..chats = [
          Chat(
            id: 'a',
            title: 'A chat',
            agent: 'shell',
            workerId: 'w',
            state: ChatState.ended,
            updatedAt: now,
          ),
        ];
      addTearDown(() {
        agents
          ..signedInForTest = null
          ..workers = const []
          ..chats = const [];
      });
      await pump(tester, 'en', const AgentsScreen());
      expect(find.text('Ended · Shell'), findsOneWidget);

      agents.workers = [worker('w', 'Desk'), worker('v', 'Laptop')];
      await pump(tester, 'en', const AgentsScreen());
      expect(find.text('Ended · Shell · Desk'), findsOneWidget);
    });

    testWidgets('checks a stale heartbeat before showing a chat as offline', (
      tester,
    ) async {
      final agents = Agents.instance;
      final wasLoaded = agents.loaded;
      final now = DateTime.now();
      final heartbeat = Completer<DateTime>();
      const id = 'worker';
      final client = (await tester.runAsync(
        () async => SupabaseClient(
          'https://example.invalid',
          'anon',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            final rows = switch (request.url.pathSegments.last) {
              'workers' => [
                {
                  'id': id,
                  'name': 'Desk',
                  'seen_at': (await heartbeat.future).toIso8601String(),
                  'agents': [
                    {'id': 'shell', 'label': 'Shell'},
                  ],
                },
              ],
              'chats' => [
                {
                  'id': 'chat',
                  'title': 'Working chat',
                  'agent': 'shell',
                  'state': 'running',
                  'worker_id': id,
                  'updated_at': now.toIso8601String(),
                },
              ],
              _ => const [],
            };
            return http.Response(jsonEncode(rows), 200, request: request);
          }),
        ),
      ))!;
      agents
        ..clientForTest = client
        ..loaded = true
        ..workers = [
          AgentWorker(
            id: id,
            name: 'Desk',
            agents: const [],
            dirs: const [],
            seenAt: now.subtract(const Duration(minutes: 5)),
          ),
        ]
        ..chats = [
          Chat(
            id: 'chat',
            title: 'Working chat',
            agent: 'shell',
            state: ChatState.running,
            workerId: id,
            updatedAt: now,
          ),
        ];
      final shown = ValueNotifier(false);
      addTearDown(() async {
        agents
          ..clientForTest = null
          ..loaded = wasLoaded
          ..chats = const [];
        shown.dispose();
        await client.dispose();
      });

      final loading = agents.load(recheckWorkers: true);
      await pump(tester, 'en', AgentsScreen(shown: shown));
      expect(find.text('Working chat'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off_rounded), findsNothing);
      expect(find.textContaining('Offline'), findsNothing);

      heartbeat.complete(now);
      await loading;
      await tester.pump();
      expect(agents.error, isNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Working · Shell'), findsOneWidget);
    });

    testWidgets("a chat whose computer stopped answering says so", (
      tester,
    ) async {
      final agents = Agents.instance;
      final now = DateTime.now();
      AgentWorker desk(DateTime seen) => AgentWorker(
        id: 'worker',
        name: 'Desk',
        seenAt: seen,
        dirs: const [],
        agents: const [AgentKind(id: 'shell', label: 'Shell')],
      );
      agents
        ..signedInForTest = true
        ..workers = [desk(now.subtract(const Duration(minutes: 5)))]
        ..chats = [
          Chat(
            id: 'away-chat',
            title: 'Left working',
            agent: 'shell',
            workerId: 'worker',
            state: ChatState.running,
            updatedAt: now,
          ),
        ];
      addTearDown(() {
        agents
          ..signedInForTest = null
          ..chats = const [];
      });

      await pump(tester, 'en', const AgentsScreen());
      expect(find.text('Offline · Shell'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);

      await pump(tester, 'en', const ChatScreen(chat: 'away-chat'));
      expect(find.text('Offline · Shell'), findsOneWidget);
      expect(
        find.textContaining('Desk has been offline since'),
        findsOneWidget,
      );

      // Back, it says how the chat stands again.
      agents
        ..workers = [desk(now)]
        ..load();
      await tester.pump();
      expect(find.text('Working · Shell'), findsOneWidget);
      expect(find.textContaining('has been offline'), findsNothing);
    });

    testWidgets('offers the first-message editor until a task chat starts', (
      tester,
    ) async {
      final agents = Agents.instance;
      const id = 'task-chat';
      Chat chat(ChatState state, {String? task = 'task'}) => Chat(
        id: id,
        agent: 'shell',
        title: 'Queued task',
        taskUuid: task,
        state: state,
        preface: 'Original instructions',
        prompt: 'Original instructions\n\nTask from Caldo: Queued task',
        updatedAt: DateTime.now(),
      );
      agents.chats = [chat(ChatState.waiting)];
      addTearDown(() => agents.chats = const []);
      await pump(tester, 'en', const ChatScreen(chat: id));
      final s = S.forCode('en');
      final edit = find.text(s.chatEditFirstMessage);
      expect(edit, findsOneWidget);
      expect(find.text(s.chatStartNow), findsOneWidget);

      await tester.tap(edit);
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller!.text, 'Original instructions');
      await tester.tap(find.text(s.cancel));
      await tester.pumpAndSettle();

      agents.chats = [chat(ChatState.asked)];
      await agents.load();
      await tester.pump();
      expect(edit, findsOneWidget);

      agents.chats = [chat(ChatState.running)];
      await agents.load();
      await tester.pump();
      expect(edit, findsNothing);

      agents.chats = [chat(ChatState.waiting, task: null)];
      await agents.load();
      await tester.pump();
      expect(edit, findsNothing);
    });

    testWidgets('restores each chat draft after leaving the chat', (
      tester,
    ) async {
      final agents = Agents.instance;
      final previous = agents.chats;
      const ids = ['draft-chat-a', 'draft-chat-b'];
      agents.chats = [
        for (final id in ids)
          Chat(
            id: id,
            title: id,
            agent: 'shell',
            state: ChatState.idle,
            updatedAt: DateTime.now(),
          ),
      ];
      addTearDown(() {
        agents.chats = previous;
        for (final id in ids) {
          agents.draftOf(id).value = '';
        }
      });
      final field = find.byType(TextField);
      String input() => tester.widget<TextField>(field).controller!.text;

      Future<void> open(String id) => pump(tester, 'en', ChatScreen(chat: id));

      Future<void> leave() async {
        await tester.pumpWidget(const SizedBox.shrink());
        expect(field, findsNothing);
      }

      await open(ids.first);
      expect(
        find.ancestor(of: field, matching: find.byType(BackdropFilter)),
        findsOneWidget,
      );
      await tester.enterText(field, 'first line\nsecond line  ');
      await leave();
      await open(ids.last);
      expect(input(), isEmpty);
      await tester.enterText(field, 'another chat');
      await leave();

      await open(ids.first);
      expect(input(), 'first line\nsecond line  ');
      await tester.enterText(field, '');
      await leave();
      await open(ids.first);
      expect(input(), isEmpty);
      await leave();
      await open(ids.last);
      expect(input(), 'another chat');
      await leave();
    });

    testWidgets('searches Codex models by ID and allows a custom model', (
      tester,
    ) async {
      Agents.instance.workers = [
        AgentWorker(
          id: 'worker',
          name: 'Worker',
          seenAt: DateTime.now(),
          dirs: const [],
          agents: [
            AgentKind.fromJson({
              'id': 'codex',
              'label': 'Codex',
              'models': ['codex-fast', 'codex-deep'],
              'default_model': 'codex-fast',
              'model_labels': {
                'codex-fast': 'Fast model',
                'codex-deep': 'Deep model',
              },
            }),
          ],
        ),
      ];
      final s = S.forCode('en');
      await pump(tester, 'en', const NewChatScreen());
      final defaultTile = find.widgetWithText(ListTile, 'Fast model');
      expect(tester.widget<ListTile>(defaultTile).subtitle, isA<Text>());
      await tester.tap(defaultTile);
      await tester.pumpAndSettle();
      final defaultChoice = tester.widget<ListTile>(defaultTile.last);
      expect(defaultChoice.selected, isTrue);
      expect((defaultChoice.subtitle as Text).data, s.chatDefault);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is ListTile &&
              widget.title is Text &&
              (widget.title as Text).data == s.chatDefault,
        ),
        findsNothing,
      );
      await tester.enterText(
        find.widgetWithText(TextField, s.search),
        'codex-deep',
      );
      await tester.pumpAndSettle();
      expect(
        tester.widgetList<ListTile>(defaultTile).any((tile) => tile.selected),
        isFalse,
      );
      await tester.tap(find.text('Deep model'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ListTile, 'Deep model'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(s.chatOther));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      await tester.enterText(
        find.descendant(of: dialog, matching: find.byType(TextField)),
        'custom-model',
      );
      await tester.tap(
        find.descendant(of: dialog, matching: find.text(s.save)),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'custom-model'), findsOneWidget);
    });

    testWidgets('keeps each agent\'s own permission across chats', (
      tester,
    ) async {
      // The last chat was Claude's; Codex was last begun with full access.
      SharedPreferences.setMockInitialValues({
        'agents_last': jsonEncode({
          'worker': 'worker',
          'agent': 'claude',
          'permission': 'auto',
          'agents': {
            'codex': {
              'model': null,
              'effort': null,
              'permission': 'full-access',
            },
          },
        }),
      });
      Agents.instance.workers = [
        AgentWorker(
          id: 'worker',
          name: 'Worker',
          seenAt: DateTime.now(),
          dirs: const [],
          agents: const [
            AgentKind(
              id: 'claude',
              label: 'Claude',
              permissions: ['auto', 'manual', 'plan'],
            ),
            AgentKind(
              id: 'codex',
              label: 'Codex',
              permissions: ['on-request', 'never', 'full-access'],
            ),
          ],
        ),
      ];
      await pump(tester, 'en', const NewChatScreen());
      await tester.pumpAndSettle();
      final p = AppTheme.of(tester.element(find.byType(NewChatScreen)));
      bool lit(String label) =>
          tester
              .widget<Material>(
                find
                    .ancestor(
                      of: find.text(label),
                      matching: find.byType(Material),
                    )
                    .first,
              )
              .color ==
          p.field;

      expect(lit('auto'), isTrue);
      await tester.tap(find.text('Codex'));
      await tester.pumpAndSettle();
      expect(lit('full-access'), isTrue);
      expect(lit('on-request'), isFalse);

      // Tapped again, the chosen agent keeps what was picked on the form.
      await tester.tap(find.text('never'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Codex'));
      await tester.pumpAndSettle();
      expect(lit('never'), isTrue);

      // Away and back, each keeps its own.
      await tester.tap(find.text('Claude'));
      await tester.pumpAndSettle();
      expect(lit('auto'), isTrue);
      await tester.tap(find.text('Codex'));
      await tester.pumpAndSettle();
      expect(lit('never'), isTrue);
    });

    testWidgets('shows Codex\'s on-request chosen when none was', (
      tester,
    ) async {
      Agents.instance.workers = [
        AgentWorker(
          id: 'worker',
          name: 'Worker',
          seenAt: DateTime.now(),
          dirs: const [],
          agents: const [
            AgentKind(
              id: 'codex',
              label: 'Codex',
              permissions: ['on-request', 'never', 'full-access'],
            ),
          ],
        ),
      ];
      await pump(tester, 'en', const NewChatScreen());
      await tester.pumpAndSettle();
      final p = AppTheme.of(tester.element(find.byType(NewChatScreen)));
      final pick = tester.widget<Material>(
        find
            .ancestor(
              of: find.text('on-request'),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(pick.color, p.field);
    });

    for (final code in S.names.keys) {
      testWidgets('fits in ${S.names[code]}', (tester) async {
        final s = S.forCode(code);
        // Not signed in, as in a test: the tab says how to be.
        await pump(tester, code, const AgentsScreen());
        expect(find.text(s.agentsSignIn), findsOneWidget);

        Agents.instance.workers = [
          AgentWorker(
            id: 'w',
            name: 'a-rather-long-computer-name',
            home: '/home/someone',
            seenAt: DateTime.now(),
            dirs: const ['/home/someone', '/home/someone/dev/src/Caldo'],
            agents: const [
              AgentKind(
                id: 'claude',
                label: 'Claude',
                models: ['fable', 'opus', 'sonnet', 'haiku'],
                efforts: ['low', 'medium', 'high', 'xhigh', 'max'],
                permissions: ['auto', 'manual', 'acceptEdits', 'plan'],
                plugins: ['clangd-lsp@claude-plugins-official'],
                skills: ['clean-code'],
                rules: true,
              ),
              AgentKind(id: 'shell', label: 'Shell', prompt: 'type'),
            ],
          ),
        ];
        const rule = AgentRule(
          id: 'r',
          name: 'Run the whole test suite before saying anything is done',
          body: 'Run `flutter test` and say what failed.',
        );
        Agents.instance.rules = const [rule];
        const caldo = AgentProject(
          id: 'p',
          name: 'Caldo, the calendar and to-do app',
          colour: 'teal',
          context: 'A calendar app in Flutter.',
          sources: ['~/dev/src/Caldo'],
        );
        const sync = AgentProject(
          id: 'q',
          name: 'Sync with the server',
          context: 'Supabase.',
          sources: ['~/notes/sync'],
        );
        Agents.instance.projects = const [caldo, sync];
        await pump(tester, code, const NewChatScreen());
        await tester.tap(find.widgetWithText(ListTile, s.chatDefault));
        await tester.pumpAndSettle();
        expect(find.text('opus'), findsOneWidget);
        await tester.tap(find.text('opus'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(ListTile, 'opus'), findsOneWidget);
        // The form's list, not a field's own scroll inside it.
        final list = find.byType(Scrollable).first;
        await tester.scrollUntilVisible(
          find.text(sync.name),
          300,
          scrollable: list,
        );
        expect(find.text(s.chatOwnFolderHint), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text(s.chatStart),
          300,
          scrollable: list,
        );
        expect(find.text(s.chatStart), findsOneWidget);
        expect(find.text(s.chatPrompt.toUpperCase()), findsNothing);
        expect(find.byType(TextField), findsOneWidget);
        expect(find.text(rule.name), findsOneWidget);
        expect(find.text(s.editRules), findsOneWidget);

        await pump(tester, code, const RulesScreen());
        expect(find.text(rule.name), findsOneWidget);
        await pump(tester, code, const RuleScreen(rule: rule));
        expect(find.text(s.ruleBody.toUpperCase()), findsOneWidget);
        Agents.instance.rules = const [];
        await pump(tester, code, const RulesScreen());
        expect(find.text(s.noRules), findsOneWidget);

        await pump(tester, code, const ProjectsScreen());
        expect(find.text(sync.name), findsOneWidget);
        await pump(tester, code, const ProjectScreen(project: sync));
        expect(find.text(sync.context), findsOneWidget);
        expect(find.text('~/notes/sync'), findsWidgets);
        expect(find.text(s.contextProject.toUpperCase()), findsOneWidget);
        await pump(tester, code, const ProjectScreen());
        expect(find.text(s.newProject), findsWidgets);
        Agents.instance.projects = const [];
        await pump(tester, code, const ProjectsScreen());
        expect(find.text(s.noProjects), findsOneWidget);
      });

      testWidgets("shows a project's history in ${S.names[code]}", (
        tester,
      ) async {
        final s = S.forCode(code);
        const caldo = AgentProject(id: 'p', name: 'Caldo', context: 'Now.');
        final at = DateTime(2026, 11, 26, 12, 30);
        Agents.instance.chats = [
          Chat(
            id: 'c1aa0000',
            agent: 'claude',
            state: ChatState.idle,
            updatedAt: at,
            title: 'Release',
          ),
        ];
        addTearDown(() => Agents.instance.chats = const []);
        await pump(
          tester,
          code,
          ProjectHistoryScreen(
            project: caldo,
            versions: [
              ProjectVersion(
                id: 4,
                version: 3,
                context: 'Mine, not merged.',
                by: 'computer:desk',
                unmerged: true,
                at: at,
              ),
              ProjectVersion(
                id: 3,
                version: 3,
                context: 'Now.',
                by: 'chat:c1aa0000',
                at: at,
              ),
              ProjectVersion(
                id: 2,
                version: 2,
                context: 'Before.',
                by: 'restore',
                at: at,
              ),
              ProjectVersion(
                id: 1,
                version: 1,
                context: 'First.',
                by: 'app',
                at: at,
              ),
            ],
          ),
        );
        expect(
          find.textContaining(s.historyByComputer('desk')),
          findsOneWidget,
        );
        expect(find.textContaining(s.historyByChat('Release')), findsOneWidget);
        expect(find.textContaining(s.historyRestored), findsOneWidget);
        expect(find.textContaining(s.historyByApp), findsOneWidget);
        expect(find.textContaining(s.historyUnmerged), findsOneWidget);
        // The info now is the latest saved, not the edit kept aside.
        expect(find.textContaining(s.historyNow), findsOneWidget);
        await tester.tap(find.textContaining('Before.'));
        await tester.pumpAndSettle();
        expect(find.text('Before.'), findsOneWidget);
        expect(find.text(s.historyRestore), findsOneWidget);
        Navigator.of(tester.element(find.text('Before.'))).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('Now.'));
        await tester.pumpAndSettle();
        expect(find.text(s.historyRestore), findsNothing);
      });

      testWidgets("shows a chat's context in ${S.names[code]}", (tester) async {
        final s = S.forCode(code);
        const caldo = AgentProject(
          id: 'p',
          name: 'Caldo',
          colour: 'teal',
          context: 'A calendar app in Flutter.',
          sources: ['~/dev/src/Caldo'],
        );
        final at = DateTime(2026, 11, 26);
        final top = Chat(
          id: 'a',
          agent: 'claude',
          state: ChatState.idle,
          updatedAt: at,
          title: 'Release 2.33',
          projectId: 'p',
          context: 'Ship on Fridays only.',
        );
        final sub = Chat(
          id: 'b',
          agent: 'claude',
          state: ChatState.idle,
          updatedAt: at,
          title: 'Fix the widget',
          projectId: 'p',
          parentId: 'a',
          context: 'Only the widget.',
        );
        Agents.instance
          ..projects = const [caldo]
          ..chats = [top, sub];
        addTearDown(() {
          Agents.instance
            ..projects = const []
            ..chats = const [];
        });
        await pump(tester, code, ChatContextScreen(chat: sub));
        expect(find.text(s.chatContext), findsOneWidget);
        expect(find.text(s.contextParents.toUpperCase()), findsOneWidget);
        expect(find.text(top.context), findsOneWidget);
        expect(find.text(caldo.context), findsOneWidget);
        expect(find.text(s.contextProjectHint('Caldo')), findsOneWidget);
        // No computer on: nothing to take a CLAUDE.md from.
        expect(find.text(s.contextImport), findsNothing);
        final list = find.byType(Scrollable).first;
        await tester.scrollUntilVisible(
          find.text(sub.context),
          200,
          scrollable: list,
        );
        expect(find.text(sub.context), findsOneWidget);
        // The parent's is changed in the parent: a tap goes there.
        await tester.scrollUntilVisible(
          find.text(top.context),
          -200,
          scrollable: list,
        );
        await tester.ensureVisible(find.text(top.context));
        await tester.pumpAndSettle();
        await tester.tap(find.text(top.context));
        await tester.pumpAndSettle();
        expect(find.text(s.contextParents.toUpperCase()), findsNothing);
        await tester.scrollUntilVisible(
          find.text(top.context),
          200,
          scrollable: find.byType(Scrollable).last,
        );
        // To the end of the list, so the tile is whole on screen.
        await tester.drag(find.byType(ListView).last, const Offset(0, -800));
        await tester.pumpAndSettle();
        await tester.tap(find.text(top.context));
        await tester.pumpAndSettle();
        expect(find.text(s.contextOwnHint), findsWidgets);
        expect(find.byType(TextField), findsOneWidget);
        tester
            .state<NavigatorState>(find.byType(Navigator).first)
            .popUntil((r) => r.isFirst);
        await tester.pumpAndSettle();

        Agents.instance.projects = const [];
        await pump(tester, code, ChatContextScreen(chat: top));
        expect(find.text(s.contextNoProject), findsOneWidget);
      });

      testWidgets('sends tasks on in ${S.names[code]}', (tester) async {
        final s = S.forCode(code);
        Agents.instance.workers = [
          AgentWorker(
            id: 'w',
            name: 'desk',
            home: '/home/someone',
            seenAt: DateTime.now(),
            dirs: const ['/home/someone'],
            agents: const [
              AgentKind(
                id: 'claude',
                label: 'Claude',
                models: ['opus', 'sonnet'],
                efforts: ['low', 'high'],
              ),
              // It would run a task's words as commands.
              AgentKind(id: 'shell', label: 'Shell', prompt: 'type'),
              // Told nothing first, so no use for a task.
              AgentKind(id: 'repl', label: 'Repl', prompt: 'none'),
            ],
          ),
        ];
        final provider = TaskProvider();
        addTearDown(provider.dispose);
        await pump(
          tester,
          code,
          ChangeNotifierProvider.value(
            value: provider,
            child: const NewChatScreen(
              tasks: [
                Task(
                  id: 1,
                  listId: 1,
                  title: 'Tidy the downloads',
                  createdAt: 0,
                ),
                Task(id: 2, listId: 1, title: 'Read the logs', createdAt: 0),
              ],
            ),
          ),
        );
        expect(find.text(s.sendToAgents), findsOneWidget);
        expect(find.text('Tidy the downloads'), findsOneWidget);
        expect(find.text('Read the logs'), findsOneWidget);
        expect(find.text('Claude'), findsOneWidget);
        expect(find.text('Shell'), findsNothing);
        expect(find.text('Repl'), findsNothing);
        // Each chat is titled by its task.
        expect(find.text(s.chatTitle.toUpperCase()), findsNothing);
        final list = find.byType(Scrollable).first;
        await tester.scrollUntilVisible(
          find.text(s.chatStartEach(2)),
          300,
          scrollable: list,
        );
        expect(find.text(s.chatForEach.toUpperCase()), findsOneWidget);
        // Both due already: nothing to wait for.
        expect(find.text(s.chatStarts.toUpperCase()), findsNothing);
      });

      testWidgets('offers to start when due in ${S.names[code]}', (
        tester,
      ) async {
        final s = S.forCode(code);
        AgentWorker worker({required bool tasks}) => AgentWorker(
          id: 'w',
          name: 'desk',
          home: '/home/someone',
          seenAt: DateTime.now(),
          dirs: const [],
          agents: [AgentKind(id: 'claude', label: 'Claude', tasks: tasks)],
        );
        final provider = TaskProvider();
        addTearDown(provider.dispose);
        final tomorrow = DateTime.now().add(const Duration(days: 1));
        Future<void> open() => pump(
          tester,
          code,
          ChangeNotifierProvider.value(
            value: provider,
            child: NewChatScreen(
              tasks: [
                Task(
                  id: 1,
                  listId: 1,
                  title: 'Renew the domain',
                  dueAt: tomorrow.millisecondsSinceEpoch,
                  createdAt: 0,
                ),
              ],
            ),
          ),
        );
        // A worker from before could never start a chat left waiting.
        Agents.instance.workers = [worker(tasks: false)];
        await open();
        expect(find.text(s.chatStarts.toUpperCase()), findsNothing);

        Agents.instance.workers = [worker(tasks: true)];
        await open();
        expect(find.text(s.chatStarts.toUpperCase()), findsOneWidget);
        expect(find.text(s.chatStartsWhenDueHint), findsNothing);
        await tester.tap(find.text(s.chatStartsWhenDue));
        await tester.pump();
        expect(find.text(s.chatStartsWhenDueHint), findsOneWidget);
      });

      testWidgets('offers to start by hand in ${S.names[code]}', (
        tester,
      ) async {
        final s = S.forCode(code);
        AgentWorker worker({required bool held}) => AgentWorker(
          id: 'w',
          name: 'desk',
          home: '/home/someone',
          seenAt: DateTime.now(),
          dirs: const [],
          agents: [AgentKind(id: 'claude', label: 'Claude', held: held)],
        );
        final list = find.byType(Scrollable).first;
        // A worker from before would end a chat left with no task.
        Agents.instance.workers = [worker(held: false)];
        await pump(tester, code, const NewChatScreen());
        expect(find.text(s.chatStartsByHand), findsNothing);

        Agents.instance.workers = [worker(held: true)];
        await pump(tester, code, const NewChatScreen());
        expect(find.text(s.chatStarts.toUpperCase()), findsOneWidget);
        expect(find.text(s.chatStartsByHandHint), findsNothing);
        await tester.tap(find.text(s.chatStartsByHand));
        await tester.pump();
        expect(find.text(s.chatStartsByHandHint), findsOneWidget);
        // Only made, so not "Start".
        await tester.scrollUntilVisible(
          find.text(s.chatCreate),
          300,
          scrollable: list,
        );
        expect(find.text(s.chatStart), findsNothing);
      });

      testWidgets('tells a chat left for later in ${S.names[code]}', (
        tester,
      ) async {
        final s = S.forCode(code);
        final now = DateTime.now();
        Agents.instance
          ..signedInForTest = true
          ..workers = [
            AgentWorker(
              id: 'w',
              name: 'desk',
              home: '/home/someone',
              seenAt: now,
              dirs: const [],
              agents: const [AgentKind(id: 'claude', label: 'Claude')],
            ),
          ]
          ..chats = [
            Chat(
              id: 'a',
              workerId: 'w',
              agent: 'claude',
              title: 'Alpha',
              state: ChatState.waiting,
              updatedAt: now,
            ),
            Chat(
              id: 'b',
              workerId: 'w',
              agent: 'claude',
              title: 'Bravo',
              state: ChatState.waiting,
              taskUuid: 't',
              updatedAt: now,
            ),
          ];
        addTearDown(() {
          Agents.instance
            ..signedInForTest = null
            ..chats = const [];
        });
        await pump(tester, code, const AgentsScreen());
        expect(find.textContaining('${s.chatHeld} · '), findsOneWidget);
        expect(find.textContaining('${s.chatWaiting} · '), findsOneWidget);
      });

      testWidgets("shows a chat's settings in ${S.names[code]}", (
        tester,
      ) async {
        final s = S.forCode(code);
        AgentWorker worker({required bool settings}) => AgentWorker(
          id: 'w',
          name: 'a-rather-long-computer-name',
          home: '/home/someone',
          seenAt: DateTime.now(),
          dirs: const ['/home/someone'],
          agents: [
            AgentKind(
              id: 'claude',
              label: 'Claude',
              models: const ['fable', 'opus', 'sonnet', 'haiku'],
              efforts: const ['low', 'medium', 'high', 'xhigh', 'max'],
              permissions: const ['auto', 'manual', 'acceptEdits', 'plan'],
              plugins: const ['clangd-lsp@claude-plugins-official'],
              skills: const ['clean-code'],
              rules: true,
              settings: settings,
            ),
          ],
        );
        Agents.instance.workers = [worker(settings: true)];
        Agents.instance.rules = const [
          AgentRule(id: 'r', name: 'Brief', body: 'Be brief, as now.'),
        ];
        Agents.instance.chats = [
          Chat(
            id: 'c',
            workerId: 'w',
            agent: 'claude',
            title: 'Tidy the repo',
            model: 'my-own-model',
            effort: 'high',
            dir: '/home/someone/dev/src/Caldo',
            permission: 'plan',
            skills: const ['gone-skill'],
            rules: const [
              (name: 'Brief', body: 'Be brief.'),
              (name: 'Old rule', body: 'Since deleted.'),
            ],
            state: ChatState.idle,
            updatedAt: DateTime.now(),
            inChat: true,
          ),
        ];
        addTearDown(() => Agents.instance.chats = const []);
        // Opened over the chat, as its menu does.
        await pump(
          tester,
          code,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ChatSettingsScreen(chat: 'c'),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text(s.chatSettings), findsOneWidget);
        expect(find.text('a-rather-long-computer-name'), findsOneWidget);
        expect(find.text('~/dev/src/Caldo'), findsOneWidget);
        expect(find.text('Tidy the repo'), findsOneWidget);
        // A model written in shows as its own choice.
        expect(find.text('my-own-model'), findsOneWidget);
        final list = find.byType(Scrollable).first;
        await tester.scrollUntilVisible(
          find.text('Old rule'),
          300,
          scrollable: list,
        );
        // Kept, and a skill the worker no longer offers, so it can go.
        expect(find.text('Brief'), findsOneWidget);
        expect(find.text('gone-skill'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text(s.chatSettingsHint('Claude')),
          100,
          scrollable: list,
        );
        expect(find.text(s.save), findsNothing);
        expect(find.text(s.cancel), findsNothing);
        final title = find.byType(TextField);
        await tester.scrollUntilVisible(title, -300, scrollable: list);
        await tester.enterText(title, 'New chat title');
        await tester.pumpAndSettle();
        expect(find.text(s.save), findsOneWidget);
        expect(find.text(s.cancel), findsOneWidget);
        await tester.enterText(title, 'Tidy the repo');
        await tester.pumpAndSettle();
        expect(find.text(s.save), findsNothing);
        expect(find.text(s.cancel), findsNothing);
        await tester.enterText(title, 'Discard this title');
        await tester.pumpAndSettle();
        await tester.tap(find.text(s.cancel));
        await tester.pumpAndSettle();
        expect(find.byType(ChatSettingsScreen), findsNothing);
        expect(Agents.instance.chat('c')?.title, 'Tidy the repo');

        // A worker from before can't take them: said, not offered.
        Agents.instance.workers = [worker(settings: false)];
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(
          find.text(s.chatSettingsOld('a-rather-long-computer-name')),
          findsOneWidget,
        );
      });

      testWidgets("shows a chat's usage in ${S.names[code]}", (tester) async {
        final soon =
            DateTime.now()
                .add(const Duration(hours: 2))
                .millisecondsSinceEpoch /
            1000;
        final usage = ChatUsage.of({
          'model': 'claude-opus-5-5[1m]',
          'context': 812345,
          'window': 1000000,
          'input': 1234,
          'output': 98765,
          'cacheRead': 12345678,
          'cacheWrite': 234567,
          'cost': 12.3456,
          'turns': 42,
          'working': 3723000,
          'limits': [
            limitRow('five_hour', 0.91, resets: soon),
            limitRow('seven_day', 0.14, resets: soon + 86400),
            limitRow('seven_day_opus', 0.5),
          ],
          'limited': 'allowed_warning',
          'limitsAt': DateTime.now().millisecondsSinceEpoch,
        })!;
        final changes = ValueNotifier(0);
        addTearDown(changes.dispose);
        await pump(
          tester,
          code,
          Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  ChatUsageStrip(
                    usage: usage,
                    onTap: () => showChatUsage(
                      context,
                      changes: changes,
                      read: () => usage,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        final s = S.forCode(code);
        expect(find.byType(ChatUsageStrip), findsOneWidget);
        await tester.tap(find.byType(ChatUsageStrip));
        await tester.pumpAndSettle();
        expect(find.text(s.usageTitle), findsOneWidget);
        expect(find.text('81%'), findsOneWidget);
        expect(find.text('91%'), findsOneWidget);
        expect(find.text(s.usageLimitNear), findsOneWidget);
        expect(find.textContaining('Opus'), findsWidgets);
        await tester.scrollUntilVisible(
          find.text(r'$12.35'),
          100,
          scrollable: find.byType(Scrollable).last,
        );
        expect(find.text('42'), findsOneWidget);
      });

      testWidgets("lists a chat's usage in ${S.names[code]}", (tester) async {
        final usage = ChatUsage.of({
          'context': 812345,
          'window': 1000000,
          'cost': 12.3456,
          'turns': 42,
          'limits': [limitRow('five_hour', 0.91)],
        })!;
        await pump(
          tester,
          code,
          Scaffold(
            body: Center(
              child: SizedBox(width: 240, child: ChatUsageBrief(usage: usage)),
            ),
          ),
        );
        final s = S.forCode(code);
        final line = tester.widget<Text>(
          find.descendant(
            of: find.byType(ChatUsageBrief),
            matching: find.byType(Text),
          ),
        );
        expect(line.data, contains(s.usageContextShort('81%')));
        expect(line.data, contains(r'$12.35'));
        expect(line.data, contains(s.usageTurns(42)));
        // The account's limits are the strip's, not a chat's.
        expect(line.data, isNot(contains('91%')));
      });

      testWidgets('lists accounts in ${S.names[code]}', (tester) async {
        final s = S.forCode(code);
        final ahead =
            DateTime.now()
                .add(const Duration(hours: 3))
                .millisecondsSinceEpoch /
            1000;
        Agents.instance.workers = [
          AgentWorker(
            id: 'w',
            name: 'a-rather-long-computer-name',
            seenAt: DateTime.now(),
            dirs: const [],
            agents: const [
              AgentKind(id: 'claude', label: 'Claude', accounts: true),
              AgentKind(id: 'codex', label: 'Codex', accounts: true),
            ],
          ),
        ];
        AgentAccount account(
          String id,
          String agent,
          AccountState state, {
          bool main = false,
          String? url,
          String? hint,
          ChatUsage? usage,
          String? note,
        }) => AgentAccount(
          id: id,
          workerId: 'w',
          agent: agent,
          state: state,
          created: DateTime.now(),
          main: main,
          email: main ? 'someone.with.a.long.address@example.com' : null,
          plan: main ? 'max' : null,
          loginUrl: url,
          loginHint: hint,
          usage: usage,
          note: note,
        );
        Agents.instance.accounts = [
          account(
            'a',
            'claude',
            AccountState.ready,
            main: true,
            usage: ChatUsage.of({
              'limits': [
                limitRow('five_hour', 0.65, resets: ahead),
                limitRow('seven_day', 0.06, resets: ahead + 86400 * 5),
                // Its window started again since: read as nothing used.
                limitRow('seven_day_opus', 0.97, resets: 1),
              ],
              'limitsAt': DateTime.now().millisecondsSinceEpoch,
            }),
          ),
          account(
            'b',
            'claude',
            AccountState.signingIn,
            url: 'https://claude.com/cai/oauth/authorize?code=true',
          ),
          account(
            'c',
            'codex',
            AccountState.signingIn,
            url: 'https://auth.openai.com/codex/device',
            hint: 'AB12-CD3EF',
          ),
          account(
            'd',
            'codex',
            AccountState.failed,
            note: 'The sign-in was not finished within 20 minutes.',
          ),
        ];
        await pump(tester, code, const WorkersScreen());
        expect(
          find.text('someone.with.a.long.address@example.com'),
          findsOneWidget,
        );
        Finder accountIcon(String agent) => find.byWidgetPredicate(
          (widget) =>
              widget is Image &&
              widget.image is AssetImage &&
              (widget.image as AssetImage).assetName ==
                  'assets/icon/$agent.png',
        );
        expect(find.text('Claude · max'), findsOneWidget);
        expect(accountIcon('claude'), findsWidgets);
        expect(find.text('65%'), findsOneWidget);
        expect(find.text('0%'), findsOneWidget);
        expect(find.text(s.usageResetSince), findsOneWidget);
        final list = find.byType(Scrollable).first;
        await tester.scrollUntilVisible(
          find.text(s.accountSend),
          100,
          scrollable: list,
        );
        expect(find.text(s.accountOpenPage), findsWidgets);
        await tester.scrollUntilVisible(
          find.text('AB12-CD3EF'),
          100,
          scrollable: list,
        );
        expect(accountIcon('codex'), findsWidgets);
        await tester.scrollUntilVisible(
          find.text(s.accountSignIn),
          100,
          scrollable: list,
        );
        expect(find.text(s.accountSignIn), findsOneWidget);

        // Chosen on a new chat's form, its limits beside its name.
        await pump(tester, code, const NewChatScreen());
        expect(find.text(s.chatAccount.toUpperCase()), findsOneWidget);
        expect(
          find.textContaining('someone.with.a.long.address@example.com'),
          findsOneWidget,
        );
        expect(find.text(s.addAccount), findsOneWidget);

        await pump(tester, code, const NewAccountScreen());
        expect(find.text('Codex'), findsOneWidget);
        expect(
          find.text(s.accountAddHint('a-rather-long-computer-name')),
          findsOneWidget,
        );
      });

      testWidgets('asks questions in ${S.names[code]}', (tester) async {
        final feed = TalkFeed.held('c', [
          const ChatItem(
            id: 'ask:r1',
            seq: 0,
            kind: 'ask',
            body: {
              'tool': 'AskUserQuestion',
              'line': 'Which colour should the badge be?',
              'choices': ['answer', 'deny'],
              'questions': [
                {
                  'question': 'Which colour should the badge be?',
                  'header': 'Colour',
                  'multiSelect': false,
                  'options': [
                    {
                      'label': 'Red, like the Sunday numbers',
                      'description':
                          'The one signal colour the calendar already has',
                    },
                    {'label': 'Grey', 'description': ''},
                  ],
                },
                {
                  'question': 'Where should it show?',
                  'header': 'Places',
                  'multiSelect': true,
                  'options': [
                    {'label': 'Schedule', 'description': ''},
                    {'label': 'Calendar', 'description': ''},
                    {'label': 'Widget', 'description': ''},
                  ],
                },
              ],
            },
          ),
        ]);
        addTearDown(feed.dispose);
        final said = <(String, String, Map<String, String>)>[];
        await pump(
          tester,
          code,
          Scaffold(
            body: TalkView(
              feed: feed,
              working: false,
              onAnswer: (item, choice, answers) =>
                  said.add((item, choice, answers)),
            ),
          ),
        );
        final s = S.forCode(code);
        Finder answer() => find.widgetWithText(FilledButton, s.chatAnswer);
        // Not until every question has an answer.
        expect(tester.widget<FilledButton>(answer()).onPressed, isNull);
        await tester.tap(find.text('Grey'));
        await tester.tap(find.text('Red, like the Sunday numbers'));
        await tester.tap(find.text('Widget'));
        await tester.tap(find.text('Schedule'));
        await tester.pump();
        expect(tester.widget<FilledButton>(answer()).onPressed, isNotNull);
        // Words of one's own, after the options picked.
        await tester.tap(find.text(s.chatOther).last);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Board too');
        await tester.tap(find.text(s.save));
        await tester.pumpAndSettle();
        await tester.tap(answer());
        expect(said, hasLength(1));
        expect((said.single.$1, said.single.$2), ('ask:r1', 'answer'));
        expect(said.single.$3, {
          'Which colour should the badge be?': 'Red, like the Sunday numbers',
          'Where should it show?': 'Schedule, Widget, Board too',
        });
      });

      testWidgets('draws a chat in ${S.names[code]}', (tester) async {
        final feed = TalkFeed.held('c', [
          const ChatItem(
            id: 'u',
            seq: 0,
            kind: 'user',
            body: {
              'text': 'How many files are there?',
              'files': [
                {
                  'name': 'a photo with a rather long name of its own.jpg',
                  'mime': 'image/jpeg',
                  'size': 2202010,
                },
                {'name': 'notes.txt', 'mime': 'text/plain', 'size': 12},
              ],
            },
          ),
          const ChatItem(
            id: 't',
            seq: 1,
            kind: 'tool',
            body: {
              'name': 'Bash',
              'line': 'ls -A | wc -l; ls -la --color=never /a/rather/long/path',
              'output': '3',
              'done': true,
            },
          ),
          const ChatItem(
            id: 'k',
            seq: 2,
            kind: 'thinking',
            body: {'text': 'Counting.'},
          ),
          const ChatItem(
            id: 'a',
            seq: 3,
            kind: 'text',
            body: {
              'text':
                  '## Files\n\nThere are **3**: `a`, `b` and `c`.\n\n'
                  '- one\n- two\n  carried on\n1. first\n\n'
                  '> quoted\n\n'
                  '| name | size |\n|---|---|\n| a | 0 |\n\n'
                  '```sh\nls -la --color=never /a/rather/long/path/to/look/in\n```',
            },
          ),
          const ChatItem(
            id: 'q',
            seq: 4,
            kind: 'ask',
            body: {
              'tool': 'Write',
              'line': '/home/someone/dev/src/Caldo/lib/a_long_file_name.dart',
              'detail': 'hi',
              'choices': ['allow', 'always', 'deny'],
            },
          ),
          const ChatItem(
            id: 'n',
            seq: 5,
            kind: 'note',
            body: {'text': 'Context compacted.'},
          ),
          const ChatItem(
            id: 'm',
            seq: 6,
            kind: 'user',
            body: {
              'text': 'Do the tests pass?',
              'sender': {
                'chat': 'abcd1234-ffff',
                'title': 'Planning the release of the next version, at length',
                'waits': true,
              },
            },
          ),
        ]);
        addTearDown(feed.dispose);
        await pump(
          tester,
          code,
          Scaffold(
            body: TalkView(feed: feed, working: true, onAnswer: (_, _, _) {}),
          ),
        );
        final s = S.forCode(code);
        // Another chat's message says whose it is, cut to a line.
        expect(
          find.text(
            s.chatFrom('Planning the release of the next version, at length'),
          ),
          findsOneWidget,
        );
        expect(find.text(s.chatAllow), findsOneWidget);
        expect(find.text(s.chatWorking), findsOneWidget);
        // Opened at the foot: the tool is above, scrolled to.
        await tester.scrollUntilVisible(
          find.text('Bash'),
          -200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Bash'));
        await tester.pump();
        expect(find.text('3'), findsWidgets);
        // The files sent with the first message, by name, over its words.
        await tester.scrollUntilVisible(
          find.text('notes.txt'),
          -200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          tester.getTopLeft(find.text('notes.txt')).dy,
          lessThan(
            tester.getTopLeft(find.text('How many files are there?')).dy,
          ),
        );
      });

      testWidgets(
        'offers to carry on after the usage limit in ${S.names[code]}',
        (tester) async {
          final resets = DateTime.now().add(const Duration(hours: 2));
          final said = [
            const ChatItem(
              id: 'u',
              seq: 0,
              kind: 'user',
              body: {'text': 'Go on.'},
            ),
            ChatItem(
              id: 'l1',
              seq: 1,
              kind: 'note',
              body: {
                'text': 'Stopped at the usage limit.',
                'limit': true,
                'resets': resets.millisecondsSinceEpoch,
              },
            ),
          ];
          final asked = <String>[];
          Future<void> show(List<ChatItem> items) async {
            final feed = TalkFeed.held('c', items);
            addTearDown(feed.dispose);
            await pump(
              tester,
              code,
              Scaffold(
                body: TalkView(
                  feed: feed,
                  working: false,
                  onAnswer: (_, _, _) {},
                  onCarry: (item) => asked.add(item.id),
                  usage: ChatUsage(
                    limits: [
                      UsageLimit(name: 'five_hour', used: 1, resets: resets),
                    ],
                  ),
                ),
              ),
            );
          }

          await show(said);
          final s = S.forCode(code);
          // Which limit, and when it resets.
          expect(find.text(s.chatLimitTitle), findsOneWidget);
          expect(find.textContaining(s.usageFiveHours), findsOneWidget);
          // Not asked for until switched on.
          final row = find.text(s.chatCarryOnReset);
          expect(row, findsOneWidget);
          expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
          expect(asked, isEmpty);
          await tester.tap(find.byType(Switch));
          expect(asked, ['l1']);

          // Once it carried on, or the user wrote again, it is only said;
          // the words it was told to carry on with aren't drawn as theirs.
          await show([
            ...said,
            const ChatItem(
              id: 'u2',
              seq: 2,
              kind: 'user',
              body: {'text': CarryOn.words},
            ),
          ]);
          expect(
            find.byIcon(Icons.pause_circle_outline_rounded),
            findsOneWidget,
          );
          expect(find.text(s.chatAtLimit), findsOneWidget);
          expect(find.text(s.chatCarriedOn), findsOneWidget);
          expect(find.text(CarryOn.words), findsNothing);
          expect(row, findsNothing);
          expect(find.byType(Switch), findsNothing);
        },
      );

      testWidgets('lists what is left for later in ${S.names[code]}', (
        tester,
      ) async {
        final now = DateTime.now();
        final soon = LaterLine(
          id: 1,
          text: 'Carry on with the migration and run every test after it\nok',
          at: now.add(const Duration(minutes: 30)),
        );
        final later = LaterLine(
          id: 2,
          text: 'Go on.',
          at: DateTime(now.year, now.month, now.day + 3, 9),
        );
        LaterLine? tapped, deleted;
        await pump(
          tester,
          code,
          Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: LaterList(
                lines: [soon, later],
                onTap: (l) => tapped = l,
                onDelete: (l) => deleted = l,
              ),
            ),
          ),
        );
        // Only its first line, and a day named when it is not today.
        expect(find.textContaining('every test'), findsOneWidget);
        expect(find.textContaining('\nok'), findsNothing);
        expect(
          find.text(LaterList.whenOf(later.at, h24: false)),
          findsOneWidget,
        );
        await tester.tap(find.text('Go on.'));
        expect(tapped, later);
        await tester.tap(find.byIcon(Icons.close_rounded).first);
        expect(deleted, soon);
      });

      testWidgets('tells ready chats from finished ones in ${S.names[code]}', (
        tester,
      ) async {
        final s = S.forCode(code);
        final now = DateTime.now();
        Chat chat(String id, String title, ChatState state) => Chat(
          id: id,
          workerId: 'w',
          agent: 'claude',
          title: title,
          state: state,
          note: state == ChatState.finished ? 'Finished the work.' : null,
          updatedAt: now,
        );
        Agents.instance
          ..signedInForTest = true
          ..workers = [
            AgentWorker(
              id: 'w',
              name: 'desk',
              home: '/home/someone',
              seenAt: now,
              dirs: const [],
              agents: const [AgentKind(id: 'claude', label: 'Claude')],
            ),
          ]
          ..chats = [
            chat('a', 'Alpha', ChatState.idle),
            chat('b', 'Bravo', ChatState.running),
            chat('c', 'Charlie', ChatState.asking),
            chat('d', 'Delta', ChatState.finished),
            chat('e', 'Echo', ChatState.yourTurn),
            chat('f', 'Foxtrot', ChatState.limited),
          ];
        addTearDown(() {
          Agents.instance
            ..signedInForTest = null
            ..chats = const [];
        });
        await pump(tester, code, const AgentsScreen());
        for (final word in [
          s.chatIdle,
          s.chatRunning,
          s.chatFinished,
          s.chatLimited,
        ]) {
          expect(find.textContaining('$word · '), findsOneWidget);
        }
        // A turn ended asking the user something waits for them, as a
        // question asked does.
        expect(find.textContaining('${s.chatAsking} · '), findsNWidgets(2));
        for (final (title, icon) in [
          ('Delta', Icons.flag_rounded),
          ('Foxtrot', Icons.pause_circle_outline_rounded),
        ]) {
          final card = find.ancestor(
            of: find.text(title),
            matching: find.byType(InkWell),
          );
          final mark = find.descendant(of: card, matching: find.byIcon(icon));
          expect(mark, findsOneWidget);
          expect(
            tester.getCenter(mark).dy,
            closeTo(tester.getCenter(card).dy, 0.001),
          );
        }
        // Finished, it still takes a message: its program runs.
        expect(chat('d', 'Delta', ChatState.finished).live, isTrue);
        expect(chat('e', 'Echo', ChatState.yourTurn).live, isTrue);
      });

      testWidgets('picks out chats in ${S.names[code]}', (tester) async {
        final s = S.forCode(code);
        final now = DateTime.now();
        Agents.instance
          ..signedInForTest = true
          ..workers = [
            AgentWorker(
              id: 'w',
              name: 'desk',
              home: '/home/someone',
              seenAt: now,
              dirs: const [],
              agents: const [AgentKind(id: 'claude', label: 'Claude')],
            ),
          ]
          ..chats = Chat.listOrder([
            Chat(
              id: 'a',
              workerId: 'w',
              agent: 'claude',
              title: 'Alpha',
              state: ChatState.idle,
              updatedAt: now,
            ),
            Chat(
              id: 'b',
              workerId: 'w',
              agent: 'claude',
              title: 'Bravo',
              state: ChatState.ended,
              updatedAt: now.subtract(const Duration(days: 2)),
              pinnedAt: now,
            ),
            Chat(
              id: 'c',
              workerId: 'w',
              agent: 'claude',
              title: 'Charlie',
              state: ChatState.ended,
              updatedAt: now.subtract(const Duration(days: 1)),
            ),
          ]);
        addTearDown(() {
          Agents.instance
            ..signedInForTest = null
            ..chats = const [];
        });
        // The pinned one on top, older though it is.
        expect([for (final c in Agents.instance.chats) c.id], ['b', 'a', 'c']);

        await pump(tester, code, const AgentsScreen());
        expect(
          tester.getTopLeft(find.text('Bravo')).dy,
          lessThan(tester.getTopLeft(find.text('Alpha')).dy),
        );
        expect(find.byIcon(Icons.push_pin), findsOneWidget);

        await tester.longPress(find.text('Alpha'));
        await tester.pump();
        expect(find.text(s.selectedCount(1)), findsOneWidget);
        expect(Selection.anyActive, isTrue);
        expect(find.byTooltip(s.chatPin), findsOneWidget);
        // Alpha's program runs: it can be stopped.
        expect(find.byTooltip(s.chatStop), findsOneWidget);
        expect(find.byTooltip(s.delete), findsOneWidget);

        // A tap picks now, rather than opening the chat.
        await tester.tap(find.text('Bravo'));
        await tester.pump();
        expect(find.text(s.selectedCount(2)), findsOneWidget);
        expect(find.byType(ChatScreen), findsNothing);
        expect(find.byTooltip(s.chatPin), findsOneWidget);

        await tester.tap(find.text('Alpha'));
        await tester.pump();
        // Only pinned ones left: they can be let go of; none to stop.
        expect(find.byTooltip(s.chatUnpin), findsOneWidget);
        expect(find.byTooltip(s.chatStop), findsNothing);

        await tester.tap(find.byTooltip(s.chatSelectAll));
        await tester.pump();
        expect(find.text(s.selectedCount(3)), findsOneWidget);
        expect(find.byTooltip(s.chatSelectAll), findsNothing);

        // Back puts them down, and stays on the tab.
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(find.text(s.agents), findsOneWidget);
        expect(Selection.anyActive, isFalse);
        expect(find.byTooltip(s.delete), findsNothing);
      });

      testWidgets('begins a subchat as its parent in ${S.names[code]}', (
        tester,
      ) async {
        final s = S.forCode(code);
        final now = DateTime.now();
        Agents.instance
          ..signedInForTest = true
          ..workers = [
            for (final (id, name) in [('w', 'desk'), ('x', 'laptop')])
              AgentWorker(
                id: id,
                name: name,
                home: '/home/someone',
                seenAt: now,
                dirs: const [],
                agents: [
                  AgentKind.fromJson({
                    'id': 'claude',
                    'label': 'Claude',
                    'models': ['opus', 'sonnet'],
                    'efforts': ['low', 'high'],
                    'permissions': ['auto', 'plan'],
                    'rules': true,
                    'talks': true,
                    'subchats': true,
                  }),
                  AgentKind.fromJson({
                    'id': 'shell',
                    'label': 'Shell',
                    'prompt': 'type',
                  }),
                ],
              ),
          ]
          ..rules = const [
            AgentRule(id: 'r', name: 'PR', body: 'Open a pull request.'),
            AgentRule(id: 'q', name: 'Quiet', body: 'Say little.'),
          ]
          ..chats = [
            Chat(
              id: 'p',
              workerId: 'x',
              agent: 'claude',
              title: 'Build the release',
              model: 'sonnet',
              effort: 'high',
              permission: 'plan',
              rules: const [(name: 'PR', body: 'Open a pull request.')],
              state: ChatState.finished,
              updatedAt: now,
              inChat: true,
            ),
          ];
        addTearDown(() {
          Agents.instance
            ..signedInForTest = null
            ..rules = const []
            ..workers = const []
            ..chats = const [];
        });
        await pump(tester, code, const NewChatScreen(parent: 'p'));
        // Tall enough to build the whole form.
        tester.view.physicalSize = const Size(960, 9000);
        await tester.pump();
        expect(find.text(s.newSubchat), findsOneWidget);
        expect(find.text('Build the release'), findsOneWidget);
        expect(find.text(s.subchatHint), findsOneWidget);
        expect(find.byType(TextField), findsOneWidget);
        // On its parent's computer and in its folder: neither is chosen.
        expect(find.text(s.chatWorker), findsNothing);
        expect(find.text(s.chatProject), findsNothing);
        // Not the shell, which would run the words it is told.
        expect(find.text('Shell'), findsNothing);
        // Its parent's choices, picked out.
        bool lit(String label) =>
            tester.widget<Text>(find.text(label)).style?.fontWeight ==
            FontWeight.w600;
        expect(lit('Claude'), isTrue);
        expect(lit('high'), isTrue);
        expect(lit('low'), isFalse);
        expect(lit('plan'), isTrue);
        expect(lit('auto'), isFalse);
        expect(lit('PR'), isTrue);
        expect(lit('Quiet'), isFalse);
      });

      testWidgets('lists subchats under their parent in ${S.names[code]}', (
        tester,
      ) async {
        final now = DateTime.now();
        Chat chat(String id, String title, {String? parent, int ago = 0}) =>
            Chat(
              id: id,
              workerId: 'w',
              agent: 'claude',
              title: title,
              parentId: parent,
              // Ended: nothing to size or read on a server.
              state: ChatState.ended,
              updatedAt: now.subtract(Duration(minutes: ago)),
            );
        Agents.instance
          ..signedInForTest = true
          ..workers = [
            AgentWorker(
              id: 'w',
              name: 'desk',
              seenAt: now,
              dirs: const [],
              agents: const [AgentKind(id: 'claude', label: 'Claude')],
            ),
          ]
          ..chats = Chat.listOrder([
            chat('a', 'Alpha', ago: 5),
            chat('b', 'Bravo', ago: 1),
            chat('a1', 'Alpha one', parent: 'a', ago: 3),
          ]);
        addTearDown(() {
          Agents.instance
            ..signedInForTest = null
            ..workers = const []
            ..chats = const [];
        });
        await pump(tester, code, const AgentsScreen());
        double top(String text) => tester.getTopLeft(find.text(text)).dy;
        double left(String text) => tester.getTopLeft(find.text(text)).dx;
        expect(top('Alpha one'), greaterThan(top('Alpha')));
        expect(left('Alpha one'), greaterThan(left('Alpha')));
        // Tied to its chat by a line, not an arrow.
        expect(
          find.byIcon(Icons.subdirectory_arrow_right_rounded),
          findsNothing,
        );
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is CustomPaint &&
                w.painter.runtimeType.toString() == '_FamilyPainter',
          ),
          findsOneWidget,
        );

        // Opened, a subchat names the chat it is part of, and that chat
        // its subchats.
        await pump(tester, code, const ChatScreen(chat: 'a1'));
        expect(find.text('Alpha'), findsOneWidget);
        await pump(tester, code, const ChatScreen(chat: 'a'));
        expect(find.text('Alpha one'), findsOneWidget);
      });
    }
  });

  group('subchats', () {
    test('are listed under their parents, a family where its first is', () {
      final now = DateTime.utc(2026, 11, 26);
      Chat chat(String id, ChatState state, int minutes, {String? parent}) =>
          Chat(
            id: id,
            agent: 'claude',
            state: state,
            parentId: parent,
            updatedAt: now.add(Duration(minutes: minutes)),
          );
      final family = Chat.families([
        chat('old', ChatState.finished, 0),
        chat('new', ChatState.finished, 9),
        chat('old.1', ChatState.finished, 1, parent: 'old'),
        chat('old.1.1', ChatState.asking, 2, parent: 'old.1'),
        chat('old.2', ChatState.finished, 3, parent: 'old'),
        chat('lost', ChatState.finished, 4, parent: 'deleted'),
      ]);
      expect(
        [for (final (c, depth) in family) '${c.id}:$depth'],
        [
          // Brought up by its grandchild, who asks for the user.
          'old:0',
          'old.2:1',
          'old.1:1',
          'old.1.1:2',
          'new:0',
          // A parent not listed: it stands alone.
          'lost:0',
        ],
      );
    });

    test('are deleted with their parents', () {
      final agents = Agents.instance;
      final now = DateTime.now();
      agents.chats = [
        for (final (id, parent) in [
          ('a', null),
          ('b', 'a'),
          ('c', 'b'),
          ('d', null),
          ('e', 'd'),
        ])
          Chat(
            id: id,
            agent: 'claude',
            parentId: parent,
            state: ChatState.idle,
            updatedAt: now,
          ),
      ];
      addTearDown(() => agents.chats = const []);
      expect([for (final c in agents.subchatsOf('a')) c.id], ['b', 'c']);
      expect(agents.subchatsOf('c'), isEmpty);
    });

    test("work in their parent's folder, told so", () {
      final ask = ChatAsk.fromJson({
        'id': '11111111-2222-3333-4444-555555555555',
        'agent': 'claude',
        'parent_id': 'abcdef12-0000-0000-0000-000000000000',
        'workspace': {
          'root': '/home/me/.local/share/caldo/work/abcdef12',
          'places': [
            {
              'source': '/home/me/dev/app',
              'path': '/home/me/.local/share/caldo/work/abcdef12/app',
              'branch': 'caldo/abcdef12',
            },
          ],
        },
      });
      // Not a folder of its own to make: its parent's, as it is.
      expect(ask.ownFolder, isFalse);
      expect(ask.parentId, 'abcdef12-0000-0000-0000-000000000000');
      expect(ask.dir, '/home/me/.local/share/caldo/work/abcdef12/app');
      expect(ask.rules, contains('subchat in Caldo'));
      expect(ask.rules, contains('chat abcdef12'));
      expect(ask.rules, contains('shared with it and its other subchats'));
      expect(ask.rules, contains('a branch of the chat this one is part of'));
      expect(ask.rules, isNot(contains('a folder of your own')));

      final own = ChatAsk.fromJson({
        'id': '11111111-2222-3333-4444-555555555555',
        'agent': 'claude',
        'workspace': <String, Object?>{},
      });
      expect(own.ownFolder, isTrue);
      expect(own.rules, isNull);
    });

    test("begin from their parent's session as one of their own", () {
      const claude = AgentSpec(
        id: 'claude',
        label: 'Claude',
        command: ['claude'],
      );
      const ask = ChatAsk(id: 'c', agent: 'claude');
      final argv = ClaudeTalk.argv(claude, ask, resume: 'parent', fork: true);
      final at = argv.indexOf('--resume');
      expect(argv.sublist(at, at + 3), [
        '--resume',
        'parent',
        '--fork-session',
      ]);
      expect(
        ClaudeTalk.argv(claude, ask, resume: 'own'),
        isNot(contains('--fork-session')),
      );
      expect(
        claudeChoices(claude, ask, fork: true),
        isNot(contains('--fork-session')),
      );
    });

    test('are offered by agents told so by their first message', () {
      Map<String, Object?> json(String id, String prompt) =>
          AgentSpec(id: id, label: id, command: [id], prompt: prompt).toJson();
      expect(json('claude', 'arg')['subchats'], isTrue);
      expect(json('llama', 'arg')['subchats'], isTrue);
      expect(json('shell', 'type')['subchats'], isFalse);
      expect(json('top', 'none')['subchats'], isFalse);
    });

    test("are told their parent's words when its session can't be theirs", () {
      final parent = {
        'id': 'abcdef12-0000-0000-0000-000000000000',
        'title': 'Release',
        'prompt': 'Ship 2.0',
      };
      final words = parentWords(parent, [
        {
          'kind': 'user',
          'body': {'text': 'Ship 2.0'},
        },
        {
          'kind': 'text',
          'body': {'text': 'Built it; the tests pass.'},
        },
        {
          'kind': 'user',
          'body': {
            'text': 'Review this.',
            'sender': {'chat': 'x', 'title': 'Reviewer'},
          },
        },
        {'kind': 'text', 'body': 'not a map'},
      ]);
      expect(words, contains('subchat of chat "Release" (abcdef12)'));
      expect(
        words,
        contains(
          'User: Ship 2.0\n\nAgent: Built it; the tests pass.\n\n'
          'Another chat: Review this.',
        ),
      );
      expect(words, isNot(contains('latest part')));

      final cut = parentWords(parent, [
        for (var i = 0; i < 10; i++)
          {
            'kind': 'text',
            'body': {'text': 'Line $i ${'x' * 100}'},
          },
      ], most: 350);
      expect(cut, contains('(its latest part)'));
      expect(cut, contains('Line 9'));
      expect(cut, isNot(contains('Line 6')));

      expect(
        parentWords(parent, const []),
        contains('Nothing was said there yet; it was begun with:\n\nShip 2.0'),
      );
      expect(withBefore('[Context]', 'Do it.'), '[Context]\n\nDo it.');
      expect(withBefore(null, 'Do it.'), 'Do it.');
    });
  });
}

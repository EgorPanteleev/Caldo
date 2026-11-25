import 'dart:convert';
import 'dart:io';

import 'package:caldo/l10n/strings.dart';
import 'package:caldo/mcp/accounts.dart';
import 'package:caldo/mcp/agents.dart';
import 'package:caldo/mcp/kept.dart';
import 'package:caldo/mcp/talk.dart';
import 'package:caldo/mcp/terminal.dart';
import 'package:caldo/mcp/usage.dart';
import 'package:caldo/mcp/worker.dart' show answerOf;
import 'package:caldo/models/task.dart';
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
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
        {'name': 'photo.jpg', 'mime': 'image/jpeg', 'size': 2202010},
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
      expect(argv[1], '-c');
      expect(argv[2], startsWith('developer_instructions='));
      expect(argv[2], endsWith('Be brief.'));
      expect(argv.last, 'Go');
      expect(
        launchOf(codex, ask, resume: 'th1'),
        containsAllInOrder(['resume', '-c', argv[2], 'th1']),
      );
      expect(
        launchOf(codex, const ChatAsk(id: 'x', agent: 'codex', prompt: 'Go')),
        ['codex', 'Go'],
      );

      const shell = AgentSpec(id: 'shell', label: 'Shell', command: ['bash']);
      expect(shell.takesRules, isFalse);
      expect(launchOf(shell, ask), ['bash']);
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

  group('the tab', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    tearDown(() {
      S.use('en');
      Agents.instance.workers = const [];
      Agents.instance.rules = const [];
      Agents.instance.accounts = const [];
    });

    Future<void> pump(WidgetTester tester, String code, Widget home) async {
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
          theme: AppTheme.dark(AppAccent.presets.first),
          home: home,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

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
        await pump(tester, code, const NewChatScreen());
        expect(find.text('opus'), findsOneWidget);
        // The form's list, not a field's own scroll inside it.
        final list = find.byType(Scrollable).first;
        await tester.scrollUntilVisible(
          find.text('~/dev/src/Caldo'),
          300,
          scrollable: list,
        );
        await tester.scrollUntilVisible(
          find.text(s.chatStart),
          300,
          scrollable: list,
        );
        expect(find.text(s.chatStart), findsOneWidget);
        expect(find.text(rule.name), findsOneWidget);
        expect(find.text(s.editRules), findsOneWidget);

        await pump(tester, code, const RulesScreen());
        expect(find.text(rule.name), findsOneWidget);
        await pump(tester, code, const RuleScreen(rule: rule));
        expect(find.text(s.ruleBody.toUpperCase()), findsOneWidget);
        Agents.instance.rules = const [];
        await pump(tester, code, const RulesScreen());
        expect(find.text(s.noRules), findsOneWidget);
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
        // Nothing changed: Save only goes back.
        await tester.ensureVisible(find.text(s.save));
        await tester.pumpAndSettle();
        await tester.tap(find.text(s.save));
        await tester.pumpAndSettle();
        expect(find.byType(ChatSettingsScreen), findsNothing);

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
        await pump(tester, code, const AccountsScreen());
        expect(
          find.text('someone.with.a.long.address@example.com'),
          findsOneWidget,
        );
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
                ),
              ),
            );
          }

          await show(said);
          final s = S.forCode(code);
          expect(find.text(s.chatAtLimit), findsOneWidget);
          // Not asked for until ticked.
          final box = find.textContaining(s.chatCarryOnAt('').split('(')[0]);
          expect(box, findsOneWidget);
          expect(asked, isEmpty);
          await tester.tap(box);
          expect(asked, ['l1']);

          // Once the user wrote again, it is only said.
          await show([
            ...said,
            const ChatItem(
              id: 'u2',
              seq: 2,
              kind: 'user',
              body: {'text': 'Well?'},
            ),
          ]);
          expect(find.text(s.chatAtLimit), findsOneWidget);
          expect(box, findsNothing);
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
          s.chatAsking,
          s.chatFinished,
        ]) {
          expect(find.textContaining('$word · '), findsOneWidget);
        }
        // A finished one is marked by a tick, not by a dot's shade.
        expect(find.byIcon(Icons.check_rounded), findsOneWidget);
        // Finished, it still takes a message: its program runs.
        expect(chat('d', 'Delta', ChatState.finished).live, isTrue);
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
          ..chats = Chat.pinnedFirst([
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
    }
  });
}

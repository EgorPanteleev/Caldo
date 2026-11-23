import 'dart:async';
import 'dart:math';

import 'package:caldo/mcp/chat_tools.dart';
import 'package:caldo/mcp/protocol.dart';
import 'package:caldo/mcp/tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// The server's chats, as a worker would keep them: [onSend] plays the
/// worker taking a message up.
class _Desk implements ChatDesk {
  final chats_ = <Map<String, dynamic>>[];
  final workers_ = <Map<String, dynamic>>[];
  final items_ = <String, List<Map<String, dynamic>>>{};
  final sent = <Map<String, Object?>>[];
  void Function(Map<String, Object?> row)? onSend;

  Map<String, dynamic> chat(String id) =>
      chats_.singleWhere((c) => c['id'] == id);

  void say(String chat, String id, String kind, Map body) {
    final list = items_.putIfAbsent(chat, () => []);
    list.add({'id': id, 'seq': list.length, 'kind': kind, 'body': body});
  }

  @override
  Future<List<Map<String, dynamic>>> chats() async => [
    for (final c in chats_) {...c},
  ];

  @override
  Future<List<Map<String, dynamic>>> workers() async => workers_;

  @override
  Future<List<Map<String, dynamic>>> items(
    String chat, {
    int? after,
    int? last,
  }) async {
    final all = items_[chat] ?? const [];
    if (last != null) return all.skip(max(0, all.length - last)).toList();
    return [
      for (final i in all)
        if ((i['seq'] as int) > (after ?? -1)) i,
    ];
  }

  @override
  Future<Map<String, dynamic>?> item(String chat, String id) async =>
      (items_[chat] ?? const []).where((i) => i['id'] == id).firstOrNull;

  @override
  Future<void> send(Map<String, Object?> row) async {
    sent.add(row);
    onSend?.call(row);
  }
}

void main() {
  late _Desk desk;
  late ChatTools tools;

  Future<String> run(String tool, Map<String, Object?> args) async {
    final server = McpServer(
      tools: tools.tools,
      name: 'caldo',
      version: 'test',
      instructions: ChatTools.instructions,
      before: () async {},
    );
    final answer = await server.call(
      tools.tools.singleWhere((t) => t.name == tool),
      args,
    );
    final text = ((answer['content'] as List).single as Map)['text'] as String;
    if (answer['isError'] == true) throw Refusal(text);
    return text;
  }

  setUp(() {
    desk = _Desk();
    desk.workers_.add({
      'id': 'w1',
      'name': 'desk',
      'seen_at': DateTime.now().toUtc().toIso8601String(),
      'agents': [
        {'id': 'claude', 'talks': true, 'chats': true},
        {'id': 'codex', 'talks': true},
        {'id': 'shell', 'label': 'Shell', 'chats': true},
      ],
    });
    desk.chats_.addAll([
      {
        'id': 'aaaa1111-0000',
        'title': 'Planner',
        'agent': 'claude',
        'model': 'opus',
        'state': 'idle',
        'mode': 'chat',
        'worker_id': 'w1',
      },
      {
        'id': 'bbbb2222-0000',
        'title': 'Tester',
        'agent': 'claude',
        'model': 'sonnet',
        'state': 'idle',
        'mode': 'chat',
        'dir': '/home/someone/dev',
        'worker_id': 'w1',
      },
      {
        'id': 'cccc3333-0000',
        'title': 'Old one',
        'agent': 'claude',
        'state': 'ended',
        'mode': 'chat',
        'worker_id': 'w1',
      },
      {
        'id': 'eeee5555-0000',
        'title': 'A shell',
        'agent': 'shell',
        'state': 'running',
        'mode': 'terminal',
        'worker_id': 'w1',
      },
      {
        'id': 'dddd4444-0000',
        'title': 'Codex',
        'agent': 'codex',
        'state': 'idle',
        'mode': 'chat',
        'worker_id': 'w1',
      },
    ]);
    tools = ChatTools(
      desk,
      self: 'aaaa1111-0000',
      poll: const Duration(milliseconds: 1),
    );
  });

  /// Plays the worker: the message said in [chat], a turn, [answer].
  void answers(String answer, {Duration after = Duration.zero}) {
    desk.onSend = (row) {
      final chat = row['chat_id'] as String;
      scheduleMicrotask(() async {
        desk.say(chat, 'u${row['key']}', 'user', {
          'text': row['data'],
          'sender': row['sender'],
        });
        desk.chat(chat)['state'] = 'running';
        await Future<void>.delayed(after);
        desk.say(chat, 't1', 'tool', {'name': 'Bash', 'line': 'flutter test'});
        desk.say(chat, 't2', 'text', {'text': answer});
        desk.chat(chat)['state'] = 'idle';
      });
    };
  }

  test(
    'lists the chats, marking this one and leaving ended ones out',
    () async {
      final list = await run('chats', {});
      expect(list, contains('[aaaa1111] Planner — claude opus, idle'));
      expect(list, contains('← this chat (you)'));
      expect(list, contains('[bbbb2222] Tester'));
      expect(list, contains('in /home/someone/dev'));
      expect(list, isNot(contains('Old one')));
      expect(await run('chats', {'include_ended': true}), contains('Old one'));
    },
  );

  test("waits for the other chat's answer and hands it back", () async {
    answers('All 443 pass.', after: const Duration(milliseconds: 20));
    final said = await run('message_chat', {
      'chat': 'bbbb',
      'message': 'Do the tests pass?',
    });
    expect(said, '"Tester" [bbbb2222] answered:\n\nAll 443 pass.');
    final row = desk.sent.single;
    expect(row['kind'], 'line');
    expect(row['data'], 'Do the tests pass?');
    expect(row['sender'], {
      'chat': 'aaaa1111-0000',
      'title': 'Planner',
      'waits': true,
    });

    // And the other chat reads as such from here.
    final read = await run('read_chat', {'chat': '[bbbb2222]'});
    expect(read, contains('Chat aaaa1111 (you): Do the tests pass?'));
    expect(read, contains('(tool: Bash flutter test)'));
    expect(read, contains('Agent: All 443 pass.'));
  });

  test('waits for a chat at work to finish before saying anything', () async {
    desk.chat('bbbb2222-0000')['state'] = 'running';
    answers('Done.');
    Timer(const Duration(milliseconds: 30), () {
      // Nothing is sent while it is busy: its words now are not the answer.
      expect(desk.sent, isEmpty);
      desk.chat('bbbb2222-0000')['state'] = 'idle';
    });
    expect(
      await run('message_chat', {'chat': 'bbbb', 'message': 'Next?'}),
      endsWith('Done.'),
    );
  });

  test('will not wait on a chat that waits on this one', () async {
    // Tester asked this chat and waits; asking it back would have each
    // wait out the other.
    desk.say('aaaa1111-0000', 'u1', 'user', {
      'text': 'Which branch?',
      'sender': {'chat': 'bbbb2222-0000', 'title': 'Tester', 'waits': true},
    });
    desk.chat('bbbb2222-0000')['state'] = 'running';
    await expectLater(
      run('message_chat', {'chat': 'bbbb', 'message': 'Which one?'}),
      throwsA(predicate((e) => '$e'.contains('waiting on your answer'))),
    );
    expect(desk.sent, isEmpty);
  });

  test('sends without waiting, and says so', () async {
    desk.chat('bbbb2222-0000')['state'] = 'running';
    final said = await run('message_chat', {
      'chat': 'bbbb',
      'message': 'FYI: main moved.',
      'wait': false,
    });
    expect(
      said,
      'Sent to "Tester" [bbbb2222]. Its answer stays in its chat '
      '(read_chat), or it may message you back.',
    );
    expect((desk.sent.single['sender'] as Map)['waits'], false);
  });

  test('refuses what cannot be answered', () async {
    Future<String> refusal(Map<String, Object?> args) => run('message_chat', {
      'message': 'Hi',
      ...args,
    }).then((_) => 'sent', onError: (Object e) => '$e');

    expect(await refusal({'chat': 'aaaa'}), contains('your own'));
    expect(await refusal({'chat': 'cccc'}), contains('has ended'));
    expect(await refusal({'chat': 'zzzz'}), contains('No chat with id zzzz'));
    // Its worker from before would pass the words off as the user's.
    expect(await refusal({'chat': 'dddd'}), contains('reinstall caldo-mcp'));
    expect(await refusal({'chat': 'eeee', 'wait': false}), contains('Shell'));
    desk.chat('bbbb2222-0000')['mode'] = 'terminal';
    expect(await refusal({'chat': 'bbbb'}), contains('in its terminal'));
    desk.workers_.single['seen_at'] = DateTime.now()
        .subtract(const Duration(minutes: 5))
        .toUtc()
        .toIso8601String();
    expect(await refusal({'chat': 'bbbb'}), contains('not online'));
    expect(desk.sent, isEmpty);
  });

  test('an assistant outside the chats signs as none', () async {
    tools = ChatTools(desk, self: null, poll: const Duration(milliseconds: 1));
    expect(await run('chats', {}), startsWith('You are not in one'));
    await run('message_chat', {'chat': 'bbbb', 'message': 'Hi', 'wait': false});
    expect(desk.sent.single['sender'], {
      'chat': null,
      'title': null,
      'waits': false,
    });
  });
}

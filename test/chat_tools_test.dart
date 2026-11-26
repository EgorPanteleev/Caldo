import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

  /// Run once what was asked for is read, as a worker writing between
  /// two reads would.
  void Function()? afterItems;

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
    final read = [
      for (final i in all)
        if ((i['seq'] as int) > (after ?? -1)) i,
    ];
    afterItems?.call();
    return read;
  }

  @override
  Future<Map<String, dynamic>?> item(String chat, String id) async =>
      (items_[chat] ?? const []).where((i) => i['id'] == id).firstOrNull;

  @override
  Future<void> send(Map<String, Object?> row) async {
    sent.add(row);
    onSend?.call(row);
  }

  final pictures = <(String, File, String, int, String)>[];

  @override
  Future<void> sendImage(
    String chat,
    File file, {
    required String mime,
    required int size,
    required String caption,
  }) async {
    pictures.add((chat, file, mime, size, caption));
  }

  final subs = <Map<String, dynamic>>[];

  @override
  Future<List<Map<String, dynamic>>> subscriptions() async => [
    for (final s in subs) {...s},
  ];

  @override
  Future<Map<String, dynamic>> subscribe(Map<String, Object?> row) async {
    final sub = {
      'id': subs.length + 1,
      'source': 'github_pulls',
      'created_at': DateTime.now().toUtc().toIso8601String(),
      ...row,
    };
    subs.add(sub);
    return sub;
  }

  @override
  Future<void> resubscribe(int id, Map<String, Object?> fields) async =>
      subs.singleWhere((s) => s['id'] == id).addAll(fields);

  @override
  Future<bool> unsubscribe(int id) async {
    final before = subs.length;
    subs.removeWhere((s) => s['id'] == id);
    return subs.length < before;
  }

  final pulls = <String, Map<String, dynamic>>{};

  @override
  Future<Map<String, dynamic>?> pullOpener(String repo, int number) async =>
      pulls['$repo#$number'];

  final told = <(String, String)>[];
  int phones = 1;

  @override
  Future<int> notify(String chat, String text) async {
    told.add((chat, text));
    return phones;
  }

  final projects_ = <Map<String, dynamic>>[];

  @override
  Future<List<Map<String, dynamic>>> projects() async => projects_;

  final savedBy = <String>[];

  @override
  Future<bool> setProjectInfo(
    String id,
    String context, {
    required int version,
    required String by,
  }) async {
    final p = projects_.firstWhere((p) => p['id'] == id);
    if ((p['version'] ?? 1) != version) return false;
    p['context'] = context;
    p['version'] = version + 1;
    savedBy.add(by);
    return true;
  }
}

/// [_Desk] whose project changes between the tool's read and its save.
class _StaleDesk extends _Desk {
  final _Desk of;

  _StaleDesk(this.of) {
    chats_.addAll(of.chats_);
    projects_.addAll(of.projects_);
  }

  @override
  Future<bool> setProjectInfo(
    String id,
    String context, {
    required int version,
    required String by,
  }) async => false;
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
        {
          'id': 'claude',
          'talks': true,
          'chats': true,
          'events': true,
          'clears': true,
          'pictures': true,
        },
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

  test('send_image sends a local picture to the current chat', () async {
    final dir = await Directory.systemTemp.createTemp('caldo-picture-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/Screenshot.png');
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
      '/x8AAwMCAO+jf2sAAAAASUVORK5CYII=',
    );
    await file.writeAsBytes(bytes);
    expect(
      await run('send_image', {'path': file.path, 'caption': ' Here it is '}),
      'Picture queued for this chat.',
    );
    final (chat, sent, mime, size, caption) = desk.pictures.single;
    expect(
      (chat, sent.path, mime, size, caption),
      ('aaaa1111-0000', file.path, 'image/png', bytes.length, 'Here it is'),
    );

    await file.writeAsString('A text file with a .png name');
    await expectLater(
      run('send_image', {'path': file.path}),
      throwsA(isA<Refusal>()),
    );
    expect(desk.pictures, hasLength(1));
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

  test('an answer written as the turn ends is not missed', () async {
    desk.onSend = (row) {
      final chat = row['chat_id'] as String;
      desk.say(chat, 'u${row['key']}', 'user', {'text': row['data']});
      desk.chat(chat)['state'] = 'running';
      // The turn, seen under way, ends just after the tool has read what
      // was said so far.
      var reads = 0;
      desk.afterItems = () {
        if (++reads < 3) return;
        desk.afterItems = null;
        desk.say(chat, 't1', 'text', {'text': 'Done.'});
        desk.chat(chat)['state'] = 'idle';
      };
    };
    final said = await run('message_chat', {
      'chat': 'bbbb',
      'message': 'Is it done?',
    });
    expect(said, '"Tester" [bbbb2222] answered:\n\nDone.');
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

  group('subscriptions', () {
    test('subscribe this chat to a repository, and change it again', () async {
      final made = await run('subscribe', {
        'repo': 'https://github.com/EgorPanteleev/Caldo/pull/3',
        'events': ['opened', 'pushed'],
        'note': 'Review it.',
      });
      expect(made, contains('Subscribed "Planner" [aaaa1111]'));
      expect(made, contains('pull requests in EgorPanteleev/Caldo (#1)'));
      expect(desk.subs.single, containsPair('chat_id', 'aaaa1111-0000'));
      expect(desk.subs.single['events'], ['opened', 'pushed']);
      expect(desk.subs.single['note'], 'Review it.');

      final again = await run('subscribe', {'repo': 'EgorPanteleev/Caldo'});
      expect(again, startsWith('Changed'));
      expect(desk.subs, hasLength(1));
      expect(desk.subs.single['events'], ['opened']);
      expect(desk.subs.single['note'], isNull);

      final listed = await run('subscriptions', {});
      expect(
        listed,
        '#1 [aaaa1111] Planner — pull requests in EgorPanteleev/Caldo: opened',
      );
      expect(await run('unsubscribe', {'id': 1}), 'Subscription #1 ended.');
      expect(desk.subs, isEmpty);
      expect(await run('subscriptions', {}), 'No subscriptions.');
    });

    test('another chat, and its folder\'s repository by default', () async {
      final made = await run('subscribe', {'chat': 'bbbb2222'});
      expect(made, contains("the chat's folder's repository"));
      expect(desk.subs.single['chat_id'], 'bbbb2222-0000');
      expect(desk.subs.single['target'], isNull);
    });

    test('an ended chat is told once it is started again', () async {
      final made = await run('subscribe', {'chat': 'cccc3333', 'repo': 'a/b'});
      expect(made, contains('told once the user starts it again'));
    });

    test('refuses what cannot be told', () async {
      Future<void> refused(Map<String, Object?> args, String why) =>
          expectLater(
            run('subscribe', args),
            throwsA(
              isA<Refusal>().having((r) => r.message, 'message', contains(why)),
            ),
          );
      await refused({'repo': 'not a repo'}, 'not a GitHub repository');
      await refused({
        'repo': 'a/b',
        'events': ['merged'],
      }, 'not merged');
      await refused({'repo': 'a/b', 'events': <String>[]}, 'Events are');
      await refused({'chat': 'eeee5555', 'repo': 'a/b'}, 'takes keys');
      // Its worker says nothing of watching: one from before.
      await refused({'chat': 'dddd4444', 'repo': 'a/b'}, 'reinstall');
      expect(desk.subs, isEmpty);
      await expectLater(run('unsubscribe', {'id': 9}), throwsA(isA<Refusal>()));
      tools = ChatTools(desk, poll: const Duration(milliseconds: 1));
      await refused({'repo': 'a/b'}, 'not in one of Caldo');
    });
  });

  group('project info', () {
    setUp(() {
      desk.projects_.addAll([
        {'id': 'p1aa', 'name': 'Caldo', 'context': 'Flutter.\nTests: 700.'},
        {'id': 'p2bb', 'name': 'Notes', 'context': ''},
      ]);
      desk.chats_.first['project_id'] = 'p1aa';
      tools = ChatTools(desk, self: 'aaaa1111-0000');
    });

    test("reads and changes this chat's project's, or one named", () async {
      expect(
        await run('project_info', {}),
        'Project "Caldo" [p1aa]:\n\nFlutter.\nTests: 700.',
      );
      expect(
        await run('project_info', {'project': 'notes'}),
        'Project "Notes" [p2bb]: no info written yet.',
      );
      expect(
        await run('update_project_info', {
          'old': 'Tests: 700.',
          'new': 'Tests: 712.',
        }),
        startsWith('Project "Caldo" info changed'),
      );
      expect(desk.projects_.first['context'], 'Flutter.\nTests: 712.');
      await run('update_project_info', {
        'project': 'p2bb',
        'text': '  A notebook.  ',
      });
      expect(desk.projects_.last['context'], 'A notebook.');
      expect(desk.savedBy, ['chat:aaaa1111-0000', 'chat:aaaa1111-0000']);
    });

    test('refuses a change made over one it has not seen', () async {
      tools = ChatTools(_StaleDesk(desk), self: 'aaaa1111-0000');
      expect(
        () => run('update_project_info', {'text': 'Mine.'}),
        throwsA(
          isA<Refusal>().having(
            (r) => r.message,
            'message',
            contains('changed meanwhile'),
          ),
        ),
      );
    });

    test('refuses what it cannot find', () async {
      expect(
        () => run('update_project_info', {'old': 'Tests: 1.', 'new': 'x'}),
        throwsA(isA<Refusal>()),
      );
      await run('update_project_info', {'text': 'a a'});
      expect(
        () => run('update_project_info', {'old': 'a', 'new': 'b'}),
        throwsA(
          isA<Refusal>().having((r) => r.message, 'message', contains('once')),
        ),
      );
      expect(
        () => run('project_info', {'project': 'Sync'}),
        throwsA(
          isA<Refusal>().having((r) => r.message, 'message', contains('Notes')),
        ),
      );
      tools = ChatTools(desk, self: 'bbbb2222-0000');
      expect(
        () => run('project_info', {}),
        throwsA(
          isA<Refusal>().having(
            (r) => r.message,
            'message',
            'This chat is in no project.',
          ),
        ),
      );
      tools = ChatTools(desk);
      expect(() => run('project_info', {}), throwsA(isA<Refusal>()));
    });
  });

  group('pull_chat', () {
    setUp(() {
      desk.pulls['EgorPanteleev/Caldo#27'] = {'chat_id': 'bbbb2222-0000'};
      desk.pulls['EgorPanteleev/Caldo#28'] = {'chat_id': 'aaaa1111-0000'};
      desk.pulls['EgorPanteleev/Caldo#29'] = {'chat_id': 'cccc3333-0000'};
      desk.pulls['EgorPanteleev/Caldo#30'] = {'chat_id': 'ffff6666-0000'};
      tools = ChatTools(
        desk,
        self: 'aaaa1111-0000',
        repoHere: () async => 'EgorPanteleev/Caldo',
      );
    });

    test('names the chat that opened a pull request', () async {
      expect(
        await run('pull_chat', {'number': 27}),
        'EgorPanteleev/Caldo#27 was opened by "Tester" [bbbb2222] — claude, '
        'idle. message_chat reaches it.',
      );
      expect(
        await run('pull_chat', {
          'repo': 'https://github.com/EgorPanteleev/Caldo/pull/28',
        }),
        endsWith('That is this chat, you.'),
      );
      expect(
        await run('pull_chat', {
          'number': '#29',
          'repo': 'EgorPanteleev/Caldo',
        }),
        endsWith('A message would start it again.'),
      );
      expect(await run('pull_chat', {'number': 30}), endsWith('gone now.'));
      expect(
        await run('pull_chat', {'number': 31}),
        startsWith('No chat is known to have opened EgorPanteleev/Caldo#31'),
      );
    });

    test('refuses without a number or with a bad repository', () async {
      for (final args in [
        <String, Object?>{},
        {'number': 3, 'repo': 'no such'},
      ]) {
        await expectLater(run('pull_chat', args), throwsA(isA<Refusal>()));
      }
    });
  });

  group('clear_context', () {
    test('this chat, by default: once its turn ends', () async {
      final said = await run('clear_context', {});
      expect(said, startsWith('Cleared once this turn ends'));
      expect(desk.sent.single['chat_id'], 'aaaa1111-0000');
      expect(desk.sent.single['kind'], 'clear');
      expect(desk.sent.single['key'], isA<String>());
    });

    test('another chat', () async {
      final said = await run('clear_context', {'chat': 'bbbb2222'});
      expect(said, startsWith('"Tester" [bbbb2222] will start afresh'));
      expect(desk.sent.single['chat_id'], 'bbbb2222-0000');
    });

    test('refuses what has nothing to clear, or cannot', () async {
      Future<void> refused(Map<String, Object?> args, String why) =>
          expectLater(
            run('clear_context', args),
            throwsA(
              isA<Refusal>().having((r) => r.message, 'message', contains(why)),
            ),
          );
      await refused({'chat': 'cccc3333'}, 'nothing to clear');
      await refused({'chat': 'eeee5555'}, 'no context to clear');
      // Its worker says nothing of clearing: one from before.
      await refused({'chat': 'dddd4444'}, 'reinstall');
      desk.chat('bbbb2222-0000')['mode'] = 'terminal';
      await refused({'chat': 'bbbb2222'}, 'type /clear there');
      expect(desk.sent, isEmpty);
      tools = ChatTools(desk, poll: const Duration(milliseconds: 1));
      await refused({}, 'not in one of Caldo');
    });
  });
  group('notify', () {
    test("tells the user's phones, from this chat", () async {
      final said = await run('notify', {'message': '  Released v2.24.0  '});
      expect(said, 'Sent to their phone.');
      expect(desk.told.single, ('aaaa1111-0000', 'Released v2.24.0'));
      desk.phones = 0;
      expect(
        await run('notify', {'message': 'Again'}),
        contains('nothing was sent'),
      );
    });

    test('refuses nothing to say, or no chat to open', () async {
      Future<void> refused(String why) => expectLater(
        run('notify', {'message': 'Hi'}),
        throwsA(
          isA<Refusal>().having((r) => r.message, 'message', contains(why)),
        ),
      );
      await expectLater(
        run('notify', {'message': ' '}),
        throwsA(isA<Refusal>()),
      );
      tools = ChatTools(desk, poll: const Duration(milliseconds: 1));
      await refused("Only an agent in one of Caldo's chats");
      expect(desk.told, isEmpty);
    });
  });
}

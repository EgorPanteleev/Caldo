import 'dart:io';

import 'package:caldo/mcp/tools.dart';
import 'package:caldo/mcp/watch.dart';
import 'package:caldo/models/task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_remote.dart';
import 'support/fake_server.dart';
import 'support/test_db.dart';

void main() {
  setUpAll(initTestDatabase);

  late FakeServer server;
  late Phone phone;
  late Caldo caldo;
  late Directory scratch;
  late List<Errand> asked;

  /// What Claude answers next, and what the phone does while it works.
  late Answer Function(Errand errand) answer;
  Future<void> Function()? meanwhile;

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  Watcher watcher() => Watcher(
    caldo: caldo,
    dir: scratch.path,
    state: WatchState(File('${scratch.path}/watch.json')),
    log: (_) {},
    hand: (errand) async {
      asked.add(errand);
      final then = meanwhile;
      meanwhile = null;
      await then?.call();
      return answer(errand);
    },
  );

  Future<void> add(
    String title, {
    String? claude = 'opus',
    DateTime? due,
    bool hasTime = false,
    String notes = '',
    int? startedAt,
    bool done = false,
  }) => phone.db.insert(
    Task(
      listId: 1,
      claude: claude,
      title: title,
      notes: notes,
      dueAt: due?.millisecondsSinceEpoch,
      hasTime: hasTime,
      startedAt: startedAt,
      done: done,
      createdAt: now.millisecondsSinceEpoch,
    ),
  );

  setUp(() async {
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase('$dir/watch_phone.db');
    server = FakeServer();
    phone = Phone('watch_phone.db', server);
    await phone.round();
    caldo = Caldo(FakeRemote(server));
    scratch = Directory.systemTemp.createTempSync('caldo_watch');
    asked = [];
    answer = (_) => const Answer(true, 'Done it.', session: 's1');
    meanwhile = null;
  });

  tearDown(() async {
    await phone.db.close();
    scratch.deleteSync(recursive: true);
  });

  test('a task handed to Claude is worked on, answered and ticked', () async {
    await add('Tidy the downloads', notes: 'Only the PDFs', claude: 'sonnet');
    await phone.round();

    Task? during;
    meanwhile = () async {
      await phone.round();
      during = await phone.named('Tidy the downloads');
    };
    expect(await watcher().once(), 1);

    // The phone's board showed it In progress while Claude worked.
    expect(during!.stage, Stage.inProgress);
    expect(asked.single.prompt, contains('Task: Tidy the downloads'));
    expect(asked.single.prompt, contains('Only the PDFs'));
    expect(asked.single.dir, scratch.path);
    expect(asked.single.model, 'sonnet');
    expect(asked.single.resume, isNull);

    await phone.round();
    final after = await phone.named('Tidy the downloads');
    expect(after.done, isTrue);
    expect(after.notes, startsWith('Only the PDFs\n\n— Claude, '));
    expect(after.notes, endsWith('—\nDone it.'));
    // Ticked as the app ticks: a line in the Done log.
    expect(await phone.count('select count(*) from completions'), 1);
  });

  test('only what is handed over, waiting and due, is taken up', () async {
    await add('Not for Claude', claude: null);
    await add('Tomorrow', due: today.add(const Duration(days: 1)));
    await add(
      'Later today',
      due: now.add(const Duration(hours: 1)),
      hasTime: true,
    );
    await add('Under way', startedAt: 1);
    await add('Finished', done: true);
    await add('Today', due: today);
    await add('Overdue', due: today.subtract(const Duration(days: 2)));
    await phone.round();

    expect(await watcher().once(), 2);
    expect(asked.map((e) => e.prompt.split('Task: ').last.split('\n').first), [
      'Overdue',
      'Today',
    ]);
  });

  test(
    'a task not done stays In progress; handed back, its session goes on',
    () async {
      await add('Fix the build', notes: 'in: ${Directory.systemTemp.path}');
      await phone.round();
      answer = (_) => const Answer(
        false,
        'The tests need a database.',
        session: 's1',
        refused: ['Bash', 'Bash'],
      );
      final w = watcher();
      expect(await w.once(), 1);
      expect(asked.single.dir, Directory.systemTemp.path);

      await phone.round();
      var task = await phone.named('Fix the build');
      expect(task.stage, Stage.inProgress);
      expect(task.notes, contains('The tests need a database.'));
      expect(task.notes, contains('Not allowed: Bash.'));
      expect(task.notes, contains('Move it back to Not started'));
      // Left alone while it stays there.
      expect(await w.once(), 0);

      // The user adds a word and moves it back.
      await phone.db.update(
        task
            .toStage(Stage.notStarted, 0)
            .copyWith(notes: '${task.notes}\n\nUse sqlite.'),
      );
      await phone.round();
      answer = (_) => const Answer(true, 'Fixed.', session: 's1');
      expect(await w.once(), 1);
      expect(asked.last.resume, 's1');
      expect(asked.last.prompt, contains('Use sqlite.'));

      await phone.round();
      task = await phone.named('Fix the build');
      expect(task.done, isTrue);
      expect(task.notes, endsWith('—\nFixed.'));
    },
  );

  test('a folder that is not there is said, not worked in', () async {
    await add('Somewhere', notes: 'in: /no/such/folder');
    await phone.round();
    expect(await watcher().once(), 1);
    expect(asked, isEmpty);
    await phone.round();
    final task = await phone.named('Somewhere');
    expect(task.stage, Stage.inProgress);
    expect(task.notes, contains('There is no folder /no/such/folder'));
  });

  test('a task left In progress by a stopped watcher is noted', () async {
    await add('Cut short');
    await phone.round();
    // Claude is never heard back from: the watcher stops part way.
    final first = watcher();
    await caldo.refresh();
    final held = caldo.book.tasks.single;
    await caldo.setStage({'id': held.uuid, 'stage': 'in_progress'});
    first.state
      ..running = held.uuid
      ..save();

    final again = watcher();
    await again.recover();
    expect(again.state.running, isNull);
    await phone.round();
    final task = await phone.named('Cut short');
    expect(task.stage, Stage.inProgress);
    expect(task.notes, contains('Interrupted'));
  });
}

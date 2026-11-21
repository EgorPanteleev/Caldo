import 'dart:convert';

import 'package:caldo/db/database.dart';
import 'package:caldo/db/sync_store.dart';
import 'package:caldo/mcp/book.dart';
import 'package:caldo/mcp/protocol.dart';
import 'package:caldo/mcp/tools.dart';
import 'package:caldo/models/special_day.dart';
import 'package:caldo/models/task.dart';
import 'package:caldo/models/task_list.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_remote.dart';
import 'support/fake_server.dart';
import 'support/test_db.dart';

void main() {
  setUpAll(initTestDatabase);

  late FakeServer server;
  late FakeRemote remote;
  late Phone phone;
  late Caldo caldo;

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  DateTime dayAfter(int n) => DateTime(today.year, today.month, today.day + n);
  String iso(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Runs [tool] as Claude would, and says what it answered.
  Future<String> run(
    String tool, [
    Map<String, Object?> args = const {},
  ]) async {
    final server = McpServer(
      tools: caldo.tools,
      name: 'caldo',
      version: 'test',
      instructions: Caldo.instructions,
      before: caldo.refresh,
    );
    final answer = await server.call(
      caldo.tools.singleWhere((t) => t.name == tool),
      args,
    );
    final text = ((answer['content'] as List).single as Map)['text'] as String;
    if (answer['isError'] == true) throw Refusal(text);
    return text;
  }

  /// The id the MCP server shows for the task called [title].
  String idOf(String title) =>
      caldo.book.tasks.singleWhere((h) => h.task.title == title).id;

  setUp(() async {
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase('$dir/mcp_phone.db');
    server = FakeServer();
    remote = FakeRemote(server);
    phone = Phone('mcp_phone.db', server);
    // The phone has been signed in: its default group is on the server.
    await phone.round();
    caldo = Caldo(remote);
  });

  tearDown(() => phone.db.close());

  test('the default group is the one every device shares', () {
    expect(Book.homeUuid, AppDatabase.defaultListUuid);
  });

  test(
    'a task added here arrives on the phone as the app writes one',
    () async {
      final work = await phone.db.insertList(
        TaskList(name: 'Work', styleId: 'teal', createdAt: 1),
      );
      await phone.round();

      await run('add_task', {
        'title': 'Dentist',
        'date': iso(dayAfter(2)),
        'time': '15:00',
        'end': '16:30',
        'priority': 'high',
        'checklist': ['Insurance card', 'Questions'],
        'remind_before_minutes': 30,
      });
      await run('add_task', {
        'title': 'Report',
        'group': 'work',
        'date': iso(dayAfter(1)),
        'repeat': 'FREQ=WEEKLY;BYDAY=1,4',
        'notes': 'Q4 figures',
      });
      await run('add_task', {'title': 'Someday'});
      await phone.round();

      final dentist = await phone.named('Dentist');
      expect(
        dentist.due,
        DateTime(dayAfter(2).year, dayAfter(2).month, dayAfter(2).day, 15),
      );
      expect(dentist.hasTime, isTrue);
      expect(dentist.duration, 90);
      expect(dentist.priority, Priority.high);
      expect(dentist.subtasks.map((s) => s.title), [
        'Insurance card',
        'Questions',
      ]);
      expect(dentist.remindBefore, 30);
      expect(dentist.listId, 1);

      // All day: the phone's own midnight of that day.
      final report = await phone.named('Report');
      expect(report.due, dayAfter(1));
      expect(report.hasTime, isFalse);
      expect(report.listId, work.id);
      expect(
        report.repeat,
        const Repeat(unit: RepeatUnit.week, weekdays: {1, 4}),
      );
      expect(report.notes, 'Q4 figures');

      expect((await phone.named('Someday')).dueAt, isNull);
    },
  );

  test('a task handed to Claude here is handed over on the phone', () async {
    await run('add_task', {'title': 'Tidy the downloads', 'claude': 'haiku'});
    await phone.round();
    expect((await phone.named('Tidy the downloads')).claude, 'haiku');
    expect(
      await run('task', {'id': idOf('Tidy the downloads')}),
      contains('Handed to Claude: haiku'),
    );

    await run('update_task', {
      'id': idOf('Tidy the downloads'),
      'claude': 'none',
    });
    await phone.round();
    expect((await phone.named('Tidy the downloads')).claude, isNull);
    await expectLater(
      run('update_task', {'id': idOf('Tidy the downloads'), 'claude': 'gpt'}),
      throwsA(isA<Refusal>()),
    );
  });

  test('the agenda reads what the phone has, day by day', () async {
    final at = DateTime.now().millisecondsSinceEpoch;
    await phone.db.insert(
      Task(
        listId: 1,
        title: 'Late',
        dueAt: dayAfter(-3).millisecondsSinceEpoch,
        createdAt: at,
      ),
    );
    await phone.db.insert(
      Task(
        listId: 1,
        title: 'Shop',
        dueAt: today.millisecondsSinceEpoch,
        createdAt: at,
      ),
    );
    await phone.db.insert(
      Task(
        listId: 1,
        title: 'Call',
        dueAt: dayAfter(1).add(const Duration(hours: 9)).millisecondsSinceEpoch,
        hasTime: true,
        createdAt: at,
      ),
    );
    await phone.db.insertSpecialDay(
      SpecialDay(
        name: 'Mum',
        month: dayAfter(1).month,
        day: dayAfter(1).day,
        year: 1960,
      ),
    );
    await phone.round();

    final agenda = await run('agenda');
    final lines = agenda.split('\n');
    int lineOf(String text) => lines.indexWhere((l) => l.contains(text));

    expect(lineOf('Overdue'), lessThan(lineOf('Late')));
    expect(lineOf('Late'), lessThan(lineOf('(today)')));
    expect(lineOf('(today)'), lessThan(lineOf('Shop')));
    expect(lineOf('Shop'), lessThan(lineOf('Mum')));
    expect(lines[lineOf('Call')], contains('09:00 Call'));
    expect(lines[lineOf('Mum')], contains('turns ${dayAfter(1).year - 1960}'));
  });

  test(
    'a tick here is the app\'s tick: logged, and a repeat rolls on',
    () async {
      final at = DateTime.now().millisecondsSinceEpoch;
      await phone.db.insert(
        Task(
          listId: 1,
          title: 'Once',
          dueAt: today.millisecondsSinceEpoch,
          createdAt: at,
        ),
      );
      await phone.db.insert(
        Task(
          listId: 1,
          title: 'Plants',
          dueAt: today.millisecondsSinceEpoch,
          repeat: Repeat.weekly,
          subtasks: const [Subtask('Ficus', done: true)],
          createdAt: at,
        ),
      );
      await phone.round();
      await caldo.refresh();

      expect(
        await run('complete_task', {'id': idOf('Once')}),
        contains('Ticked off'),
      );
      final rolled = await run('complete_task', {'id': '[${idOf('Plants')}]'});
      expect(rolled, contains(iso(dayAfter(7))));
      await phone.round();

      expect((await phone.named('Once')).done, isTrue);
      final plants = await phone.named('Plants');
      expect(plants.done, isFalse);
      expect(plants.dueDay, dayAfter(7));
      expect(plants.subtasks.single.done, isFalse);
      expect(await phone.count('SELECT COUNT(*) FROM completions'), 2);

      // Out of Done takes the tick back, and its line in the log.
      await run('set_stage', {'id': idOf('Once'), 'stage': 'in_progress'});
      await phone.round();
      final once = await phone.named('Once');
      expect(once.done, isFalse);
      expect(once.stage, Stage.inProgress);
      expect(await phone.count('SELECT COUNT(*) FROM completions'), 1);
    },
  );

  test('an edit sends only what it changed', () async {
    final at = DateTime.now().millisecondsSinceEpoch;
    final task = await phone.db.insert(
      Task(
        listId: 1,
        title: 'Draft',
        dueAt: today.millisecondsSinceEpoch,
        createdAt: at,
      ),
    );
    await phone.round();
    await caldo.refresh();

    // The phone renames it, and has not synced when the notes are written.
    await Future.delayed(const Duration(milliseconds: 5));
    await phone.db.update(task.copyWith(title: 'Draft letter'));
    await phone.round();
    await run('update_task', {
      'id': idOf('Draft'),
      'append_notes': 'Ask about the deposit.',
      'date': iso(dayAfter(3)),
    });
    await phone.round();

    final got = await phone.named('Draft letter');
    expect(got.notes, 'Ask about the deposit.');
    expect(got.dueDay, dayAfter(3));
  });

  test('an edit that lost to another device says so', () async {
    final at = DateTime.now().millisecondsSinceEpoch;
    await phone.db.insert(Task(listId: 1, title: 'Race', createdAt: at));
    await phone.round();
    await caldo.refresh();
    final uuid = caldo.book.tasks.single.uuid;

    remote.meanwhile = () => server.push([
      SyncRow(
        table: 'tasks',
        uuid: uuid,
        data: const {'title': 'Race won'},
        updatedAt: DateTime.now().millisecondsSinceEpoch + 60000,
      ),
    ]);
    await expectLater(
      run('update_task', {'id': idOf('Race'), 'title': 'Race lost'}),
      throwsA(isA<Refusal>()),
    );
  });

  test('a deletion reaches the phone', () async {
    await phone.db.insert(Task(listId: 1, title: 'Gone', createdAt: 1));
    await phone.round();
    await caldo.refresh();

    await run('delete_task', {'id': idOf('Gone')});
    await phone.round();

    expect(
      await phone.count("SELECT COUNT(*) FROM tasks WHERE title = 'Gone'"),
      0,
    );
  });

  test('a special day added here is on the phone', () async {
    await run('add_special_day', {
      'name': 'Anna',
      'month': 2,
      'day': 29,
      'year': 1992,
    });
    await phone.round();

    final day = (await phone.db.getSpecialDays()).single;
    expect(day.name, 'Anna');
    expect((day.month, day.day, day.year), (2, 29, 1992));
    expect(day.kind, SpecialKind.birthday);
    expect(day.styleId, 'pink');
  });

  test('ids, groups and words that do not fit are turned down', () async {
    await phone.db.insert(Task(listId: 1, title: 'One', createdAt: 1));
    await phone.round();

    for (final (tool, args) in [
      ('task', {'id': 'ffffffff'}),
      ('add_task', {'title': 'X', 'group': 'Nowhere'}),
      ('add_task', {'title': 'X', 'time': '10:00'}),
      ('add_task', {'title': 'X', 'date': '2026-02-30'}),
      ('add_task', {'title': 'X', 'date': 'today', 'repeat': 'sometimes'}),
      (
        'add_task',
        {'title': 'X', 'date': 'today', 'time': '10:00', 'end': '09:00'},
      ),
    ]) {
      await expectLater(
        run(tool, args),
        throwsA(isA<Refusal>()),
        reason: '$tool $args',
      );
    }
    expect(await phone.count('SELECT COUNT(*) FROM tasks'), 1);
  });

  test('speaks MCP over stdio', () async {
    final mcp = McpServer(
      tools: caldo.tools,
      name: 'caldo',
      version: 'test',
      instructions: Caldo.instructions,
      before: caldo.refresh,
    );
    final said = <Map<String, Object?>>[];
    final lines = [
      {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': '2025-06-18', 'capabilities': {}},
      },
      {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
      {
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {'name': 'groups', 'arguments': {}},
      },
      {'jsonrpc': '2.0', 'id': 4, 'method': 'nope'},
    ].map((m) => '${jsonEncode(m)}\n');
    await mcp.serve(
      Stream.fromIterable([utf8.encode(lines.join())]),
      (line) => said.add(jsonDecode(line) as Map<String, Object?>),
    );

    expect(said.map((m) => m['id']), [1, 2, 3, 4]);
    expect((said[0]['result'] as Map)['protocolVersion'], '2025-06-18');
    final tools = ((said[1]['result'] as Map)['tools'] as List).cast<Map>();
    expect(tools.map((t) => t['name']), contains('agenda'));
    final answer = said[2]['result'] as Map;
    expect(answer['isError'], isFalse);
    expect(
      ((answer['content'] as List).single as Map)['text'],
      contains('Personal (default)'),
    );
    expect((said[3]['error'] as Map)['code'], -32601);
  });
}

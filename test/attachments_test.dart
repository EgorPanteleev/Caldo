import 'dart:io';

import 'package:caldo/db/database.dart';
import 'package:caldo/l10n/strings.dart';
import 'package:caldo/models/task.dart';
import 'package:caldo/models/task_list.dart';
import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/screens/task_edit_screen.dart';
import 'package:caldo/services/attachments.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/widgets/attachments_field.dart';
import 'package:caldo/widgets/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/test_db.dart';

/// Keeps what the form would have written instead of writing it.
class _Capture extends TaskProvider {
  Task? added;
  Task? updated;

  @override
  Future<void> add(Task task) async => added = task;

  @override
  Future<void> update(Task task) async => updated = task;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(initTestDatabase);

  setUp(resetTestDatabase);

  tearDown(() => Attachments.instance.dir = null);

  const receipt = Attachment(
    file: 'a1/Receipt.pdf',
    name: 'Receipt.pdf',
    mime: 'application/pdf',
    size: 2400000,
  );
  const fence = Attachment(
    file: 'b2/IMG_20261113_101500.jpg',
    name: 'IMG_20261113_101500.jpg',
    mime: 'image/jpeg',
    size: 3100000,
  );

  test('attachments are stored with their task and read back', () async {
    final db = AppDatabase.instance;
    await db.insert(
      const Task(
        listId: 1,
        title: 'Fence',
        createdAt: 0,
        attachments: [receipt, fence],
      ),
    );

    final read = (await db.getTasks()).single;
    expect(read.attachments, [receipt, fence]);
    expect(read.attachments.map((a) => a.isImage), [false, true]);
  });

  test('attachments that cannot be read leave the task readable', () {
    final task = Task.fromMap({
      'id': 1,
      'title': 'Fence',
      'created_at': 0,
      'attachments': '{"not": "a list"}',
    });
    expect(task.title, 'Fence');
    expect(task.attachments, isEmpty);
    // One without a file to name is no attachment; the rest still are.
    final some = Task.fromMap({
      'id': 1,
      'title': 'Fence',
      'created_at': 0,
      'attachments': '[{"name": "lost"}, {"file": "c3"}]',
    });
    expect(some.attachments.single.file, 'c3');
  });

  test('search finds a task by an attachment\'s name', () async {
    final db = AppDatabase.instance;
    await db.insert(
      const Task(
        listId: 1,
        title: 'Fence',
        createdAt: 0,
        attachments: [receipt],
      ),
    );
    await db.insert(const Task(listId: 1, title: 'Call mum', createdAt: 1));

    expect((await db.getTasks(query: 'receipt')).map((t) => t.title), [
      'Fence',
    ]);
    // Stored as JSON: its keys and the copy's own name are not words in it.
    expect(await db.getTasks(query: 'mime'), isEmpty);
    expect(await db.getTasks(query: 'a1/'), isEmpty);
  });

  test('a repeating task comes round again with what is attached', () {
    final task = Task(
      id: 1,
      listId: 1,
      title: 'Pay rent',
      createdAt: 0,
      dueAt: DateTime(2026, 11, 1).millisecondsSinceEpoch,
      repeat: Repeat.monthly,
      attachments: const [receipt],
    );
    final next = task.completed(0);
    expect(next.due, DateTime(2026, 12, 1));
    expect(next.attachments, [receipt]);
  });

  test('the sweep lets go of copies no task refers to', () async {
    final dir = Directory.systemTemp.createTempSync('caldo_attachments');
    addTearDown(() => dir.deleteSync(recursive: true));
    Attachments.instance.dir = dir.path;
    final now = DateTime(2026, 11, 13, 12);
    final old = now.subtract(const Duration(days: 2));
    File made(String path, DateTime at) => File('${dir.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync('x')
      ..setLastModifiedSync(at);
    final kept = made('a1/Receipt.pdf', old);
    final orphan = made('dead/IMG_1.jpg', old);
    // Picked into a form a moment ago, and not saved yet.
    final fresh = made(
      'new/IMG_2.jpg',
      now.subtract(const Duration(minutes: 5)),
    );

    await Attachments.instance.sweepAgainst(const [
      Task(listId: 1, title: 'Fence', createdAt: 0, attachments: [receipt]),
    ], now: now);

    expect(kept.existsSync(), isTrue);
    expect(orphan.existsSync(), isFalse);
    // Its folder goes with it.
    expect(orphan.parent.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
  });

  test('sizes are written as the pickers write them', () {
    final s = S.forCode('en');
    expect(sizeText(s, 900), '1 KB');
    expect(sizeText(s, 340 * 1024), '340 KB');
    expect(sizeText(s, 2516582), '2.4 MB');
    expect(sizeText(s, 31 * 1024 * 1024), '31 MB');
  });

  testWidgets('a card marks what is attached, with how many', (tester) async {
    Widget card(List<Attachment> attachments) => MaterialApp(
      theme: AppTheme.dark(AppAccent.presets.first),
      home: Scaffold(
        body: TaskCard(
          task: Task(
            id: 1,
            listId: 1,
            title: 'Fence',
            createdAt: 0,
            attachments: attachments,
          ),
          list: TaskList(id: 1, name: 'Work', createdAt: 0),
          onTap: () {},
          onToggle: () {},
        ),
      ),
    );

    await tester.pumpWidget(card(const []));
    expect(find.byKey(attachmentMarkKey), findsNothing);

    await tester.pumpWidget(card(const [receipt]));
    expect(find.byKey(attachmentMarkKey), findsOneWidget);
    expect(find.text('1'), findsNothing);

    await tester.pumpWidget(card(const [receipt, fence]));
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('the form attaches what is picked, and takes it off again', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('caldo_attachments');
    addTearDown(() => dir.deleteSync(recursive: true));
    Attachments.instance.dir = dir.path;
    File('${dir.path}/a1/Receipt.pdf')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(2048, 0));

    const channel = MethodChannel('caldo/attachments');
    final messenger = tester.binding.defaultBinaryMessenger;
    String? from;
    messenger.setMockMethodCallHandler(channel, (call) async {
      from = (call.arguments as Map)['from'] as String?;
      return {
        'attached': [receipt.toJson()],
        'tooBig': <String>[],
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final capture = _Capture();
    tester.view.physicalSize = const Size(960, 1920);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<TaskProvider>.value(value: capture),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(AppAccent.presets.first),
          home: const TaskEditScreen(
            task: Task(
              id: 7,
              listId: 1,
              title: 'Fence',
              createdAt: 0,
              // A photo whose copy never came to this phone.
              attachments: [fence],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The photo is drawn as missing rather than failing the form.
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);

    await tester.ensureVisible(find.text('File'));
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    expect(from, 'files');
    expect(find.text('Receipt.pdf'), findsOneWidget);
    // Its copy is here, so it says how big it is rather than that it is
    // missing.
    expect(find.text('2.3 MB'), findsOneWidget);

    // Off with the photo, and save.
    // In the middle of the screen, clear of the app bar.
    Scrollable.ensureVisible(
      tester.element(find.byIcon(Icons.broken_image_outlined)),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(capture.updated?.attachments, [receipt]);
  });
}

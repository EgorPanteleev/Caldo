import 'dart:io';

import 'package:caldo/l10n/strings.dart';
import 'package:caldo/main.dart';
import 'package:caldo/models/task.dart';
import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/screens/home_screen.dart';
import 'package:caldo/services/attachments.dart';
import 'package:caldo/services/desktop.dart';
import 'package:caldo/services/updates.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/utils/platform.dart';
import 'package:caldo/widgets/attachments_field.dart';
import 'package:caldo/widgets/quick_add_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_db.dart';

/// The desktop's side of Caldo: what the app does for itself on Linux that
/// Android's activity does for it on a phone, and the few places a screen
/// has to know there is no soft keyboard and no camera.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    initTestDatabase();
    await initializeDateFormatting();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
  });

  tearDown(KeyboardGap.instance.forget);

  /// Just Linux: the tests are told they are on Android unless they say.
  final linux = TargetPlatformVariant.only(TargetPlatform.linux);

  group('files', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('caldo_desktop'));
    tearDown(() => dir.deleteSync(recursive: true));

    File make(String name, [int bytes = 4]) =>
        File(p.join(dir.path, 'from', name))
          ..createSync(recursive: true)
          ..writeAsBytesSync(List.filled(bytes, 7));

    test('a picked file is copied into a folder of its own, by name', () async {
      final store = p.join(dir.path, 'attachments');
      final photo = make('Fence.JPG', 10);
      final same = make('more/Fence.JPG', 20);
      final picked = await Desktop.attach([photo.path, same.path], into: store);

      expect(picked.tooBig, isEmpty);
      expect(picked.attached, hasLength(2));
      final [first, second] = picked.attached;
      expect(first.name, 'Fence.JPG');
      expect(first.mime, 'image/jpeg');
      expect(first.size, 10);
      expect(p.basename(first.file), 'Fence.JPG', reason: 'kept by its name');
      // Two of one name do not land on each other.
      expect(p.dirname(first.file), isNot(p.dirname(second.file)));
      expect(File(p.join(store, first.file)).lengthSync(), 10);
      expect(File(p.join(store, second.file)).lengthSync(), 20);
      // The original is left where it was.
      expect(photo.existsSync(), isTrue);
    });

    test(
      'one too big is named and left out, one missing is passed over',
      () async {
        final store = p.join(dir.path, 'attachments');
        final film = make('film.mp4', 64);
        final note = make('note.txt', 8);
        final picked = await Desktop.attach(
          [film.path, p.join(dir.path, 'gone.pdf'), note.path],
          into: store,
          limit: 32,
        );
        expect(picked.tooBig, ['film.mp4']);
        expect([for (final a in picked.attached) a.name], ['note.txt']);
      },
    );

    test('only what Flutter can draw is called an image', () {
      expect(Desktop.mimeOf('a.png'), 'image/png');
      expect(Desktop.mimeOf('A.JPEG'), 'image/jpeg');
      expect(Desktop.mimeOf('scan.pdf'), 'application/pdf');
      // A thumbnail of either would be a broken tile.
      expect(Desktop.mimeOf('raw.heic'), 'application/octet-stream');
      expect(Desktop.mimeOf('logo.svg'), 'application/octet-stream');
      expect(Desktop.mimeOf('Makefile'), 'application/octet-stream');
    });

    test(
      'an automatic backup keeps the latest few and nothing else\'s',
      () async {
        final folder = Directory(p.join(dir.path, 'backups'))..createSync();
        for (var day = 1; day <= 8; day++) {
          File(
            p.join(folder.path, 'caldo-auto-2026-10-0$day.json'),
          ).writeAsStringSync('{}');
        }
        final byHand = File(p.join(folder.path, 'caldo-2026-01-01.json'))
          ..writeAsStringSync('mine');

        await Desktop.writeInto(
          folder.path,
          'caldo-auto-2026-11-15.json',
          'caldo-auto-',
          '{"app":"caldo"}',
          7,
        );

        final left = [for (final f in folder.listSync()) p.basename(f.path)]
          ..sort();
        expect(left, [
          'caldo-2026-01-01.json',
          for (var day = 3; day <= 8; day++) 'caldo-auto-2026-10-0$day.json',
          'caldo-auto-2026-11-15.json',
        ]);
        expect(byHand.readAsStringSync(), 'mine');
        expect(
          File(
            p.join(folder.path, 'caldo-auto-2026-11-15.json'),
          ).readAsStringSync(),
          '{"app":"caldo"}',
        );
      },
    );

    test('a folder that has gone is not made again', () async {
      final gone = p.join(dir.path, 'unplugged');
      await expectLater(
        Desktop.writeInto(gone, 'caldo-auto-x.json', 'caldo-auto-', '{}', 7),
        throwsA(isA<FileSystemException>()),
      );
      expect(Directory(gone).existsSync(), isFalse);
    });

    test('a folder is shown from home', () {
      expect(
        Desktop.shown('/home/a/Sync/caldo', home: '/home/a'),
        '~/Sync/caldo',
      );
      expect(Desktop.shown('/home/a', home: '/home/a'), '~');
      expect(
        Desktop.shown('/mnt/disk/caldo', home: '/home/a'),
        '/mnt/disk/caldo',
      );
      expect(Desktop.shown('/home/ab/x', home: '/home/a'), '/home/ab/x');
    });
  });

  test('a release offers a desktop its own file, by that name', () {
    // What `tool/package_linux.sh` writes and a release has to carry.
    expect(Updates.linuxFile, 'Caldo-linux-x64.tar.gz');
  });

  test('what is said of the phone is said of the computer', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final lang in S.supported.map((l) => l.languageCode)) {
      S.use(lang);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final phone = [
        S.current.backupNote,
        S.current.backupAutoNote,
        S.current.attachmentMissing,
        S.current.followPhone('X'),
      ];
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(onDesktop, isTrue);
      final desktop = [
        S.current.backupNote,
        S.current.backupAutoNote,
        S.current.attachmentMissing,
        S.current.followPhone('X'),
      ];
      for (var i = 0; i < phone.length; i++) {
        expect(desktop[i], isNot(phone[i]), reason: '$lang, phrase $i');
        expect(S.current.hasOwn('backupNoteDesktop'), isTrue, reason: lang);
      }
      expect(desktop.last, contains('X'));
    }
    S.use('en');
    expect(S.current.backupNote, contains('this computer'));
  });

  Future<TaskProvider> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(460, 880);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late TaskProvider provider;
    await tester.runAsync(() async => provider = await seedProvider());
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<TaskProvider>.value(value: provider),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(AppAccent.presets.first),
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pump();
    return provider;
  }

  testWidgets(
    'with no keyboard to come up, the plus still brings up the field',
    (tester) async {
      await pumpShell(tester);
      expect(find.byType(TextField).hitTestable(), findsNothing);
      expect(find.byKey(tabBarKey).hitTestable(), findsOneWidget);

      await tester.tap(find.byKey(barAddKey));
      await tester.pump();
      // Nothing has said the keys are up, and nothing will: the field
      // being written in stands for it.
      expect(tester.view.viewInsets.bottom, 0);
      expect(find.byType(TextField).hitTestable(), findsOneWidget);
      expect(find.byKey(tabBarKey).hitTestable(), findsNothing);

      // Enter on an empty field lets go of it, and the bar is back.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.byType(TextField).hitTestable(), findsNothing);
      expect(find.byKey(tabBarKey).hitTestable(), findsOneWidget);

      // So does Escape.
      await tester.tap(find.byKey(barAddKey));
      await tester.pump();
      expect(find.byType(TextField).hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(TextField).hitTestable(), findsNothing);
      expect(find.byKey(tabBarKey).hitTestable(), findsOneWidget);

      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
    },
    variant: linux,
  );

  testWidgets('on a phone the field waits for the keys, as it did', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(barAddKey));
    await tester.pump();
    expect(onDesktop, isFalse);
    // Focused, and not drawn until the keyboard is.
    expect(find.byType(TextField).hitTestable(), findsNothing);
    expect(find.byKey(tabBarKey).hitTestable(), findsOneWidget);
    tester.widget<TextField>(find.byType(TextField)).focusNode!.unfocus();
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
  });

  Future<void> pumpField(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(AppAccent.presets.first),
      home: Scaffold(
        body: AttachmentsField(
          attachments: const <Attachment>[],
          onAdd: (AttachFrom _) {},
          onRemove: (_) {},
        ),
      ),
    ),
  );

  testWidgets('a desktop is not offered the camera', (tester) async {
    await pumpField(tester);
    expect(find.text('Photo'), findsOneWidget);
    expect(find.text('File'), findsOneWidget);
    expect(find.text('Camera'), findsNothing);
  }, variant: linux);

  testWidgets('a phone still is', (tester) async {
    await pumpField(tester);
    expect(find.text('Camera'), findsOneWidget);
  });

  testWidgets('a window wider than a phone keeps the app to its middle', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late Size given;
    late Size said;
    Future<void> pumpAt(Size window) async {
      tester.view.physicalSize = window;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(AppAccent.presets.first),
          builder: (context, child) => PhoneWide(child: child!),
          home: LayoutBuilder(
            builder: (context, box) {
              given = box.biggest;
              said = MediaQuery.sizeOf(context);
              return const SizedBox.expand(key: Key('app'));
            },
          ),
        ),
      );
    }

    await pumpAt(const Size(1600, 900));
    expect(given, const Size(PhoneWide.width, 900));
    expect(said, given, reason: 'the screen it is told of is the one it has');
    final app = tester.getRect(find.byKey(const Key('app')));
    expect(app.center.dx, 800);

    // At a phone's width it has all of it.
    await pumpAt(const Size(460, 880));
    expect(given, const Size(460, 880));
    expect(said, given);
  });
}

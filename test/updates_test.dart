import 'package:caldo/services/updates.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/widgets/desk.dart';
import 'package:caldo/widgets/update_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _release(
  String tag, {
  String body = '',
  List<String> files = const ['Caldo-arm64.apk', 'Caldo-universal.apk'],
  bool prerelease = false,
}) => {
  'tag_name': tag,
  'body': body,
  'draft': false,
  'prerelease': prerelease,
  'assets': [
    for (final f in files)
      {'name': f, 'browser_download_url': 'https://example.com/$tag/$f'},
  ],
};

const _phone = ['Caldo-arm64.apk', 'Caldo-universal.apk'];

void main() {
  test('a release is newer by its numbers, not by its spelling', () {
    // Compared as text, 1.3.10 comes before 1.3.9 — and every release from
    // the tenth patch on would be taken for an old one.
    expect(Updates.isNewer('1.3.10', than: '1.3.9'), isTrue);
    expect(Updates.isNewer('1.4.0', than: '1.3.13'), isTrue);
    expect(Updates.isNewer('2.0.0', than: '1.99.99'), isTrue);

    expect(Updates.isNewer('1.3.13', than: '1.3.13'), isFalse);
    expect(Updates.isNewer('1.3.9', than: '1.3.10'), isFalse);
    // The build number after a plus is not part of the release.
    expect(Updates.isNewer('1.3.13', than: '1.3.13+27'), isFalse);
    // A missing part counts as zero.
    expect(Updates.isNewer('1.4', than: '1.3.13'), isTrue);
    expect(Updates.isNewer('1.3', than: '1.3.0'), isFalse);
  });

  test('the file fetched is the one built for the phone', () {
    expect(Updates.apkFor('arm64-v8a'), 'Caldo-arm64.apk');
    expect(Updates.apkFor('armeabi-v7a'), 'Caldo-armv7.apk');
    // Anything else — an emulator's x86_64 — gets the one that runs
    // everywhere.
    expect(Updates.apkFor('x86_64'), 'Caldo-universal.apk');
    expect(Updates.apkFor(''), 'Caldo-universal.apk');
  });

  test('nothing is checked until the app has switched it on', () async {
    // The widget tests drive the real shell; a check that reached the network
    // from inside one would be a test that depends on the network.
    expect(await Updates.instance.check(), isNull);
  });

  test('the newest release is offered, with every skipped one\'s notes', () {
    final update = Updates.pick(
      [
        _release('v2.10.0', body: 'Ten\r\n'),
        _release('v2.9.8', body: '<!-- priority: high -->\nNew:\n\n- Fix'),
        _release('v2.9.7'),
        _release('v2.9.6', body: 'Installed already'),
        _release('v2.11.0', prerelease: true),
      ],
      installed: '2.9.6',
      names: _phone,
    )!;
    expect(update.version, '2.10.0');
    expect(update.file.path, '/v2.10.0/Caldo-arm64.apk');
    // Newest first; one with nothing to say leaves no heading.
    expect([for (final n in update.notes) n.version], ['2.10.0', '2.9.8']);
    expect(update.notes.first.text, 'Ten');
    // The mark is read, then taken out of what is shown.
    expect(update.notes.last.text, 'New:\n\n- Fix');
    // One urgent release on the way makes the whole update urgent.
    expect(update.urgent, isTrue);
  });

  test('nothing newer, or no file for this device, is no update', () {
    expect(
      Updates.pick([_release('v2.9.6')], installed: '2.9.6', names: _phone),
      isNull,
    );
    expect(
      Updates.pick(
        [_release('v2.9.7')],
        installed: '2.9.6',
        names: [Updates.linuxFile],
      ),
      isNull,
    );
    final plain = Updates.pick(
      [_release('v2.9.7', body: 'priority: high, in words')],
      installed: '2.9.6',
      names: _phone,
    )!;
    expect(plain.urgent, isFalse);
  });

  group('update prompt', () {
    final updates = Updates.instance;
    final file = Uri.parse('https://example.com/a.apk');

    tearDown(() {
      updates.offered.value = null;
      updates.progress.value = null;
      updates.hitch.value = null;
    });

    Future<void> pump(
      WidgetTester tester,
      GlobalKey<NavigatorState> navigator,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(AppAccent.presets.first),
          navigatorKey: navigator,
          builder: (context, child) => ValueListenableBuilder<Update?>(
            valueListenable: updates.offered,
            builder: (context, update, _) => UpdatePrompt(
              update: update,
              navigator: navigator,
              child: DeskKeys(navigator: navigator, wide: true, child: child!),
            ),
          ),
          home: const Scaffold(body: Text('Home')),
        ),
      );
    }

    testWidgets('opens with notes and blocks the current screen until Later', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await pump(tester, navigator);
      var taps = 0;
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: TextButton(
                onPressed: () => taps++,
                child: const Text('Working screen'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final workingScreen = find.text('Working screen', skipOffstage: false);
      final outside = tester.getCenter(workingScreen);

      updates.offered.value = Update(
        '2.9.8',
        file,
        notes: const [
          ReleaseNotes('2.9.8', 'New:\n\n- Attachments sync.'),
          ReleaseNotes('2.9.7', 'Fixes:\n- A crash'),
        ],
      );
      await tester.pumpAndSettle();

      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      expect(tester.getCenter(dialog), const Offset(400, 300));
      expect(
        find.ancestor(
          of: find.byType(ModalBarrier),
          matching: find.byType(BackdropFilter),
        ),
        findsOneWidget,
      );
      expect(find.text("What's new"), findsOneWidget);
      expect(find.text('Attachments sync.'), findsOneWidget);
      expect(find.text('A crash'), findsOneWidget);
      expect(find.text('2.9.7'), findsOneWidget);

      await tester.tapAt(outside);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);
      expect(taps, 0);

      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      await tester.tap(workingScreen);
      expect(taps, 1);
      expect(updates.offered.value, isNull);
    });

    testWidgets('long notes scroll on a phone with both actions visible', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 460);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      updates.offered.value = Update(
        '2.9.7',
        file,
        notes: [
          ReleaseNotes('2.9.7', '${'- A change\n' * 30}- The last change'),
        ],
      );
      await pump(tester, GlobalKey<NavigatorState>());
      await tester.pumpAndSettle();

      expect(find.text('Update').hitTestable(), findsOneWidget);
      expect(find.text('Later').hitTestable(), findsOneWidget);
      final lastChange = find.text('The last change');
      expect(lastChange.hitTestable(), findsNothing);
      await tester.dragUntilVisible(
        lastChange,
        find.byType(SingleChildScrollView),
        const Offset(0, -160),
      );
      expect(lastChange.hitTestable(), findsOneWidget);
      expect(find.text('Update').hitTestable(), findsOneWidget);
      expect(find.text('Later').hitTestable(), findsOneWidget);
    });

    testWidgets('Update starts the installer flow and shows a failure', (
      tester,
    ) async {
      const channel = MethodChannel('caldo/updates');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var attempts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'info');
        attempts++;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      updates.offered.value = Update('2.9.7', file);
      await pump(tester, GlobalKey<NavigatorState>());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();
      expect(attempts, 1);
      expect(updates.hitch.value, InstallHitch.failed);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Update').hitTestable(), findsOneWidget);
      expect(find.text('Later').hitTestable(), findsOneWidget);
    });

    testWidgets('an urgent one bars the app, with no Later', (tester) async {
      tester.view.physicalSize = const Size(411, 731);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(AppAccent.presets.first),
          home: UpdateWall(
            update: Update(
              '2.9.7',
              file,
              notes: const [ReleaseNotes('2.9.7', '- A fix that matters')],
              urgent: true,
            ),
          ),
        ),
      );
      expect(find.text('Important'), findsOneWidget);
      expect(
        find.text("Caldo can't be used until this update is installed"),
        findsOneWidget,
      );
      expect(find.text('A fix that matters'), findsOneWidget);
      expect(find.text('Update'), findsOneWidget);
      expect(find.text('Later'), findsNothing);
    });
  });
}

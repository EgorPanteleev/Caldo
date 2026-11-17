import 'package:caldo/services/updates.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/widgets/update_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  group('banner', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Updates.instance.offered.value = null;
    });

    Future<void> pump(WidgetTester tester, Update update) async {
      Updates.instance.offered.value = update;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(AppAccent.presets.first),
          home: Scaffold(
            body: ValueListenableBuilder<Update?>(
              valueListenable: Updates.instance.offered,
              builder: (context, update, _) => update == null
                  ? const SizedBox()
                  : UpdateBanner(update: update),
            ),
          ),
        ),
      );
    }

    final file = Uri.parse('https://example.com/a.apk');

    testWidgets('Later puts it off until a newer one', (tester) async {
      await pump(
        tester,
        Update('2.9.7', file, notes: [const ReleaseNotes('2.9.7', '- Fix')]),
      );
      expect(find.text('Caldo 2.9.7'), findsOneWidget);
      await tester.tap(find.text('Later'));
      await tester.pump();
      expect(find.byType(UpdateBanner), findsNothing);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('updateLater'), startsWith('2.9.7@'));
    });

    testWidgets('an urgent one has no Later', (tester) async {
      await pump(tester, Update('2.9.7', file, urgent: true));
      expect(find.text('Important'), findsOneWidget);
      expect(find.text('Update'), findsOneWidget);
      expect(find.text('Later'), findsNothing);
    });

    testWidgets('a tap opens what is new', (tester) async {
      await pump(
        tester,
        Update(
          '2.9.8',
          file,
          notes: const [
            ReleaseNotes('2.9.8', 'New:\n\n- Attachments sync.'),
            ReleaseNotes('2.9.7', 'Fixes:\n- A crash'),
          ],
        ),
      );
      await tester.tap(find.text('Caldo 2.9.8'));
      await tester.pumpAndSettle();
      expect(find.text("What's new"), findsOneWidget);
      expect(find.text('Attachments sync.'), findsOneWidget);
      expect(find.text('A crash'), findsOneWidget);
      // Two releases, so each is headed by its version.
      expect(find.text('2.9.7'), findsOneWidget);
      expect(find.text('Later'), findsNWidgets(2));
    });
  });
}

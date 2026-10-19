import 'package:caldo/services/updates.dart';
import 'package:flutter_test/flutter_test.dart';

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
}

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/strings.dart';
import '../utils/platform.dart';
import 'desktop.dart';

/// A newer release than the one installed, and the file of it this phone
/// should fetch — an APK, or on a desktop the program packed up.
@immutable
class Update {
  final String version;
  final Uri file;

  /// What each release between the one installed and this one says about
  /// itself, newest first — skipping a few versions shows all their notes.
  final List<ReleaseNotes> notes;

  /// Whether any of those releases is marked as one not to put off
  /// ([Updates.urgentMark]): it is offered without Later.
  final bool urgent;

  const Update(
    this.version,
    this.file, {
    this.notes = const [],
    this.urgent = false,
  });
}

/// A release's own words, as written on GitHub.
@immutable
class ReleaseNotes {
  final String version;
  final String text;

  const ReleaseNotes(this.version, this.text);
}

/// Where a download has got to, from nothing to all of it, or null while
/// nothing is being downloaded.
typedef DownloadProgress = double?;

/// What kept an install from reaching Android's installer: Caldo isn't
/// allowed to install apps yet, or the download failed.
enum InstallHitch { allow, failed }

/// Finds out whether a newer Caldo has been released, fetches it, and hands
/// it to Android to install over this one.
///
/// Releases are the GitHub ones, read from the public API with no account
/// and no token: the repository is public for exactly this reason, since an
/// app that can read a private repository carries a key to it that anyone
/// with the APK can take out. Each release carries the same three APKs, and
/// the one fetched is the one built for this phone's processor. A release
/// that carries [linuxFile] as well is offered to a desktop, which unpacks
/// it over itself (`Desktop.replaceWith`); one that does not is offered to
/// phones alone.
///
/// Nothing here runs until [enable] has been called, which `main` does and
/// nothing else: the widget tests drive the real shell, and a check that
/// went out to the network from inside a test would be a test that depends
/// on the network.
class Updates {
  Updates._();

  static final instance = Updates._();

  static const _channel = MethodChannel('caldo/updates');
  // Every recent release rather than only the latest, so that notes and an
  // urgent mark on one in between are not lost on a phone that skipped it.
  static final _releases = Uri.parse(
    'https://api.github.com/repos/EgorPanteleev/Caldo/releases?per_page=20',
  );

  /// Written in a release's notes, marks it as one not to be put off. A
  /// comment, so GitHub's page does not show it.
  static final urgentMark = RegExp(
    r'<!--\s*priority:\s*high\s*-->',
    caseSensitive: false,
  );

  /// How long Later keeps the banner away. A newer release than the one put
  /// off is offered at once.
  static const laterFor = Duration(days: 3);

  static const _laterKey = 'updateLater';

  /// Where a release can be read about and fetched by hand.
  static const _page = 'https://github.com/EgorPanteleev/Caldo/releases/tag';

  /// The desktop's file in a release: the program's directory, packed
  /// (`tool/package_linux.sh`).
  static const linuxFile = 'Caldo-linux-x64.tar.gz';

  bool _enabled = false;

  /// Where the current download has got to.
  final ValueNotifier<DownloadProgress> progress = ValueNotifier(null);

  /// The newer release, once [look] has found one, whether or not it has
  /// been put off — Settings offers it either way.
  final ValueNotifier<Update?> available = ValueNotifier(null);

  /// The release the banner offers: [available] unless it was put off.
  final ValueNotifier<Update?> offered = ValueNotifier(null);

  /// Why the last install did not get as far as Android's installer, until
  /// the next one starts.
  final ValueNotifier<InstallHitch?> hitch = ValueNotifier(null);

  void enable() => _enabled = true;

  /// What is installed and where a download goes: from the activity on a
  /// phone, and on a desktop from the program's own directory.
  Future<Map<String, Object?>?> _info() async => onDesktop
      ? {
          'version': await Desktop.version(),
          'abi': 'linux',
          'dir': Desktop.updates,
        }
      : await _channel.invokeMapMethod<String, Object?>('info');

  /// The version installed, as Android has it, or null before [enable] or if
  /// the activity cannot be asked.
  Future<String?> installed() async {
    if (!_enabled) return null;
    try {
      final info = await _info();
      return info?['version'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Checks for a newer release and offers it, unless it was put off.
  Future<void> look() async {
    final update = await check();
    if (update == null) return;
    available.value = update;
    if (update.urgent || !await _putOff(update)) offered.value = update;
  }

  /// Keeps the banner away for [laterFor]. An urgent release can't be.
  Future<void> later(Update update) async {
    if (update.urgent) return;
    offered.value = null;
    final until = DateTime.now().add(laterFor).millisecondsSinceEpoch;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_laterKey, '${update.version}@$until');
  }

  Future<bool> _putOff(Update update) async {
    final prefs = await SharedPreferences.getInstance();
    final [version, until] = (prefs.getString(_laterKey) ?? '@').split('@');
    return version == update.version &&
        DateTime.now().millisecondsSinceEpoch < (int.tryParse(until) ?? 0);
  }

  /// The newer release, if there is one. Null on any failure at all — no
  /// network, GitHub out of reach or rate-limited, a release with no file
  /// for this phone — because not hearing about an update is the cost of
  /// every one of those, and none of them is worth telling anyone about.
  Future<Update?> check() async {
    if (!_enabled) return null;
    try {
      final info = await _info();
      if (info == null) return null;
      final installed = info['version'] as String? ?? '';
      // A build that cannot say what it is has nothing to be newer than.
      if (installed.isEmpty) return null;
      final abi = info['abi'] as String? ?? '';

      // No falling back on a desktop: the APK for every phone is still
      // not a program for this one, and nor is one built for another
      // processor.
      final names = onDesktop
          ? [if (Abi.current() == Abi.linuxX64) linuxFile]
          : [apkFor(abi), 'Caldo-universal.apk'];
      return pick(
        await _getJson(_releases) as List<dynamic>,
        installed: installed,
        names: names,
      );
    } catch (_) {
      return null;
    }
  }

  /// The newest of [releases] (GitHub's list) newer than [installed], with
  /// the first of [names] it carries, or null if it is not newer or carries
  /// none of them. Drafts and pre-releases don't count.
  @visibleForTesting
  static Update? pick(
    List<dynamic> releases, {
    required String installed,
    required List<String> names,
  }) {
    final newer = <(String, Map<dynamic, dynamic>)>[
      for (final r in releases)
        if (r is Map && r['draft'] != true && r['prerelease'] != true)
          if (_versionOf(r) case final v when isNewer(v, than: installed))
            (v, r),
    ]..sort((a, b) => isNewer(a.$1, than: b.$1) ? -1 : 1);
    if (newer.isEmpty) return null;

    final (version, latest) = newer.first;
    final assets = [
      for (final a in latest['assets'] as List<dynamic>? ?? const [])
        if (a is Map) a,
    ];
    String? url;
    for (final name in names) {
      for (final a in assets) {
        if (a['name'] == name) url ??= a['browser_download_url'] as String?;
      }
    }
    if (url == null) return null;

    final bodies = [
      for (final (v, r) in newer) (v, r['body'] as String? ?? ''),
    ];
    return Update(
      version,
      Uri.parse(url),
      notes: [
        for (final (v, body) in bodies)
          if (cleanNotes(body) case final text when text.isNotEmpty)
            ReleaseNotes(v, text),
      ],
      urgent: bodies.any((b) => urgentMark.hasMatch(b.$2)),
    );
  }

  static String _versionOf(Map<dynamic, dynamic> release) {
    final tag = release['tag_name'] as String? ?? '';
    return tag.startsWith('v') ? tag.substring(1) : tag;
  }

  /// A release's notes as they read on its page: without comments (the
  /// [urgentMark] among them), Windows line ends, or blank lines at either
  /// end.
  @visibleForTesting
  static String cleanNotes(String body) => body
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '')
      .replaceAll('\r', '')
      .trim();

  /// Installs [update], noting in [hitch] what stopped it. A tap while a
  /// download is under way does nothing.
  Future<void> start(Update update) async {
    if (progress.value != null) return;
    hitch.value = null;
    try {
      if (!await install(update)) hitch.value = InstallHitch.allow;
    } catch (_) {
      hitch.value = InstallHitch.failed;
    }
  }

  /// Fetches [update] into the app's own cache and installs it over this
  /// one. Returns false when Android first wants the user to allow Caldo to
  /// install apps — the settings page for that has been opened instead, and
  /// tapping again once it is allowed carries on.
  ///
  /// On a desktop the program is unpacked over the one installed and
  /// started in its place — where the user it runs as may write there. One
  /// a package manager installed is not Caldo's to replace, and the page
  /// the release is on is opened instead.
  Future<bool> install(Update update) async {
    if (onDesktop && !Desktop.replaceable) {
      await Desktop.open('$_page/v${update.version}');
      return true;
    }
    final info = await _info();
    final dir = info?['dir'] as String?;
    if (dir == null) throw StateError('no download directory');
    final file = File(
      '$dir/Caldo-${update.version}.${onDesktop ? 'tar.gz' : 'apk'}',
    );

    if (!file.existsSync()) {
      // Whatever an earlier update left behind goes first: each is twenty
      // megabytes of a version that is either installed already or never
      // will be.
      final folder = Directory(dir)..createSync(recursive: true);
      for (final old in folder.listSync()) {
        if (old is File) old.deleteSync();
      }
      final partial = File('${file.path}.part');
      progress.value = 0;
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 10);
        try {
          final request = await client.getUrl(update.file);
          final response = await request.close();
          if (response.statusCode != 200) {
            throw HttpException('download failed: ${response.statusCode}');
          }
          final total = response.contentLength;
          var received = 0;
          final sink = partial.openWrite();
          try {
            // A connection that stops sending without closing would hold
            // the banner at its last percent for good.
            await for (final chunk in response.timeout(
              const Duration(seconds: 30),
            )) {
              sink.add(chunk);
              received += chunk.length;
              if (total > 0) progress.value = received / total;
            }
          } finally {
            await sink.close();
          }
          // A connection dropped early ends the stream as if it were done.
          // Renamed into place, that half of an APK was taken for a finished
          // download on every tap after, and every install of it failed.
          if (total > 0 && received != total) {
            throw HttpException('download cut short: $received of $total');
          }
        } finally {
          client.close(force: true);
        }
        // Renamed into place only once it is whole, so a download cut off
        // half way is never mistaken for one that finished.
        await partial.rename(file.path);
      } finally {
        progress.value = null;
      }
    }

    if (onDesktop) {
      try {
        // Ends this program; the new one opens in its place.
        await Desktop.replaceWith(file.path);
      } on FileSystemException {
        // Not a download worth keeping: the next tap fetches it again.
        if (file.existsSync()) file.deleteSync();
        rethrow;
      }
      return true;
    }
    final outcome = await _channel.invokeMethod<String>('install', {
      'path': file.path,
      'words': {
        'title': S.current.updateInstalled(update.version),
        'text': S.current.tapToOpen,
        'channel': S.current.updatesChannel,
      },
    });
    return outcome == 'started';
  }

  Future<Object?> _getJson(Uri url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final request = await client.getUrl(url);
      // GitHub turns away requests without one.
      request.headers
        ..set(HttpHeaders.userAgentHeader, 'Caldo')
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != 200) {
        throw HttpException('status ${response.statusCode}');
      }
      final body = await response.transform(utf8.decoder).join();
      return jsonDecode(body);
    } finally {
      client.close();
    }
  }

  /// Whether [version] comes after [than], read as dotted numbers — so 1.3.10
  /// is after 1.3.9, which comparing them as text gets backwards.
  @visibleForTesting
  static bool isNewer(String version, {required String than}) {
    List<int> parts(String v) => [
      for (final p in v.split('+').first.split('.')) int.tryParse(p) ?? 0,
    ];
    final a = parts(version);
    final b = parts(than);
    for (var i = 0; i < a.length || i < b.length; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  /// Which of a release's three APKs is built for a phone whose processor
  /// Android names [abi].
  @visibleForTesting
  static String apkFor(String abi) => switch (abi) {
    'arm64-v8a' => 'Caldo-arm64.apk',
    'armeabi-v7a' => 'Caldo-armv7.apk',
    _ => 'Caldo-universal.apk',
  };
}

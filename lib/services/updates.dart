import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A newer release than the one installed, and the file of it this phone
/// should fetch.
@immutable
class Update {
  final String version;
  final Uri apk;

  const Update(this.version, this.apk);
}

/// Where a download has got to, from nothing to all of it, or null while
/// nothing is being downloaded.
typedef DownloadProgress = double?;

/// Finds out whether a newer Caldo has been released, fetches it, and hands
/// it to Android's installer.
///
/// Releases are the GitHub ones, read from the public API with no account
/// and no token: the repository is public for exactly this reason, since an
/// app that can read a private repository carries a key to it that anyone
/// with the APK can take out. Each release carries the same three APKs, and
/// the one fetched is the one built for this phone's processor.
///
/// Nothing here runs until [enable] has been called, which `main` does and
/// nothing else: the widget tests drive the real shell, and a check that
/// went out to the network from inside a test would be a test that depends
/// on the network.
class Updates {
  Updates._();

  static final instance = Updates._();

  static const _channel = MethodChannel('caldo/updates');
  static final _latest = Uri.parse(
    'https://api.github.com/repos/EgorPanteleev/Caldo/releases/latest',
  );

  bool _enabled = false;

  /// Where the current download has got to.
  final ValueNotifier<DownloadProgress> progress = ValueNotifier(null);

  void enable() => _enabled = true;

  /// The newer release, if there is one. Null on any failure at all — no
  /// network, GitHub out of reach or rate-limited, a release with no file
  /// for this phone — because not hearing about an update is the cost of
  /// every one of those, and none of them is worth telling anyone about.
  Future<Update?> check() async {
    if (!_enabled) return null;
    try {
      final info = await _channel.invokeMapMethod<String, Object?>('info');
      if (info == null) return null;
      final installed = info['version'] as String? ?? '';
      final abi = info['abi'] as String? ?? '';

      final release = await _getJson(_latest);
      final tag = release['tag_name'] as String? ?? '';
      final version = tag.startsWith('v') ? tag.substring(1) : tag;
      if (!isNewer(version, than: installed)) return null;

      final assets = [
        for (final a in release['assets'] as List<dynamic>? ?? const [])
          if (a is Map) a,
      ];
      String? urlOf(String name) {
        for (final a in assets) {
          if (a['name'] == name) return a['browser_download_url'] as String?;
        }
        return null;
      }

      final url = urlOf(apkFor(abi)) ?? urlOf('Caldo-universal.apk');
      if (url == null) return null;
      return Update(version, Uri.parse(url));
    } catch (_) {
      return null;
    }
  }

  /// Fetches [update] into the app's own cache and opens the installer on
  /// it. Returns false when Android first wants the user to allow Caldo to
  /// install apps — the settings page for that has been opened instead, and
  /// tapping again once it is allowed carries on.
  Future<bool> install(Update update) async {
    final info = await _channel.invokeMapMethod<String, Object?>('info');
    final dir = info?['dir'] as String?;
    if (dir == null) throw StateError('no download directory');
    final file = File('$dir/Caldo-${update.version}.apk');

    if (!file.existsSync()) {
      // Whatever an earlier update left behind goes first: each is twenty
      // megabytes of a version that is either installed already or never
      // will be.
      for (final old in Directory(dir).listSync()) {
        if (old is File) old.deleteSync();
      }
      final partial = File('${file.path}.part');
      progress.value = 0;
      try {
        final client = HttpClient();
        try {
          final request = await client.getUrl(update.apk);
          final response = await request.close();
          if (response.statusCode != 200) {
            throw HttpException('download failed: ${response.statusCode}');
          }
          final total = response.contentLength;
          var received = 0;
          final sink = partial.openWrite();
          await for (final chunk in response) {
            sink.add(chunk);
            received += chunk.length;
            if (total > 0) progress.value = received / total;
          }
          await sink.close();
        } finally {
          client.close();
        }
        // Renamed into place only once it is whole, so a download cut off
        // half way is never mistaken for one that finished.
        await partial.rename(file.path);
      } finally {
        progress.value = null;
      }
    }

    final outcome = await _channel.invokeMethod<String>('install', {
      'path': file.path,
    });
    return outcome == 'started';
  }

  Future<Map<String, dynamic>> _getJson(Uri url) async {
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
      return jsonDecode(body) as Map<String, dynamic>;
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

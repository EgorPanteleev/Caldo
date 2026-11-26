import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase/supabase.dart';

import '../db/sync_store.dart';
import '../theme/tweaks.dart';
import '../utils/platform.dart';
import 'caldo_server.dart';
import 'file_sync.dart';
import 'push.dart';
import 'sync.dart';

/// Signing in, and the server a signed-in device syncs with.
///
/// The login is a name and a password, and an account is made only with an
/// invite (`supabase/migrations/…_invites.sql`). Codes sent by email were
/// the first way in, but the server has no mail of its own to send them
/// with. Auth wants an address, so a name is kept as one under a domain
/// that can never receive mail ([loginOf]).
///
/// Nothing happens until [enable] is called from `main`, so the widget tests
/// never go online; without an account the app is what it always was.
class Account {
  Account._();
  static final instance = Account._();

  static const _builtServer = CaldoServer.url;

  /// The address Auth knows the name [name] by.
  static String loginOf(String name) => CaldoServer.loginOf(name);

  /// The name in a login, or the login itself for an account made by email.
  static String nameIn(String login) => CaldoServer.nameIn(login);

  /// Letters, digits, `_` and `-`, in parts joined by single dots, three to
  /// thirty-two in all: what an address can carry before its `@`.
  static bool fitsName(String name) {
    final n = name.trim().toLowerCase();
    return n.length >= 3 &&
        n.length <= 32 &&
        RegExp(r'^[a-z0-9_-]+(\.[a-z0-9_-]+)*$').hasMatch(n);
  }

  /// The invite in [text]: a whole link as sent (caldo://invite/…) or the
  /// code alone, as typed or pasted on a computer, where the link opens
  /// nothing.
  static String inviteIn(String text) => text
      .trim()
      .split('/')
      .last
      .replaceAll(RegExp(r'[^A-Za-z0-9]'), '')
      .toUpperCase();

  static String linkTo(String invite) => 'caldo://invite/$invite';

  static const _serverKey = 'sync_server';
  static const _sessionKey = 'sync_session';

  /// The server's address in force, or null for none.
  final server = ValueNotifier<String?>(null);

  /// The login of whoever is signed in, or null.
  final email = ValueNotifier<String?>(null);

  /// Whether whoever is signed in may make invites.
  final admin = ValueNotifier<bool>(false);

  SupabaseClient? _client;
  StreamSubscription<AuthState>? _auth;

  /// The client, while signed in: for what lives on the server only (the
  /// Agents tab's chats), not the synced rows.
  SupabaseClient? get client =>
      _client?.auth.currentSession == null ? null : _client;
  RealtimeChannel? _channel;
  Timer? _every;

  /// While open, a round this often even if nothing was heard: a realtime
  /// channel can drop without a word.
  static const _interval = Duration(minutes: 5);

  /// Android's round while the app is closed (`DailySync.kt`): booked here
  /// while signed in, and run here while the app's engine lives.
  static const _daily = MethodChannel('caldo/sync');

  /// Set for [syncOnce]: an engine with no screens, holding the session
  /// only for one round.
  bool _quiet = false;

  Future<void> enable() async {
    final prefs = await SharedPreferences.getInstance();
    final address = prefs.getString(_serverKey) ?? _builtServer;
    if (address.isEmpty) return;
    if (!onDesktop) {
      _daily.setMethodCallHandler((call) async {
        if (call.method != 'sync') return null;
        await Sync.instance.run();
        await Sync.instance.carried;
        return Sync.instance.error.value == null;
      });
    }
    _connect(address);
    final stored = prefs.getString(_sessionKey);
    // Booked on every opening as well as at sign-in, so a device signed in
    // before there was a daily round has one too.
    unawaited(_book(stored != null));
    if (stored != null) {
      // Said at once, from what was kept, so Settings does not show a
      // signed-in device as signed out while the session is renewed — or,
      // offline, until the server can be reached.
      email.value = _emailIn(stored);
      // Not waited for: `main` waits for this, and renewing a session is a
      // round trip to the server, which offline only ends in a timeout.
      unawaited(_restore().then((_) => Sync.instance.run()));
    }
  }

  /// One round from an engine with no screens: Android's while the app is
  /// closed. Takes the session up from where the app keeps it, runs the
  /// round, and lets go of it all again — no channel, no timer, and no
  /// session left in memory to be renewed here behind the app's back.
  Future<({bool reached, bool changed})> syncOnce() async {
    final prefs = await SharedPreferences.getInstance();
    // This engine may have been started long ago for the widget, and the
    // session renewed by the app since: an old refresh token used again
    // ends the session everywhere.
    await prefs.reload();
    final address = prefs.getString(_serverKey) ?? _builtServer;
    if (address.isEmpty || prefs.getString(_sessionKey) == null) {
      return (reached: true, changed: false);
    }
    _quiet = true;
    _connect(address);
    try {
      final changed = await Sync.instance.run();
      await Sync.instance.carried;
      final reached =
          Sync.instance.server?.account != null &&
          Sync.instance.error.value == null;
      return (reached: reached, changed: changed);
    } finally {
      await _disconnect();
      _quiet = false;
    }
  }

  /// Books Android's daily round, or calls it off.
  Future<void> _book(bool signedIn) async {
    if (onDesktop || _quiet) return;
    try {
      await _daily.invokeMethod<void>(signedIn ? 'keep' : 'stop');
    } on MissingPluginException {
      // No activity: the widget's engine, or a test.
    }
  }

  static String? _emailIn(String session) {
    try {
      final user = (jsonDecode(session) as Map)['user'] as Map?;
      return user?['email'] as String?;
    } on FormatException {
      return null;
    }
  }

  void _connect(String address) {
    _client = SupabaseClient(
      address,
      CaldoServer.keyFor(address),
      // A code typed in needs no PKCE, which would want somewhere to keep
      // its verifier between sending the code and checking it.
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
    );
    server.value = address;
    _auth = _client!.auth.onAuthStateChange.listen(_onAuth);
    Sync.instance.server = _Server(this);
  }

  Future<void> _disconnect() async {
    await _stopListening();
    await _auth?.cancel();
    _auth = null;
    await _client?.dispose();
    _client = null;
    server.value = null;
    Sync.instance.server = null;
  }

  Future<void> _onAuth(AuthState state) async {
    final prefs = await SharedPreferences.getInstance();
    final session = state.session;
    if (state.event == AuthChangeEvent.signedOut) {
      await prefs.remove(_sessionKey);
      email.value = null;
      admin.value = false;
      await Tweaks.instance.setOn(false);
      await _stopListening();
      await _book(false);
      return;
    }
    if (session == null) return;
    await prefs.setString(_sessionKey, jsonEncode(session.toJson()));
    email.value = session.user.email;
    if (_quiet) return;
    _listen();
    unawaited(Push.signedIn(_client!));
    unawaited(_askAdmin());
    unawaited(_book(true));
  }

  Future<void> _askAdmin() async {
    try {
      admin.value = await _client!.rpc('is_admin') as bool;
    } catch (_) {
      // Unreachable; asked again on the next sign-in or opening.
    }
  }

  /// Brings back the session kept from last time, renewing it if it has
  /// run out. Offline that fails, and the kept one is left for next time.
  Future<void> _restore() async {
    final client = _client;
    if (client == null || client.auth.currentSession != null) return;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_sessionKey);
    if (stored == null) return;
    try {
      await client.auth.recoverSession(stored);
    } on AuthException catch (e) {
      // Refused, rather than unreachable: the session is over for good.
      if (e.statusCode == '400' || e.statusCode == '401') {
        await prefs.remove(_sessionKey);
        email.value = null;
        await _book(false);
      }
    } catch (_) {
      // Unreachable; tried again on the next round.
    }
  }

  /// Hears when the account's rows change on the server, from another
  /// device, and runs a round then rather than waiting for the next.
  void _listen() {
    final client = _client;
    if (client == null || _channel != null) return;
    _channel = client
        .channel('caldo-sync')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'sync_rows',
          callback: (change) => Sync.instance.heard(change.newRecord),
        )
        .subscribe();
    _every = Timer.periodic(_interval, (_) => Sync.instance.run());
  }

  Future<void> _stopListening() async {
    _every?.cancel();
    _every = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) await _client?.removeChannel(channel);
  }

  /// Points this device at the server at [address], or at none. A device
  /// signed in elsewhere is signed out first: an account is one server's.
  Future<void> setServer(String? address) async {
    final prefs = await SharedPreferences.getInstance();
    final next = address?.trim().replaceAll(RegExp(r'/+$'), '') ?? '';
    if (next == (server.value ?? '')) return;
    if (email.value != null) await signOut();
    await _disconnect();
    await prefs.setString(_serverKey, next);
    if (next.isNotEmpty) _connect(next);
  }

  /// Signs in, and syncs at once: the first round sends everything on this
  /// device to the account.
  Future<void> signIn(String name, String password) async {
    await _client!.auth.signInWithPassword(
      email: loginOf(name),
      password: password,
    );
    await Sync.instance.run();
  }

  /// Makes an account with [invite] and signs in to it. The server turns
  /// it down (403) unless the invite is one not yet used.
  Future<void> join(String invite, String name, String password) async {
    await _client!.auth.signUp(
      email: loginOf(name),
      password: password,
      data: {'invite': inviteIn(invite)},
    );
    await Sync.instance.run();
  }

  /// A link that makes one account; only an admin's is honoured.
  Future<String> makeInvite() async =>
      linkTo(await _client!.rpc('make_invite') as String);

  /// Signs out. Everything stays on this device, and is sent again if it
  /// signs in to another account.
  Future<void> signOut() async {
    await Push.signingOut(client);
    try {
      await _client?.auth.signOut(scope: SignOutScope.local);
    } catch (_) {
      // Signed out here whether or not the server heard.
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionKey);
    email.value = null;
    admin.value = false;
    // An admin's colours are an admin's: they go with the account.
    await Tweaks.instance.setOn(false);
    await _stopListening();
    await _book(false);
  }

  /// Deletes the account and everything it holds on the server. This
  /// device keeps its own.
  Future<void> deleteAccount() async {
    // The files first: the server keeps them apart from the account, and
    // nothing could reach them once it is gone.
    final files = _Files(this);
    await files.remove([...(await files.list()).keys]);
    await _client!.rpc('delete_account');
    await signOut();
  }
}

/// The account's rows on the server, through the two functions the
/// migration makes (`supabase/migrations/…_sync.sql`).
class _Server implements SyncServer {
  final Account _owner;

  _Server(this._owner);

  SupabaseClient get _client => _owner._client!;

  @override
  String? get account => _owner._client?.auth.currentUser?.id;

  @override
  Future<void> ready() async {
    await _owner._restore();
    // Asked at sign-in, and again before every round until it says yes: a
    // device signed in before it was made an admin, or offline when it
    // asked, would otherwise not know until it was opened afresh.
    if (!_owner._quiet && !_owner.admin.value && account != null) {
      unawaited(_owner._askAdmin());
    }
  }

  @override
  Future<void> push(List<SyncRow> rows) => _client.rpc(
    'sync_push',
    params: {
      'rows': [for (final r in rows) r.toJson()],
    },
  );

  @override
  FileStore get files => _Files(_owner);

  @override
  Future<List<SyncRow>> pull(int since, int page) async {
    final rows = await _client.rpc(
      'sync_pull',
      params: {'since': since, 'page': page},
    );
    return [
      for (final r in rows as List) SyncRow.fromJson(r as Map<String, Object?>),
    ];
  }
}

/// The account's attachment files, in its own folder of the `attachments`
/// bucket (`supabase/migrations/…_attachments.sql`).
class _Files implements FileStore {
  final Account _owner;

  _Files(this._owner);

  SupabaseClient get _client => _owner._client!;
  StorageFileApi get _bucket => _client.storage.from('attachments');
  String get _home => _client.auth.currentUser!.id;

  static const _page = 1000;

  @override
  Future<Map<String, DateTime>> list() async {
    final kept = <String, DateTime>{};
    for (var offset = 0; ; offset += _page) {
      final page = await _bucket.list(
        path: _home,
        searchOptions: SearchOptions(limit: _page, offset: offset),
      );
      for (final f in page) {
        // A folder has no id; there are none in a home of files alone.
        if (f.id == null) continue;
        kept[f.name] = DateTime.tryParse(f.createdAt ?? '') ?? DateTime.now();
      }
      if (page.length < _page) return kept;
    }
  }

  @override
  Future<void> put(String key, File file, String mime) async {
    try {
      await _bucket.upload(
        '$_home/$key',
        file,
        fileOptions: FileOptions(contentType: mime, upsert: true),
      );
    } on StorageException catch (e) {
      throw FileRefused(e);
    }
  }

  @override
  Future<Uint8List?> get(String key) async {
    try {
      return await _bucket.download('$_home/$key');
    } on StorageException catch (e) {
      // Not found is answered as a 400 as well as a 404.
      if (e.statusCode == '400' || e.statusCode == '404') return null;
      throw FileRefused(e);
    }
  }

  @override
  Future<void> remove(List<String> keys) async {
    for (var i = 0; i < keys.length; i += _page) {
      final some = keys.sublist(i, (i + _page).clamp(0, keys.length));
      await _bucket.remove([for (final k in some) '$_home/$k']);
    }
  }
}

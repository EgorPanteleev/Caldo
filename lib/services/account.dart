import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase/supabase.dart';

import '../db/sync_store.dart';
import 'sync.dart';

/// Signing in, and the server a signed-in device syncs with.
///
/// Sign-in is a six-figure code sent by email and typed into the app. A link
/// would open a browser, and on the desktop a browser has no way back into
/// the program. There is no password to forget.
///
/// Nothing happens until [enable] is called from `main`, so the widget tests
/// never go online; without an account the app is what it always was.
class Account {
  Account._();
  static final instance = Account._();

  /// Where the server is. Built in with `--dart-define=CALDO_SYNC_URL=…`
  /// once there is one fixed address; until then each device is told in
  /// Settings, since the emulator, the desktop and a phone each reach this
  /// PC at a different address.
  static const _builtServer = String.fromEnvironment('CALDO_SYNC_URL');

  /// The server's public key: it only says which project a request is for,
  /// and every row is guarded by who is signed in, not by this. The default
  /// is the one every local Supabase is started with.
  static const _key = String.fromEnvironment(
    'CALDO_SYNC_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwi'
        'cm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnW'
        'NReilDMblYTn_I0',
  );

  static const _serverKey = 'sync_server';
  static const _sessionKey = 'sync_session';

  /// The server's address in force, or null for none.
  final server = ValueNotifier<String?>(null);

  /// Who is signed in, or null.
  final email = ValueNotifier<String?>(null);

  SupabaseClient? _client;
  StreamSubscription<AuthState>? _auth;
  RealtimeChannel? _channel;
  Timer? _every;

  /// While open, a round this often even if nothing was heard: a realtime
  /// channel can drop without a word.
  static const _interval = Duration(minutes: 5);

  Future<void> enable() async {
    final prefs = await SharedPreferences.getInstance();
    final address = prefs.getString(_serverKey) ?? _builtServer;
    if (address.isEmpty) return;
    _connect(address);
    final stored = prefs.getString(_sessionKey);
    if (stored != null) {
      // Said at once, from what was kept, so Settings does not show a
      // signed-in device as signed out while the session is renewed — or,
      // offline, until the server can be reached.
      email.value = _emailIn(stored);
      await _restore();
      Sync.instance.run();
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
      _key,
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
      await _stopListening();
      return;
    }
    if (session == null) return;
    await prefs.setString(_sessionKey, jsonEncode(session.toJson()));
    email.value = session.user.email;
    _listen();
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
          callback: (_) => Sync.instance.soon(),
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

  /// Sends a code to [address], making the account if there is none.
  Future<void> sendCode(String address) async {
    await _client!.auth.signInWithOtp(email: address.trim());
  }

  /// Signs in with the code sent to [address], and syncs at once: the first
  /// round sends everything on this device to the account.
  Future<void> verify(String address, String code) async {
    await _client!.auth.verifyOTP(
      email: address.trim(),
      token: code.trim(),
      type: OtpType.email,
    );
    await Sync.instance.run();
  }

  /// Signs out. Everything stays on this device, and is sent again if it
  /// signs in to another account.
  Future<void> signOut() async {
    try {
      await _client?.auth.signOut(scope: SignOutScope.local);
    } catch (_) {
      // Signed out here whether or not the server heard.
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionKey);
    email.value = null;
    await _stopListening();
  }

  /// Deletes the account and everything it holds on the server. This
  /// device keeps its own.
  Future<void> deleteAccount() async {
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
  Future<void> ready() => _owner._restore();

  @override
  Future<void> push(List<SyncRow> rows) => _client.rpc(
    'sync_push',
    params: {
      'rows': [for (final r in rows) r.toJson()],
    },
  );

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

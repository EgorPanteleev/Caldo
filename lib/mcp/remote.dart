import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:supabase/supabase.dart';

import '../services/caldo_server.dart';
import 'book.dart';

/// The account's rows on the server: the same two functions every device
/// syncs through (`sync_push`, `sync_pull`).
abstract class Remote {
  /// Hands up rows. The server keeps the later edit of each, and lays a
  /// row's fields over what it holds, so a row may carry only those that
  /// changed.
  Future<void> push(List<ServerRow> rows);

  /// The account's rows written after [since], oldest first, at most [page].
  Future<List<ServerRow>> pull(int since, int page);
}

/// Said when there is no session to go on, or the server has ended it.
class SignedOut implements Exception {
  final String why;
  const SignedOut(this.why);

  @override
  String toString() => why;
}

/// The session the MCP server signs in with, kept in a file only its owner
/// can read: a session, not the password, so the password is typed once,
/// at `caldo-mcp login`, and kept nowhere.
///
/// Every Claude session starts a server of its own, and each of them holds
/// the one session. A refresh token spent twice ends a Supabase session
/// everywhere (the phone's daily round met it: CLAUDE.md, Sync), so the
/// session is renewed only under a lock, and read from the file first: one
/// renewed by another server since is taken up, not renewed again.
class SessionFile {
  final String dir;

  SessionFile(this.dir);

  /// `$XDG_CONFIG_HOME/caldo/mcp`, or `~/.config/caldo/mcp`.
  factory SessionFile.standard() {
    final env = Platform.environment;
    final config = env['XDG_CONFIG_HOME'] ?? '${env['HOME']}/.config';
    return SessionFile('$config/caldo/mcp');
  }

  File get _file => File('$dir/session.json');

  /// What is kept: the server's address and the session, or null.
  ({String server, String session})? read() {
    if (!_file.existsSync()) return null;
    try {
      final json = jsonDecode(_file.readAsStringSync()) as Map;
      return (
        server: json['server'] as String,
        session: jsonEncode(json['session']),
      );
    } catch (_) {
      return null;
    }
  }

  void write(String server, Session session) {
    Directory(dir).createSync(recursive: true);
    Process.runSync('chmod', ['700', dir]);
    // Made unreadable to others before anything is in it, then put in
    // place whole, so a server reading meanwhile never sees half of one.
    final next = File('${_file.path}.next')..writeAsStringSync('');
    Process.runSync('chmod', ['600', next.path]);
    next.writeAsStringSync(
      jsonEncode({'server': server, 'session': session.toJson()}),
    );
    next.renameSync(_file.path);
  }

  void clear() {
    if (_file.existsSync()) _file.deleteSync();
  }

  /// Runs [body] holding the lock every server shares.
  Future<T> locked<T>(Future<T> Function() body) async {
    Directory(dir).createSync(recursive: true);
    final lock = await File('$dir/session.lock').open(mode: FileMode.write);
    await lock.lock(FileLock.blockingExclusive);
    try {
      return await body();
    } finally {
      await lock.unlock();
      await lock.close();
    }
  }
}

/// [Remote] on Supabase, signed in with the session in [file].
class SupabaseRemote implements Remote {
  final SessionFile file;
  final SupabaseClient _client;
  final String server;

  SupabaseRemote._(this.file, this.server)
    : _client = clientFor(server, renews: false);

  /// The server the kept session belongs to; Caldo's own if none is kept.
  factory SupabaseRemote(SessionFile file) =>
      SupabaseRemote._(file, file.read()?.server ?? CaldoServer.url);

  /// A client for [address]. One that [renews] keeps its session fresh on a
  /// timer of its own; the server's renews only under the lock, by hand.
  static SupabaseClient clientFor(String address, {bool renews = true}) =>
      SupabaseClient(
        address,
        CaldoServer.keyFor(address),
        authOptions: AuthClientOptions(
          autoRefreshToken: renews,
          // A password needs no PKCE, as the app has it.
          authFlowType: AuthFlowType.implicit,
        ),
      );

  /// Signs in as [name] and keeps the session.
  static Future<String> signIn(
    SessionFile file,
    String server,
    String name,
    String password,
  ) async {
    final client = clientFor(server, renews: false);
    try {
      final response = await client.auth.signInWithPassword(
        email: CaldoServer.loginOf(name),
        password: password,
      );
      await file.locked(() async => file.write(server, response.session!));
      return CaldoServer.nameIn(response.user!.email ?? name);
    } finally {
      await client.dispose();
    }
  }

  /// Who the session is for, by name, or null with none.
  String? get name {
    final email = _client.auth.currentUser?.email;
    return email == null ? null : CaldoServer.nameIn(email);
  }

  /// A session good for a while yet: the one held, or the file's, renewed
  /// if it has run out.
  Future<void> ready() async {
    final held = _client.auth.currentSession;
    if (held != null && !_endingSoon(held)) return;
    await file.locked(() async {
      final kept = file.read();
      if (kept == null) {
        throw const SignedOut(
          'Not signed in to Caldo. Run `caldo-mcp login` in a terminal.',
        );
      }
      final stored = Session.fromJson(jsonDecode(kept.session));
      try {
        // Taken up only well short of the client's own 30s margin: a
        // session it finds expired, with renewing off, it signs out on the
        // server, ending it for every device. A worker held up between
        // the two looks met that once and sat signed out for 9 hours.
        if (stored != null && !_endingSoon(stored)) {
          // Still good (renewed by another server, perhaps): taken up as
          // it is.
          await _client.auth.recoverSession(kept.session);
        } else {
          // Renewed by hand: with renewing off, the client will not do it
          // in `recoverSession`, only sign out.
          await _client.auth.refreshSession(stored?.refreshToken);
        }
      } on AuthException catch (e) {
        if (e.statusCode == '400' || e.statusCode == '401') {
          file.clear();
          throw const SignedOut(
            'The Caldo session has ended. Run `caldo-mcp login` again.',
          );
        }
        rethrow;
      }
      final now = _client.auth.currentSession;
      if (now != null && now.refreshToken != _refreshIn(kept.session)) {
        file.write(server, now);
      }
    });
  }

  static bool _endingSoon(Session s) {
    final at = s.expiresAt;
    if (at == null) return true;
    return at - DateTime.now().millisecondsSinceEpoch ~/ 1000 < 60;
  }

  static String? _refreshIn(String session) =>
      (jsonDecode(session) as Map)['refresh_token'] as String?;

  @override
  Future<void> push(List<ServerRow> rows) async {
    await ready();
    await _client.rpc(
      'sync_push',
      params: {
        'rows': [for (final r in rows) r.toJson()],
      },
    );
  }

  @override
  Future<List<ServerRow>> pull(int since, int page) async {
    await ready();
    final rows = await _client.rpc(
      'sync_pull',
      params: {'since': since, 'page': page},
    );
    return [
      for (final r in rows as List)
        ServerRow.fromJson((r as Map).cast<String, Object?>()),
    ];
  }

  /// The client, its session good for a while yet: for the worker's
  /// tables, which are not synced rows.
  Future<SupabaseClient> signedIn() async {
    await ready();
    return _client;
  }

  /// The client as it is, for a realtime channel: one held open is told
  /// each renewed token by the client itself.
  SupabaseClient get client => _client;

  String? get userId => _client.auth.currentUser?.id;

  /// Says whenever the account's rows change on the server, as the app's
  /// realtime channel hears it (`Account._listen`). The channel signs in
  /// with the session held, and is told each renewed token by the client.
  Stream<void> changes() {
    final heard = StreamController<void>.broadcast();
    _client
        .channel('caldo-watch')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'sync_rows',
          callback: (_) => heard.add(null),
        )
        .subscribe();
    return heard.stream;
  }

  /// Ends this session on the server: its refresh token is spent for good.
  Future<void> signOut() => _client.auth.signOut(scope: SignOutScope.local);

  Future<void> dispose() => _client.dispose();
}

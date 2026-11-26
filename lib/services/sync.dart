import 'dart:async';

import 'package:flutter/foundation.dart';

import '../db/sync_store.dart';
import 'file_sync.dart';

/// Where the rows go: the account's copy on the server.
abstract class SyncServer {
  /// Who is signed in, or null.
  String? get account;

  /// Asked before each round: a session that could not be renewed while
  /// offline is tried again here.
  Future<void> ready() async {}

  /// Hands up rows changed here. The server keeps the later edit of each.
  Future<void> push(List<SyncRow> rows);

  /// The account's rows written after [since], oldest first, at most [page].
  Future<List<SyncRow>> pull(int since, int page);

  /// Where the account's attachment files are kept, or null for nowhere.
  FileStore? get files => null;
}

/// One round of sync: what changed here goes up, then what changed anywhere
/// comes down.
///
/// Up first, so that what comes down already has this device's changes
/// weighed against everyone else's on the server. A round asked for while
/// one is running is run once that one ends, rather than alongside it.
class Sync {
  /// The app's own, on its database; [Account] hands it a server.
  static final instance = Sync(SyncStore());

  final SyncStore store;
  final FileSync files;
  SyncServer? server;

  /// Called when a round has changed something here, to read the lists back.
  VoidCallback? onChanged;

  Sync(this.store, {this.server, FileSync? files})
    : files = files ?? FileSync(store.db);

  static const _batch = 200;
  static const _page = 500;

  /// When the last round finished, and how it ended.
  final ValueNotifier<DateTime?> lastSynced = ValueNotifier(null);
  final ValueNotifier<Object?> error = ValueNotifier(null);
  final ValueNotifier<bool> running = ValueNotifier(false);

  Future<bool>? _round;
  bool _again = false;
  Timer? _soon;
  Future<void>? _carrying;
  bool _carryAgain = false;

  /// A round in a moment: for a change just made here, or one heard of
  /// there. Changes come in bursts — a tick is a write and a read-back, a
  /// drag writes a whole day — and one round can carry the lot.
  ///
  /// Nothing at all without a server, so no timer is left behind in a test.
  void soon() {
    _pullWanted = true;
    _schedule();
  }

  /// A round in a moment if anything here is still to be sent: what a
  /// change made here asks for. A read of the lists back after a round had
  /// brought rows down asked for one more, two seconds on, which sent
  /// nothing and brought nothing.
  void sendSoon() => _schedule();

  bool _pullWanted = false;

  void _schedule() {
    if (server?.account == null) return;
    _soon?.cancel();
    _soon = Timer(const Duration(seconds: 2), () async {
      final pull = _pullWanted;
      _pullWanted = false;
      if (pull || await store.hasOutgoing()) unawaited(run());
    });
  }

  /// A row changed on the server, as realtime tells it. This device's own
  /// rows come back so the moment they are sent, and a round for them only
  /// brought them down again to be left as they were; anything else is a
  /// change from elsewhere, and a round fetches it.
  Future<void> heard(Map<String, dynamic> row) async {
    try {
      if (await store.holds(SyncRow.fromJson(row))) return;
    } catch (_) {
      // Not a row this can read: the round will say.
    }
    soon();
  }

  /// Runs a round, or has one run after the one under way. Says whether
  /// anything here changed.
  Future<bool> run() {
    if (_round != null) {
      _again = true;
      return _round!;
    }
    return _round = _rounds().whenComplete(() => _round = null);
  }

  Future<bool> _rounds() async {
    var changed = false;
    do {
      _again = false;
      changed = await _once() || changed;
    } while (_again);
    return changed;
  }

  Future<bool> _once() async {
    final server = this.server;
    if (server == null) return false;
    await server.ready();
    final account = server.account;
    if (account == null) return false;
    running.value = true;
    try {
      await store.adopt(account);
      final out = await store.outgoing();
      for (var i = 0; i < out.length; i += _batch) {
        final batch = out.sublist(i, (i + _batch).clamp(0, out.length));
        await server.push(batch);
        await store.sent(batch);
      }
      final (_, since) = await store.state();
      final down = <SyncRow>[];
      var cursor = since;
      while (true) {
        final page = await server.pull(cursor, _page);
        down.addAll(page);
        if (page.isNotEmpty) cursor = page.last.seq;
        if (page.length < _page) break;
      }
      final changed = await store.apply(down, cursor);
      lastSynced.value = DateTime.now();
      error.value = null;
      if (changed) onChanged?.call();
      _carry();
      return changed;
    } catch (e) {
      // Nothing is lost: what was not sent is still marked to send, and the
      // count is only moved on with what it was written beside.
      error.value = e;
      return false;
    } finally {
      running.value = false;
    }
  }

  /// Done once the files the rounds so far have asked for are carried.
  Future<void> get carried async {
    while (_carrying != null) {
      await _carrying;
    }
  }

  /// Carries the attachments' files after a round, apart from it: a photo
  /// on its way up should not hold back the next round's rows, and the
  /// rows naming a file have to be there before it.
  void _carry() {
    if (_carrying != null) {
      _carryAgain = true;
      return;
    }
    _carrying = _carryAll().whenComplete(() => _carrying = null);
  }

  Future<void> _carryAll() async {
    do {
      _carryAgain = false;
      final store = server?.files;
      if (store == null || server?.account == null) return;
      try {
        if (await files.carry(store)) onChanged?.call();
      } catch (e) {
        // Unreachable, most likely; carried after the next round.
        debugPrint('Attachments not carried: $e');
      }
    } while (_carryAgain);
  }
}

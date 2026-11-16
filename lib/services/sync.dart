import 'dart:async';

import 'package:flutter/foundation.dart';

import '../db/sync_store.dart';

/// Where the rows go: the account's copy on the server.
abstract class SyncServer {
  /// Who is signed in, or null.
  String? get account;

  /// Hands up rows changed here. The server keeps the later edit of each.
  Future<void> push(List<SyncRow> rows);

  /// The account's rows written after [since], oldest first, at most [page].
  Future<List<SyncRow>> pull(int since, int page);
}

/// One round of sync: what changed here goes up, then what changed anywhere
/// comes down.
///
/// Up first, so that what comes down already has this device's changes
/// weighed against everyone else's on the server. A round asked for while
/// one is running is run once that one ends, rather than alongside it.
class Sync {
  final SyncStore store;
  SyncServer? server;

  /// Called when a round has changed something here, to read the lists back.
  VoidCallback? onChanged;

  Sync(this.store, {this.server});

  static const _batch = 200;
  static const _page = 500;

  /// When the last round finished, and how it ended.
  final ValueNotifier<DateTime?> lastSynced = ValueNotifier(null);
  final ValueNotifier<Object?> error = ValueNotifier(null);
  final ValueNotifier<bool> running = ValueNotifier(false);

  Future<bool>? _round;
  bool _again = false;

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
    final account = server?.account;
    if (server == null || account == null) return false;
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
}

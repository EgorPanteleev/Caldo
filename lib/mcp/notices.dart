import 'dart:async';

/// When a worker tells the user's phones that a chat waits on them (asked
/// for 2026-11-25), from how its chats stand as they change.
///
/// - A question or a permission asked: told at once. Nothing goes on until
///   the user answers, whoever began the turn.
/// - A turn over: told after [hold], unless another has begun by then — a
///   message left for later, or one sent meanwhile, carries straight on.
///   Only a turn the user began: one begun by another chat's message or a
///   subscription's event is waited on by that chat, or by nobody. The
///   reviewer's rounds would otherwise ring all day.
///
/// - Stopped at the account's limit: told at once, whoever began the turn —
///   no chat goes on until the limit is lifted or the user says so.
/// - A pull request opened: told at once, and again among the turn's last
///   words when that is told, as a chat's newest notice takes the place of
///   the one before on the phone.
///
/// Only a turn seen to begin here is told as over, so a chat taken up again
/// after the worker restarts doesn't ring for one long done. A muted
/// chat's are dropped by the push function, which reads the chat anyway.
class Notices {
  /// Tells the phones of [chat], as `waiting` or `asking`, with [text]:
  /// the question, or what the agent said last (empty for unknown).
  final void Function(String chat, String kind, String text) tell;
  final Duration hold;

  Notices({required this.tell, this.hold = const Duration(seconds: 20)});

  final _turning = <String>{};
  final _fromOthers = <String>{};
  final _held = <String, Timer>{};

  /// The question last told, so one said again isn't told twice.
  final _asked = <String, String>{};

  /// Chats whose stop at the limit is told, until they run again.
  final _limited = <String>{};

  /// The pull requests opened in each chat's turn under way.
  final _opened = <String, List<String>>{};

  /// A message for [chat]: the user's for a null [sender], else another
  /// chat's, an assistant's outside Caldo or an event.
  void heard(String chat, Map? sender) {
    if (sender == null) {
      _fromOthers.remove(chat);
    } else {
      _fromOthers.add(chat);
    }
  }

  /// Keys typed into [chat]'s terminal: the user's own, whatever came last.
  void typed(String chat) => _fromOthers.remove(chat);

  /// [chat] now stands [to]; [said] is the agent's last words, if known.
  void stands(String chat, String to, {String? note, String? said}) {
    switch (to) {
      case 'running':
        _held.remove(chat)?.cancel();
        _turning.add(chat);
        _asked.remove(chat);
        _limited.remove(chat);
      case 'asking':
        _held.remove(chat)?.cancel();
        // Answered, it runs on, and its end is told as any turn's.
        _turning.add(chat);
        final question = note ?? '';
        if (_asked[chat] == question) return;
        _asked[chat] = question;
        tell(chat, 'asking', question);
      case 'finished' || 'your_turn':
        _asked.remove(chat);
        final opened = _opened.remove(chat) ?? const [];
        if (!_turning.remove(chat) || _fromOthers.contains(chat)) return;
        _held.remove(chat)?.cancel();
        final text = [
          for (final pull in opened) 'Opened pull request $pull.',
          ?note ?? said,
        ].join('\n');
        _held[chat] = Timer(hold, () {
          _held.remove(chat);
          tell(chat, 'waiting', text);
        });
      case 'limited':
        // The turn's end, if it was about to be told, is this instead.
        _held.remove(chat)?.cancel();
        _turning.remove(chat);
        _asked.remove(chat);
        _opened.remove(chat);
        if (!_limited.add(chat)) return;
        tell(chat, 'waiting', note ?? 'Out of usage: stopped at the limit.');
      default:
        // Idle (its program up, or gone), ended, failed: nothing to tell.
        // Who spoke last still stands for the next turn.
        _held.remove(chat)?.cancel();
        _turning.remove(chat);
        _asked.remove(chat);
        _opened.remove(chat);
    }
  }

  /// [chat] opened the pull request [pull] (`owner/repo#12`).
  void opened(String chat, String pull) {
    if (_turning.contains(chat)) (_opened[chat] ??= []).add(pull);
    tell(chat, 'waiting', 'Opened pull request $pull.');
  }

  /// [chat] deleted: nothing kept of it.
  void forget(String chat) {
    _limited.remove(chat);
    _opened.remove(chat);
    _held.remove(chat)?.cancel();
    _turning.remove(chat);
    _asked.remove(chat);
    _fromOthers.remove(chat);
  }
}

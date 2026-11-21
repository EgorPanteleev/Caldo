import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/task.dart';
import 'book.dart';
import 'tools.dart';

/// What Claude is asked to do for one task, where, and by which model.
class Errand {
  final String prompt;

  /// The folder Claude works in.
  final String dir;

  /// The model the task names ([Task.claude]).
  final String model;

  /// The session to carry on, for a task handed back after an answer.
  final String? resume;

  const Errand(this.prompt, this.dir, this.model, {this.resume});
}

/// What came back from Claude.
class Answer {
  final bool ok;
  final String text;
  final String? session;

  /// The tools Claude was not let use, as it named them.
  final List<String> refused;

  const Answer(this.ok, this.text, {this.session, this.refused = const []});
}

/// Runs `claude -p` on an errand, nobody at the keys: what it may do
/// without asking is [permissionMode]'s to say ("auto" lets a classifier
/// pass the safe and stop the rest; everything stopped is reported).
class ClaudeCli {
  final String command;
  final String permissionMode;
  final Duration timeout;

  const ClaudeCli({
    this.command = 'claude',
    this.permissionMode = 'auto',
    this.timeout = const Duration(minutes: 30),
  });

  Future<Answer> call(Errand errand) async {
    final process = await Process.start(command, [
      '-p',
      '--output-format',
      'json',
      '--permission-mode',
      permissionMode,
      '--model',
      errand.model,
      if (errand.resume != null) ...['--resume', errand.resume!],
    ], workingDirectory: errand.dir);
    // On stdin rather than as an argument: a task's notes may be long.
    process.stdin.write(errand.prompt);
    await process.stdin.close();
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    if (code == -1) {
      return Answer(false, 'Stopped after ${timeout.inMinutes} minutes.');
    }
    final said = await out;
    try {
      final json = jsonDecode(said) as Map;
      return Answer(
        json['is_error'] != true && json['subtype'] == 'success',
        (json['result'] as String? ?? '').trim(),
        session: json['session_id'] as String?,
        refused: [
          for (final d in json['permission_denials'] as List? ?? const [])
            if (d is Map) '${d['tool_name']}',
        ],
      );
    } on FormatException {
      final why = (await err).trim();
      return Answer(
        false,
        'claude exited with $code'
        '${why.isEmpty ? '' : ': ${_tail(why, 600)}'}',
      );
    }
  }
}

/// What the watcher keeps between runs, beside the session: the task it
/// was in the middle of, and each answered task's Claude session.
class WatchState {
  final File file;

  /// The uuid of the task being worked on, while it is.
  String? running;

  /// Per task uuid, the session that answered it and the folder it ran in:
  /// a session is carried on only from where it began.
  final Map<String, ({String session, String dir})> sessions = {};

  WatchState(this.file) {
    if (!file.existsSync()) return;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map;
      running = json['running'] as String?;
      for (final MapEntry(:key, :value)
          in (json['sessions'] as Map? ?? const {}).entries) {
        sessions[key as String] = (
          session: value['session'] as String,
          dir: value['dir'] as String,
        );
      }
    } catch (_) {
      // Unreadable: started afresh; at worst a session is not carried on.
    }
  }

  void save() {
    file.parent.createSync(recursive: true);
    final next = File('${file.path}.next')
      ..writeAsStringSync(
        jsonEncode({
          'running': running,
          'sessions': {
            for (final MapEntry(:key, :value) in sessions.entries)
              key: {'session': value.session, 'dir': value.dir},
          },
        }),
      );
    next.renameSync(file.path);
  }
}

/// Hands Claude the tasks the app has handed to a model ([Task.claude]),
/// and writes what it did back into them.
///
/// The board says how each stands, so the phone shows it with nothing more
/// in the app: a task handed over is Not started until taken up; then In
/// progress; answered, it is ticked off with the answer in its notes. One that could not be done stays In progress with the reason, and
/// moved back to Not started — a note added, say — it is taken up again,
/// in the same Claude session, which then has its earlier work in mind.
/// A task with a date waits for its day (or its time), so an errand can be
/// set for later, and a repeating one comes back each round.
class Watcher {
  final Caldo caldo;
  final Future<Answer> Function(Errand errand) hand;
  final WatchState state;

  /// Where Claude works when a task does not say (an "in: ~/dir" line).
  final String dir;

  final void Function(String line) log;

  /// The time, put back for tests.
  final DateTime Function() _now;

  Watcher({
    required this.caldo,
    required this.hand,
    required this.state,
    required this.dir,
    void Function(String line)? log,
    DateTime Function()? now,
  }) : log = log ?? print,
       _now = now ?? DateTime.now;

  /// Most of an answer that the notes take; the rest stays in the session.
  static const _longest = 6000;

  /// The tasks waiting for Claude, earliest due first.
  List<Held> get waiting {
    final now = _now();
    final today = DateTime(now.year, now.month, now.day);
    return [
      for (final h in caldo.book.tasks)
        if (h.task.claude != null &&
            h.task.stage == Stage.notStarted &&
            _isDue(h.task, now, today))
          h,
    ]..sort((a, b) => (a.task.dueAt ?? 0).compareTo(b.task.dueAt ?? 0));
  }

  static bool _isDue(Task t, DateTime now, DateTime today) {
    final due = t.due;
    if (due == null) return true;
    return t.hasTime ? !due.isAfter(now) : !t.dueDay!.isAfter(today);
  }

  /// Works through what is waiting, then again whenever [heard] says the
  /// account changed, and every [every] whatever it says: realtime may
  /// drop, the pull costs little.
  Future<Never> run({
    Stream<void>? heard,
    Duration every = const Duration(minutes: 1),
  }) async {
    String? failing;
    Future<void> safely(Future<Object?> Function() body) async {
      try {
        await body();
        failing = null;
      } catch (e) {
        // Said once, not every minute while the network is down.
        if ('$e' != failing) log('$e');
        failing = '$e';
      }
    }

    var wake = Completer<void>();
    heard?.listen((_) {
      if (!wake.isCompleted) wake.complete();
    });
    await safely(recover);
    while (true) {
      await safely(once);
      await Future.any([wake.future, Future<void>.delayed(every)]);
      if (wake.isCompleted) {
        // A phone sends a change as a few pushes; let them all land.
        await Future<void>.delayed(const Duration(seconds: 2));
        wake = Completer<void>();
      }
    }
  }

  /// Notes on a task left In progress by a watcher that stopped part way.
  Future<void> recover() async {
    final uuid = state.running;
    if (uuid == null) return;
    await caldo.refresh();
    final h = caldo.book.tasks.where((h) => h.uuid == uuid).firstOrNull;
    if (h != null && h.task.stage == Stage.inProgress) {
      await _note(
        h,
        'Interrupted: the watcher stopped before Claude had finished. '
        'Move it back to Not started to try again.',
      );
    }
    state
      ..running = null
      ..save();
  }

  /// Pulls, and works through every task waiting; how many there were.
  Future<int> once() async {
    await caldo.refresh();
    var done = 0;
    // One at a time, read again after each: the last may have taken long,
    // and what is waiting may have changed meanwhile.
    for (var next = waiting.firstOrNull; next != null;) {
      await _work(next);
      done++;
      await caldo.refresh();
      next = waiting.firstOrNull;
    }
    return done;
  }

  Future<void> _work(Held h) async {
    try {
      await caldo.setStage({'id': h.uuid, 'stage': 'in_progress'});
    } on Refusal catch (e) {
      // Changed elsewhere at that moment; looked at again next time.
      log('[${h.id}] not taken up: $e');
      return;
    }
    state
      ..running = h.uuid
      ..save();
    final model = h.task.claude!;
    log('[${h.id}] ${h.task.title}: handed to Claude ($model)');

    final where = _dirOf(h.task.notes);
    final last = state.sessions[h.uuid];
    Answer answer;
    try {
      if (!Directory(where).existsSync()) {
        answer = Answer(false, 'There is no folder $where on this computer.');
      } else if (last != null && last.dir == where && h.task.repeat.isNone) {
        answer = await hand(
          Errand(_againPrompt(h.task), where, model, resume: last.session),
        );
        // A session gone from this computer: begun again from the task.
        if (!answer.ok && answer.session == null) {
          answer = await hand(Errand(_prompt(h.task), where, model));
        }
      } else {
        answer = await hand(Errand(_prompt(h.task), where, model));
      }
    } catch (e) {
      answer = Answer(false, 'Claude could not be started: $e');
    }

    if (answer.session case final session?) {
      state.sessions[h.uuid] = (session: session, dir: where);
    }
    state
      ..running = null
      ..save();
    log(
      '[${h.id}] ${answer.ok ? 'answered' : 'not done'}'
      '${answer.session == null ? '' : ' (session ${answer.session})'}',
    );

    await caldo.refresh();
    final now = caldo.book.tasks.where((t) => t.uuid == h.uuid).firstOrNull;
    if (now == null) {
      log('[${h.id}] deleted meanwhile; the answer is in the session only.');
      return;
    }
    final said = StringBuffer(
      answer.text.isEmpty ? '(Claude said nothing.)' : _cut(answer.text),
    );
    if (answer.refused.isNotEmpty) {
      said.write('\n\nNot allowed: ${answer.refused.toSet().join(', ')}.');
    }
    if (!answer.ok) {
      said.write(
        '\n\nNot done. Move it back to Not started to try again'
        '${answer.session == null ? '' : '; Claude will remember this try'}.',
      );
    }
    await _note(now, said.toString());
    if (answer.ok && now.task.stage == Stage.inProgress) {
      await caldo.completeTask({'id': h.uuid});
    }
  }

  Future<void> _note(Held h, String text) async {
    final at = _now();
    final stamp =
        '${at.day}.${at.month.toString().padLeft(2, '0')} '
        '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    try {
      await caldo.updateTask({
        'id': h.uuid,
        'append_notes': '— Claude, $stamp —\n$text',
      });
    } on Refusal catch (e) {
      log('[${h.id}] answer not written: $e');
    }
  }

  /// The folder a task's notes name with a line "in: ~/somewhere", or
  /// [dir].
  String _dirOf(String notes) {
    final line = RegExp(
      r'^\s*(?:in|dir):\s*(\S.*?)\s*$',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(notes);
    final named = line?.group(1);
    if (named == null) return dir;
    final home = Platform.environment['HOME'] ?? '';
    return named == '~'
        ? home
        : named.startsWith('~/')
        ? '$home${named.substring(1)}'
        : named;
  }

  String _prompt(Task t) {
    final out = StringBuffer(
      'This task was handed to you from Caldo, the user\'s calendar and '
      'to-do app. Nobody is watching this session and no one can answer questions: do the task '
      'yourself, here on the user\'s computer. If something you need is '
      'missing, or a step is risky or can\'t be undone, stop there and say '
      'what is needed instead.\n\n'
      'Your last message is written into the task\'s notes for the user to '
      'read on their phone, so keep it short and plain: what you did, '
      'where, and anything left for them. Do not tick the task off or edit '
      'it with the Caldo tools; that is done for you.\n\n'
      'Task: ${t.title}\n',
    );
    if (t.due != null) out.writeln('Due: ${t.due}');
    if (t.notes.isNotEmpty) out.write('Notes:\n${t.notes}\n');
    if (t.subtasks.isNotEmpty) {
      out.writeln('Checklist:');
      for (final s in t.subtasks) {
        out.writeln('- [${s.done ? 'x' : ' '}] ${s.title}');
      }
    }
    return out.toString();
  }

  String _againPrompt(Task t) =>
      'The user has handed this task back to you in Caldo. Read its notes '
      'as they are now (your earlier answer is in them, and anything the '
      'user has added since is after it) and carry on. Answer as before: '
      'short, for the notes.\n\n'
      'Task: ${t.title}\n'
      '${t.notes.isEmpty ? '' : 'Notes:\n${t.notes}\n'}';

  static String _cut(String text) => text.length <= _longest
      ? text
      : '${text.substring(0, _longest)}…\n(The rest is in the Claude session.)';
}

String _tail(String text, int most) =>
    text.length <= most ? text : '…${text.substring(text.length - most)}';

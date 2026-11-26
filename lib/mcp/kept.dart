import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'agent_scope.dart';

/// A chat's program — Claude's `stream-json`, Codex's app server — run
/// apart from the worker, so it lives on while the worker is started again
/// (reinstalled, restarted by systemd), as a terminal's does in tmux. As
/// the worker's child on pipes it went with the worker, and its turn with
/// it.
///
/// Its input is a named pipe it holds open itself, so it never reads an
/// end while no worker is writing; what it writes, and how it ended, go to
/// files beside the terminals' (`<base>.out`, `.err`, `.code`), and what
/// is written to it is kept too (`.written`). A worker started again finds
/// it by its files and reads on from where the last one got to
/// ([offset]).
class Kept {
  /// Its files' path, less their endings.
  final String base;

  /// The program's own pid, to stop it, and the shell's that waits on it,
  /// to know it is still there.
  final int _pid;
  final int _shell;

  /// How far into its output has been handed on.
  int offset;

  Kept._(this.base, this._pid, this._shell, this.offset);

  /// The shell between: holds the pipe open read-write (so the program,
  /// reading it, never sees an end), runs the program, says both pids, and
  /// leaves its exit status once it ends.
  static const _script = r'''
b=$1; shift
exec 3<>"$b.in"
"$@" <&3 >>"$b.out" 2>>"$b.err" 3<&- &
echo "$! $$" > "$b.pid.next" && mv "$b.pid.next" "$b.pid"
wait $!
echo $? > "$b.code.next" && mv "$b.code.next" "$b.code"
''';

  /// Runs [argv] in [cwd], its files at [base], with [environment] added
  /// to the worker's own.
  static Future<Kept> start(
    String base,
    List<String> argv, {
    required String cwd,
    Map<String, String>? environment,
  }) async {
    clear(base);
    File(base).parent.createSync(recursive: true);
    final pipe = await Process.run('mkfifo', ['$base.in']);
    if (pipe.exitCode != 0) {
      throw StateError('No pipe for it: ${pipe.stderr}'.trim());
    }
    File('$base.out').createSync();
    final launch = agentScope([
      'sh',
      '-c',
      _script,
      'sh',
      base,
      ...argv,
    ], errors: '$base.err');
    final launcher = await Process.start(
      launch.first,
      launch.sublist(1),
      workingDirectory: cwd,
      environment: environment,
      mode: ProcessStartMode.detached,
    );
    // Starting a scope under a slice short of memory has taken 7s; 5s was
    // given, and the program came up after it was called failed — then the
    // next message started a second on the same session beside it.
    final until = DateTime.now().add(startWithin);
    while (DateTime.now().isBefore(until)) {
      final kept = _read(base, 0);
      if (kept != null) return kept;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final errors = File('$base.err');
    final why = errors.existsSync() ? errors.readAsStringSync().trim() : '';
    await _abandon(launcher.pid);
    clear(base);
    throw StateError('${argv.first} did not start. $why'.trim());
  }

  /// How long a program is given to come up.
  static Duration startWithin = const Duration(seconds: 30);

  /// A launch given up on, ended with all it started: detached, it leads
  /// a process group of its own, and its scope is named by its pid.
  static Future<void> _abandon(int pid) async {
    await Process.run('kill', ['-KILL', '--', '-$pid']);
    if (Platform.environment.containsKey('CALDO_AGENT_SLICE')) {
      await Process.run('systemctl', [
        '--user',
        'stop',
        'caldo-agent-$pid.scope',
      ]);
    }
  }

  /// The program started at [base] by a worker before this one, read up to
  /// [offset]: running still, or ended with its last words unread; null if
  /// there is none.
  static Kept? find(String base, int offset) => _read(base, offset);

  /// An old program may still have output to read after it has exited.
  bool get hasExited => _code != null || !_alive;

  static Kept? _read(String base, int offset) {
    try {
      final pids = File('$base.pid').readAsStringSync().trim().split(' ');
      return Kept._(base, int.parse(pids[0]), int.parse(pids[1]), offset);
    } catch (_) {
      return null;
    }
  }

  /// Its files gone: it has ended, or is ended now.
  static void clear(String base) {
    for (final end in const ['in', 'out', 'err', 'pid', 'code', 'written']) {
      try {
        File('$base.$end').deleteSync();
      } on FileSystemException {
        // Not there.
      }
    }
  }

  /// Whether the shell waiting on it is still there: ended hard, or the
  /// computer started again, it is not — and its pid may be another's by
  /// now, so the shell is known by its words.
  bool get _alive {
    if (Directory('/proc').existsSync()) {
      try {
        return File('/proc/$_shell/cmdline').readAsStringSync().contains(base);
      } on FileSystemException {
        return false;
      }
    }
    final ps = Process.runSync('ps', ['-o', 'args=', '-p', '$_shell']);
    return '${ps.stdout}'.contains(base);
  }

  /// Its exit status, once it has ended.
  int? get _code {
    final file = File('$base.code');
    if (!file.existsSync()) return null;
    try {
      return int.tryParse(file.readAsStringSync().trim()) ?? -1;
    } on FileSystemException {
      return null;
    }
  }

  /// Its whole lines up to [offset]: what a worker before this one handed
  /// on already, read again to know where it stands.
  Iterable<String> before() sync* {
    final file = File('$base.out');
    if (!file.existsSync()) return;
    final raf = file.openSync();
    try {
      final bytes = raf.readSync(min(offset, raf.lengthSync()));
      // Up to the last line's end: the rest is read on as it comes.
      final end = bytes.lastIndexOf(10) + 1;
      offset = end;
      yield* const LineSplitter().convert(
        utf8.decode(bytes.sublist(0, end), allowMalformed: true),
      );
    } finally {
      raf.closeSync();
    }
  }

  /// What was written to it, a line each.
  Iterable<String> written() {
    try {
      return File('$base.written').readAsLinesSync();
    } on FileSystemException {
      return const [];
    }
  }

  Timer? _reading;
  RandomAccessFile? _out;
  final _part = <int>[];

  void Function(String line)? _onLine;
  void Function(int code, String why)? _onExit;

  /// Reads in a row that found nothing new.
  int _quiet = 0;
  DateTime _looked = DateTime.now();

  /// Hands on each whole line of its output as it comes, every few
  /// milliseconds, and [onExit] once it has ended and all of it is read.
  ///
  /// Read every 30ms while it writes, less often the longer it has been
  /// quiet, down to four times a second: a program waiting between turns
  /// was looked at 33 times a second for hours, on the thread that also
  /// sends what the others write. Anything written to it ([write]) has it
  /// read briskly again, as an answer is on its way.
  void listen(
    void Function(String line) onLine,
    void Function(int code, String why) onExit,
  ) {
    _onLine = onLine;
    _onExit = onExit;
    _quiet = 0;
    _readSoon();
  }

  static Duration _gapAfter(int quiet) => Duration(
    milliseconds: quiet < 10
        ? 30
        : quiet < 40
        ? 100
        : 250,
  );

  void _readSoon() {
    _reading?.cancel();
    _reading = Timer(_gapAfter(_quiet), _readNow);
  }

  void _readNow() {
    final onLine = _onLine;
    final onExit = _onExit;
    if (onLine == null || onExit == null) return;
    // Its status first: once there, all it wrote is in its file.
    final code = _code;
    final read = _readOn(onLine);
    // A look for the shell about once a second.
    var gone = false;
    final now = DateTime.now();
    if (code == null && now.difference(_looked) >= const Duration(seconds: 1)) {
      _looked = now;
      gone = !_alive;
    }
    if (code == null && !gone) {
      _quiet = read ? 0 : _quiet + 1;
      _readSoon();
      return;
    }
    _stopReading();
    onExit(code ?? -1, gone ? 'It was ended from outside.' : _why());
  }

  /// Whether anything was read.
  bool _readOn(void Function(String line) onLine) {
    try {
      final out = _out ??= File('$base.out').openSync();
      out.setPositionSync(offset);
      final more = out.lengthSync() - offset;
      if (more <= 0) return false;
      final bytes = out.readSync(more);
      offset += bytes.length;
      var from = 0;
      for (var i = 0; i < bytes.length; i++) {
        if (bytes[i] != 10) continue;
        _part.addAll(bytes.sublist(from, i));
        from = i + 1;
        final line = utf8.decode(_part, allowMalformed: true);
        _part.clear();
        onLine(line);
      }
      _part.addAll(bytes.sublist(from));
      return true;
    } on FileSystemException {
      // Its files cleared under it: it is being ended.
      return false;
    }
  }

  /// Its last few lines of errors, to say why it ended if it ended badly.
  String _why() {
    try {
      final lines = File('$base.err').readAsLinesSync();
      return lines.skip(lines.length > 6 ? lines.length - 6 : 0).join('\n');
    } on FileSystemException {
      return '';
    }
  }

  void _stopReading() {
    _reading?.cancel();
    _reading = null;
    _onLine = null;
    _onExit = null;
    _out?.closeSync();
    _out = null;
  }

  RandomAccessFile? _in;
  Future<void> _writing = Future.value();

  /// [line] written to it, after what was written before. The pipe is
  /// opened read-write, as a seek on it would be refused and a write-only
  /// open would wait for a reader that has gone.
  void write(String line) {
    if (_onLine != null && _quiet > 0) {
      _quiet = 0;
      _readSoon();
    }
    _writing = _writing
        .then((_) async {
          final into = _in ??= await File(
            '$base.in',
          ).open(mode: FileMode.write);
          await into.writeString('$line\n');
          await File(
            '$base.written',
          ).writeAsString('$line\n', mode: FileMode.append);
        })
        .catchError((Object _) {
          // Gone: its exit says so.
        });
  }

  /// Ends it — asked, then made to after [grace] — and clears its files.
  Future<void> stop({Duration grace = const Duration(seconds: 3)}) async {
    _stopReading();
    if (_code == null && _alive) Process.killPid(_pid, ProcessSignal.sigterm);
    final until = DateTime.now().add(grace);
    while (_code == null && _alive && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (_code == null && _alive) Process.killPid(_pid, ProcessSignal.sigkill);
    await _writing.whenComplete(() => _in?.close());
    clear(base);
  }
}

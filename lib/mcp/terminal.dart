import 'dart:convert';
import 'dart:io';

/// The terminals a worker runs its chats in: one tmux session each, on a
/// tmux server of Caldo's own (`tmux -L caldo`).
///
/// tmux rather than a terminal of the worker's own: a chat lives on when
/// the worker is started again, and can be looked at on the computer
/// itself (`tmux -L caldo attach -t c<id>`). What a program writes is
/// piped as it is into a file the worker reads on ([outOf]), and keys go
/// in as bytes, so the app's terminal sees what the program wrote.
class Tmux {
  final String socket;

  /// Where each chat's output, events and start flag are kept.
  final String dir;

  Tmux({this.socket = 'caldo', required this.dir});

  static bool get installed =>
      Process.runSync('sh', ['-c', 'command -v tmux']).exitCode == 0;

  Future<ProcessResult> _tmux(List<String> args) =>
      Process.run('tmux', ['-L', socket, '-f', '/dev/null', ...args]);

  static String nameOf(String chat) => 'c${chat.replaceAll('-', '')}';

  String outOf(String chat) => '$dir/$chat.out';
  String eventsOf(String chat) => '$dir/$chat.events';

  /// Starts [argv] in [cwd] for [chat] at [cols]×[rows]. The program waits
  /// for a flag until the pipe is in place, or its first words — Claude's
  /// whole first screen — would go unread.
  Future<void> start(
    String chat,
    List<String> argv, {
    required String cwd,
    required int cols,
    required int rows,
  }) async {
    Directory(dir).createSync(recursive: true);
    final flag = '$dir/$chat.go';
    final name = nameOf(chat);
    final made = await _tmux([
      'new-session', '-d', '-s', name, '-x', '$cols', '-y', '$rows',
      '-c', cwd,
      '--',
      'sh', '-c',
      'while [ ! -e "\$0" ]; do sleep 0.05; done; rm -f "\$0"; '
          'export TERM=xterm-256color COLORTERM=truecolor; exec "\$@"',
      flag, ...argv,
      // Kept by the server for every session after: the pane stays once
      // its program ends, so its exit is read; its size is the app's.
      ';', 'set', '-g', 'remain-on-exit', 'on',
      ';', 'set', '-g', 'window-size', 'manual',
      ';', 'set', '-g', 'history-limit', '5000',
      ';', 'set', '-g', 'escape-time', '0',
      // Claude asks for it, to know when its terminal is looked at.
      ';', 'set', '-g', 'focus-events', 'on',
      ';', 'pipe-pane', '-O', '-t', name, 'cat >> ${_quoted(outOf(chat))}',
    ]);
    if (made.exitCode != 0) {
      throw StateError('tmux would not start it: ${made.stderr}'.trim());
    }
    File(flag).writeAsStringSync('');
  }

  /// The chats with a session here, and for each whether its program has
  /// ended and how.
  Future<Map<String, ({bool dead, int status})>> panes() async {
    final r = await _tmux([
      'list-panes',
      '-a',
      '-F',
      '#{session_name} #{pane_dead} #{pane_dead_status}',
    ]);
    // No server: nothing running.
    if (r.exitCode != 0) return const {};
    return {
      for (final line in LineSplitter.split('${r.stdout}'))
        if (line.split(' ') case [final name, final dead, ...final rest])
          name: (dead: dead == '1', status: int.tryParse(rest.join()) ?? 0),
    };
  }

  /// Bytes as if typed: escape sequences and all, as the app's terminal
  /// put them out.
  Future<void> keys(String chat, List<int> bytes) async {
    if (bytes.isEmpty) return;
    await _tmux([
      'send-keys',
      '-t',
      nameOf(chat),
      '-H',
      for (final b in bytes) b.toRadixString(16),
    ]);
  }

  /// [text] pasted (bracketed, if the program asked for it), then Enter on
  /// its own a moment later: Claude takes text and Enter that arrive
  /// together as one paste, the Enter a new line in it.
  Future<void> line(String chat, String text) async {
    final name = nameOf(chat);
    if (text.isNotEmpty) {
      await _tmux([
        'set-buffer',
        '-b',
        name,
        '--',
        text,
        ';',
        'paste-buffer',
        '-p',
        '-d',
        '-b',
        name,
        '-t',
        name,
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    await _tmux(['send-keys', '-t', name, 'Enter']);
  }

  Future<void> resize(String chat, int cols, int rows) => _tmux([
    'resize-window',
    '-t',
    nameOf(chat),
    '-x',
    '$cols',
    '-y',
    '$rows',
  ]);

  Future<void> kill(String chat) => _tmux(['kill-session', '-t', nameOf(chat)]);

  /// The screen as it stands, scrollback and all, as bytes that draw it on
  /// a blank terminal of the same size, the cursor left where it is — and
  /// the modes its program had turned on put back: drawn from a picture
  /// alone, the app's terminal no longer knew Claude takes the mouse, and
  /// a swipe was sent as arrow keys, which step through its history.
  Future<String?> snapshot(String chat) async {
    final name = nameOf(chat);
    final at = await _tmux([
      'display',
      '-p',
      '-t',
      name,
      '#{cursor_x} #{cursor_y} #{alternate_on} ${[for (final (flag, _) in modes) '#{$flag}'].join(' ')}',
    ]);
    if (at.exitCode != 0) return null;
    final [x, y, alt, ...flags] = '${at.stdout}'.trim().split(' ');
    final shot = await _tmux([
      'capture-pane',
      '-p',
      '-e',
      '-t',
      name,
      if (alt != '1') ...['-S', '-2000'],
    ]);
    if (shot.exitCode != 0) return null;
    final lines = '${shot.stdout}'.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    return '\x1b[0m\x1b[H\x1b[2J'
        '${alt == '1' ? '\x1b[?1049h\x1b[H\x1b[2J' : ''}'
        '${lines.join('\x1b[0m\r\n')}'
        '\x1b[0m\x1b[${int.parse(y) + 1};${int.parse(x) + 1}H'
        '${modesOf(flags)}';
  }

  /// The private modes a snapshot restores, by the tmux flag that says
  /// whether each is on: the mouse's reports, bracketed paste, the
  /// cursor's keys and whether it shows.
  static const modes = [
    ('mouse_standard_flag', 1000),
    ('mouse_button_flag', 1002),
    ('mouse_all_flag', 1003),
    ('mouse_utf8_flag', 1005),
    ('mouse_sgr_flag', 1006),
    ('bracket_paste_flag', 2004),
    ('keypad_cursor_flag', 1),
    ('cursor_flag', 25),
  ];

  /// Each of [modes] set or reset as [flags] (tmux's `1` or `0`) say.
  static String modesOf(List<String> flags) => [
    for (final (i, (_, mode)) in modes.indexed)
      if (i < flags.length) '\x1b[?$mode${flags[i] == '1' ? 'h' : 'l'}',
  ].join();

  /// A chat's files, once it is done with.
  void forget(String chat) {
    for (final f in [outOf(chat), eventsOf(chat), '$dir/$chat.go']) {
      final file = File(f);
      if (file.existsSync()) file.deleteSync();
    }
  }
}

String _quoted(String s) => "'${s.replaceAll("'", r"'\''")}'";

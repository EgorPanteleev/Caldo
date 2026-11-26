import 'dart:io';

/// One file of what Claude is told on a worker beside a project's own
/// words: a `CLAUDE.md` it reads in the project's folders, the user's own
/// for every folder, or one of its memory files.
class ContextFile {
  /// From `~`.
  final String path;

  /// `user`: `~/.claude/CLAUDE.md`, read in every folder; `folder`: a
  /// `CLAUDE.md` of a source or of a folder above it; `memory`: one of
  /// Claude's memory files for a source's repository.
  final String kind;

  /// The project folder it is read for, from `~`; null for the user's own.
  final String? source;

  /// Its words; null for one not written yet.
  final String? body;

  /// In a git repository, with a change not committed: a chat's worktree
  /// is made from the last commit, so it doesn't see the change yet.
  final bool uncommitted;

  const ContextFile({
    required this.path,
    required this.kind,
    this.source,
    this.body,
    this.uncommitted = false,
  });

  String get name => path.split('/').last;

  bool get memory => kind == 'memory';

  factory ContextFile.fromJson(Map json) => ContextFile(
    path: '${json['path']}',
    kind: '${json['kind']}',
    source: json['source'] as String?,
    body: json['body'] as String?,
    uncommitted: json['uncommitted'] == true,
  );

  Map<String, Object?> toJson() => {
    'path': path,
    'kind': kind,
    'source': ?source,
    'body': body,
    if (uncommitted) 'uncommitted': true,
  };
}

/// A file written by someone else since it was read: not written over.
class ContextChanged implements Exception {
  final String path;

  const ContextChanged(this.path);

  @override
  String toString() => '$path was changed on the computer since it was read';
}

/// The files of a project's context on a worker, read and written for the
/// app (`agent_context_asks`). Only `CLAUDE.md` files and memory files are
/// ever written, and only over what was read.
class ContextFiles {
  /// The names Claude reads its instructions from in a folder.
  static const _names = ['CLAUDE.md', '.claude/CLAUDE.md', 'CLAUDE.local.md'];

  /// Bigger files are none of Claude's instructions, and too much for a row.
  static const _most = 512 * 1024;

  /// What Claude is told on this computer in [sources] (from `~`): the
  /// user's own `CLAUDE.md` first, then per source the `CLAUDE.md` files
  /// from the home folder down to it (one to write offered where there is
  /// none) and its repository's memory, its index first.
  static Future<List<ContextFile>> read(
    String home,
    List<String> sources,
  ) async {
    final user = '$home/.claude/CLAUDE.md';
    final out = <ContextFile>[await _file(home, user, kind: 'user')];
    final seen = {out.first.path};
    void add(ContextFile f) {
      if (seen.add(f.path)) out.add(f);
    }

    for (final source in sources) {
      final dir = expand(home, source.trim());
      if (!Directory(dir).existsSync()) continue;
      final short = shorten(home, dir);
      final top = await _top(dir) ?? dir;
      var any = false;
      for (final folder in _down(home, dir)) {
        for (final name in _names) {
          final path = '$folder/$name';
          // The home folder's `.claude/CLAUDE.md` is the user's own.
          if (path == user || !File(path).existsSync()) continue;
          any = true;
          add(await _file(home, path, kind: 'folder', source: short));
        }
      }
      // Where one would be read first: the repository's top.
      if (!any) {
        add(await _file(home, '$top/CLAUDE.md', kind: 'folder', source: short));
      }
      final memory = Directory(memoryOf(home, await _main(dir) ?? top));
      if (!memory.existsSync()) continue;
      final files =
          [
            for (final e in memory.listSync())
              if (e is File && e.path.endsWith('.md')) e.path,
          ]..sort((a, b) {
            final index = (a.endsWith('/MEMORY.md') ? 0 : 1).compareTo(
              b.endsWith('/MEMORY.md') ? 0 : 1,
            );
            return index != 0 ? index : a.compareTo(b);
          });
      for (final path in files) {
        add(await _file(home, path, kind: 'memory', source: short));
      }
    }
    return out;
  }

  /// [path] (from `~`) written with [body], or taken away for null (a
  /// memory file only), if it still holds [was] (null: if it isn't there).
  static Future<ContextFile> write(
    String home,
    String path, {
    required String? body,
    required String? was,
  }) async {
    final full = expand(home, path);
    final kind = kindOf(home, full);
    if (kind == null) {
      throw ArgumentError('Only CLAUDE.md and memory files are written: $path');
    }
    if (body == null && kind != 'memory') {
      throw ArgumentError('Only a memory file is taken away: $path');
    }
    final file = File(full);
    final now = file.existsSync() ? file.readAsStringSync() : null;
    if (now != was) throw ContextChanged(path);
    if (body == null) {
      file.deleteSync();
    } else {
      file.parent.createSync(recursive: true);
      // Whole or not at all: Claude may read it at any moment.
      final next = File('$full.caldo-next')..writeAsStringSync(body);
      next.renameSync(full);
    }
    return _file(
      home,
      full,
      kind: kind,
      source: kind == 'user' ? null : shorten(home, file.parent.path),
    );
  }

  /// What [full] is of the files Caldo writes, or null for any other.
  static String? kindOf(String home, String full) {
    if (!full.startsWith('$home/') ||
        full.split('/').any((s) => s == '..' || s == '.')) {
      return null;
    }
    if (full == '$home/.claude/CLAUDE.md') return 'user';
    final parts = full.substring(home.length + 1).split('/');
    if (parts.length == 5 &&
        parts[0] == '.claude' &&
        parts[1] == 'projects' &&
        parts[3] == 'memory' &&
        parts[4].endsWith('.md') &&
        !parts[4].startsWith('.')) {
      return 'memory';
    }
    if (_names.any((n) => full.endsWith('/$n'))) return 'folder';
    return null;
  }

  /// Where Claude keeps its memory of the folder [top]: in a folder named
  /// by the path, every character but letters and digits a dash.
  static String memoryOf(String home, String top) =>
      '$home/.claude/projects/'
      '${top.replaceAll(RegExp('[^A-Za-z0-9]'), '-')}/memory';

  static String expand(String home, String dir) => dir == '~'
      ? home
      : dir.startsWith('~/')
      ? '$home${dir.substring(1)}'
      : dir;

  static String shorten(String home, String path) => path == home
      ? '~'
      : path.startsWith('$home/')
      ? '~${path.substring(home.length)}'
      : path;

  /// [dir] and the folders above it to [home], the highest first, as
  /// Claude reads them; only [dir] if it is not under [home].
  static List<String> _down(String home, String dir) {
    if (!dir.startsWith('$home/')) return [dir];
    final out = [dir];
    for (var at = dir; at.startsWith('$home/');) {
      at = at.substring(0, at.lastIndexOf('/'));
      out.insert(0, at);
    }
    return out;
  }

  static Future<ContextFile> _file(
    String home,
    String path, {
    required String kind,
    String? source,
  }) async {
    final file = File(path);
    String? body;
    if (file.existsSync() && file.lengthSync() <= _most) {
      try {
        body = file.readAsStringSync();
      } on FileSystemException {
        // Not text: shown as missing rather than garbled.
      }
    }
    return ContextFile(
      path: shorten(home, path),
      kind: kind,
      source: source,
      body: body,
      uncommitted: body != null && kind == 'folder' && await _uncommitted(path),
    );
  }

  /// The top of [dir]'s repository, or null outside one.
  static Future<String?> _top(String dir) async =>
      (await _git(dir, ['rev-parse', '--show-toplevel']))?.trim();

  /// The top of the main checkout of [dir]'s repository, whose memory
  /// Claude reads in each of its worktrees too.
  static Future<String?> _main(String dir) async {
    final common = (await _git(dir, [
      'rev-parse',
      '--path-format=absolute',
      '--git-common-dir',
    ]))?.trim();
    if (common == null) return null;
    return common.endsWith('/.git')
        ? common.substring(0, common.length - 5)
        : _top(dir);
  }

  static Future<bool> _uncommitted(String path) async {
    final out = await _git(File(path).parent.path, [
      'status',
      '--porcelain',
      '--',
      path,
    ]);
    return out != null && out.trim().isNotEmpty;
  }

  static Future<String?> _git(String dir, List<String> args) async {
    try {
      final r = await Process.run('git', args, workingDirectory: dir);
      return r.exitCode == 0 ? '${r.stdout}' : null;
    } on ProcessException {
      return null;
    }
  }
}

import 'dart:io';

/// A project's info, kept in Caldo, written into each of its folders on a
/// worker's computer as the files Claude and Codex read there on their own
/// (asked 2026-11-26: "the only source of context, for all chats and
/// claude or codex in dir"): `CLAUDE.local.md` and `AGENTS.override.md`.
/// Caldo holds the one copy; these are written over whenever it changes,
/// and kept out of git (`.git/info/exclude`), so they are never committed
/// and a chat's worktree, made from a commit, never has them — Caldo's
/// chats are told the info apart, and read no such file (`quietEnv`,
/// [codexQuiet]).
class ProjectFiles {
  /// The names written: Claude's local instructions, and Codex's, which it
  /// reads in place of a folder's `AGENTS.md`.
  static const names = ['CLAUDE.local.md', 'AGENTS.override.md'];

  /// How a file written here begins: one without it is the user's, and is
  /// neither written over nor removed.
  static const mark = '<!-- Written by Caldo';

  /// Whether [body] is one of these files, not the user's own words.
  static bool written(String? body) => body?.startsWith(mark) ?? false;

  /// What goes in a folder for [projects] (`(name, info)`, those naming
  /// it); empty when none has any info.
  static String bodyOf(List<(String, String)> projects) {
    final parts = [
      for (final (name, info) in projects)
        if (info.trim().isNotEmpty) (name.trim(), info.trim()),
    ];
    if (parts.isEmpty) return '';
    final names = parts.map((p) => '"${p.$1}"').join(', ');
    return [
      '$mark from the project info of $names. Change it in Caldo, or with '
          'its update_project_info tool, not here: it is written over. -->',
      for (final (_, info) in parts) info,
    ].join('\n\n');
  }

  /// [dir]'s files made to say [body], or removed for an empty one; a file
  /// of the user's own left as it is. The names of those left so, for the
  /// worker to say why.
  static Future<List<String>> write(String dir, String body) async {
    final kept = <String>[];
    var wrote = false;
    for (final name in names) {
      final file = File('$dir/$name');
      final was = file.existsSync() ? file.readAsStringSync() : null;
      if (was != null && !written(was)) {
        kept.add(file.path);
        continue;
      }
      if (body.isEmpty) {
        if (was != null) file.deleteSync();
      } else if (was != '$body\n') {
        file.writeAsStringSync('$body\n');
        wrote = true;
      }
    }
    if (wrote) await _exclude(dir);
    return kept;
  }

  /// [names] kept out of git in [dir]'s repository, if it is in one: in
  /// its own `info/exclude`, not a `.gitignore` that would be committed.
  static Future<void> _exclude(String dir) async {
    final r = await Process.run('git', [
      'rev-parse',
      '--path-format=absolute',
      '--git-path',
      'info/exclude',
    ], workingDirectory: dir);
    if (r.exitCode != 0) return;
    final file = File('${r.stdout}'.trim());
    // Anchored to the folder from the repository's top, as git reads it.
    final top = await Process.run('git', [
      'rev-parse',
      '--show-prefix',
    ], workingDirectory: dir);
    final prefix = top.exitCode == 0 ? '${top.stdout}'.trim() : '';
    final had = file.existsSync() ? file.readAsLinesSync() : const <String>[];
    final missing = [
      for (final name in names)
        if (!had.contains('/$prefix$name')) name,
    ];
    if (missing.isEmpty) return;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      [
        if (had.isNotEmpty && had.last.isNotEmpty) '',
        '# Caldo writes these from a project\'s info.',
        for (final name in missing) '/$prefix$name',
        '',
      ].join('\n'),
      mode: FileMode.append,
    );
  }
}

/// What Codex is started with in Caldo's chats: no `AGENTS.md` or
/// `AGENTS.override.md` read, as it is told its context apart.
const codexQuiet = ['-c', 'project_doc_max_bytes=0'];

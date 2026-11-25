import 'dart:io';

/// A chat's own folder on its worker, `~/.local/share/caldo/work/<chat>`, in
/// place of a folder chosen on the form. Each source of its project that is
/// in a git repository is a worktree of that repository there, on a branch
/// of the chat's own (`caldo/<id>`), so chats on one project don't write
/// over each other or over the user's own checkout; a source that is not
/// is the user's folder itself, given to the agent beside it.
///
/// Where it was made is written on the chat (`chats.workspace`, [toJson]),
/// so a chat started again finds the same folders, and Claude the same
/// session, whose transcript is kept by the folder it began in.
class Workspace {
  /// The chat's own folder.
  final String root;
  final List<Place> places;

  const Workspace(this.root, this.places);

  /// The folder its program starts in: the one worktree, so its
  /// repository's CLAUDE.md and settings are read from the start, or the
  /// chat's own folder, with every worktree in it.
  String get cwd {
    final trees = [
      for (final p in places)
        if (p.branch != null) p.path,
    ]..sort((a, b) => a.length.compareTo(b.length));
    // Several sources in one repository are one worktree.
    if (trees.isEmpty || !trees.every((t) => _within(t, trees.first))) {
      return root;
    }
    return trees.first;
  }

  /// The folders it is given besides [cwd]: the sources that are no
  /// repository's, and the worktrees outside [cwd].
  List<String> get added => [
    for (final p in places)
      if (!_within(p.path, cwd)) p.path,
  ];

  Map<String, Object?> toJson() => {
    'root': root,
    'places': [for (final p in places) p.toJson()],
  };

  /// What the chat's `workspace` says was made; null if it is still to be.
  static Workspace? of(Object? json) {
    if (json is! Map || json['root'] is! String) return null;
    return Workspace(json['root'] as String, [
      for (final p in json['places'] as List? ?? const [])
        if (p is Map) Place.fromJson(p),
    ]);
  }

  /// Where chat [chat]'s folder is under [home].
  static String rootOf(String home, String chat) => '${_work(home)}/$chat';

  static String _work(String home) => '$home/.local/share/caldo/work';

  /// The branch chat [chat]'s worktrees are on.
  static String branchOf(String chat) => 'caldo/${chat.substring(0, 8)}';

  /// Makes chat [chat]'s workspace for [sources] (already expanded), or
  /// finds what is left of it: a worktree gone is made again on its branch.
  /// Throws, saying which, if a source is not on this computer.
  static Future<Workspace> make(
    String home,
    String chat,
    List<String> sources,
  ) async {
    final root = rootOf(home, chat);
    final branch = branchOf(chat);
    Directory(root).createSync(recursive: true);
    final places = <Place>[];
    // A repository's worktree by its top folder, made once however many of
    // its folders are sources.
    final trees = <String, String>{};
    final names = <String>{};
    for (final source in sources) {
      if (!Directory(source).existsSync()) {
        throw FileSystemException('There is no folder $source', source);
      }
      final top = await _topOf(source);
      if (top == null) {
        places.add(Place(source: source, path: source));
        continue;
      }
      var tree = trees[top];
      if (tree == null) {
        tree = '$root/${_free(names, _baseName(top))}';
        await _worktree(top, tree, branch);
        trees[top] = tree;
      }
      final within = source == top ? '' : source.substring(top.length);
      places.add(Place(source: source, path: '$tree$within', branch: branch));
    }
    return Workspace(root, places);
  }

  /// Chat [chat]'s workspace gone, the chat deleted: its worktrees taken
  /// out of their repositories, its branch with them if it holds nothing
  /// not merged (else kept, so no commit is lost), and its folder deleted.
  /// What it had not committed goes with it.
  static Future<void> remove(String home, String chat) async {
    final root = Directory(rootOf(home, chat));
    if (!root.existsSync()) return;
    for (final e in root.listSync()) {
      if (e is! Directory || !File('${e.path}/.git').existsSync()) continue;
      final common = (await _git(e.path, [
        'rev-parse',
        '--path-format=absolute',
        '--git-common-dir',
      ]))?.trim();
      if (common == null || common.isEmpty) continue;
      await _git(home, [
        '--git-dir=$common',
        'worktree',
        'remove',
        '--force',
        e.path,
      ]);
      await _git(home, ['--git-dir=$common', 'branch', '-d', branchOf(chat)]);
    }
    if (root.existsSync()) root.deleteSync(recursive: true);
  }

  /// The chats whose folders are under [home], by id.
  static List<String> made(String home) {
    final dir = Directory(_work(home));
    if (!dir.existsSync()) return const [];
    return [
      for (final e in dir.listSync())
        if (e is Directory && _uuid.hasMatch(_baseName(e.path)))
          _baseName(e.path),
    ];
  }

  /// [tree] made a worktree of [top] on [branch]: the branch made from
  /// what [top] has checked out, or taken up if it is there from before.
  static Future<void> _worktree(String top, String tree, String branch) async {
    if (File('$tree/.git').existsSync()) return;
    await _git(top, ['worktree', 'prune']);
    final there =
        await _git(top, ['rev-parse', '--verify', '--quiet', branch]) != null;
    final made = await _git(top, [
      'worktree',
      'add',
      if (there) ...[tree, branch] else ...['-b', branch, tree],
    ], failing: true);
    if (made == null) throw StateError('No worktree of $top could be made.');
  }

  /// The top folder of the git repository [dir] is in, or null.
  static Future<String?> _topOf(String dir) async =>
      (await _git(dir, ['rev-parse', '--show-toplevel']))?.trim();

  /// git's output for [args] run in [dir], or null if it failed — thrown,
  /// with what git said, if [failing].
  static Future<String?> _git(
    String dir,
    List<String> args, {
    bool failing = false,
  }) async {
    try {
      final r = await Process.run('git', args, workingDirectory: dir);
      if (r.exitCode == 0) return '${r.stdout}';
      if (!failing) return null;
      throw StateError('git ${args.first}: ${'${r.stderr}'.trim()}');
    } on ProcessException {
      if (failing) rethrow;
      return null;
    }
  }

  static String _baseName(String path) =>
      path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? 'source';

  /// [name], or with a number after it if it is taken in [names].
  static String _free(Set<String> names, String name) {
    var out = name;
    for (var n = 2; !names.add(out); n++) {
      out = '$name-$n';
    }
    return out;
  }

  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  static bool _within(String path, String dir) =>
      path == dir || path.startsWith('$dir/');
}

/// One source of a chat's project, and where the chat works on it: a
/// worktree on [branch], or, with none, the source itself.
class Place {
  final String source;
  final String path;
  final String? branch;

  const Place({required this.source, required this.path, this.branch});

  factory Place.fromJson(Map json) => Place(
    source: '${json['source']}',
    path: '${json['path']}',
    branch: json['branch'] as String?,
  );

  Map<String, Object?> toJson() => {
    'source': source,
    'path': path,
    'branch': ?branch,
  };
}

/// A chat's project, `{name, context: [{name, body}]}` as the app keeps it
/// on the chat, written out as the agent is told it: the project's words
/// and its parents', the whole project's first; null if it has none.
String? projectText(Object? project) {
  if (project is! Map) return null;
  final name = '${project['name'] ?? ''}'.trim();
  final parts = [
    for (final c in project['context'] as List? ?? const [])
      if (c case {'body': final String body} when body.trim().isNotEmpty)
        switch ('${c['name'] ?? ''}'.trim()) {
          '' => body.trim(),
          final named => '## $named\n\n${body.trim()}',
        },
  ];
  if (name.isEmpty && parts.isEmpty) return null;
  return [
    name.isEmpty
        ? 'This session is part of one of the user\'s projects.'
        : 'This session is part of the user\'s project "$name".',
    if (parts.isNotEmpty)
      'What they wrote about it, the whole project first:\n\n'
          '${parts.join('\n\n')}',
  ].join(' ');
}

/// What the agent is told of [workspace]: where it is, and which folders
/// are its own to change and which are the user's.
String? workspaceText(Workspace? workspace) {
  if (workspace == null) return null;
  final lines = [
    'You work in a folder of your own made for this session, '
        '${workspace.root}.',
    for (final p in workspace.places)
      p.branch != null
          ? '${p.path} is a git worktree of ${p.source} on a branch of this '
                'session\'s own, ${p.branch}: change and commit there, not in '
                '${p.source}, which is the user\'s own checkout.'
          : '${p.path} is the user\'s own folder, not a copy: what you change '
                'there is changed for them and their other sessions.',
  ];
  return lines.join('\n');
}

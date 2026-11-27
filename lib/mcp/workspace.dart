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

/// What a chat is told it knows, as kept in Caldo, in place of the
/// CLAUDE.md and memory files Claude would read on its own (kept from it by
/// `quietEnv`; Codex reads no CLAUDE.md). Two of each (asked 2026-11-27:
/// "one where agents writing, second where im writing my own
/// instructions"): its [project]'s (`{name, instructions, context: [{name,
/// body}]}`, as the worker read it at the start) instructions, the user's,
/// and info, kept by its chats; the instructions and notes of the chats it
/// is part of ([parents], `[{id, title, context, notes}]`, outermost first:
/// a subchat has all its parent has); then its [own] instructions and its
/// [notes], which its agent keeps. Null if there is none of it.
String? contextText(
  Object? project,
  Object? parents,
  Object? own, [
  Object? notes,
]) {
  String attr(String s) => s.replaceAll('"', "'");
  String tag(String name, String attrs, String words) =>
      '<$name$attrs>\n$words\n</$name>';
  final parts = <String>[];
  if (project is Map) {
    final name = '${project['name'] ?? ''}'.trim();
    final named = name.isEmpty ? '' : ' project="${attr(name)}"';
    final told = '${project['instructions'] ?? ''}'.trim();
    if (told.isNotEmpty) parts.add(tag('project-instructions', named, told));
    final words = [
      for (final c in project['context'] as List? ?? const [])
        if (c case {'body': final String body} when body.trim().isNotEmpty)
          body.trim(),
    ].join('\n\n');
    if (name.isNotEmpty || words.isNotEmpty) {
      parts.add(
        words.isEmpty
            ? '<project-info$named/>'
            : tag('project-info', named, words),
      );
    }
  }
  for (final p in parents is List ? parents : const []) {
    if (p is! Map) continue;
    final id = '${p['id'] ?? ''}';
    final short = id.length < 8 ? id : id.substring(0, 8);
    final title = '${p['title'] ?? ''}'.trim();
    final at =
        ' chat="$short"${title.isEmpty ? '' : ' title="${attr(title)}"'}';
    final words = '${p['context'] ?? ''}'.trim();
    if (words.isNotEmpty) parts.add(tag('parent-instructions', at, words));
    final kept = '${p['notes'] ?? ''}'.trim();
    if (kept.isNotEmpty) parts.add(tag('parent-notes', at, kept));
  }
  final mine = own is String ? own.trim() : '';
  if (mine.isNotEmpty) parts.add(tag('own-instructions', '', mine));
  final kept = notes is String ? notes.trim() : '';
  if (kept.isNotEmpty) parts.add(tag('own-notes', '', kept));
  if (parts.isEmpty) return null;
  final file = project is Map && project['file'] is String
      ? project['file'] as String
      : null;
  final change = file == null
      ? "change it with Caldo's update_project_info tool (project_info "
            'reads it as it is now)'
      : 'edit its file, $file (it is saved to Caldo within seconds and '
            "reaches every chat), or use Caldo's update_project_info tool; "
            'read the file first, as it may have changed since this session '
            'began';
  return [
    "This session's context, as kept in Caldo. It stands in for CLAUDE.md "
        'files and memory, which are not read here. The instructions are '
        "the user's own words: follow them, and never change them (you "
        'have no way to). The info and notes are kept by agents. '
        "project-instructions and project-info are the project's, shared "
        'by every chat in it: when your work changes something project-info '
        'says, or it lacks something every chat there should know, $change. '
        'Never write a CLAUDE.md or AGENTS.md for it. parent-instructions '
        'and parent-notes are those of the chats this one is part of, '
        "outermost first. own-instructions are this chat's alone; "
        "own-notes are this chat's notes to itself, which it reads again "
        'after a restart or a cleared context: keep in them what it must '
        "not forget of its work, with Caldo's update_chat_notes tool "
        '(chat_notes reads them).',
    ...parts,
  ].join('\n\n');
}

/// What the agent is told of [workspace]: where it is, and which folders
/// are its own to change and which are the user's. [shared] for a
/// subchat's, which is the folder of the chat it is part of.
String? workspaceText(Workspace? workspace, {bool shared = false}) {
  if (workspace == null) return null;
  final whose = shared
      ? 'of the chat this one is part of'
      : 'of this session\'s own';
  final lines = [
    shared
        ? 'You work in the folder of the chat this one is part of, '
              '${workspace.root}, shared with it and its other subchats: what '
              'you change there is changed for them too.'
        : 'You work in a folder of your own made for this session, '
              '${workspace.root}.',
    for (final p in workspace.places)
      p.branch != null
          ? '${p.path} is a git worktree of ${p.source} on a branch $whose, '
                '${p.branch}: change and commit there, not in '
                '${p.source}, which is the user\'s own checkout.'
          : '${p.path} is the user\'s own folder, not a copy: what you change '
                'there is changed for them and their other sessions.',
  ];
  return lines.join('\n');
}

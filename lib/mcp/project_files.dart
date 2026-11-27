import 'dart:convert';
import 'dart:io';

/// What a worker reads and saves of the account's projects
/// (`agent_projects`), for [ProjectSync]: the server in the worker, a
/// stand-in in tests.
abstract class ProjectStore {
  /// Every project, by name: `id`, `name`, `context`, `version`,
  /// `sources`, `instructions`.
  Future<List<Map<String, dynamic>>> projects();

  /// Project [id]'s info saved as [text] by [by], only if it is still at
  /// version [expect]; its new version, or null if it was not.
  Future<int?> save(String id, String text, int expect, String by);

  /// An edit that could not be merged with a change made meanwhile, kept
  /// in the project's history to restore, not made its info.
  Future<void> keepUnmerged(String id, String text, int version, String by);
}

/// A project's info, kept in Caldo, as a file on each worker's computer
/// that goes both ways (asked 2026-11-26: "the only source of context, for
/// all chats and claude or codex in dir", then the file made two-way).
///
/// Each project has one file here, `~/.local/share/caldo/projects/<id>.md`,
/// and each folder it names a link to it under the names Claude and Codex
/// read on their own: `CLAUDE.local.md` and `AGENTS.override.md` (in place
/// of a folder's `AGENTS.md`). Both kept out of git in `.git/info/exclude`.
/// A change in Caldo is written into the file; an edit of the file — by an
/// agent, or by hand — is saved to Caldo, only on the version last seen
/// ([ProjectStore.save]), so nothing is written over unseen. Changed in
/// both, the two are merged as git merges (`git merge-file`); where they
/// can't be, Caldo's stands and the edit is kept in the history.
///
/// The last text the file and Caldo agreed on, its "base", is kept per
/// project in `.base/`, and its version in `.sync.json`, so a worker
/// started again knows which side changed.
class ProjectSync {
  final String home;
  final ProjectStore store;

  /// This computer's name, for who saved an edit (`computer:<name>`).
  final String computer;
  final void Function(String line) log;

  ProjectSync({
    required this.home,
    required this.store,
    required this.computer,
    required this.log,
    Iterable<String> linkedBefore = const [],
  }) : dir = '$home/.local/share/caldo/projects' {
    _read(linkedBefore);
  }

  /// Where the projects' files are.
  final String dir;

  /// The names linked in a project's folders.
  static const names = ['CLAUDE.local.md', 'AGENTS.override.md'];

  /// How a project's file begins; one at a link's place without it is the
  /// user's own, and is left as it is.
  static const mark = '<!-- Caldo project info';

  /// How Caldo's one-way copies from before began: taken in, then linked.
  static const _oldMark = '<!-- Written by Caldo';

  /// Whether [body] is a project's file, not the user's own words.
  static bool written(String? body) =>
      body != null && (body.startsWith(mark) || body.startsWith(_oldMark));

  /// Project [id]'s file.
  String fileOf(String id) => '$dir/${_short(id)}.md';

  String _baseOf(String id) => '$dir/.base/${_short(id)}.md';

  static String _short(String id) => id.length < 8 ? id : id.substring(0, 8);

  /// Per project id, the version its base is at.
  final Map<String, int> _versions = {};

  /// The folders a link was put in, to take them away once no project
  /// names the folder.
  final Set<String> _linked = {};

  /// The folders each project has links in, as the last pass found them:
  /// watched for an edit made through a link put in a file's place.
  Map<String, List<String>> get folders => Map.unmodifiable(_folders);
  final Map<String, List<String>> _folders = {};

  /// Said once a run: files of the user's own, folders named twice.
  final _said = <String>{};

  File get _stateFile => File('$dir/.sync.json');

  void _read(Iterable<String> linkedBefore) {
    try {
      final json = jsonDecode(_stateFile.readAsStringSync()) as Map;
      for (final MapEntry(:key, :value)
          in (json['versions'] as Map? ?? const {}).entries) {
        _versions['$key'] = (value as num).toInt();
      }
      _linked.addAll([for (final d in json['linked'] as List? ?? []) '$d']);
    } catch (_) {
      // None yet: the folders written into before, one way.
      _linked.addAll(linkedBefore);
    }
  }

  void _save() {
    Directory(dir).createSync(recursive: true);
    final next = File('${_stateFile.path}.next')
      ..writeAsStringSync(
        jsonEncode({'versions': _versions, 'linked': _linked.toList()}),
      );
    next.renameSync(_stateFile.path);
  }

  /// One pass over every project: Caldo's changes written into the files,
  /// the files' edits saved to Caldo, links put where they belong. The
  /// ids of projects whose info changed, for their chats to be told.
  Future<Set<String>> run() async {
    final rows = await store.projects();
    final changed = <String>{};
    final owner = <String, String>{};
    final names = <String, String>{};
    for (final row in rows) {
      final id = '${row['id']}';
      names[id] = '${row['name'] ?? ''}'.trim();
      for (final s in row['sources'] as List? ?? const []) {
        final source = '$s'.trim();
        if (source.isEmpty) continue;
        final folder = _expand(source);
        if (!Directory(folder).existsSync()) continue;
        final first = owner.putIfAbsent(folder, () => id);
        if (first != id && _said.add('twice $folder $id')) {
          log(
            'projects: $folder is named by "${names[first]}" and '
            '"${names[id]}"; only the first\'s info is linked there',
          );
        }
      }
    }
    _folders.clear();
    for (final MapEntry(key: folder, value: id) in owner.entries) {
      (_folders[id] ??= []).add(folder);
    }
    for (final row in rows) {
      final id = '${row['id']}';
      if (await _one(row, _folders[id] ?? const [])) changed.add(id);
    }
    // Projects deleted: their files and links go.
    final ids = {for (final r in rows) _short('${r['id']}')};
    final files = Directory(dir).existsSync()
        ? Directory(dir).listSync().whereType<File>()
        : const <File>[];
    for (final f in files) {
      final name = f.uri.pathSegments.last;
      if (!name.endsWith('.md')) continue;
      final id = name.substring(0, name.length - 3);
      if (ids.contains(id)) continue;
      f.deleteSync();
      final base = File('$dir/.base/$name');
      if (base.existsSync()) base.deleteSync();
      _versions.removeWhere((k, _) => _short(k) == id);
    }
    // Folders no project names any more: Caldo's links and copies go.
    for (final folder in _linked.difference(owner.keys.toSet())) {
      for (final name in ProjectSync.names) {
        final at = '$folder/$name';
        if (!_ours(at)) continue;
        // A link's target may be gone already: the link itself goes.
        FileSystemEntity.typeSync(at, followLinks: false) ==
                FileSystemEntityType.link
            ? Link(at).deleteSync()
            : File(at).deleteSync();
      }
    }
    _linked
      ..clear()
      ..addAll(owner.keys);
    _save();
    return changed;
  }

  /// Project [row] in step with its file and the links in [folders];
  /// whether its info is new since the last pass.
  Future<bool> _one(Map<String, dynamic> row, List<String> folders) async {
    final id = '${row['id']}';
    final name = '${row['name'] ?? ''}'.trim();
    final server = '${row['context'] ?? ''}'.trim();
    final told = '${row['instructions'] ?? ''}'.trim();
    final version = (row['version'] as num?)?.toInt() ?? 1;
    final file = File(fileOf(id));
    final baseFile = File(_baseOf(id));
    final base = baseFile.existsSync() ? baseFile.readAsStringSync() : null;
    final seen = _versions[id];

    // Every place an edit may be: the file, and a link's place where an
    // editor wrote a file of its own in place of the link.
    final copies = <(String, String, DateTime)>[];
    if (_isFile(file.path)) {
      if (_body(file.readAsStringSync()) case final body?) {
        copies.add((file.path, body, _mtime(file)));
      }
    }
    for (final folder in folders) {
      for (final n in names) {
        final at = '$folder/$n';
        if (!_isFile(at)) continue;
        final text = File(at).readAsStringSync();
        if (!written(text)) {
          if (_said.add('own $at')) {
            log('projects: $at is not Caldo\'s; left as it is');
          }
          continue;
        }
        if (_body(text) case final body?) {
          copies.add((at, body, _mtime(File(at))));
        }
      }
    }

    var now = server;
    var at = version;
    final by = 'computer:$computer';
    final edits = base == null
        ? const <(String, String, DateTime)>[]
        : (copies.where((c) => c.$2 != base).toList()
            ..sort((a, b) => b.$3.compareTo(a.$3)));
    if (edits.isNotEmpty) {
      final mine = edits.first.$2;
      // Two places edited apart: the latest is taken, the rest kept.
      for (final other in edits.skip(1)) {
        if (other.$2 != mine) {
          await store.keepUnmerged(id, other.$2, version, by);
        }
      }
      if (version == seen || server == base) {
        // Caldo unchanged since: the edit is saved as it is.
        final saved = await store.save(id, mine, version, by);
        if (saved == null) return false; // Changed just now: next pass.
        now = mine;
        at = saved;
        log('projects: "$name" saved from its file (version $saved)');
      } else {
        final merged = await _merge(base!, mine, server);
        if (merged != null) {
          final saved = merged == server
              ? version
              : await store.save(id, merged, version, by);
          if (saved == null) return false;
          now = merged;
          at = saved;
          log('projects: "$name" merged with its file (version $saved)');
        } else {
          await store.keepUnmerged(id, mine, version, by);
          log(
            'projects: "$name" was changed in Caldo and in its file at '
            'once; Caldo\'s kept, the file\'s in its history',
          );
        }
      }
    }

    final text = _withMark(name, now, told);
    if (!_isFile(file.path) || file.readAsStringSync() != text) {
      _write(file, text);
    }
    if (base != now) {
      baseFile.parent.createSync(recursive: true);
      baseFile.writeAsStringSync(now);
    }
    final fresh = seen != at;
    _versions[id] = at;
    for (final folder in folders) {
      var linked = false;
      for (final n in names) {
        final place = '$folder/$n';
        if (_link(place, file.path)) linked = true;
      }
      if (linked) await _exclude(folder);
    }
    return fresh && seen != null;
  }

  /// [place] made a link to [target], unless the user has a file of their
  /// own there; whether it was made now.
  bool _link(String place, String target) {
    final type = FileSystemEntity.typeSync(place, followLinks: false);
    if (type == FileSystemEntityType.link) {
      if (Link(place).targetSync() == target) return false;
      Link(place).deleteSync();
    } else if (type == FileSystemEntityType.file) {
      if (!written(File(place).readAsStringSync())) return false;
      File(place).deleteSync();
    } else if (type != FileSystemEntityType.notFound) {
      return false;
    }
    Link(place).createSync(target);
    return true;
  }

  /// Whether [place] is a link to a project's file, or a copy of Caldo's.
  bool _ours(String place) {
    final type = FileSystemEntity.typeSync(place, followLinks: false);
    if (type == FileSystemEntityType.link) {
      return Link(place).targetSync().startsWith('$dir/');
    }
    return type == FileSystemEntityType.file &&
        written(File(place).readAsStringSync());
  }

  static bool _isFile(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.file;

  static DateTime _mtime(File f) => f.lastModifiedSync();

  /// Written whole into a new file and moved over the old, so a reader
  /// never finds half of it; the links name the path, and still reach it.
  static void _write(File file, String text) {
    file.parent.createSync(recursive: true);
    final next = File('${file.path}.next')..writeAsStringSync(text);
    next.renameSync(file.path);
  }

  /// Where the user's instructions begin and end in a project's file: read
  /// there, never saved from it, as only the user changes them, in Caldo.
  static const _toldFrom =
      "<!-- The user's instructions, read only: they are changed in Caldo, "
      'not here. -->';
  static const _toldTo =
      '<!-- End of the user\'s instructions. The project info below is kept '
      'by its agents: change it as your work changes what it says. -->';

  String _withMark(String name, String body, [String told = '']) {
    final named = name.replaceAll('"', "'").replaceAll('-->', '');
    final head =
        '$mark for "$named": edit it here, or with Caldo\'s '
        'update_project_info tool. It is saved to Caldo within seconds and '
        'reaches every chat in the project. -->';
    if (told.isEmpty) return '$head\n\n$body\n';
    return '$head\n\n$_toldFrom\n\n$told\n\n$_toldTo\n\n$body\n';
  }

  /// [text] without the line that heads a project's file, nor the user's
  /// instructions after it; null if it can't be told where they end — an
  /// editor took the end's mark away — so nothing of it is saved.
  static String? _body(String text) {
    if (!written(text)) return text.trim();
    final end = text.indexOf('-->');
    if (end < 0) return '';
    final rest = text.substring(end + 3);
    final to = rest.indexOf(_toldTo);
    if (to >= 0) return rest.substring(to + _toldTo.length).trim();
    if (rest.contains(_toldFrom)) return null;
    return rest.trim();
  }

  /// [mine] and [theirs], both changed from [base], as one; null if they
  /// changed the same lines.
  static Future<String?> _merge(String base, String mine, String theirs) async {
    final tmp = Directory.systemTemp.createTempSync('caldo-merge');
    try {
      File('${tmp.path}/mine').writeAsStringSync('$mine\n');
      File('${tmp.path}/base').writeAsStringSync('$base\n');
      File('${tmp.path}/theirs').writeAsStringSync('$theirs\n');
      final r = await Process.run('git', [
        'merge-file',
        '-p',
        '${tmp.path}/mine',
        '${tmp.path}/base',
        '${tmp.path}/theirs',
      ]);
      return r.exitCode == 0 ? '${r.stdout}'.trim() : null;
    } finally {
      tmp.deleteSync(recursive: true);
    }
  }

  String _expand(String path) {
    final full = path == '~'
        ? home
        : path.startsWith('~/')
        ? '$home${path.substring(1)}'
        : path;
    return full.replaceAll(RegExp(r'/+$'), '');
  }

  /// [names] kept out of git in [folder]'s repository, if it is in one:
  /// in its own `info/exclude`, not a `.gitignore` that would be committed.
  static Future<void> _exclude(String folder) async {
    final r = await Process.run('git', [
      'rev-parse',
      '--path-format=absolute',
      '--git-path',
      'info/exclude',
    ], workingDirectory: folder);
    if (r.exitCode != 0) return;
    final file = File('${r.stdout}'.trim());
    // Anchored to the folder from the repository's top, as git reads it.
    final top = await Process.run('git', [
      'rev-parse',
      '--show-prefix',
    ], workingDirectory: folder);
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
        '# Caldo links these to a project\'s info.',
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

/// What Codex is started with in Caldo's chats: told nothing from the
/// folder ([codexQuiet]), free to write [file], its project's info, and
/// given Caldo's own MCP server ([codexCaldo]), as Claude has it.
List<String> codexInCaldo(String? file) => [
  ...codexQuiet,
  ...codexMayWrite(file),
  ...codexCaldo(),
];

/// Caldo's MCP server for Codex, whether or not the user set one up for
/// it (asked 2026-11-26: "make everything for codex too"): its tools, told
/// by `CALDO_CHAT` which chat calls them — Codex hands a server only the
/// variables named in `env_vars` — and let to wait as long as
/// `message_chat` may (2h), past Codex's own 60s. None if `caldo-mcp` is
/// not on the PATH.
List<String> codexCaldo() => switch (caldoMcp) {
  final command? => [
    '-c',
    'mcp_servers.caldo.command=${jsonEncode(command)}',
    '-c',
    'mcp_servers.caldo.env_vars=["CALDO_CHAT"]',
    '-c',
    'mcp_servers.caldo.tool_timeout_sec=$caldoToolTimeout',
  ],
  null => const [],
};

/// How long Codex lets one of Caldo's tools run: `message_chat` waits up
/// to two hours.
const caldoToolTimeout = 7260;

/// Where `caldo-mcp` is on this computer's PATH, looked for once.
final String? caldoMcp = () {
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    if (dir.isEmpty) continue;
    final f = File('$dir/caldo-mcp');
    if (f.existsSync()) return f.path;
  }
  return null;
}();

/// What Codex is started with to write [file], its project's info, which
/// is outside the folder it works in.
List<String> codexMayWrite(String? file) => file == null
    ? const []
    : [
        '-c',
        'sandbox_workspace_write.writable_roots=${jsonEncode([File(file).parent.path])}',
      ];

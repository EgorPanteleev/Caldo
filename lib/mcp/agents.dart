import 'dart:convert';
import 'dart:io';

/// One kind of agent a worker can run in a terminal: Claude, Codex, a model
/// on this computer, a plain shell — and what the app may choose for it.
///
/// Claude is known in full (its plugins, skills, permission modes, and the
/// hooks that say when it is waiting); any other is a command line written
/// out in `agents.json` beside the session ([AgentBook.read]), with
/// `{model}`, `{effort}`, `{prompt}` and the rest put in where named.
class AgentSpec {
  final String id;
  final String label;
  final List<String> models;
  final List<String> efforts;
  final List<String> permissions;

  /// Installed plugins, by name, and those on unless a chat says otherwise.
  final List<String> plugins;
  final List<String> pluginsOn;
  final List<String> skills;

  /// How the first message reaches it: as an argument, typed in once it is
  /// up, or not at all.
  final String prompt;

  /// The command line, each part a word or a list of words left out
  /// together when any of them names a blank that is empty.
  final List<Object> command;

  const AgentSpec({
    required this.id,
    required this.label,
    required this.command,
    this.models = const [],
    this.efforts = const [],
    this.permissions = const [],
    this.plugins = const [],
    this.pluginsOn = const [],
    this.skills = const [],
    this.prompt = 'arg',
  });

  bool get isClaude => id == 'claude';

  /// What the app is told: everything but the command line.
  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'models': models,
    'efforts': efforts,
    'permissions': permissions,
    'plugins': plugins,
    'plugins_on': pluginsOn,
    'skills': skills,
    'prompt': prompt,
  };

  /// The words to run for [blanks]: each `{name}` put in, and each part
  /// naming an empty one left out with the words it stands with.
  List<String> argv(Map<String, String?> blanks) {
    final out = <String>[];
    final named = RegExp(r'\{(\w+)\}');
    for (final part in command) {
      final words = part is List ? part.cast<String>() : [part as String];
      final empty = words.any(
        (w) =>
            named.allMatches(w).any((m) => (blanks[m.group(1)] ?? '').isEmpty),
      );
      if (empty) continue;
      out.addAll(
        words.map((w) => w.replaceAllMapped(named, (m) => blanks[m[1]]!)),
      );
    }
    return out;
  }

  factory AgentSpec.fromJson(String id, Map json) => AgentSpec(
    id: id,
    label: json['label'] as String? ?? id,
    command: [
      for (final part in json['command'] as List)
        part is List ? part.cast<String>() : part as String,
    ],
    models: _strings(json['models']),
    efforts: _strings(json['efforts']),
    prompt: json['prompt'] as String? ?? 'arg',
  );
}

List<String> _strings(Object? list) => [
  for (final s in list as List? ?? const []) '$s',
];

/// What this computer can run, looked for afresh each time a worker says
/// what it has: a plugin installed meanwhile shows in the app within the
/// minute.
class AgentBook {
  final String home;

  /// Where `agents.json` is kept (beside the MCP server's session).
  final String config;

  AgentBook({required this.home, required this.config});

  /// Every agent here: Claude and Codex if on the PATH, a shell always,
  /// then whatever `agents.json` adds or puts in their place.
  List<AgentSpec> read() {
    final out = <String, AgentSpec>{};
    if (_onPath('claude')) out['claude'] = _claude();
    if (_onPath('codex')) {
      out['codex'] = const AgentSpec(
        id: 'codex',
        label: 'Codex',
        command: [
          'codex',
          ['-m', '{model}'],
          ['-c', 'model_reasoning_effort={effort}'],
          '{prompt}',
        ],
        efforts: ['minimal', 'low', 'medium', 'high'],
      );
    }
    out['shell'] = AgentSpec(
      id: 'shell',
      label: 'Shell',
      command: [Platform.environment['SHELL'] ?? 'bash', '-l'],
      prompt: 'type',
    );
    final file = File('$config/agents.json');
    if (file.existsSync()) {
      try {
        final json = jsonDecode(file.readAsStringSync()) as Map;
        for (final MapEntry(:key, :value) in json.entries) {
          out[key as String] = AgentSpec.fromJson(key, value as Map);
        }
      } catch (e) {
        stderr.writeln('agents.json not read: $e');
      }
    }
    return out.values.toList();
  }

  /// Folders Claude has been used in here, that are still here: a start
  /// for the app's choice of where an agent works.
  List<String> dirs() {
    final out = <String>{home};
    try {
      final json =
          jsonDecode(File('$home/.claude.json').readAsStringSync()) as Map;
      for (final dir in (json['projects'] as Map? ?? const {}).keys) {
        if (dir is String &&
            !dir.startsWith('/tmp') &&
            Directory(dir).existsSync()) {
          out.add(dir);
        }
      }
    } catch (_) {
      // No Claude here, or a file it changed the shape of.
    }
    return out.take(40).toList();
  }

  AgentSpec _claude() {
    final plugins = <String>[];
    final pluginPaths = <String, String>{};
    try {
      final json =
          jsonDecode(
                File(
                  '$home/.claude/plugins/installed_plugins.json',
                ).readAsStringSync(),
              )
              as Map;
      for (final MapEntry(:key, :value)
          in (json['plugins'] as Map? ?? const {}).entries) {
        plugins.add(key as String);
        final at = (value as List).firstOrNull;
        if (at is Map && at['installPath'] is String) {
          pluginPaths[key] = at['installPath'] as String;
        }
      }
    } catch (_) {}
    final on = <String>[];
    try {
      final json =
          jsonDecode(File('$home/.claude/settings.json').readAsStringSync())
              as Map;
      for (final MapEntry(:key, :value)
          in (json['enabledPlugins'] as Map? ?? const {}).entries) {
        if (value == true && plugins.contains(key)) on.add(key as String);
      }
    } catch (_) {}
    final skills = <String>[
      ..._skillsIn('$home/.claude/skills', ''),
      for (final MapEntry(:key, :value) in pluginPaths.entries)
        ..._skillsIn('$value/skills', '${key.split('@').first}:'),
    ];
    return AgentSpec(
      id: 'claude',
      label: 'Claude',
      command: const ['claude'],
      models: const ['fable', 'opus', 'sonnet', 'haiku'],
      efforts: const ['low', 'medium', 'high', 'xhigh', 'max'],
      permissions: const [
        'auto',
        'manual',
        'acceptEdits',
        'plan',
        'bypassPermissions',
      ],
      plugins: plugins,
      pluginsOn: on,
      skills: skills,
    );
  }

  static List<String> _skillsIn(String dir, String prefix) {
    final d = Directory(dir);
    if (!d.existsSync()) return const [];
    return [
      for (final e in d.listSync()..sort((a, b) => a.path.compareTo(b.path)))
        if (e is Directory && File('${e.path}/SKILL.md').existsSync())
          '$prefix${e.uri.pathSegments.where((s) => s.isNotEmpty).last}',
    ];
  }

  static bool _onPath(String name) => (Platform.environment['PATH'] ?? '')
      .split(':')
      .any((dir) => dir.isNotEmpty && File('$dir/$name').existsSync());
}

/// What a chat asks for, as the app wrote it.
class ChatAsk {
  final String id;
  final String agent;
  final String title;
  final String? model;
  final String? effort;
  final String? dir;
  final String? permission;

  /// Null leaves Claude's own choice of plugins be.
  final List<String>? plugins;
  final List<String> skills;
  final String prompt;
  final String? session;
  final String? taskUuid;
  final int cols;
  final int rows;

  const ChatAsk({
    required this.id,
    required this.agent,
    this.title = '',
    this.model,
    this.effort,
    this.dir,
    this.permission,
    this.plugins,
    this.skills = const [],
    this.prompt = '',
    this.session,
    this.taskUuid,
    this.cols = 80,
    this.rows = 24,
  });

  factory ChatAsk.fromJson(Map json) => ChatAsk(
    id: json['id'] as String,
    agent: json['agent'] as String,
    title: json['title'] as String? ?? '',
    model: _blank(json['model']),
    effort: _blank(json['effort']),
    dir: _blank(json['dir']),
    permission: _blank(json['permission']),
    plugins: json['plugins'] == null ? null : _strings(json['plugins']),
    skills: _strings(json['skills']),
    prompt: json['prompt'] as String? ?? '',
    session: _blank(json['session']),
    taskUuid: json['task_uuid'] as String?,
    cols: json['cols'] as int? ?? 80,
    rows: json['rows'] as int? ?? 24,
  );
}

String? _blank(Object? s) => s is String && s.trim().isNotEmpty ? s : null;

/// The words that start [ask] with [spec]: Claude's built here, every other
/// from its command line. With [resume], Claude takes up that session.
/// [events] is the file Claude's hooks write to, so the worker hears when
/// it is waiting.
List<String> launchOf(
  AgentSpec spec,
  ChatAsk ask, {
  String? resume,
  String? prompt,
  String? events,
}) {
  final first = prompt ?? ask.prompt;
  if (!spec.isClaude) {
    return spec.argv({
      'model': ask.model,
      'effort': ask.effort,
      'permission': ask.permission,
      'dir': ask.dir,
      'title': ask.title,
      'prompt': spec.prompt == 'arg' ? first : null,
    });
  }
  final settings = <String, Object?>{
    if (events != null)
      'hooks': {
        for (final hook in _hooks)
          hook: [
            {
              'hooks': [
                {
                  'type': 'command',
                  // One line per event; a hook's input is one JSON object.
                  'command': '{ cat; echo; } >> ${_quoted(events)}',
                },
              ],
            },
          ],
      },
    if (ask.plugins case final chosen?)
      'enabledPlugins': {for (final p in spec.plugins) p: chosen.contains(p)},
  };
  return [
    'claude',
    if (ask.model != null) ...['--model', ask.model!],
    if (ask.effort != null) ...['--effort', ask.effort!],
    if (ask.permission != null) ...['--permission-mode', ask.permission!],
    if (resume != null) ...['--resume', resume],
    if (ask.title.isNotEmpty) ...['-n', ask.title],
    if (settings.isNotEmpty) ...['--settings', jsonEncode(settings)],
    if (ask.skills.isNotEmpty) ...[
      '--append-system-prompt',
      'The user chose these skills for this session: '
          '${ask.skills.join(', ')}. Use them (the Skill tool) wherever '
          'they apply.',
    ],
    if (first.isNotEmpty) first,
  ];
}

/// The hooks that tell the worker how Claude stands: its session, a turn
/// begun, a question for the user, a tool let through, a turn done.
const _hooks = [
  'SessionStart',
  'UserPromptSubmit',
  'Notification',
  'PostToolUse',
  'Stop',
];

String _quoted(String s) => "'${s.replaceAll("'", r"'\''")}'";

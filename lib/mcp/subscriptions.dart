import 'dart:convert';
import 'dart:io';

import 'talk.dart';

/// What a chat is subscribed to (`chat_subscriptions`): a repository's
/// pull requests, watched by the chat's worker, each happening told to the
/// chat as a message. Asked as "every new PR, reviewer get an message":
/// a reviewing chat need not look every ten minutes, spending a turn each
/// time to find nothing; the worker's look costs no turns.
class Subscription {
  final int id;
  final String chat;
  final String source;

  /// "owner/name"; null for the repository of the chat's folder, not yet
  /// found.
  final String? target;

  /// Of [kinds].
  final List<String> events;

  /// Said after each event: what to do with it.
  final String? note;

  /// What the chat has been told of, by pull request number (`Seen`).
  final Map<String, Object?>? seen;
  final String? error;
  final DateTime created;

  const Subscription({
    required this.id,
    required this.chat,
    this.source = 'github_pulls',
    this.target,
    this.events = const ['opened'],
    this.note,
    this.seen,
    this.error,
    required this.created,
  });

  factory Subscription.fromJson(Map json) => Subscription(
    id: json['id'] as int,
    chat: json['chat_id'] as String,
    source: json['source'] as String? ?? 'github_pulls',
    target: json['target'] as String?,
    events: [
      for (final e in json['events'] as List? ?? const ['opened']) '$e',
    ],
    note: json['note'] as String?,
    seen: json['seen'] is Map
        ? (json['seen'] as Map).cast<String, Object?>()
        : null,
    error: json['error'] as String?,
    created: DateTime.parse(json['created_at'] as String),
  );

  /// The happenings a subscription can tell: opened (or out of draft, or
  /// reopened), new commits on an open one, merged or closed.
  static const kinds = ['opened', 'pushed', 'closed'];

  /// A repository's name as GitHub has it, "owner/name".
  static final repoName = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');

  /// "owner/name" out of what was given: the name itself, or a link to
  /// the repository or one of its pages.
  static String? repoOf(String given) {
    var name = given.trim().replaceAll(RegExp(r'\.git$'), '');
    final link = RegExp(
      r'^(?:https?://|git@)?github\.com[/:]([^/\s]+/[^/\s#?]+)',
    ).firstMatch(name);
    if (link != null) name = link.group(1)!.replaceAll(RegExp(r'\.git$'), '');
    return repoName.hasMatch(name) ? name : null;
  }

  /// "pull requests in owner/name", as the agent and the MCP tools say it.
  String get label =>
      'pull requests in ${target ?? "the chat's folder's repository"}';
}

/// A pull request as `gh pr list` tells it.
class Pull {
  final int number;
  final String title;
  final String url;
  final String author;
  final String head;
  final String base;
  final String sha;

  /// OPEN, CLOSED or MERGED.
  final String state;
  final bool draft;
  final String body;
  final DateTime created;

  const Pull({
    required this.number,
    required this.title,
    this.url = '',
    this.author = '',
    this.head = '',
    this.base = '',
    this.sha = '',
    this.state = 'OPEN',
    this.draft = false,
    this.body = '',
    required this.created,
  });

  factory Pull.fromJson(Map json) => Pull(
    number: json['number'] as int,
    title: json['title'] as String? ?? '',
    url: json['url'] as String? ?? '',
    author: (json['author'] as Map?)?['login'] as String? ?? '',
    head: json['headRefName'] as String? ?? '',
    base: json['baseRefName'] as String? ?? '',
    sha: json['headRefOid'] as String? ?? '',
    state: json['state'] as String? ?? 'OPEN',
    draft: json['isDraft'] == true,
    body: json['body'] as String? ?? '',
    created: DateTime.parse(json['createdAt'] as String),
  );

  bool get open => state == 'OPEN';

  /// As kept in a subscription's `seen`.
  Map<String, Object?> get mark => {
    'sha': sha,
    'state': state,
    if (draft) 'draft': true,
  };
}

/// What has happened to [pulls] since [sub] last looked: the lines to tell
/// its chat, and what it has seen now. Told only of the events it asked
/// for, and never of one opened before it was made; a draft counts as
/// opened once it is ready for review.
({List<String> told, Map<String, Object?> seen}) pullEvents(
  Subscription sub,
  List<Pull> pulls,
) {
  final was = sub.seen ?? const {};
  final seen = <String, Object?>{...was};
  final told = <String>[];
  bool wants(String event) => sub.events.contains(event);
  // Oldest first, as they happened.
  for (final p in [...pulls]..sort((a, b) => a.number.compareTo(b.number))) {
    final key = '${p.number}';
    final before = was[key] is Map ? was[key] as Map : null;
    seen[key] = p.mark;
    if (before == null) {
      // One there before the subscription is no news; one opened since,
      // and closed before a look, is told of only if closings are.
      if (!p.created.isAfter(sub.created)) continue;
      if (p.open && !p.draft && wants('opened')) told.add(_opened(p, 'opened'));
      if (!p.open && wants('closed')) told.add(_closed(p));
      continue;
    }
    final wasOpen = before['state'] == 'OPEN';
    final wasDraft = before['draft'] == true;
    if (!p.open) {
      if (wasOpen && wants('closed')) told.add(_closed(p));
      continue;
    }
    if (p.draft) continue;
    if (!wasOpen) {
      if (wants('opened')) told.add(_opened(p, 'reopened'));
    } else if (wasDraft) {
      if (wants('opened')) told.add(_opened(p, 'ready for review'));
    } else if (before['sha'] != p.sha && wants('pushed')) {
      told.add(
        '#${p.number} got new commits '
        '(${_sha(before['sha'])} → ${_sha(p.sha)}): ${p.title}\n${p.url}',
      );
    }
  }
  // The last 200 by number: a list read is GitHub's latest 50.
  final kept = seen.keys.toList()
    ..sort((a, b) => (int.tryParse(b) ?? 0).compareTo(int.tryParse(a) ?? 0));
  for (final key in kept.skip(200)) {
    seen.remove(key);
  }
  return (told: told, seen: seen);
}

String _sha(Object? sha) {
  final s = '${sha ?? ''}';
  return s.length > 7 ? s.substring(0, 7) : s;
}

String _opened(Pull p, String how) {
  final body = p.body.trim();
  return [
    '#${p.number} $how: ${p.title}',
    [
      if (p.author.isNotEmpty) 'by ${p.author}',
      if (p.head.isNotEmpty) '${p.head} → ${p.base}',
    ].join(' · '),
    p.url,
    if (body.isNotEmpty) '\n${clip(body, 1500)}',
  ].where((l) => l.isNotEmpty).join('\n');
}

String _closed(Pull p) =>
    '#${p.number} ${p.state == 'MERGED' ? 'merged' : 'closed without merging'}'
    ': ${p.title}\n${p.url}';

/// The message [told] makes for [sub]'s chat: the events, then its note.
String pullsMessage(Subscription sub, List<String> told) {
  final note = sub.note?.trim() ?? '';
  return [
    'Pull requests in ${sub.target}:',
    ...told,
    if (note.isNotEmpty) note,
  ].join('\n\n');
}

/// Who an event is from, as `chat_in`'s `sender` says it: the agent is
/// told it is not the user (`withSender`), and the app draws it so.
Map<String, Object?> eventSender(Subscription sub) => {
  'event': sub.source,
  'title': sub.target,
  'subscription': sub.id,
};

/// Reads GitHub with `gh`, as the user is signed into it on the worker.
class GitHub {
  /// Runs `gh` with these words in [dir]; its output, or throws.
  final Future<String> Function(List<String> args, {String? dir}) _gh;

  GitHub({Future<String> Function(List<String> args, {String? dir})? gh})
    : _gh = gh ?? _run;

  static Future<String> _run(List<String> args, {String? dir}) async {
    final ProcessResult r;
    try {
      r = await Process.run(
        'gh',
        args,
        workingDirectory: dir,
      ).timeout(const Duration(seconds: 30));
    } on ProcessException {
      throw const GitHubError('gh is not installed on this computer');
    }
    if (r.exitCode != 0) {
      final why = '${r.stderr}'.trim().split('\n').first;
      throw GitHubError(why.isEmpty ? 'gh failed (${r.exitCode})' : why);
    }
    return '${r.stdout}';
  }

  /// [repo]'s latest pull requests, open or not.
  Future<List<Pull>> pulls(String repo) async {
    final out = await _gh([
      'pr',
      'list',
      '--repo',
      repo,
      '--state',
      'all',
      '--limit',
      '50',
      '--json',
      'number,title,url,author,headRefName,baseRefName,headRefOid,'
          'isDraft,state,createdAt,body',
    ]);
    return [
      for (final p in jsonDecode(out) as List)
        if (p is Map) Pull.fromJson(p),
    ];
  }

  /// The GitHub repository [dir] is a checkout of, "owner/name".
  Future<String> repoIn(String dir) async {
    if (!Directory(dir).existsSync()) throw GitHubError('no folder $dir');
    final out = await _gh([
      'repo',
      'view',
      '--json',
      'nameWithOwner',
      '-q',
      '.nameWithOwner',
    ], dir: dir);
    final name = Subscription.repoOf(out);
    if (name == null) throw GitHubError('$dir is not a GitHub repository');
    return name;
  }
}

class GitHubError implements Exception {
  final String message;
  const GitHubError(this.message);

  @override
  String toString() => message;
}

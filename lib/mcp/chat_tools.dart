import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:supabase/supabase.dart';

import '../services/chat_files.dart';
import 'agents.dart';
import 'book.dart' show newUuid;
import 'remote.dart';
import 'subscriptions.dart';
import 'talk.dart';
import 'tools.dart';

/// The account's chats with agents as the server holds them: the Agents
/// tab's tables, which are not synced rows.
abstract class ChatDesk {
  /// Every chat, the latest touched first.
  Future<List<Map<String, dynamic>>> chats();

  Future<List<Map<String, dynamic>>> workers();

  /// [chat]'s items after [after], in order; or its last [last], in order.
  Future<List<Map<String, dynamic>>> items(
    String chat, {
    int? after,
    int? last,
  });

  /// [chat]'s item [id], or null if not there yet.
  Future<Map<String, dynamic>?> item(String chat, String id);

  /// Input for a chat, as the app sends it (`chat_in`).
  Future<void> send(Map<String, Object?> row);

  /// Uploads a picture and queues it for the worker to publish in the chat.
  Future<void> sendImage(
    String chat,
    File file, {
    required String mime,
    required int size,
    required String caption,
  });

  /// Every chat's subscriptions (`chat_subscriptions`), oldest first.
  Future<List<Map<String, dynamic>>> subscriptions();

  /// A subscription made, as the server keeps it.
  Future<Map<String, dynamic>> subscribe(Map<String, Object?> row);

  Future<void> resubscribe(int id, Map<String, Object?> fields);

  /// Whether there was one with [id] to put away.
  Future<bool> unsubscribe(int id);

  /// The chat that opened [repo]'s pull request [number], as its worker
  /// noted it (`chat_pulls`): `chat_id`, `url`, `created_at`; or null.
  Future<Map<String, dynamic>?> pullOpener(String repo, int number);

  /// The user's phones told [text] from [chat] (the Edge Function `push`);
  /// how many were reached.
  Future<int> notify(String chat, String text);

  /// Every project (`agent_projects`): id, name, its info (`context`) and
  /// `version`.
  Future<List<Map<String, dynamic>>> projects();

  /// Project [id]'s info written as [context] by [by], only if it is still
  /// at [version]; whether it was.
  Future<bool> setProjectInfo(
    String id,
    String context, {
    required int version,
    required String by,
  });
}

/// [ChatDesk] on Supabase, signed in as the MCP server is.
class SupabaseChatDesk implements ChatDesk {
  final SupabaseRemote remote;

  SupabaseChatDesk(this.remote);

  Future<SupabaseClient> get _db => remote.signedIn();

  @override
  Future<List<Map<String, dynamic>>> chats() async => (await _db)
      .from('chats')
      .select(
        'id, title, prompt, agent, model, state, mode, dir, worker_id, '
        'project_id, updated_at',
      )
      .order('updated_at', ascending: false)
      .limit(200);

  @override
  Future<List<Map<String, dynamic>>> workers() async =>
      (await _db).from('workers').select('id, name, agents, seen_at');

  @override
  Future<List<Map<String, dynamic>>> items(
    String chat, {
    int? after,
    int? last,
  }) async {
    final db = await _db;
    final rows = db
        .from('chat_items')
        .select('id, seq, kind, body')
        .eq('chat_id', chat);
    if (last != null) {
      final latest = await rows.order('seq', ascending: false).limit(last);
      return latest.reversed.toList();
    }
    return rows.gt('seq', after ?? -1).order('seq', ascending: true);
  }

  @override
  Future<Map<String, dynamic>?> item(String chat, String id) async =>
      (await _db)
          .from('chat_items')
          .select('id, seq, kind, body')
          .eq('chat_id', chat)
          .eq('id', id)
          .maybeSingle();

  @override
  Future<void> send(Map<String, Object?> row) async =>
      (await _db).from('chat_in').insert(row);

  @override
  Future<void> sendImage(
    String chat,
    File file, {
    required String mime,
    required int size,
    required String caption,
  }) async {
    final db = await _db;
    final key = '$chat/${newUuid()}';
    final image = await ChatFiles.upload(
      db,
      key,
      file,
      name: p.basename(file.path),
      mime: mime,
      size: size,
    );
    try {
      await db.from('chat_in').insert({
        'chat_id': chat,
        'kind': 'picture',
        'data': caption,
        'files': [image],
      });
    } on PostgrestException {
      final user = db.auth.currentUser?.id;
      if (user != null) {
        try {
          await db.storage.from(ChatFiles.bucket).remove(['$user/$key']);
        } catch (_) {
          // Chat deletion will also clean up uploads that were never shown.
        }
      }
      rethrow;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> subscriptions() async => (await _db)
      .from('chat_subscriptions')
      .select()
      .order('id', ascending: true);

  @override
  Future<Map<String, dynamic>> subscribe(Map<String, Object?> row) async =>
      (await _db).from('chat_subscriptions').insert(row).select().single();

  @override
  Future<void> resubscribe(int id, Map<String, Object?> fields) async =>
      (await _db).from('chat_subscriptions').update(fields).eq('id', id);

  @override
  Future<bool> unsubscribe(int id) async =>
      (await (await _db)
              .from('chat_subscriptions')
              .delete()
              .eq('id', id)
              .select('id'))
          .isNotEmpty;

  @override
  Future<Map<String, dynamic>?> pullOpener(String repo, int number) async =>
      (await _db)
          .from('chat_pulls')
          .select('chat_id, url, created_at')
          .eq('repo', repo)
          .eq('number', number)
          .maybeSingle();

  @override
  Future<int> notify(String chat, String text) async {
    final answer = await (await _db).functions.invoke(
      'push',
      body: {'chat': chat, 'kind': 'said', 'text': text},
    );
    final data = answer.data;
    return data is Map ? (data['sent'] as num?)?.toInt() ?? 0 : 0;
  }

  @override
  Future<List<Map<String, dynamic>>> projects() async =>
      (await _db).from('agent_projects').select('id, name, context, version');

  @override
  Future<bool> setProjectInfo(
    String id,
    String context, {
    required int version,
    required String by,
  }) async =>
      await (await _db)
          .from('agent_projects')
          .update({'context': context, 'changed_by': by})
          .eq('id', id)
          .eq('version', version)
          .select('id')
          .maybeSingle() !=
      null;
}

/// Chats talking to each other: tools for an agent in one of Caldo's chats
/// — or any assistant with Caldo's MCP server — to see the user's other
/// chats, read one, and send one a message, waiting on its answer or not.
///
/// A message goes as the app's own words do, a `line` in `chat_in`, saying
/// who it is from (`sender`), so the agent it reaches is told it is not
/// the user's (`withSender`) and the app shows whose it is. Waited on, the
/// answer is that turn's words, read back from the chat's items once it
/// stands idle again: so a chat at work is waited for first, or its
/// running turn's words would be taken for the answer.
class ChatTools {
  final ChatDesk desk;

  /// The chat these tools are called from (`chatEnv`), or null for an
  /// assistant outside Caldo's chats.
  final String? self;

  /// How often a chat waited on is looked at.
  final Duration poll;

  final DateTime Function() _now;

  /// The repository of the folder this runs in, when a tool is not told.
  final Future<String> Function() _repoHere;

  ChatTools(
    this.desk, {
    this.self,
    this.poll = const Duration(seconds: 1),
    DateTime Function()? now,
    Future<String> Function()? repoHere,
  }) : _now = now ?? DateTime.now,
       _repoHere = repoHere ?? (() => GitHub().repoIn(Directory.current.path));

  /// The chat this process runs under, as its worker started it; null if
  /// not one of Caldo's.
  static String? get here {
    final id = Platform.environment[chatEnv]?.trim();
    return id == null || id.isEmpty ? null : id;
  }

  static const _gone = {'ended', 'failed'};
  static const _busy = {'new', 'running', 'asking'};

  /// Longest answer handed back: its end, where an agent says what it
  /// found.
  static const _most = 20000;

  // ---- Finding things ---------------------------------------------------

  static String _short(String id) => id.substring(0, min(8, id.length));

  static String _titleOf(Map chat) {
    final title = '${chat['title'] ?? ''}'.trim();
    if (title.isNotEmpty) return title;
    final prompt = '${chat['prompt'] ?? ''}'.trim().split('\n').first;
    return prompt.isEmpty ? 'untitled' : clip(prompt, 60);
  }

  Future<Map<String, dynamic>> _chat(Object? id) async {
    final want = '${id ?? ''}'.trim().toLowerCase().replaceAll(
      RegExp(r'[\[\]]'),
      '',
    );
    if (want.length < 4) {
      throw const Refusal('Give the chat id, as [abcd1234] (see chats).');
    }
    final found = [
      for (final c in await desk.chats())
        if ('${c['id']}'.startsWith(want)) c,
    ];
    if (found.isEmpty) throw Refusal('No chat with id $want (see chats).');
    if (found.length > 1) {
      throw Refusal(
        'Id $want matches ${found.length} chats: '
        '${found.map((c) => '[${_short(c['id'])}] ${_titleOf(c)}').join(', ')}.',
      );
    }
    return found.single;
  }

  Future<Map<String, Map>> _workers() async => {
    for (final w in await desk.workers()) '${w['id']}': w,
  };

  bool _online(Map? worker) {
    final seen = DateTime.tryParse('${worker?['seen_at']}');
    return seen != null &&
        _now().difference(seen.toLocal()) < const Duration(seconds: 90);
  }

  /// What [worker] says it can do with [agent], as it tells the app.
  static Map? _kind(Map? worker, String agent) {
    final agents = worker?['agents'];
    if (agents is! List) return null;
    return agents.whereType<Map>().where((a) => a['id'] == agent).firstOrNull;
  }

  // ---- The tools --------------------------------------------------------

  Future<String> chats(Map<String, Object?> args) async {
    final all = args['include_ended'] == true;
    final workers = await _workers();
    final lines = <String>[];
    for (final c in await desk.chats()) {
      final state = '${c['state']}';
      if (!all && _gone.contains(state) && c['id'] != self) continue;
      final worker = workers['${c['worker_id']}'];
      final where = worker == null
          ? 'no computer'
          : '${worker['name']}${_online(worker) ? '' : ' (offline)'}';
      final agent = [
        '${c['agent']}',
        if ('${c['model'] ?? ''}'.isNotEmpty) '${c['model']}',
      ].join(' ');
      lines.add(
        '[${_short(c['id'])}] ${_titleOf(c)} — $agent, $state'
        '${c['mode'] == 'terminal' ? ', in its terminal' : ''}, on $where'
        '${'${c['dir'] ?? ''}'.isEmpty ? '' : ', in ${c['dir']}'}'
        '${c['id'] == self ? '  ← this chat (you)' : ''}',
      );
      if (lines.length == 40) break;
    }
    if (lines.isEmpty) return 'No chats${all ? '' : ' running'}.';
    return [
      if (self == null) 'You are not in one of these chats.',
      ...lines,
    ].join('\n');
  }

  Future<String> readChat(Map<String, Object?> args) async {
    final chat = await _chat(args['chat']);
    final last = ((args['last'] as num?)?.toInt() ?? 20).clamp(1, 200);
    final said = <String>[];
    for (final item in await desk.items(chat['id'], last: last)) {
      final body = item['body'] is Map ? item['body'] as Map : const {};
      final files = body['files'];
      final text = [
        if (files is List)
          for (final file in files.whereType<Map>())
            if (file['name'] is String) '[Attachment: ${file['name']}]',
        '${body['text'] ?? ''}'.trim(),
      ].join('\n').trim();
      switch (item['kind']) {
        case 'user':
          final sender = body['sender'];
          final who = sender is Map
              ? sender['event'] != null
                    ? 'Caldo (pull requests in ${sender['title']})'
                    : sender['chat'] == null
                    ? 'An assistant outside Caldo'
                    : 'Chat ${_short('${sender['chat']}')}'
                          '${sender['chat'] == self ? ' (you)' : ''}'
              : 'User';
          said.add('$who: ${clip(text, 4000)}');
        case 'text':
          if (text.isNotEmpty) said.add('Agent: ${clip(text, 4000)}');
        case 'tool':
          said.add('  (tool: ${body['name'] ?? ''} ${body['line'] ?? ''})');
        case 'ask':
          if (body['answer'] == null) {
            said.add('  (asking the user: ${body['tool']} ${body['line']})');
          }
        case 'note':
          if (text.isNotEmpty) said.add('  (note: $text)');
      }
    }
    final head = '[${_short(chat['id'])}] ${_titleOf(chat)} — ${chat['state']}';
    return said.isEmpty
        ? '$head\nNothing said yet.'
        : '$head\n\n${said.join('\n\n')}';
  }

  Future<String> messageChat(Map<String, Object?> args) async {
    final message = (args['message'] as String? ?? '').trim();
    if (message.isEmpty) throw const Refusal('Say what to tell it.');
    final wait = args['wait'] as bool? ?? true;
    final minutes = ((args['timeout_minutes'] as num?)?.toInt() ?? 10).clamp(
      1,
      120,
    );
    final until = _now().add(Duration(minutes: minutes));
    var chat = await _chat(args['chat']);
    final id = chat['id'] as String;
    final name = '"${_titleOf(chat)}" [${_short(id)}]';
    if (id == self) throw const Refusal('That is this chat, your own.');
    if (_gone.contains(chat['state'])) {
      throw Refusal(
        '$name has ${chat['state']}; the user can start it again in '
        "Caldo's Agents tab.",
      );
    }
    final workers = await _workers();
    final worker = workers['${chat['worker_id']}'];
    if (!_online(worker)) {
      throw Refusal(
        "$name's computer${worker == null ? '' : ', ${worker['name']},'} "
        'is not online.',
      );
    }
    final kind = _kind(worker, '${chat['agent']}');
    // A shell, say: the words would be run as a command.
    if (kind != null && kind['talks'] != true) {
      throw Refusal(
        '$name runs ${kind['label'] ?? chat['agent']}, which takes keys, '
        'not messages: only Claude and Codex chats can be messaged.',
      );
    }
    // One not reinstalled since would pass the words off as the user's.
    if (kind?['chats'] != true) {
      throw Refusal(
        "${worker!['name']} runs a Caldo worker from before chats could "
        'message each other: reinstall caldo-mcp there '
        '(tool/mcp/install.sh, tool/mcp/watch.sh) first.',
      );
    }
    final talks = chat['mode'] == 'chat';
    if (wait && !talks) {
      throw Refusal(
        '$name is in its terminal, where its answer cannot be read back. '
        'Send with wait false, or ask the user to move it to its chat.',
      );
    }

    // At work on what this chat asked it, waiting on this answer: waited
    // on in turn, each would wait out the other's timeout.
    if (wait && _busy.contains(chat['state']) && await _waitsOnMe(id)) {
      throw Refusal(
        '$name is waiting on your answer to its message: just answer it '
        'in this turn (it is handed back), or send with wait false.',
      );
    }

    // At work on something else: what it says now is not the answer.
    if (wait && _busy.contains(chat['state'])) {
      while (_busy.contains(chat['state'])) {
        if (!_now().isBefore(until)) {
          return '$name is still busy (${chat['state']}) after $minutes '
              'minutes; nothing was sent. Try again later, or send with '
              'wait false.';
        }
        await Future<void>.delayed(poll);
        chat = await _chat(id);
      }
      if (_gone.contains(chat['state'])) {
        throw Refusal('$name ${chat['state']} while waiting; nothing sent.');
      }
    }

    String? myTitle;
    if (self != null) {
      for (final c in await desk.chats()) {
        if (c['id'] == self) myTitle = _titleOf(c);
      }
    }
    final key = 'm${_now().microsecondsSinceEpoch}${Random().nextInt(1 << 20)}';
    await desk.send({
      'chat_id': id,
      'kind': 'line',
      'data': message,
      'key': key,
      'sender': {'chat': self, 'title': myTitle, 'waits': wait},
    });
    if (!wait) {
      return 'Sent to $name. Its answer stays in its chat (read_chat)'
          '${self == null ? '' : ', or it may message you back'}.';
    }

    // Its words, then the turn they began, to its end.
    Map<String, dynamic>? said;
    final heard = _now().add(const Duration(seconds: 30));
    while ((said = await desk.item(id, 'u$key')) == null) {
      if (!_now().isBefore(heard) || !_now().isBefore(until)) {
        return 'Sent to $name, but its computer has not taken it up yet; '
            'it will be said there when it is. Look with read_chat later.';
      }
      await Future<void>.delayed(poll);
    }
    final from = said!['seq'] as int;
    var begun = false;
    var quiet = 0;
    while (true) {
      final after = await desk.items(id, after: from);
      chat = await _chat(id);
      final state = '${chat['state']}';
      if (after.isNotEmpty || _busy.contains(state)) begun = true;
      // Idle with nothing said a while: it took it up and said nothing.
      if (!_busy.contains(state)) quiet++;
      if ((begun || quiet > 20) && !_busy.contains(state)) {
        return _answer(name, after, state);
      }
      if (!_now().isBefore(until)) {
        final words = _words(after);
        return '$name is still at work after $minutes minutes'
            '${state == 'asking' ? ', waiting for the user to answer it in '
                      'its chat' : ''}; its answer will stay in its chat '
            '(read_chat).'
            '${words.isEmpty ? '' : ' So far:\n\n${_tail(words)}'}';
      }
      await Future<void>.delayed(poll);
    }
  }

  /// Whether this chat's turn under way answers [chat], which waits on it.
  Future<bool> _waitsOnMe(String chat) async {
    final me = self;
    if (me == null) return false;
    final said = await desk.items(me, last: 30);
    final asked = said.lastWhere(
      (i) => i['kind'] == 'user',
      orElse: () => const {},
    );
    final sender = (asked['body'] as Map?)?['sender'];
    return sender is Map && sender['chat'] == chat && sender['waits'] == true;
  }

  static String _words(List<Map<String, dynamic>> items) => [
    for (final item in items)
      if (item['kind'] == 'text' && item['body'] is Map)
        if ('${(item['body'] as Map)['text'] ?? ''}'.trim() case final text
            when text.isNotEmpty)
          text,
  ].join('\n\n');

  static String _tail(String text) =>
      text.length <= _most ? text : '…${text.substring(text.length - _most)}';

  static String _answer(
    String name,
    List<Map<String, dynamic>> items,
    String state,
  ) {
    final words = _words(items);
    final failed = [
      for (final item in items)
        if (item['kind'] == 'note' &&
            item['body'] is Map &&
            (item['body'] as Map)['error'] == true)
          '${(item['body'] as Map)['text']}',
    ];
    if (words.isEmpty) {
      return '$name said nothing back'
          '${failed.isEmpty ? '' : ': ${failed.join('; ')}'}'
          '${_gone.contains(state) ? ' (it has $state)' : ''}.';
    }
    return '$name answered:\n\n${_tail(words)}';
  }

  // ---- Clearing ---------------------------------------------------------

  /// A chat's context cleared, as `/clear` does in Claude: asked for so a
  /// chat at standing work — the reviewer, done with a round of pull
  /// requests — starts each round afresh. Its worker waits for the turn
  /// under way to end, so the agent asking for its own can still answer.
  Future<String> clearContext(Map<String, Object?> args) async {
    final chat = await _namedOrMine(args['chat']);
    final id = chat['id'] as String;
    final mine = id == self;
    final name = mine ? 'This chat' : '"${_titleOf(chat)}" [${_short(id)}]';
    if (_gone.contains(chat['state'])) {
      throw Refusal('$name has ${chat['state']}: there is nothing to clear.');
    }
    final worker = (await _workers())['${chat['worker_id']}'];
    final kind = _kind(worker, '${chat['agent']}');
    if (kind != null && kind['talks'] != true) {
      throw Refusal(
        '$name runs ${kind['label'] ?? chat['agent']}, which has no '
        'context to clear.',
      );
    }
    if (chat['mode'] == 'terminal') {
      throw Refusal('$name is in its terminal: type /clear there instead.');
    }
    if (kind?['clears'] != true) {
      throw Refusal(
        "${worker?['name'] ?? 'Its computer'} runs a Caldo worker from "
        'before contexts could be cleared: reinstall caldo-mcp there '
        '(tool/mcp/install.sh, tool/mcp/watch.sh) first.',
      );
    }
    if (!_online(worker)) {
      throw Refusal("$name's computer, ${worker!['name']}, is not online.");
    }
    await desk.send({
      'chat_id': id,
      'kind': 'clear',
      'key': 'c${_now().microsecondsSinceEpoch}${Random().nextInt(1 << 20)}',
    });
    return mine
        ? 'Cleared once this turn ends: what you say now is still shown, '
              'but you will remember none of it. The next message starts '
              'afresh, with your rules and subscriptions.'
        : '$name will start afresh with its next message, once the turn '
              'it may be on ends.';
  }

  // ---- Subscriptions ----------------------------------------------------

  /// The chat a tool is asked for: the one named, else this one.
  // ---- Project info -----------------------------------------------------

  /// The project named [named] (by name or id), else this chat's.
  Future<Map<String, dynamic>> _project(Object? named) async {
    final want = '${named ?? ''}'.trim().toLowerCase();
    final all = await desk.projects();
    if (want.isEmpty) {
      final me = self;
      final chat = me == null
          ? null
          : (await desk.chats()).where((c) => c['id'] == me).firstOrNull;
      if (chat == null) {
        throw const Refusal(
          "Name the project: you are not one of this account's chats.",
        );
      }
      final id = chat['project_id'];
      if (id == null) throw const Refusal('This chat is in no project.');
      return all.where((p) => p['id'] == id).firstOrNull ??
          (throw const Refusal("This chat's project has been deleted."));
    }
    final found = [
      for (final p in all)
        if ('${p['name'] ?? ''}'.trim().toLowerCase() == want ||
            '${p['id']}'.startsWith(want))
          p,
    ];
    if (found.length == 1) return found.single;
    final names = all.map((p) => '"${p['name']}"').join(', ');
    throw Refusal(
      found.isEmpty
          ? 'No project "$named"; there are ${names.isEmpty ? 'none' : names}.'
          : '"$named" names ${found.length} projects; give its id.',
    );
  }

  Future<String> projectInfo(Map<String, Object?> args) async {
    final project = await _project(args['project']);
    final words = '${project['context'] ?? ''}';
    return 'Project "${project['name']}" [${_short('${project['id']}')}]'
        '${words.trim().isEmpty ? ': no info written yet.' : ':\n\n$words'}';
  }

  Future<String> updateProjectInfo(Map<String, Object?> args) async {
    final project = await _project(args['project']);
    final was = '${project['context'] ?? ''}';
    final String now;
    if (args['text'] case final String text) {
      now = text.trim();
    } else if (args['old'] case final String old when old.isNotEmpty) {
      final at = was.indexOf(old);
      if (at < 0) {
        throw const Refusal(
          'old is not in the project info as it is now (read it again '
          'with project_info).',
        );
      }
      if (was.indexOf(old, at + 1) >= 0) {
        throw const Refusal(
          'old is in the project info more than once: give more of it.',
        );
      }
      now = was.replaceRange(at, at + old.length, '${args['new'] ?? ''}');
    } else {
      throw const Refusal('Give text (the whole info) or old and new.');
    }
    if (now == was) return 'Nothing changed.';
    final saved = await desk.setProjectInfo(
      '${project['id']}',
      now,
      version: (project['version'] as num?)?.toInt() ?? 1,
      by: self == null ? 'assistant' : 'chat:$self',
    );
    if (!saved) {
      throw const Refusal(
        'The project info was changed meanwhile: read it again with '
        'project_info, then make your change.',
      );
    }
    return 'Project "${project['name']}" info changed (${now.length} '
        'characters). Each chat in it is told it when its program next '
        'starts.';
  }

  Future<Map<String, dynamic>> _namedOrMine(Object? id) async {
    if ('${id ?? ''}'.trim().isNotEmpty) return _chat(id);
    final me = self;
    if (me == null) {
      throw const Refusal(
        'You are not in one of Caldo\'s chats: say which chat (see chats).',
      );
    }
    return _chat(me);
  }

  static String _subLine(Map sub, Map<String, Map> chats) {
    final s = Subscription.fromJson(sub);
    final chat = chats[s.chat];
    final note = s.note?.trim() ?? '';
    return '#${s.id} [${_short(s.chat)}] '
        '${chat == null ? '' : '${_titleOf(chat)} — '}${s.label}: '
        '${s.events.join(', ')}'
        '${note.isEmpty ? '' : '; then told "${clip(note, 200)}"'}'
        '${s.error == null ? '' : ' (cannot watch: ${s.error})'}';
  }

  Future<String> subscribe(Map<String, Object?> args) async {
    final chat = await _namedOrMine(args['chat']);
    final id = chat['id'] as String;
    final name = '"${_titleOf(chat)}" [${_short(id)}]';
    final given = '${args['repo'] ?? ''}'.trim();
    final repo = given.isEmpty ? null : Subscription.repoOf(given);
    if (given.isNotEmpty && repo == null) {
      throw Refusal('"$given" is not a GitHub repository: give owner/name.');
    }
    final events = args['events'] is List
        ? {for (final e in args['events'] as List) '$e'}.toList()
        : const ['opened'];
    final unknown = events.where((e) => !Subscription.kinds.contains(e));
    if (events.isEmpty || unknown.isNotEmpty) {
      throw Refusal(
        'Events are some of ${Subscription.kinds.join(', ')}'
        '${unknown.isEmpty ? '' : '; not ${unknown.join(', ')}'}.',
      );
    }
    final note = '${args['note'] ?? ''}'.trim();
    final worker = (await _workers())['${chat['worker_id']}'];
    final kind = _kind(worker, '${chat['agent']}');
    if (kind != null && kind['talks'] != true) {
      throw Refusal(
        '$name runs ${kind['label'] ?? chat['agent']}, which takes keys, '
        'not messages: only Claude and Codex chats can be told of events.',
      );
    }
    if (kind?['events'] != true) {
      throw Refusal(
        "${worker?['name'] ?? "Its computer"} runs a Caldo worker from "
        'before subscriptions: reinstall caldo-mcp there '
        '(tool/mcp/install.sh, tool/mcp/watch.sh) first.',
      );
    }
    // One a repository for a chat: asked again, it is changed.
    final had = [
      for (final s in await desk.subscriptions())
        if (s['chat_id'] == id && s['target'] == repo) s,
    ].firstOrNull;
    final fields = {'events': events, 'note': note.isEmpty ? null : note};
    final Map sub;
    if (had != null) {
      await desk.resubscribe(had['id'] as int, fields);
      sub = {...had, ...fields};
    } else {
      sub = await desk.subscribe({'chat_id': id, 'target': repo, ...fields});
    }
    final what = Subscription.fromJson(sub).label;
    final later = _gone.contains(chat['state'])
        ? ' It has ${chat['state']}: what happens meanwhile is told once '
              'the user starts it again.'
        : '';
    return '${had == null ? 'Subscribed' : 'Changed: subscribed'} $name to '
        '$what (#${sub['id']}): told of ${events.join(', ')}, within a '
        'minute, as a message from Caldo. Those opened before now are not '
        'told.$later';
  }

  Future<String> subscriptions(Map<String, Object?> args) async {
    final only = '${args['chat'] ?? ''}'.trim().isEmpty
        ? null
        : (await _chat(args['chat']))['id'];
    final chats = {for (final c in await desk.chats()) '${c['id']}': c};
    final lines = [
      for (final s in await desk.subscriptions())
        if (only == null || s['chat_id'] == only) _subLine(s, chats),
    ];
    return lines.isEmpty ? 'No subscriptions.' : lines.join('\n');
  }

  Future<String> unsubscribe(Map<String, Object?> args) async {
    final id = switch (args['id']) {
      final num n => n.toInt(),
      final String s => int.tryParse(s.replaceAll('#', '').trim()),
      _ => null,
    };
    if (id == null) {
      throw const Refusal('Give the subscription\'s number (subscriptions).');
    }
    if (!await desk.unsubscribe(id)) {
      throw Refusal('No subscription #$id (see subscriptions).');
    }
    return 'Subscription #$id ended.';
  }

  // ---- Pull requests ----------------------------------------------------

  /// Which chat opened a pull request: the one to talk to about it. Known
  /// for those opened by `gh pr create` in one of Caldo's chats, as its
  /// worker saw it go by — a description need not name its chat.
  Future<String> pullChat(Map<String, Object?> args) async {
    final given = '${args['repo'] ?? ''}'.trim();
    final link = RegExp(r'/pull/(\d+)').firstMatch(given);
    final number = switch (args['number']) {
      final num n => n.toInt(),
      final String s => int.tryParse(s.replaceAll('#', '').trim()),
      _ => link == null ? null : int.parse(link[1]!),
    };
    if (number == null) {
      throw const Refusal("Give the pull request's number, or its link.");
    }
    final String repo;
    if (given.isEmpty) {
      try {
        repo = await _repoHere();
      } on GitHubError catch (e) {
        throw Refusal('Say which repository (owner/name): $e.');
      }
    } else {
      repo =
          Subscription.repoOf(given) ??
          (throw Refusal(
            '"$given" is not a GitHub repository: give owner/name.',
          ));
    }
    final row = await desk.pullOpener(repo, number);
    if (row == null) {
      return 'No chat is known to have opened $repo#$number: it was opened '
          "outside Caldo's chats, or by a worker from before this was noted.";
    }
    final id = '${row['chat_id']}';
    final chat = [
      for (final c in await desk.chats())
        if (c['id'] == id) c,
    ].firstOrNull;
    if (chat == null) {
      return '$repo#$number was opened by chat [${_short(id)}], which is '
          'gone now.';
    }
    final state = '${chat['state']}';
    return '$repo#$number was opened by "${_titleOf(chat)}" [${_short(id)}]'
        ' — ${chat['agent']}, $state'
        '${id == self
            ? '. That is this chat, you.'
            : _gone.contains(state)
            ? '. A message would start it again.'
            : '. message_chat reaches it.'}';
  }

  /// What the agent says is worth the user's looking now, on their phones:
  /// through even a muted chat, as a mention gets through elsewhere.
  Future<String> notify(Map<String, Object?> args) async {
    final text = '${args['message'] ?? ''}'.trim();
    if (text.isEmpty) throw const Refusal('Say what to tell the user.');
    final chat = self;
    if (chat == null) {
      throw const Refusal(
        "Only an agent in one of Caldo's chats can notify the user: the "
        'notification opens its chat.',
      );
    }
    final sent = await desk.notify(chat, clip(text, 1000));
    return sent == 0
        ? 'No phone of the user\'s is signed in to be told; nothing was sent.'
        : 'Sent to ${sent == 1 ? 'their phone' : '$sent phones'}.';
  }

  Future<String> sendImage(Map<String, Object?> args) async {
    final chat = self;
    if (chat == null) {
      throw const Refusal('Only an agent in a Caldo chat can send a picture.');
    }
    final row = await _chat(chat);
    if (row['mode'] != 'chat' || _gone.contains(row['state'])) {
      throw const Refusal(
        'This chat must be active in Chat mode to show a picture.',
      );
    }
    final worker = (await _workers())['${row['worker_id']}'];
    if (_kind(worker, '${row['agent']}')?['pictures'] != true) {
      throw const Refusal(
        'Update and restart this chat’s Caldo worker to send pictures.',
      );
    }
    final path = args['path'];
    if (path is! String || path.trim().isEmpty) {
      throw const Refusal('Give the path to a local image file.');
    }
    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw const Refusal('Give the path to an existing image file.');
    }
    if (stat.size > ChatFiles.largestFile) {
      throw const Refusal('Pictures can be at most 50 MB.');
    }
    final handle = await file.open();
    final String? mime;
    try {
      mime = lookupMimeType('', headerBytes: await handle.read(32));
    } finally {
      await handle.close();
    }
    if (mime == null ||
        !const {
          'image/png',
          'image/jpeg',
          'image/webp',
          'image/gif',
          'image/bmp',
        }.contains(mime)) {
      throw const Refusal('Use a PNG, JPEG, WebP, GIF, or BMP image.');
    }
    await desk.sendImage(
      chat,
      file,
      mime: mime,
      size: stat.size,
      caption: (args['caption'] as String? ?? '').trim(),
    );
    return 'Picture queued for this chat.';
  }

  static Map<String, Object?> _shape(
    Map<String, Object?> properties, [
    List<String> required = const [],
  ]) => {
    'type': 'object',
    'properties': properties,
    if (required.isNotEmpty) 'required': required,
  };

  static const _chatId = {
    'type': 'string',
    'description': 'The chat id, as chats lists it ([abcd1234]).',
  };

  late final List<Tool> tools = [
    Tool(
      'send_image',
      'Shows a local image to the user in this Caldo chat as a picture '
          'message, with an optional caption. Use this for screenshots, '
          'diagrams, or other images you want them to see in the chat.',
      _shape(
        {
          'path': {
            'type': 'string',
            'description': 'Path to the local image file.',
          },
          'caption': {
            'type': 'string',
            'description': 'Optional message under the picture.',
          },
        },
        ['path'],
      ),
      sendImage,
    ),
    Tool(
      'chats',
      "The user's chats with agents (Claude, Codex…) in Caldo's Agents "
          'tab, latest first: id, title, agent and model, how it stands, '
          'which computer, which folder. Marks the one you are, if you are '
          'one of them.',
      _shape({
        'include_ended': {
          'type': 'boolean',
          'description': 'List ended chats too (default false).',
        },
      }),
      chats,
      reads: true,
    ),
    Tool(
      'read_chat',
      "What was said lately in one of the user's chats: the user's and "
          "other chats' messages, the agent's answers, its tools in a line.",
      _shape(
        {
          'chat': _chatId,
          'last': {
            'type': 'integer',
            'description': 'How many of its last items (default 20).',
          },
        },
        ['chat'],
      ),
      readChat,
      reads: true,
    ),
    Tool(
      'message_chat',
      "Sends a message to another of the user's chats, as the user would "
          'type it there; its agent is told it is from you, not the user. '
          'By default waits for its answer and hands it back (a chat at '
          'work is waited for first). With wait false it returns at once; '
          'the other agent may then answer with message_chat. Do not wait '
          'on a chat that is waiting on you.',
      _shape(
        {
          'chat': _chatId,
          'message': {'type': 'string'},
          'wait': {
            'type': 'boolean',
            'description': 'Wait for its answer (default true).',
          },
          'timeout_minutes': {
            'type': 'integer',
            'description': 'How long to wait, 1–120 (default 10).',
          },
        },
        ['chat', 'message'],
      ),
      messageChat,
    ),
    Tool(
      'clear_context',
      "Clears a chat's context (by default this one's), as /clear does: "
          'once the turn under way ends, everything said is forgotten and '
          'the next message starts a fresh session, with the same rules, '
          'skills and subscriptions. The chat keeps what was said on '
          'screen. For standing work done in rounds: clear after each.',
      _shape({
        'chat': {
          'type': 'string',
          'description': 'The chat to clear ([abcd1234]); default this one.',
        },
      }),
      clearContext,
    ),
    Tool(
      'subscribe',
      "Subscribes a chat (by default this one) to a GitHub repository's "
          'pull requests: its computer looks every minute, with gh, and '
          'tells the chat what happened as a message from Caldo — no need '
          'to look for new ones yourself. Asked again for the same '
          'repository, it changes what is told.',
      _shape({
        'chat': {
          'type': 'string',
          'description': 'The chat to tell ([abcd1234]); default this one.',
        },
        'repo': {
          'type': 'string',
          'description':
              'owner/name or its link; default the repository of the '
              "chat's folder.",
        },
        'events': {
          'type': 'array',
          'items': {'type': 'string', 'enum': Subscription.kinds},
          'description':
              'What to be told of: opened (also out of draft, reopened), '
              'pushed (new commits), closed (merged or not). Default '
              'opened.',
        },
        'note': {
          'type': 'string',
          'description':
              'Said after each event, e.g. what to do with it ("Review it '
              'as your rules say").',
        },
      }),
      subscribe,
    ),
    Tool(
      'subscriptions',
      "What the user's chats are subscribed to, by number.",
      _shape({
        'chat': {
          'type': 'string',
          'description': 'Only this chat\'s ([abcd1234]).',
        },
      }),
      subscriptions,
      reads: true,
    ),
    Tool(
      'unsubscribe',
      'Ends a subscription, by its number (see subscriptions).',
      _shape(
        {
          'id': {'type': 'integer'},
        },
        ['id'],
      ),
      unsubscribe,
    ),
    Tool(
      'notify',
      "Sends the user a notification on their phone, from this chat; a tap "
          'opens it. Only for what is worth their looking now: you need '
          'their answer and they may not be watching, or something they '
          'wait on is done (a release made). They are already told when a '
          'turn of theirs ends or you ask them something; do not repeat '
          'that. Goes through even if they muted this chat.',
      _shape(
        {
          'message': {
            'type': 'string',
            'description':
                'One or two short lines, e.g. "Released v2.24.0: '
                'pushes for waiting chats".',
          },
        },
        ['message'],
      ),
      notify,
    ),
    Tool(
      'pull_chat',
      'Which of the user\'s chats opened a GitHub pull request, so you can '
          'talk to it about it with message_chat. Known for those opened '
          "with gh pr create in one of Caldo's chats.",
      _shape({
        'number': {
          'type': 'integer',
          'description': "The pull request's number.",
        },
        'repo': {
          'type': 'string',
          'description':
              'owner/name, or a link to the pull request (then no number '
              'is needed); default the repository of your folder.',
        },
      }),
      pullChat,
      reads: true,
    ),
    Tool(
      'project_info',
      "A project's info, as the user and its chats keep it in Caldo: what "
          'every chat in the project is told (in place of CLAUDE.md), as it '
          'is now.',
      _shape({'project': _projectName}),
      projectInfo,
      reads: true,
    ),
    Tool(
      'update_project_info',
      "Changes a project's info, shared by every chat in it (in place of "
          'CLAUDE.md): keep it current when your work changes something it '
          'says. Give old and new to change one part (old must be found '
          'once, as project_info shows it), or text for the whole. Other '
          'chats are told it when their program next starts.',
      _shape({
        'project': _projectName,
        'old': {
          'type': 'string',
          'description': 'The words to replace, exactly as they are.',
        },
        'new': {'type': 'string', 'description': 'What replaces old.'},
        'text': {
          'type': 'string',
          'description': 'The whole info, in place of all of it.',
        },
      }),
      updateProjectInfo,
    ),
  ];

  static const _projectName = {
    'type': 'string',
    'description': "The project's name or id; default this chat's.",
  };

  /// Added to what the assistant is told when it connects.
  static const instructions =
      " Chats with agents in Caldo's Agents tab can talk to each other: "
      'chats lists them, read_chat reads one, message_chat sends one a '
      'message. A chat can be subscribed to pull requests on GitHub '
      '(subscribe), and is then told of new ones as they come; pull_chat '
      'says which chat opened one. clear_context clears a chat\'s context, '
      'as /clear does. project_info and update_project_info read and keep '
      "current a project's info, which its chats read in place of "
      'CLAUDE.md. notify sends the user a notification on their phone. '
      'Use send_image to show a local picture to the user in this chat.';
}

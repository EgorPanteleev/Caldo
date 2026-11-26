import 'dart:io';

import 'package:caldo/mcp/wire.dart';
import 'package:caldo/services/agents.dart';
import 'package:flutter_test/flutter_test.dart';

/// The values [constraint] allows, as the latest migration to set it says.
Set<String> _allowed(String constraint, String table, String column) {
  final files =
      Directory('supabase/migrations')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.sql'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  Set<String>? last;
  final named = RegExp(
    'add constraint $constraint\\s+check \\($column in \\(([^)]*)\\)\\)',
  );
  final inline = RegExp(
    'create table public\\.$table \\(.*?\\b$column text[^,]*?'
    'check \\($column in \\(([^)]*)\\)\\)',
    dotAll: true,
  );
  for (final file in files) {
    final sql = file.readAsStringSync();
    for (final m in [...inline.allMatches(sql), ...named.allMatches(sql)]) {
      last = {for (final w in RegExp(r"'([a-z_]+)'").allMatches(m[1]!)) w[1]!};
    }
  }
  return last ?? const {};
}

/// Every word in [pattern]'s first group across [paths].
Set<String> _used(List<String> paths, RegExp pattern) => {
  for (final path in paths)
    for (final m in pattern.allMatches(File(path).readAsStringSync())) m[1]!,
};

void main() {
  test('the database allows the words and no others', () {
    expect(_allowed('chats_state_check', 'chats', 'state'), Wire.chatStates);
    expect(_allowed('chat_in_kind_check', 'chat_in', 'kind'), Wire.inputKinds);
    expect(
      _allowed('chat_items_kind_check', 'chat_items', 'kind'),
      Wire.itemKinds,
    );
  });

  test('the app reads every state a chat can be in', () {
    for (final state in Wire.chatStates.difference({'new'})) {
      final chat = Chat.fromJson({
        'id': 'c',
        'agent': 'claude',
        'state': state,
        'updated_at': '2026-11-26T10:00:00Z',
      });
      // What a state the app does not know is read as.
      expect(chat.state, isNot(ChatState.asked), reason: state);
    }
  });

  test('the app leaves only input the database takes', () {
    final kinds = _used([
      'lib/services/agents.dart',
    ], RegExp(r"_in\(\s*[\w.!]+,\s*'([a-z_]+)'"));
    expect(kinds, isNotEmpty);
    expect(Wire.inputKinds, containsAll(kinds));
  });

  test('the worker posts only items the database takes', () {
    final kinds = _used([
      for (final f in Directory('lib/mcp').listSync().whereType<File>())
        if (f.path.endsWith('.dart')) f.path,
    ], RegExp(r"\.item\((?:[^;]*?),\s*'([a-z_]+)',\s*\{", dotAll: true));
    expect(kinds, isNotEmpty);
    expect(Wire.itemKinds, containsAll(kinds));
  });
}

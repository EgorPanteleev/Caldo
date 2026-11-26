import 'dart:convert';

import 'package:caldo/services/agents.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

Map<String, dynamic> _chat(String id, {String state = 'idle', String? at}) => {
  'id': id,
  'agent': 'claude',
  'state': state,
  'title': id,
  'context': 'Long words $id',
  'updated_at': at ?? '2026-11-20T10:00:00Z',
};

PostgresChangePayload _change(
  PostgresChangeEvent type, {
  Map<String, dynamic> row = const {},
  Map<String, dynamic> old = const {},
}) => PostgresChangePayload(
  schema: 'public',
  table: 'chats',
  commitTimestamp: DateTime(2026),
  eventType: type,
  newRecord: row,
  oldRecord: old,
  errors: null,
);

void main() {
  late SupabaseClient client;
  final asked = <String>[];

  setUp(() async {
    asked.clear();
    client = SupabaseClient(
      'https://example.invalid',
      'anon',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      realtimeClientOptions: RealtimeClientOptions(
        transport: (_, _) => throw StateError('Realtime unavailable'),
      ),
      httpClient: MockClient((request) async {
        asked.add(request.url.toString());
        final path = request.url.path;
        final query = request.url.queryParameters;
        final rows = switch (path) {
          '/rest/v1/workers' => <Object>[],
          '/rest/v1/agent_accounts' => <Object>[],
          // Two hundred newer ones would leave the old running chat out.
          '/rest/v1/chats' when query.containsKey('limit') => [
            _chat('new', state: 'finished', at: '2026-11-25T10:00:00Z'),
          ],
          '/rest/v1/chats' => [_chat('old', state: 'running')],
          _ => <Object>[],
        };
        return http.Response(jsonEncode(rows), 200, request: request);
      }),
    );
    await client.auth.recoverSession(
      jsonEncode({
        'access_token': 'token',
        'token_type': 'bearer',
        'user': {'id': 'me'},
      }),
    );
    Agents.instance.clientForTest = client;
  });

  tearDown(() async {
    Agents.instance.clientForTest = null;
    await client.dispose();
  });

  test('a chat still going is listed however old', () async {
    final agents = Agents.instance;
    await agents.load();
    expect(agents.chats.map((c) => c.id), containsAll(['new', 'old']));
    expect(asked.where((u) => u.contains('state=not.in.')), isNotEmpty);
  });

  test('a change heard is put in place without reading the list', () async {
    final agents = Agents.instance;
    await agents.load();
    asked.clear();

    // An update that leaves the large context out keeps what was read.
    agents.heard(
      'chats',
      _change(
        PostgresChangeEvent.update,
        row: {
          'id': 'old',
          'agent': 'claude',
          'state': 'finished',
          'title': 'Renamed',
          'updated_at': '2026-11-26T10:00:00Z',
        },
      ),
    );
    final old = agents.chats.firstWhere((c) => c.id == 'old');
    expect(old.title, 'Renamed');
    expect(old.state, ChatState.finished);
    expect(old.context, 'Long words old');
    // Newest first.
    expect(agents.chats.first.id, 'old');

    agents.heard(
      'chats',
      _change(PostgresChangeEvent.insert, row: _chat('made')),
    );
    expect(agents.chats.map((c) => c.id), contains('made'));
    agents.heard(
      'chats',
      _change(PostgresChangeEvent.delete, old: {'id': 'made'}),
    );
    expect(agents.chats.map((c) => c.id), isNot(contains('made')));
    expect(asked, isEmpty);
  });
}

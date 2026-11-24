import 'package:caldo/mcp/agents.dart';
import 'package:caldo/mcp/subscriptions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final made = DateTime.utc(2026, 11, 24, 12);
  final before = made.subtract(const Duration(hours: 1));
  final after = made.add(const Duration(minutes: 5));

  Subscription sub({
    List<String> events = const ['opened'],
    Map<String, Object?>? seen,
    String? note,
  }) => Subscription(
    id: 7,
    chat: 'aaaa1111-0000',
    target: 'EgorPanteleev/Caldo',
    events: events,
    note: note,
    seen: seen,
    created: made,
  );

  Pull pull(
    int number, {
    DateTime? created,
    String state = 'OPEN',
    bool draft = false,
    String sha = 'aaaaaaaaaa',
  }) => Pull(
    number: number,
    title: 'Change $number',
    url: 'https://github.com/EgorPanteleev/Caldo/pull/$number',
    author: 'EgorPanteleev',
    head: 'branch-$number',
    base: 'master',
    sha: sha,
    state: state,
    draft: draft,
    body: 'What changed in $number.',
    created: created ?? after,
  );

  /// Looks once at [pulls], then at [then]: what the second look tells.
  List<String> twice(Subscription s, List<Pull> pulls, List<Pull> then) {
    final first = pullEvents(s, pulls);
    final next = Subscription(
      id: s.id,
      chat: s.chat,
      target: s.target,
      events: s.events,
      seen: first.seen,
      created: s.created,
    );
    return pullEvents(next, then).told;
  }

  test('only those opened since it was made are told, once', () {
    final first = pullEvents(sub(), [
      pull(1, created: before),
      pull(2, created: before, state: 'MERGED'),
      pull(3),
    ]);
    expect(first.told, hasLength(1));
    expect(
      first.told.single,
      '#3 opened: Change 3\n'
      'by EgorPanteleev · branch-3 → master\n'
      'https://github.com/EgorPanteleev/Caldo/pull/3\n'
      '\nWhat changed in 3.',
    );
    expect(first.seen.keys, unorderedEquals(['1', '2', '3']));
    expect(twice(sub(), [pull(3)], [pull(3)]), isEmpty);
  });

  test('a draft is told once it is ready for review', () {
    final first = pullEvents(sub(), [pull(4, draft: true)]);
    expect(first.told, isEmpty);
    expect(
      twice(sub(), [pull(4, draft: true)], [pull(4)]).single,
      startsWith('#4 ready for review: Change 4'),
    );
  });

  test('pushes and closings only when asked for', () {
    final open = [pull(5, created: before)];
    final pushed = [pull(5, created: before, sha: 'bbbbbbbbbb')];
    expect(twice(sub(), open, pushed), isEmpty);
    expect(
      twice(sub(events: ['pushed']), open, pushed).single,
      '#5 got new commits (aaaaaaa → bbbbbbb): Change 5\n'
      'https://github.com/EgorPanteleev/Caldo/pull/5',
    );

    final merged = [pull(5, created: before, state: 'MERGED')];
    final closed = [pull(5, created: before, state: 'CLOSED')];
    expect(twice(sub(), open, merged), isEmpty);
    expect(
      twice(sub(events: ['closed']), open, merged).single,
      startsWith('#5 merged: Change 5'),
    );
    expect(
      twice(sub(events: ['closed']), open, closed).single,
      startsWith('#5 closed without merging'),
    );
    // Reopened, it is opened again.
    expect(twice(sub(), closed, open).single, startsWith('#5 reopened'));
  });

  test('one opened and closed between two looks', () {
    final s = sub(events: ['opened', 'closed']);
    expect(
      pullEvents(s, [pull(6, state: 'MERGED')]).told.single,
      startsWith('#6 merged'),
    );
    expect(pullEvents(sub(), [pull(6, state: 'MERGED')]).told, isEmpty);
  });

  test('the message: events in order, then the note', () {
    final s = sub(note: 'Review it as your rules say.');
    final told = pullEvents(s, [pull(9), pull(8)]).told;
    final message = pullsMessage(s, told);
    expect(message, startsWith('Pull requests in EgorPanteleev/Caldo:\n\n#8'));
    expect(message.indexOf('#8'), lessThan(message.indexOf('#9')));
    expect(message, endsWith('\n\nReview it as your rules say.'));
    // The agent is told it is an event, not the user.
    final said = withSender(message, eventSender(s));
    expect(said, startsWith('[Events this chat is subscribed to'));
    expect(said, contains('not a message from the user'));
    expect(said, contains('#7'));
  });

  test('a repository from a name or a link', () {
    expect(Subscription.repoOf('EgorPanteleev/Caldo'), 'EgorPanteleev/Caldo');
    expect(
      Subscription.repoOf('https://github.com/EgorPanteleev/Caldo/pull/24'),
      'EgorPanteleev/Caldo',
    );
    expect(
      Subscription.repoOf('git@github.com:EgorPanteleev/Caldo.git'),
      'EgorPanteleev/Caldo',
    );
    expect(Subscription.repoOf('Caldo'), isNull);
    expect(Subscription.repoOf('a b/c'), isNull);
  });

  test('reads gh pr list', () async {
    late List<String> asked;
    final github = GitHub(
      gh: (args, {dir}) async {
        asked = args;
        return '[{"author":{"login":"EgorPanteleev"},"baseRefName":"master",'
            '"body":"Hi","createdAt":"2026-11-24T19:13:38Z",'
            '"headRefName":"bump","headRefOid":"ae84be14","isDraft":false,'
            '"number":25,"state":"MERGED","title":"Call it 2.21.0",'
            '"url":"https://github.com/EgorPanteleev/Caldo/pull/25"}]';
      },
    );
    final pulls = await github.pulls('EgorPanteleev/Caldo');
    expect(asked.take(4), ['pr', 'list', '--repo', 'EgorPanteleev/Caldo']);
    expect(pulls.single.number, 25);
    expect(pulls.single.state, 'MERGED');
    expect(pulls.single.author, 'EgorPanteleev');
    expect(pulls.single.created, DateTime.utc(2026, 11, 24, 19, 13, 38));
  });
}

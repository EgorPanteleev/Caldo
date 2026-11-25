import 'package:caldo/mcp/notices.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<(String, String, String)> told;
  late Notices notices;

  setUp(() {
    told = [];
    notices = Notices(
      tell: (chat, kind, text) => told.add((chat, kind, text)),
      hold: const Duration(milliseconds: 20),
    );
  });

  Future<void> later() =>
      Future<void>.delayed(const Duration(milliseconds: 40));

  test("tells a turn of the user's over, a while after", () async {
    notices.heard('c', null);
    notices.stands('c', 'running');
    notices.stands('c', 'finished', said: 'Done: 3 tests added.');
    expect(told, isEmpty);
    await later();
    expect(told, [('c', 'waiting', 'Done: 3 tests added.')]);
  });

  test('not a turn that carries straight on into another', () async {
    notices.stands('c', 'running');
    notices.stands('c', 'finished');
    notices.stands('c', 'running');
    await later();
    expect(told, isEmpty);
    notices.stands('c', 'finished', note: 'Stopped at the usage limit.');
    await later();
    expect(told, [('c', 'waiting', 'Stopped at the usage limit.')]);
  });

  test("nor one begun by another chat's message, or an event", () async {
    notices.heard('c', {'chat': 'other'});
    notices.stands('c', 'running');
    notices.stands('c', 'finished');
    notices.heard('c', {'event': 'pulls'});
    notices.stands('c', 'running');
    notices.stands('c', 'idle');
    notices.stands('c', 'running');
    notices.stands('c', 'finished');
    await later();
    expect(told, isEmpty);
    // Typed into its terminal by the user: theirs again.
    notices.typed('c');
    notices.stands('c', 'running');
    notices.stands('c', 'finished');
    await later();
    expect(told.single.$2, 'waiting');
  });

  test('nor one never seen to begin: a chat taken up again', () async {
    notices.stands('c', 'finished');
    await later();
    expect(told, isEmpty);
  });

  test('tells a question at once, whoever began the turn, once', () async {
    notices.heard('c', {'chat': 'other'});
    notices.stands('c', 'running');
    notices.stands('c', 'asking', note: 'Bash: rm -rf build');
    notices.stands('c', 'asking', note: 'Bash: rm -rf build');
    expect(told, [('c', 'asking', 'Bash: rm -rf build')]);
    notices.stands('c', 'running');
    notices.stands('c', 'asking', note: 'Bash: rm -rf build');
    expect(told, hasLength(2));
  });

  test('a chat deleted while held is not told', () async {
    notices.stands('c', 'running');
    notices.stands('c', 'finished');
    notices.forget('c');
    await later();
    expect(told, isEmpty);
  });

  test('tells a turn ended asking something as any turn over', () async {
    notices.stands('c', 'running');
    notices.stands('c', 'your_turn', said: 'Want me to open a PR?');
    await later();
    expect(told, [('c', 'waiting', 'Want me to open a PR?')]);
  });
}

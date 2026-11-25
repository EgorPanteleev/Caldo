import 'package:caldo/mcp/asks_back.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a question at the end asks', () {
    expect(asksBack('Fixed the parser.\n\nWant me to open a PR?'), isTrue);
    expect(asksBack('Готово. Открыть PR?'), isTrue);
    expect(asksBack('Done. Should I also **update the docs?**'), isTrue);
    expect(asksBack('Which do you prefer (A or B?)'), isTrue);
  });

  test('an offer at the end asks, in the languages used', () {
    expect(
      asksBack('All tests pass. Let me know if you want the README too.'),
      isTrue,
    );
    expect(asksBack('If you\'d like, I can also add a migration.'), isTrue);
    expect(asksBack('Готово. Если хотите, добавлю тесты.'), isTrue);
    expect(asksBack('Могу также обновить README.'), isTrue);
    expect(asksBack('Fertig. Soll ich noch Tests schreiben.'), isTrue);
  });

  test('so do choices listed after the question', () {
    expect(
      asksBack(
        'Two ways to go:\n\nWhich one would suit?\n\n'
        '1. Keep the cache\n2. Drop it',
      ),
      isTrue,
    );
  });

  test('a report that asks nothing has finished', () {
    expect(asksBack(''), isFalse);
    expect(asksBack('Done: 3 tests added, all passing.'), isFalse);
    expect(asksBack('Changes:\n\n- Fixed the parser\n- Added a test'), isFalse);
    expect(asksBack('Готово, PR #42 открыт.'), isFalse);
  });

  test('not for a question earlier on, or one in code or a link', () {
    expect(
      asksBack('Why did it fail? A missing await.\n\nFixed and pushed.'),
      isFalse,
    );
    expect(asksBack('Use `a ?? b` there now.'), isFalse);
    expect(asksBack('Opened https://example.com/x?id=3 for it.'), isFalse);
    expect(asksBack('Done.\n\n```dart\nfinal x = y ? 1 : 2;\n```'), isFalse);
  });
}

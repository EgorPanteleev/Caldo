import 'package:caldo/models/task.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/widgets/quick_add_bar.dart' show splitTags;
import 'package:flutter_test/flutter_test.dart';
import 'support/test_db.dart';

/// Tags: written in a title, carried by a task, and what the screens can be
/// narrowed to.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(initTestDatabase);

  setUp(resetTestDatabase);

  test('a #word in a quick-added title is a tag, not part of it', () {
    final split = splitTags('Essay #uni draft #Friends', known: ['friends']);
    expect(split.words, 'Essay draft');
    // Spelled as the tag already in use, so it is one group and not two.
    expect(split.tags, ['uni', 'friends']);

    // The filter's tag goes on too, once.
    expect(splitTags('Read #UNI', also: 'uni').tags, ['UNI']);
    expect(splitTags('Read', also: 'uni').tags, ['uni']);
    // A # inside a word is not a tag.
    expect(splitTags('Issue C#7').tags, isEmpty);
  });

  test('a tag is a word, whatever it was typed as', () {
    expect(Task.tagOf('  #uni '), 'uni');
    expect(Task.tagOf('study group'), 'study-group');
    expect(Task.tagOf('#'), isNull);
  });

  test('the screens can be narrowed to one tag, and nothing else is', () async {
    final today = dayOf(DateTime.now());
    final provider = TaskProvider();
    await provider.loadLists();
    Future<void> add(String title, List<String> tags, {int days = 0}) =>
        provider.add(
          Task(
            listId: 1,
            title: title,
            dueAt: today.add(Duration(days: days)).millisecondsSinceEpoch,
            tags: tags,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
    await add('Essay', ['uni']);
    await add('Lecture', ['Uni', 'early'], days: 1);
    await add('Pizza', ['friends']);
    await add('Laundry', []);
    await add('Old reading', ['uni'], days: -3);

    // "Uni" is "uni": one tag, under the spelling it was first written in.
    expect(provider.tags, {'uni': 3, 'early': 1, 'friends': 1});

    String titles(Map<DateTime, List<Task>> days) => [
      for (final day in days.keys.toList()..sort())
        for (final t in days[day]!) t.title,
    ].join(', ');

    provider.setFilter('uni');
    expect(titles(provider.upcomingByDay), 'Essay, Lecture');
    expect(provider.overdue.map((t) => t.title), ['Old reading']);
    expect(provider.tasksForDay(today).map((t) => t.title), ['Essay']);
    // The widget and the menu's dot still see everything.
    expect(titles(provider.allUpcomingByDay), contains('Pizza'));
    expect(provider.allOverdue, hasLength(1));

    // Taken off its last task, the tag is gone, and so is the filter on it.
    provider.setFilter('friends');
    final pizza = await taskNamed('Pizza');
    await provider.update(pizza.copyWith(tags: []));
    expect(provider.tags.containsKey('friends'), isFalse);
    expect(provider.filter, isNull);
    expect(titles(provider.upcomingByDay), contains('Laundry'));
  });

  test('search finds a task by its tag, with or without the #', () async {
    final provider = TaskProvider();
    await provider.loadLists();
    await provider.add(
      Task(
        listId: 1,
        title: 'Essay',
        tags: const ['uni'],
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    expect((await provider.searchAll('#uni')).map((t) => t.title), ['Essay']);
    expect((await provider.searchAll('uni')).map((t) => t.title), ['Essay']);
    expect(await provider.searchAll('#friends'), isEmpty);
  });
}

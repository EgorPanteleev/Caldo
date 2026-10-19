import 'package:caldo/models/task.dart';
import 'package:caldo/models/task_list.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/widgets/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final list = TaskList(id: 1, name: 'Work', createdAt: 0);

  Future<void> pumpCard(WidgetTester tester, {required bool done}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(AppAccent.presets.first),
        home: Scaffold(
          body: TaskCard(
            task: Task(
              id: 1,
              listId: 1,
              title: 'Ship',
              done: done,
              createdAt: 0,
            ),
            list: list,
            onTap: () {},
            onToggle: () {},
          ),
        ),
      ),
    );
  }

  /// How far the mark inside the tick is drawn, from nothing to all of it.
  double markDrawn(WidgetTester tester) {
    final paint = tester.widget<CustomPaint>(find.byKey(taskCardMarkKey));
    return (paint.painter! as CheckMark).progress;
  }

  /// The ink the card is actually filled with this frame — the widget holds
  /// where the animation is going, the render object where it has got to.
  Color cardInk(WidgetTester tester) {
    final box = tester.renderObject<RenderDecoratedBox>(
      find
          .descendant(
            of: find.byType(TaskCard),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    return (box.decoration as BoxDecoration).color!;
  }

  testWidgets('the mark is drawn into the tick rather than switched on', (
    tester,
  ) async {
    await pumpCard(tester, done: false);
    expect(markDrawn(tester), 0, reason: 'nothing drawn yet');

    await pumpCard(tester, done: true);
    await tester.pump(const Duration(milliseconds: 120));

    // Halfway through, the stroke is partly drawn: ticking a task off is the
    // one gesture in the app worth watching happen.
    final half = markDrawn(tester);
    expect(half, greaterThan(0));
    expect(half, lessThan(1));

    await tester.pumpAndSettle();
    expect(markDrawn(tester), 1);
  });

  testWidgets('the card sinks into the ground over the same moment', (
    tester,
  ) async {
    await pumpCard(tester, done: false);
    final open = cardInk(tester);

    await pumpCard(tester, done: true);
    await tester.pump(const Duration(milliseconds: 16));
    final early = cardInk(tester);
    expect(early.a, lessThan(open.a), reason: 'already fading');
    expect(early.a, greaterThan(0.07), reason: 'not there yet');

    await tester.pumpAndSettle();
    expect(cardInk(tester).a, moreOrLessEquals(0.07, epsilon: 0.001));
  });

  testWidgets('a leaving card folds away to nothing', (tester) async {
    Future<void> pump({required bool leaving}) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(AppAccent.presets.first),
        home: Scaffold(
          body: Column(
            children: [
              TaskCard(
                task: Task(
                  id: 1,
                  listId: 1,
                  title: 'Ship',
                  done: true,
                  createdAt: 0,
                ),
                list: list,
                onTap: () {},
                onToggle: () {},
                leaving: leaving,
              ),
            ],
          ),
        ),
      ),
    );

    await pump(leaving: false);
    final full = tester.getSize(find.byType(TaskCard)).height;
    expect(full, greaterThan(0));

    await pump(leaving: true);
    await tester.pump(const Duration(milliseconds: 70));
    // On its way: still taking room, so the cards below are not yet moving.
    expect(tester.getSize(find.byType(TaskCard)).height, greaterThan(0));

    await tester.pumpAndSettle();
    // Gone, and the gap it was in closed with it.
    expect(tester.getSize(find.byType(TaskCard)).height, 0);
  });
}

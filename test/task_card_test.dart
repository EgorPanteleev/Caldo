import 'package:caldo/l10n/strings.dart';
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
            // The fill, not the rim a picked-out card wears in front of it.
            matching: find.byWidgetPredicate(
              (w) =>
                  w is DecoratedBox &&
                  w.position == DecorationPosition.background,
            ),
          )
          .first,
    );
    return (box.decoration as CardPane).ink;
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
    expect(early.a, greaterThan(TaskCard.doneInk), reason: 'not there yet');

    await tester.pumpAndSettle();
    expect(
      cardInk(tester).a,
      moreOrLessEquals(TaskCard.doneInk, epsilon: 0.001),
    );
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

  testWidgets('the tick answers the tap; the cross-out comes a beat after', (
    tester,
  ) async {
    Future<void> pump({required bool ticking}) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(AppAccent.presets.first),
        home: Scaffold(
          body: TaskCard(
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
            ticking: ticking,
          ),
        ),
      ),
    );
    TextDecoration? titleLine() => tester
        .widget<DefaultTextStyle>(
          find
              .ancestor(
                of: find.text('Ship'),
                matching: find.byType(DefaultTextStyle),
              )
              .first,
        )
        .style
        .decoration;

    await pump(ticking: true);
    await tester.pumpAndSettle();
    expect(markDrawn(tester), 1, reason: 'ticked at once');
    expect(titleLine(), isNot(TextDecoration.lineThrough));

    await pump(ticking: false);
    await tester.pumpAndSettle();
    expect(titleLine(), TextDecoration.lineThrough);
  });

  testWidgets('a task sent to an agent says where the agent stands', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(411 * 3, 400 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final s = S.forCode('en');
    Future<void> pump(String? state) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(AppAccent.presets.first),
        home: Scaffold(
          body: TaskCard(
            task: Task(
              id: 1,
              listId: 1,
              title: 'Renew the domain before it lapses',
              notes: 'The registrar is the one with the orange logo',
              dueAt: DateTime(2026, 11, 25, 9).millisecondsSinceEpoch,
              hasTime: true,
              startedAt: 1,
              agent: 'Codex · gpt-5.1-codex-max',
              agentState: state,
              createdAt: 0,
            ),
            list: list,
            onTap: () {},
            onToggle: () {},
          ),
        ),
      ),
    );

    // Sent and in progress, its agent says nothing yet: the badge stays.
    await pump(null);
    expect(find.byType(InProgressBadge), findsOneWidget);

    for (final (state, word) in [
      (AgentState.waiting, s.agentWaiting),
      (AgentState.working, s.agentWorking),
      (AgentState.asking, s.agentAsking),
      (AgentState.review, s.agentReview),
      (AgentState.failed, s.agentFailed),
    ]) {
      await pump(state);
      // Its word says more than In progress; a long label is cut, not
      // the row overflowed.
      expect(find.byType(InProgressBadge), findsNothing);
      final mark = tester.widget<Text>(
        find.descendant(
          of: find.byKey(claudeMarkKey),
          matching: find.byType(Text),
        ),
      );
      expect(mark.textSpan!.toPlainText(), endsWith(' · $word'));
      expect(tester.takeException(), isNull);
    }
  });
}

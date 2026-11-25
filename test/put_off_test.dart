import 'package:caldo/l10n/strings.dart';
import 'package:caldo/models/task.dart';
import 'package:caldo/models/task_list.dart';
import 'package:caldo/services/agents.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/widgets/put_off.dart';
import 'package:caldo/widgets/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final list = TaskList(id: 1, name: 'Work', createdAt: 0);
  final s = S.forCode('en');

  Widget card(String title) => PutOff(
    task: Task(id: 1, listId: 1, title: title, createdAt: 0),
    leftOnly: true,
    child: TaskCard(
      task: Task(id: 1, listId: 1, title: title, createdAt: 0),
      list: list,
      onTap: () {},
      onToggle: () {},
    ),
  );

  /// Days in a pager, as under the calendar, a card on each.
  Future<PageController> pumpDays(WidgetTester tester) async {
    tester.view.physicalSize = const Size(411 * 3, 600 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final pager = PageController(initialPage: 5);
    addTearDown(pager.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(AppAccent.presets.first),
        home: Scaffold(
          body: PageView.builder(
            controller: pager,
            itemBuilder: (_, i) =>
                Align(alignment: Alignment.topCenter, child: card('Day $i')),
          ),
        ),
      ),
    );
    return pager;
  }

  /// A finger drawn across [by] slowly, as a hand pulls a card.
  Future<void> pull(WidgetTester tester, String on, double by) async {
    final from = tester.getCenter(find.text(on));
    final finger = await tester.startGesture(from);
    for (var i = 1; i <= 20; i++) {
      await finger.moveTo(from + Offset(by * i / 20, 0));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await finger.up();
    await tester.pumpAndSettle();
  }

  testWidgets('under the calendar a card is pulled open leftwards', (
    tester,
  ) async {
    Agents.instance.signedInForTest = true;
    addTearDown(() => Agents.instance.signedInForTest = null);
    final pager = await pumpDays(tester);
    await pull(tester, 'Day 5', -150);
    // Open on its actions, the day where it was.
    expect(pager.page, 5);
    expect(find.text(s.tomorrow), findsOneWidget);
    expect(find.text(s.pickDay), findsOneWidget);
    expect(find.text(s.swipeAgent), findsOneWidget);
  });

  testWidgets('rightwards over a card the day turns back', (tester) async {
    final pager = await pumpDays(tester);
    await pull(tester, 'Day 5', 260);
    expect(pager.page, 4);
    // Signed out: no agent to send to.
    await pull(tester, 'Day 4', -150);
    expect(find.text(s.pickDay), findsOneWidget);
    expect(find.text(s.swipeAgent), findsNothing);
  });
}

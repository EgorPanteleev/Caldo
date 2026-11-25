import 'package:caldo/l10n/strings.dart';
import 'package:caldo/mcp/subscriptions.dart';
import 'package:caldo/screens/agents_screen.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final s = S.forCode('en');
  final scrollable = find.byType(Scrollable).first;

  Future<void> show(WidgetTester tester, {Subscription? sub}) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [S.delegate],
        theme: AppTheme.dark(AppAccent.presets.first),
        home: SubscriptionScreen(chat: 'reviewer', sub: sub),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('new subscription defaults to the folder and new PRs', (
    tester,
  ) async {
    await show(tester);

    final source = tester.widget<RadioGroup<bool>>(
      find.byType(RadioGroup<bool>),
    );
    expect(source.groupValue, isTrue);
    expect(find.text(s.chatSubRepoHint), findsNothing);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, s.chatSubOpened),
          )
          .value,
      isTrue,
    );

    await tester.tap(find.text(s.chatSubOtherRepo));
    await tester.pumpAndSettle();
    expect(find.text(s.chatSubRepoHint), findsOneWidget);

    final subscribe = find.widgetWithText(FilledButton, s.chatSubCreate);
    await tester.scrollUntilVisible(subscribe, 150, scrollable: scrollable);
    await tester.tap(subscribe);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text(s.chatSubBadRepo),
      -150,
      scrollable: scrollable,
    );
    expect(find.text(s.chatSubBadRepo), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text(s.chatSubThisRepo),
      -150,
      scrollable: scrollable,
    );
    await tester.tap(find.text(s.chatSubThisRepo));
    await tester.pumpAndSettle();
    expect(find.text(s.chatSubRepoHint), findsNothing);
    expect(find.text(s.chatSubBadRepo), findsNothing);
  });

  testWidgets('editing keeps the saved repository and selected events', (
    tester,
  ) async {
    await show(
      tester,
      sub: Subscription(
        id: 1,
        chat: 'reviewer',
        target: 'caldo/app',
        events: const ['pushed', 'closed'],
        created: DateTime.utc(2026),
      ),
    );

    expect(find.text('caldo/app'), findsOneWidget);
    expect(
      tester.widget<RadioGroup<bool>>(find.byType(RadioGroup<bool>)).groupValue,
      isFalse,
    );
    for (final label in [s.chatSubPushed, s.chatSubClosed]) {
      final tile = find.widgetWithText(CheckboxListTile, label);
      await tester.scrollUntilVisible(tile, 100, scrollable: scrollable);
      expect(tester.widget<CheckboxListTile>(tile).value, isTrue);
      await tester.tap(tile);
      await tester.pumpAndSettle();
    }
    final save = find.widgetWithText(FilledButton, s.save);
    await tester.scrollUntilVisible(save, 150, scrollable: scrollable);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
  });
}

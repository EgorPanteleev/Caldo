import 'package:caldo/l10n/strings.dart';
import 'package:caldo/screens/agents_screen.dart';
import 'package:caldo/services/agents.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/widgets/screen_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Accounts groups and aligns worker and account cards', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(340, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final now = DateTime.now().toUtc();
    final old = now.subtract(const Duration(minutes: 3));
    AgentWorker worker(String name, DateTime seenAt, DateTime? sampledAt) =>
        AgentWorker.fromJson({
          'id': name,
          'name': name,
          'seen_at': seenAt.toIso8601String(),
          if (name == 'Desk')
            'agents': [
              {'id': 'codex', 'accounts': true},
            ],
          if (sampledAt != null)
            'resources': {
              'sampled_at': sampledAt.toIso8601String(),
              'cpu_percent': 25,
              'ram_used_bytes': 4 << 30,
              'ram_total_bytes': 16 << 30,
            },
        });

    final agents = Agents.instance;
    agents
      ..signedInForTest = true
      ..workers = [
        worker('Desk', now, now),
        worker('Away', old, old),
        worker('Upgraded server', now, null),
        worker('Previous worker build', now, old),
      ]
      ..accounts = [
        AgentAccount(
          id: 'work',
          workerId: 'Desk',
          agent: 'codex',
          name: 'Work login',
          state: AccountState.ready,
          created: now,
        ),
        AgentAccount(
          id: 'personal',
          workerId: 'Away',
          agent: 'claude',
          name: 'Personal login',
          state: AccountState.ready,
          created: now,
        ),
      ];
    addTearDown(() {
      agents
        ..workers = const []
        ..accounts = const []
        ..signedInForTest = null;
    });

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [S.delegate],
        theme: AppTheme.dark(AppAccent.presets.first),
        home: const AgentsScreen(),
      ),
    );
    final s = S.forCode('en');
    final title = find.byKey(screenTitleKey);
    await tester.tap(find.byTooltip('Accounts'));
    await tester.pumpAndSettle();

    expect(tester.widget<Text>(title).data, 'Accounts');
    expect(find.text('Desk'), findsOneWidget);
    expect(find.text('Away · offline'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    expect(find.text('4.0 / 16.0 GiB'), findsOneWidget);
    expect(find.text('GPU'), findsNWidgets(4));
    expect(find.text('—'), findsNWidgets(10));
    double top(String label) => tester.getTopLeft(find.text(label)).dy;
    expect(top('Desk'), lessThan(top('Work login')));
    expect(top('Work login'), lessThan(top('Away · offline')));
    expect(top('Away · offline'), lessThan(top('Personal login')));
    expect(top('Personal login'), lessThan(top('Upgraded server')));
    Rect cardRect(String label, Type type) => tester.getRect(
      find.ancestor(of: find.text(label), matching: find.byType(type)).first,
    );
    final workerCard = cardRect('Desk', DecoratedBox);
    final accountCard = cardRect('Work login', Material);
    expect(accountCard.left, workerCard.left);
    expect(accountCard.right, workerCard.right);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip(s.addAccount));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(title).data, s.addAccount);
    expect(find.text(s.accountAddHint('Desk')), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(title).data, 'Accounts');

    tester.view.physicalSize = const Size(340, 275);
    await tester.pump();
    final personalLogin = find.text('Personal login').hitTestable();
    expect(personalLogin, findsNothing);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const WorkersScreen(accountId: 'personal'),
      ),
    );
    await tester.pumpAndSettle();
    expect(personalLogin, findsOneWidget);
    navigator.pop();
    await tester.pumpAndSettle();

    agents.workers = [worker('Desk', now, null)];
    await agents.load();
    await tester.pump();
    expect(find.text('25%'), findsNothing);
    expect(find.text('GPU'), findsOneWidget);
    expect(find.text('Personal login'), findsNothing);
  });
}

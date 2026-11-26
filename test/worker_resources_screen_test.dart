import 'package:caldo/l10n/strings.dart';
import 'package:caldo/screens/agents_screen.dart';
import 'package:caldo/services/agents.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Workers shows current metrics and hides older samples', (
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
      ];
    addTearDown(() {
      agents
        ..workers = const []
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
    await tester.tap(find.byTooltip('Workers'));
    await tester.pumpAndSettle();

    expect(find.text('Workers'), findsOneWidget);
    expect(find.text('Desk'), findsOneWidget);
    expect(find.text('Away · offline'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    expect(find.text('4.0 / 16.0 GiB'), findsOneWidget);
    expect(find.text('GPU'), findsNWidgets(4));
    expect(find.text('—'), findsNWidgets(10));
    expect(tester.takeException(), isNull);

    agents.workers = [worker('Desk', now, null)];
    await agents.load();
    await tester.pump();
    expect(find.text('25%'), findsNothing);
    expect(find.text('GPU'), findsOneWidget);
  });
}

import 'package:caldo/l10n/strings.dart';
import 'package:caldo/models/task.dart';
import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/screens/board_screen.dart';
import 'package:caldo/screens/calendar_screen.dart';
import 'package:caldo/screens/settings_screen.dart';
import 'package:caldo/screens/task_edit_screen.dart';
import 'package:caldo/screens/tasks_screen.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_db.dart';

/// Every screen with words on it, drawn in every language on a small
/// phone. German and Kazakh run long, and a word that does not fit is an
/// overflow, which fails the test — the same net the English screens are
/// pumped through.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    initTestDatabase();
    await initializeDateFormatting();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
  });
  tearDown(() => S.use('en'));

  for (final code in S.names.keys) {
    testWidgets('the screens fit in ${S.names[code]}', (tester) async {
      late TaskProvider provider;
      Task? ship;
      await tester.runAsync(() async {
        provider = await seedProvider();
        ship = await taskNamed('Ship');
      });
      tester.view.physicalSize = const Size(960, 1920);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      Future<void> pump(Widget screen) async {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<TaskProvider>.value(value: provider),
              ChangeNotifierProvider(create: (_) => SettingsProvider()),
            ],
            child: MaterialApp(
              locale: Locale(code),
              supportedLocales: S.supported,
              localizationsDelegates: const [
                S.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              theme: AppTheme.dark(AppAccent.presets.first),
              home: screen,
            ),
          ),
        );
        // The screens start reads of their own, which fake time cannot
        // finish; real time can.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }

      await pump(const TasksScreen());
      expect(find.text(S.forCode(code).schedule), findsOneWidget);
      await pump(const CalendarScreen());
      await pump(const BoardScreen());
      expect(
        find.textContaining(
          S.forCode(code).inProgress.toUpperCase(),
          findRichText: true,
        ),
        findsOneWidget,
      );
      await pump(const SettingsScreen());
      expect(find.text(S.forCode(code).settings), findsOneWidget);
      await pump(TaskEditScreen(task: ship));
      expect(find.text(S.forCode(code).editTask), findsOneWidget);
    });
  }
}

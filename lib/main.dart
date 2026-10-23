import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/settings_provider.dart';
import 'providers/task_provider.dart';
import 'screens/home_screen.dart';
import 'services/reminders.dart';
import 'services/updates.dart';
import 'theme/app_theme.dart';
import 'widgets/quick_add_bar.dart';
import 'widgets/theme_switcher.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before the first screen, because the first thing a screen does is load its
  // tasks, and loading tasks is what sets the alarms.
  await Reminders.instance.init();
  // Where the keyboard is comes from Android as well as from MediaQuery —
  // see KeyboardGap. Nothing reads it until a field is tapped, but the
  // channel has to be listening before that.
  KeyboardGap.instance.listen();
  // Checking for a newer release is switched on here and nowhere else, so
  // the widget tests — which drive the real shell — never go online.
  Updates.instance.enable();
  // Read before the first frame: the app has to open on the right screen,
  // not open on Schedule and swap a frame later. It is one small read, and
  // the provider reads the rest for itself once it is up.
  final start = await SettingsProvider.storedStartScreen();
  runApp(CaldoApp(start: start));
}

class CaldoApp extends StatelessWidget {
  /// The screen to open on, read from storage before the app was built.
  final StartScreen start;

  const CaldoApp({super.key, this.start = StartScreen.schedule});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        // The agenda is loaded here rather than waiting for the screen that
        // shows it: the reminders are set from it, and they should be in place
        // whichever screen the app happens to open on.
        ChangeNotifierProvider(
          create: (_) => TaskProvider()
            ..loadLists()
            ..loadTasks(),
        ),
      ],
      child: Consumer<SettingsProvider>(
        builder: (context, settings, _) => MaterialApp(
          title: 'Caldo',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(settings.accent),
          darkTheme: AppTheme.dark(settings.accent),
          themeMode: settings.themeMode,
          // Theme changes apply instantly; ThemeSwitcher animates the switch
          // as a cross-fade for a perfectly smooth transition.
          themeAnimationDuration: Duration.zero,
          // The clock Settings names goes in where every widget can read it,
          // and where reading it has the widget redrawn when it changes.
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(alwaysUse24HourFormat: settings.use24Hour),
            child: ThemeSwitcher(child: child!),
          ),
          home: HomeScreen(start: start),
        ),
      ),
    );
  }
}

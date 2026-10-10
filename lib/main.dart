import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/settings_provider.dart';
import 'providers/task_provider.dart';
import 'screens/home_screen.dart';
import 'services/reminders.dart';
import 'theme/app_theme.dart';
import 'widgets/theme_switcher.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before the first screen, because the first thing a screen does is load its
  // tasks, and loading tasks is what sets the alarms.
  await Reminders.instance.init();
  runApp(const CaldoApp());
}

class CaldoApp extends StatelessWidget {
  const CaldoApp({super.key});

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
          builder: (context, child) => ThemeSwitcher(child: child!),
          home: const HomeScreen(),
        ),
      ),
    );
  }
}

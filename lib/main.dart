import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/settings_provider.dart';
import 'providers/task_provider.dart';
import 'screens/home_screen.dart';
import 'theme/app_theme.dart';
import 'widgets/theme_switcher.dart';

void main() {
  runApp(const CaldoApp());
}

class CaldoApp extends StatelessWidget {
  const CaldoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        ChangeNotifierProvider(create: (_) => TaskProvider()..loadLists()),
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

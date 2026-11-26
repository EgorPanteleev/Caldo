import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'l10n/strings.dart';
import 'providers/events_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/task_provider.dart';
import 'providers/vault_provider.dart';
import 'screens/home_screen.dart';
import 'services/account.dart';
import 'services/attachments.dart';
import 'services/background.dart';
import 'services/desktop.dart';
import 'services/device_calendars.dart';
import 'services/recording.dart';
import 'services/reminders.dart';
import 'services/sync.dart';
import 'services/today_widget.dart';
import 'services/updates.dart';
import 'theme/app_theme.dart';
import 'theme/look.dart';
import 'theme/tweaks.dart';
import 'utils/platform.dart';
import 'widgets/background_surface.dart';
import 'widgets/desk.dart';
import 'widgets/perf_hud.dart';
import 'widgets/quick_add_bar.dart';
import 'widgets/recording_overlay.dart';
import 'widgets/theme_switcher.dart';
import 'widgets/update_prompt.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // On a desktop the app finds its own directories and database, which on
  // a phone the activity and sqflite's plugin do — before anything below
  // reads either.
  if (onDesktop) await Desktop.start();
  // Every language's month and weekday names, for the dates in Russian.
  await initializeDateFormatting();
  // Before the first screen, because the first thing a screen does is load its
  // tasks, and loading tasks is what sets the alarms.
  await Reminders.instance.init();
  // A reminder put up over the lock screen starts the app to show it.
  await Reminders.instance.takeLaunch();
  // Where the keyboard is comes from Android as well as from MediaQuery —
  // see KeyboardGap. Nothing reads it until a field is tapped, but the
  // channel has to be listening before that.
  if (!onDesktop) KeyboardGap.instance.listen();
  // Checking for a newer release is switched on here and nowhere else, so
  // the widget tests — which drive the real shell — never go online.
  Updates.instance.enable();
  // The home-screen widget, and hearing about the changes it and a
  // reminder's buttons make — both switched on here only, for the same
  // reason the update check is.
  // A desktop has neither a home screen to put the widget on nor a
  // calendar of the phone's to read; a reminder's buttons it does have, and
  // they are heard the same way.
  if (!onDesktop) TodayWidget.enable();
  Background.listen();
  // A round that changed something here is read back as a change from
  // outside is, and the account is taken up if there is one.
  Sync.instance.onChanged = () => Background.changed.value++;
  await Account.instance.enable();
  if (!onDesktop) DeviceCalendars.enable();
  // Where the attachments are kept, before the first form can draw one;
  // then the copies no task refers to any more are let go of.
  await Attachments.instance.enable();
  Attachments.instance.sweep();
  // Read before the first frame: the app has to open on the right screen,
  // not open on Schedule and swap a frame later. It is one small read, and
  // the provider reads the rest for itself once it is up.
  final start = await SettingsProvider.storedStartScreen();
  // An admin's colours, for the same reason: the first frame in them, not
  // in stock ones a moment before.
  await Tweaks.instance.load();
  // Whether Debug's record button is over every screen.
  await Recording.instance.load();
  runApp(CaldoApp(start: start));
}

class CaldoApp extends StatelessWidget {
  /// The app's navigator, for Escape to go back through on a desktop.
  static final _navigator = GlobalKey<NavigatorState>();

  /// The screen to open on, read from storage before the app was built.
  final AppScreen start;

  const CaldoApp({super.key, this.start = AppScreen.schedule});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        // The agenda is loaded here rather than waiting for the screen that
        // shows it: the reminders are set from it, and they should be in place
        // whichever screen the app happens to open on.
        //
        // Whether done tasks are drawn is Settings', and is handed over from
        // the first build on, not only once it is switched there.
        ChangeNotifierProxyProvider<SettingsProvider, TaskProvider>(
          create: (_) => TaskProvider()
            ..loadLists()
            ..start(),
          update: (_, settings, tasks) =>
              tasks!..setShowCompleted(settings.showCompleted),
        ),
        // The vault, which reads nothing until its screen is first shown.
        ChangeNotifierProvider(create: (_) => VaultProvider()),
        // The phone's own calendars, read as Settings says.
        ChangeNotifierProxyProvider<SettingsProvider, EventsProvider>(
          create: (_) => EventsProvider(),
          update: (_, settings, events) => events!
            ..configure(
              on: settings.showDeviceEvents,
              hidden: settings.hiddenCalendars,
            ),
        ),
      ],
      child: ListenableBuilder(
        listenable: Listenable.merge([Tweaks.instance, PerfHud.graphs]),
        // Only what the app as a whole is drawn with: a Consumer here had
        // every switch in Settings rebuild every screen there is.
        builder: (context, _) =>
            Selector<
              SettingsProvider,
              ({
                AppAccent accent,
                PaletteBackground background,
                Look look,
                ThemeMode themeMode,
                Locale? locale,
                bool use24Hour,
              })
            >(
              selector: (_, s) => (
                accent: s.accent,
                background: s.background,
                look: s.look,
                themeMode: s.themeMode,
                locale: s.locale,
                use24Hour: s.use24Hour,
              ),
              builder: (context, settings, _) => MaterialApp(
                title: 'Caldo',
                debugShowCheckedModeBanner: false,
                showPerformanceOverlay: PerfHud.graphsDrawn,
                theme: AppTheme.light(
                  settings.accent,
                  background: settings.background,
                ),
                darkTheme: AppTheme.dark(
                  settings.accent,
                  background: settings.background,
                ),
                themeMode: settings.themeMode,
                locale: settings.locale,
                supportedLocales: S.supported,
                localizationsDelegates: const [
                  S.delegate,
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                // Theme changes apply instantly; ThemeSwitcher animates the switch
                // as a cross-fade for a perfectly smooth transition.
                themeAnimationDuration: Duration.zero,
                scrollBehavior: onDesktop ? const DesktopScrolling() : null,
                // The clock Settings names goes in where every widget can read it,
                // and where reading it has the widget redrawn when it changes.
                builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
                  // The system bars wear the app's ground: left to the window's
                  // theme the navigation bar stays pure black, and Flutter's own
                  // status-bar scrim darkens a band across the top.
                  value: _barsOn(Theme.of(context)),
                  // Settings › Debug's recording and numbers, over everything,
                  // the urgent update's wall included.
                  child: RecordingOverlay(
                    child: PerfHud(
                      child: MediaQuery(
                        data: MediaQuery.of(
                          context,
                        ).copyWith(alwaysUse24HourFormat: settings.use24Hour),
                        child: ThemeSwitcher(
                          child: ValueListenableBuilder<Update?>(
                            valueListenable: Updates.instance.offered,
                            // An urgent update takes the navigator's place, and
                            // everything on it goes: the app is not to be used again
                            // until the update is in, and it starts afresh then.
                            builder: (context, update, child) =>
                                update != null && update.urgent
                                ? UpdateWall(update: update)
                                : UpdatePrompt(
                                    update: update,
                                    navigator: _navigator,
                                    child: child!,
                                  ),
                            child: onDesktop
                                ? DeskScope(
                                    navigator: _navigator,
                                    builder: (context, wide) => DeskKeys(
                                      navigator: _navigator,
                                      wide: wide,
                                      // A window too narrow for the desktop's layout is
                                      // the phone's app, at a phone's width.
                                      child: PhoneWide(
                                        on: !wide,
                                        child: child!,
                                      ),
                                    ),
                                  )
                                : child!,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                navigatorObservers: [
                  if (onDesktop) DeskScope.observer,
                  Recording.routes,
                ],
                navigatorKey: _navigator,
                home: HomeScreen(start: start),
              ),
            ),
      ),
    );
  }
}

SystemUiOverlayStyle _barsOn(ThemeData theme) {
  final dark = theme.brightness == Brightness.dark;
  final icons = dark ? Brightness.light : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: icons,
    statusBarBrightness: theme.brightness,
    systemNavigationBarColor:
        (theme.extension<AppPalette>() ??
                (dark ? AppPalette.dark : AppPalette.light))
            .bg,
    systemNavigationBarIconBrightness: icons,
    systemNavigationBarDividerColor: Colors.transparent,
  );
}

/// Keeps the app to the width of a large phone, in the middle of a window
/// made a little wider than that — one wider still gets the desktop's own
/// layout (`Desk`).
///
/// Every screen here is laid out for a phone held upright, and a window can
/// be made any shape: stretched, the tab bar was a pill a metre long and a
/// task's card a stripe from one edge to the other.
///
/// The same widgets whatever the width, so nothing under it loses its
/// state as the window is dragged past [width]; and the window's size is
/// handed down as the column's, for whatever measures itself against "the
/// screen".
class PhoneWide extends StatelessWidget {
  /// Off for the wide layout, which has the whole window. Still in the tree
  /// then, so the navigator under it stays where it is as the layout
  /// changes.
  final bool on;
  final Widget child;

  const PhoneWide({super.key, this.on = true, required this.child});

  static const width = 640.0;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = on ? PhoneWide.width : double.infinity;
    return BackgroundSurface(
      color: AppTheme.of(context).bg,
      child: Center(
        // The menu slides in from beyond the app's edge, and stays beyond
        // it until it does.
        child: ClipRect(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width),
            child: MediaQuery(
              data: media.copyWith(
                size: Size(
                  media.size.width < width ? media.size.width : width,
                  media.size.height,
                ),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// How the app scrolls under a mouse: as it does under a finger.
///
/// Left to itself Flutter gives a desktop a scrollbar down every list —
/// the clock's wheels and the row of groups among them — and takes a drag
/// of the mouse for the start of a selection rather than a scroll, which
/// would leave the month, the days under it and the board's lanes with no
/// way to be turned: they have no arrows, they are swiped.
class DesktopScrolling extends MaterialScrollBehavior {
  const DesktopScrolling();

  @override
  Set<PointerDeviceKind> get dragDevices => PointerDeviceKind.values.toSet();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

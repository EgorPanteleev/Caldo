import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Locale, ThemeMode, TimeOfDay;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/holidays.dart';
import '../db/database.dart';
import '../l10n/strings.dart';
import '../services/reminders.dart';
import '../services/today_widget.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';

/// The screens the menu leads to, Settings aside: it is always there, being
/// the way back to the others.
enum AppScreen { schedule, calendar, board, done }

/// Holds user-configurable settings: the screen the app opens on and which
/// screens are in the menu, its theme mode and accent, which day the
/// calendar week starts on, whether completed tasks stay visible, and when a
/// task is allowed to interrupt.
class SettingsProvider extends ChangeNotifier {
  static const _kStartScreen = 'start_screen';
  static const _kHiddenScreens = 'hidden_screens';
  static const _kThemeMode = 'theme_mode';
  static const _kAccent = 'accent_id';
  static const _kWeekStart = 'week_starts_monday';
  static const _kShowCompleted = 'show_completed';
  static const _kHolidayCountry = 'holiday_country';
  static const _kShowHolidays = 'show_holidays';

  /// The colour new tasks used to start in, which a setting chose before
  /// tasks had groups. Read once, to colour the default group.
  static const _kDefaultStyle = 'default_task_style';
  static const _kReminders = 'reminders_enabled';
  static const _kReminderAt = 'reminder_minutes';
  static const _kReminderLead = 'reminder_lead';
  static const _kFullScreen = 'full_screen_reminders';
  static const _kClock = 'use_24_hour';
  static const _kDeviceEvents = 'show_device_events';
  static const _kHiddenCalendars = 'hidden_calendars';
  static const _kLanguage = 'language';

  /// The screen the app opens on. Schedule out of the box: it is the one
  /// that answers "what now", which is what opening a to-do list is usually
  /// for.
  AppScreen _startScreen = AppScreen.schedule;

  /// The screens left out of the menu. Never all four: a menu of Settings
  /// alone would be an app with nothing in it.
  Set<AppScreen> _hiddenScreens = const {};

  /// The app defaults to dark mode.
  ThemeMode _themeMode = ThemeMode.dark;

  /// The active accent colour (defaults to violet).
  AppAccent _accent = AppAccent.presets.first;

  /// Whether calendar weeks start on Monday (false = Sunday).
  bool _weekStartsMonday = true;

  /// Whether completed tasks stay listed under the open ones.
  bool _showCompleted = true;

  /// Whether public holidays are marked on the calendar.
  bool _showHolidays = true;

  /// The country whose holidays are shown, or null to follow the device.
  String? _holidayCountry;

  /// Whether events from the phone's own calendars are shown. Off until
  /// asked for, since it needs a permission and most of what a to-do list is
  /// for does not.
  bool _showDeviceEvents = false;

  /// The phone's calendars whose events are left out, by id. Left out rather
  /// than let in, so a calendar added later shows up without being asked.
  Set<String> _hiddenCalendars = const {};

  /// Whether a dated task puts up a notification when it comes due.
  bool _reminders = true;

  /// Minutes past midnight an all-day task is announced at. A timed task is
  /// announced at its own time; one with no time still has to be said at some
  /// point in the day, and nine in the morning is the least of the evils.
  int _reminderMinutes = 9 * 60;

  /// Minutes ahead of its time a timed task is announced, unless it says
  /// otherwise. At the time out of the box, which is what it always was.
  int _reminderLead = 0;

  /// Whether a reminder takes the whole screen while the phone is locked,
  /// the way an alarm does. On out of the box: it was asked for.
  bool _fullScreen = true;

  /// The leads offered, here and on the task form.
  static const leads = [0, 5, 10, 15, 30, 60];

  /// Whether times are written on a 24-hour clock, or null for as the phone
  /// does until a choice is made here.
  bool? _use24Hour;

  /// The language chosen here, or null for the phone's.
  String? _language;

  /// Whether times are written on a 24-hour clock: the choice made here, or
  /// the phone's own until there is one.
  bool get use24Hour =>
      _use24Hour ?? PlatformDispatcher.instance.alwaysUse24HourFormat;

  String? get language => _language;

  /// The language to hand `MaterialApp`, or null to let it follow the phone.
  Locale? get locale => _language == null ? null : Locale(_language!);

  /// The language actually in force: the one chosen, or the phone's when
  /// there is a translation for it, or English.
  String get languageInForce => _language ?? phoneLanguage;

  static String get phoneLanguage {
    final phone = PlatformDispatcher.instance.locale.languageCode;
    return S.supports(phone) ? phone : 'en';
  }

  /// The screen the app opens on: the one chosen, unless it has been taken
  /// out of the menu since, and then the first one still in it. The choice
  /// is kept, so putting the screen back puts it back as the start too.
  AppScreen get startScreen => _opensOn(_startScreen, _hiddenScreens);
  Set<AppScreen> get hiddenScreens => _hiddenScreens;

  /// The screens in the menu, in its order.
  List<AppScreen> get shownScreens => [
    for (final screen in AppScreen.values)
      if (!_hiddenScreens.contains(screen)) screen,
  ];

  static AppScreen _opensOn(AppScreen chosen, Set<AppScreen> hidden) =>
      hidden.contains(chosen)
      ? AppScreen.values.firstWhere(
          (s) => !hidden.contains(s),
          orElse: () => chosen,
        )
      : chosen;
  ThemeMode get themeMode => _themeMode;
  AppAccent get accent => _accent;
  bool get weekStartsMonday => _weekStartsMonday;
  bool get showCompleted => _showCompleted;
  bool get showHolidays => _showHolidays;
  String? get holidayCountry => _holidayCountry;
  bool get showDeviceEvents => _showDeviceEvents;
  Set<String> get hiddenCalendars => _hiddenCalendars;
  bool get reminders => _reminders;
  int get reminderMinutes => _reminderMinutes;
  int get reminderLead => _reminderLead;
  bool get fullScreenReminders => _fullScreen;

  /// The hour all-day reminders land on, as the pickers want it.
  TimeOfDay get reminderTime =>
      TimeOfDay(hour: _reminderMinutes ~/ 60, minute: _reminderMinutes % 60);

  /// The country the calendar actually marks holidays for: the chosen one,
  /// the device's when none is chosen, and none at all when they are off.
  String? get effectiveHolidayCountry =>
      _showHolidays ? (_holidayCountry ?? Holidays.detectCountry()) : null;

  /// The stored choice on its own, read before the first frame.
  ///
  /// [load] cannot be waited for: it ends by asking Android about
  /// notifications, and on a first run that is a dialog the user has to
  /// answer — waiting for it would hold the app on a blank screen until they
  /// did. The screen to open on has to be known before anything is drawn,
  /// though, or the app shows Schedule for a frame or two and then swaps,
  /// which is worse than the setting not existing.
  static Future<AppScreen> storedStartScreen() async {
    final prefs = await SharedPreferences.getInstance();
    return _opensOn(
      _startScreenFromString(prefs.getString(_kStartScreen)),
      _screensFrom(prefs.getStringList(_kHiddenScreens)),
    );
  }

  /// Puts the stored settings where a background isolate needs them — the
  /// clock notifications are written on, and when the alarms go off —
  /// without the permission request [load] ends with, which nobody would be
  /// there to answer. Reloaded from disk each time: the isolate may have
  /// been running since before the setting was last changed.
  static Future<void> prime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final settings = SettingsProvider().._read(prefs);
    S.use(settings.languageInForce);
    Dates.use24Hour = settings.use24Hour;
    await settings._tellReminders();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _read(prefs);
    await _taskColourToGroup(prefs);
    S.use(languageInForce);
    Dates.use24Hour = use24Hour;
    await _tellReminders();
    // Reminders are on out of the box, so the first run is where Android has
    // to be asked — nothing else in the app would ever ask, and a permission
    // that was never requested looks exactly like a feature that is broken.
    if (_reminders) await Reminders.instance.requestPermission();
    notifyListeners();
  }

  /// A new task takes its group's colour now; a colour of its own on every
  /// task added would hide the group's. The setting it used to take one from
  /// is gone, and what it said is kept as the colour of the default group,
  /// where new tasks land when no group is chosen — so they come out in the
  /// colour they always have.
  static Future<void> _taskColourToGroup(SharedPreferences prefs) async {
    final colour = prefs.getString(_kDefaultStyle);
    if (colour == null) return;
    final db = AppDatabase.instance;
    final lists = await db.getLists();
    if (lists.isNotEmpty) {
      await db.updateList(lists.first.copyWith(styleId: colour));
    }
    await prefs.remove(_kDefaultStyle);
  }

  void _read(SharedPreferences prefs) {
    _startScreen = _startScreenFromString(prefs.getString(_kStartScreen));
    _hiddenScreens = _screensFrom(prefs.getStringList(_kHiddenScreens));
    _themeMode = _themeModeFromString(prefs.getString(_kThemeMode));
    _accent = AppAccent.byId(prefs.getString(_kAccent));
    _weekStartsMonday = prefs.getBool(_kWeekStart) ?? _weekStartsMonday;
    _showCompleted = prefs.getBool(_kShowCompleted) ?? _showCompleted;
    _showHolidays = prefs.getBool(_kShowHolidays) ?? _showHolidays;
    _holidayCountry = prefs.getString(_kHolidayCountry);
    _reminders = prefs.getBool(_kReminders) ?? _reminders;
    _reminderMinutes = prefs.getInt(_kReminderAt) ?? _reminderMinutes;
    _reminderLead = prefs.getInt(_kReminderLead) ?? _reminderLead;
    _fullScreen = prefs.getBool(_kFullScreen) ?? _fullScreen;
    _use24Hour = prefs.getBool(_kClock);
    _language = prefs.getString(_kLanguage);
    _showDeviceEvents = prefs.getBool(_kDeviceEvents) ?? _showDeviceEvents;
    _hiddenCalendars = {...?prefs.getStringList(_kHiddenCalendars)};
  }

  Future<void> update({
    AppScreen? startScreen,
    Set<AppScreen>? hiddenScreens,
    ThemeMode? themeMode,
    AppAccent? accent,
    bool? weekStartsMonday,
    bool? showCompleted,
    bool? showHolidays,
    String? holidayCountry,
    bool? reminders,
    int? reminderMinutes,
    int? reminderLead,
    bool? fullScreenReminders,
    bool? use24Hour,
    String? language,

    /// Go back to the phone's language.
    bool clearLanguage = false,
    bool? showDeviceEvents,
    Set<String>? hiddenCalendars,

    /// Go back to following the device's country.
    bool clearHolidayCountry = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (startScreen != null) {
      _startScreen = startScreen;
      await prefs.setString(_kStartScreen, startScreen.name);
    }
    if (hiddenScreens != null &&
        hiddenScreens.length < AppScreen.values.length) {
      _hiddenScreens = hiddenScreens;
      await prefs.setStringList(_kHiddenScreens, [
        for (final screen in hiddenScreens) screen.name,
      ]);
    }
    if (themeMode != null) {
      _themeMode = themeMode;
      await prefs.setString(_kThemeMode, themeMode.name);
    }
    if (accent != null) {
      _accent = accent;
      await prefs.setString(_kAccent, accent.id);
    }
    if (weekStartsMonday != null) {
      _weekStartsMonday = weekStartsMonday;
      await prefs.setBool(_kWeekStart, weekStartsMonday);
    }
    if (showCompleted != null) {
      _showCompleted = showCompleted;
      await prefs.setBool(_kShowCompleted, showCompleted);
    }
    if (showHolidays != null) {
      _showHolidays = showHolidays;
      await prefs.setBool(_kShowHolidays, showHolidays);
    }
    if (clearHolidayCountry) {
      _holidayCountry = null;
      await prefs.remove(_kHolidayCountry);
    } else if (holidayCountry != null) {
      _holidayCountry = holidayCountry;
      await prefs.setString(_kHolidayCountry, holidayCountry);
    }
    if (use24Hour != null && use24Hour != this.use24Hour) {
      _use24Hour = use24Hour;
      await prefs.setBool(_kClock, use24Hour);
      Dates.use24Hour = use24Hour;
      // A notification already set says its time in the words it was set
      // with; set again, it says it the new way.
      await Reminders.instance.refresh();
    }
    if (reminders != null) {
      _reminders = reminders;
      await prefs.setBool(_kReminders, reminders);
    }
    if (reminderMinutes != null) {
      _reminderMinutes = reminderMinutes;
      await prefs.setInt(_kReminderAt, reminderMinutes);
    }
    if (clearLanguage || (language != null && language != _language)) {
      _language = clearLanguage ? null : language;
      if (_language == null) {
        await prefs.remove(_kLanguage);
      } else {
        await prefs.setString(_kLanguage, _language!);
      }
      // In force at once rather than when the app next draws its words: the
      // alarms are set again just below, and say what they say in it.
      S.use(languageInForce);
      await Reminders.instance.refresh();
      await TodayWidget.republish();
    }
    if (showDeviceEvents != null) {
      _showDeviceEvents = showDeviceEvents;
      await prefs.setBool(_kDeviceEvents, showDeviceEvents);
    }
    if (hiddenCalendars != null) {
      _hiddenCalendars = hiddenCalendars;
      await prefs.setStringList(_kHiddenCalendars, [...hiddenCalendars]);
    }
    if (reminderLead != null) {
      _reminderLead = reminderLead;
      await prefs.setInt(_kReminderLead, reminderLead);
    }
    if (fullScreenReminders != null) {
      _fullScreen = fullScreenReminders;
      await prefs.setBool(_kFullScreen, fullScreenReminders);
    }
    if (reminders != null ||
        reminderMinutes != null ||
        reminderLead != null ||
        fullScreenReminders != null) {
      await _tellReminders();
    }
    notifyListeners();
  }

  /// Hands the settings that matter to the scheduler, which holds them
  /// rather than reaching back here: it is called from a provider that may not
  /// be in scope, and from the database layer, which has no context at all.
  Future<void> _tellReminders() => Reminders.instance.configure(
    enabled: _reminders,
    allDayMinutes: _reminderMinutes,
    lead: _reminderLead,
    fullScreen: _fullScreen,
  );

  static AppScreen _startScreenFromString(String? value) =>
      AppScreen.values.asNameMap()[value] ?? AppScreen.schedule;

  static Set<AppScreen> _screensFrom(List<String>? names) {
    final byName = AppScreen.values.asNameMap();
    final screens = {
      for (final name in names ?? const <String>[])
        if (byName[name] != null) byName[name]!,
    };
    return screens.length < AppScreen.values.length ? screens : const {};
  }

  ThemeMode _themeModeFromString(String? value) {
    return switch (value) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
  }
}

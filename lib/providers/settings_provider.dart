import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode, TimeOfDay;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/holidays.dart';
import '../services/reminders.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';

/// Which of the two task screens the app opens on.
enum StartScreen { schedule, calendar }

/// Holds user-configurable settings: the screen the app opens on, its theme
/// mode and accent, which day the calendar week starts on, whether completed
/// tasks stay visible, and when a task is allowed to interrupt.
class SettingsProvider extends ChangeNotifier {
  static const _kStartScreen = 'start_screen';
  static const _kThemeMode = 'theme_mode';
  static const _kAccent = 'accent_id';
  static const _kWeekStart = 'week_starts_monday';
  static const _kShowCompleted = 'show_completed';
  static const _kHolidayCountry = 'holiday_country';
  static const _kShowHolidays = 'show_holidays';
  static const _kDefaultStyle = 'default_task_style';
  static const _kReminders = 'reminders_enabled';
  static const _kReminderAt = 'reminder_minutes';
  static const _kClock = 'use_24_hour';

  /// The screen the app opens on. Schedule out of the box: it is the one
  /// that answers "what now", which is what opening a to-do list is usually
  /// for.
  StartScreen _startScreen = StartScreen.schedule;

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

  /// The colour a new task starts with, or null to take its list's.
  String? _defaultTaskStyleId;

  /// Whether a dated task puts up a notification when it comes due.
  bool _reminders = true;

  /// Minutes past midnight an all-day task is announced at. A timed task is
  /// announced at its own time; one with no time still has to be said at some
  /// point in the day, and nine in the morning is the least of the evils.
  int _reminderMinutes = 9 * 60;

  /// Whether times are written on a 24-hour clock, or null for as the phone
  /// does until a choice is made here.
  bool? _use24Hour;

  /// Whether times are written on a 24-hour clock: the choice made here, or
  /// the phone's own until there is one.
  bool get use24Hour =>
      _use24Hour ?? PlatformDispatcher.instance.alwaysUse24HourFormat;

  StartScreen get startScreen => _startScreen;
  ThemeMode get themeMode => _themeMode;
  AppAccent get accent => _accent;
  bool get weekStartsMonday => _weekStartsMonday;
  bool get showCompleted => _showCompleted;
  bool get showHolidays => _showHolidays;
  String? get holidayCountry => _holidayCountry;
  String? get defaultTaskStyleId => _defaultTaskStyleId;
  bool get reminders => _reminders;
  int get reminderMinutes => _reminderMinutes;

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
  static Future<StartScreen> storedStartScreen() async {
    final prefs = await SharedPreferences.getInstance();
    return _startScreenFromString(prefs.getString(_kStartScreen));
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _startScreen = _startScreenFromString(prefs.getString(_kStartScreen));
    _themeMode = _themeModeFromString(prefs.getString(_kThemeMode));
    _accent = AppAccent.byId(prefs.getString(_kAccent));
    _weekStartsMonday = prefs.getBool(_kWeekStart) ?? _weekStartsMonday;
    _showCompleted = prefs.getBool(_kShowCompleted) ?? _showCompleted;
    _showHolidays = prefs.getBool(_kShowHolidays) ?? _showHolidays;
    _holidayCountry = prefs.getString(_kHolidayCountry);
    _defaultTaskStyleId = prefs.getString(_kDefaultStyle);
    _reminders = prefs.getBool(_kReminders) ?? _reminders;
    _reminderMinutes = prefs.getInt(_kReminderAt) ?? _reminderMinutes;
    _use24Hour = prefs.getBool(_kClock);
    Dates.use24Hour = use24Hour;
    await _tellReminders();
    // Reminders are on out of the box, so the first run is where Android has
    // to be asked — nothing else in the app would ever ask, and a permission
    // that was never requested looks exactly like a feature that is broken.
    if (_reminders) await Reminders.instance.requestPermission();
    notifyListeners();
  }

  Future<void> update({
    StartScreen? startScreen,
    ThemeMode? themeMode,
    AppAccent? accent,
    bool? weekStartsMonday,
    bool? showCompleted,
    bool? showHolidays,
    String? holidayCountry,
    String? defaultTaskStyleId,
    bool? reminders,
    int? reminderMinutes,
    bool? use24Hour,

    /// Go back to following the device's country.
    bool clearHolidayCountry = false,

    /// Go back to new tasks taking their list's colour.
    bool clearDefaultTaskStyle = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (startScreen != null) {
      _startScreen = startScreen;
      await prefs.setString(_kStartScreen, startScreen.name);
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
    if (clearDefaultTaskStyle) {
      _defaultTaskStyleId = null;
      await prefs.remove(_kDefaultStyle);
    } else if (defaultTaskStyleId != null) {
      _defaultTaskStyleId = defaultTaskStyleId;
      await prefs.setString(_kDefaultStyle, defaultTaskStyleId);
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
    if (reminders != null || reminderMinutes != null) await _tellReminders();
    notifyListeners();
  }

  /// Hands the two settings that matter to the scheduler, which holds them
  /// rather than reaching back here: it is called from a provider that may not
  /// be in scope, and from the database layer, which has no context at all.
  Future<void> _tellReminders() => Reminders.instance.configure(
    enabled: _reminders,
    allDayMinutes: _reminderMinutes,
  );

  static StartScreen _startScreenFromString(String? value) {
    return value == StartScreen.calendar.name
        ? StartScreen.calendar
        : StartScreen.schedule;
  }

  ThemeMode _themeModeFromString(String? value) {
    return switch (value) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
  }
}

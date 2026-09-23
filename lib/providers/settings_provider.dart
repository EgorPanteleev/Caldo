import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/holidays.dart';
import '../theme/app_theme.dart';

/// Holds user-configurable settings: the app's theme mode and accent, which
/// day the calendar week starts on, and whether completed tasks stay visible.
class SettingsProvider extends ChangeNotifier {
  static const _kThemeMode = 'theme_mode';
  static const _kAccent = 'accent_id';
  static const _kWeekStart = 'week_starts_monday';
  static const _kShowCompleted = 'show_completed';
  static const _kHolidayCountry = 'holiday_country';
  static const _kShowHolidays = 'show_holidays';

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

  ThemeMode get themeMode => _themeMode;
  AppAccent get accent => _accent;
  bool get weekStartsMonday => _weekStartsMonday;
  bool get showCompleted => _showCompleted;
  bool get showHolidays => _showHolidays;
  String? get holidayCountry => _holidayCountry;

  /// The country the calendar actually marks holidays for: the chosen one,
  /// the device's when none is chosen, and none at all when they are off.
  String? get effectiveHolidayCountry =>
      _showHolidays ? (_holidayCountry ?? Holidays.detectCountry()) : null;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _themeMode = _themeModeFromString(prefs.getString(_kThemeMode));
    _accent = AppAccent.byId(prefs.getString(_kAccent));
    _weekStartsMonday = prefs.getBool(_kWeekStart) ?? _weekStartsMonday;
    _showCompleted = prefs.getBool(_kShowCompleted) ?? _showCompleted;
    _showHolidays = prefs.getBool(_kShowHolidays) ?? _showHolidays;
    _holidayCountry = prefs.getString(_kHolidayCountry);
    notifyListeners();
  }

  Future<void> update({
    ThemeMode? themeMode,
    AppAccent? accent,
    bool? weekStartsMonday,
    bool? showCompleted,
    bool? showHolidays,
    String? holidayCountry,

    /// Go back to following the device's country.
    bool clearHolidayCountry = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
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
    notifyListeners();
  }

  ThemeMode _themeModeFromString(String? value) {
    return switch (value) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
  }
}

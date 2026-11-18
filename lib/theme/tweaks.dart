import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';

/// An admin's own colours, tried on the device rather than guessed at and
/// built: every colour the palette has, for either theme, the accent, the
/// four signal colours, and how deep the cards' ink is.
///
/// Kept on this device only — not in a backup, not synced — and in force
/// only while [on]: one switch puts the app back as shipped, which is the
/// thing a tried colour is judged against. Signing out switches it off.
/// The page that sets them is Settings › Debug, shown only to an admin
/// (`Account.admin`); English only, like the keyboard numbers.
///
/// The palette and the accent go through the theme, so a change rebuilds
/// what reads it. The signals and the ink are read straight from here
/// ([AppColors], [cardInk]) by widgets that read the theme too, and are
/// redrawn with it.
class Tweaks extends ChangeNotifier {
  static final instance = Tweaks();

  static const _key = 'debug_tweaks';

  bool _on = false;
  final _colours = <String, Color>{};
  final _numbers = <String, double>{};

  /// Whether the overrides are in force.
  bool get on => _on;

  /// How many things are set away from stock, on or off.
  int get count => _colours.length + _numbers.length;

  /// The colour set for [key], while in force.
  Color? colour(String key) => _on ? _colours[key] : null;

  /// The colour set for [key] whether or not in force, for the page.
  Color? stored(String key) => _colours[key];

  /// The number set for [key], while in force, else [stock].
  double number(String key, double stock) =>
      _on ? (_numbers[key] ?? stock) : stock;

  double? storedNumber(String key) => _numbers[key];

  /// How deep a card's ink is, as a share of what it was built at.
  static double get cardInk => instance.number('cardInk', 1);

  /// How deep a done card's ink is, likewise.
  static double get doneInk => instance.number('doneInk', 1);

  /// How deep a day's chip over the opened month is, likewise.
  static double get chipInk => instance.number('chipInk', 1);

  /// How far ahead of the frame's vsync the keyboard's slide is read for
  /// the add field riding it, opening and closing, in milliseconds
  /// (`KeyboardGap`). Nothing as shipped: the keys and Flutter's frame for
  /// one vsync were judged to reach the screen together. Here to be
  /// moved on a phone while looking at it, if they do not.
  static double get keysLeadOpen => instance.number('keysLeadOpen', 0);
  static double get keysLeadClose => instance.number('keysLeadClose', 0);

  /// The palette fields, as the page names them, in the order it lists them.
  static const palette = <(String, String)>[
    ('bg', 'Ground'),
    ('calendar', 'Calendar ground'),
    ('sidebar', 'Sidebar'),
    ('panel', 'Panel'),
    ('panelHi', 'Panel, raised'),
    ('field', 'Field'),
    ('border', 'Border'),
    ('text', 'Text'),
    ('muted', 'Muted text'),
    ('faint', 'Faint text'),
  ];

  /// [p] with what is set for [side] (`dark` or `light`) laid over it.
  AppPalette applyTo(AppPalette p, String side) {
    if (!_on) return p;
    Color? c(String field) => _colours['$side.$field'];
    return p.copyWith(
      bg: c('bg'),
      sidebar: c('sidebar'),
      panel: c('panel'),
      panelHi: c('panelHi'),
      field: c('field'),
      border: c('border'),
      text: c('text'),
      muted: c('muted'),
      faint: c('faint'),
      calendar: c('calendar'),
    );
  }

  /// [a] with the accent's own colours set here laid over it. Set once, the
  /// accent holds whichever preset is chosen in Appearance.
  AppAccent applyToAccent(AppAccent a) {
    if (!_on) return a;
    return AppAccent(
      id: a.id,
      label: a.label,
      color: _colours['accent.color'] ?? a.color,
      soft: _colours['accent.soft'] ?? a.soft,
      gradientEnd: _colours['accent.gradientEnd'] ?? a.gradientEnd,
    );
  }

  static Color stockOf(AppPalette p, String field) => switch (field) {
    'bg' => p.bg,
    'sidebar' => p.sidebar,
    'panel' => p.panel,
    'panelHi' => p.panelHi,
    'field' => p.field,
    'border' => p.border,
    'text' => p.text,
    'muted' => p.muted,
    'faint' => p.faint,
    'calendar' => p.calendar,
    _ => throw ArgumentError(field),
  };

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final json = jsonDecode(raw) as Map<String, Object?>;
      _read(json);
    } catch (_) {
      // Unreadable: start from stock rather than not start.
    }
  }

  void _read(Map<String, Object?> json) {
    _on = json['on'] == true;
    _colours
      ..clear()
      ..addAll({
        for (final MapEntry(:key, :value)
            in (json['colours'] as Map? ?? const {}).entries)
          key as String: ?parse(value as String),
      });
    _numbers
      ..clear()
      ..addAll({
        for (final MapEntry(:key, :value)
            in (json['numbers'] as Map? ?? const {}).entries)
          key as String: (value as num).toDouble(),
      });
  }

  Map<String, Object?> get _json => {
    'on': _on,
    'colours': {for (final e in _colours.entries) e.key: hex(e.value)},
    'numbers': _numbers,
  };

  /// What is set, as one piece of text to hand on — to be built in, or put
  /// on another device with [paste].
  String get asText => const JsonEncoder.withIndent('  ').convert({
    'colours': {for (final e in _colours.entries) e.key: hex(e.value)},
    'numbers': _numbers,
  });

  /// Takes up what [asText] wrote. False if it could not be read.
  Future<bool> paste(String text) async {
    try {
      final json = jsonDecode(text) as Map<String, Object?>;
      _read({...json, 'on': true});
    } catch (_) {
      return false;
    }
    await _save();
    return true;
  }

  Future<void> _save() async {
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(_json));
  }

  Future<void> setOn(bool on) async {
    if (on == _on) return;
    _on = on;
    await _save();
  }

  /// Sets [key] to [colour], or back to stock with null. With [keep] false
  /// it is only shown — while a colour is being picked — and [setColour]
  /// with it, or [revert], follows.
  Future<void> setColour(String key, Color? colour, {bool keep = true}) async {
    colour == null ? _colours.remove(key) : _colours[key] = colour;
    if (keep) {
      await _save();
    } else {
      notifyListeners();
    }
  }

  Future<void> setNumber(String key, double? value, {bool keep = true}) async {
    value == null ? _numbers.remove(key) : _numbers[key] = value;
    if (keep) {
      await _save();
    } else {
      notifyListeners();
    }
  }

  /// Everything back to stock, and off.
  Future<void> reset() async {
    _colours.clear();
    _numbers.clear();
    _on = false;
    await _save();
  }

  /// `#RRGGBB`, or `#AARRGGBB` when not opaque.
  static String hex(Color c) {
    final argb = c.toARGB32();
    final digits = argb.toRadixString(16).padLeft(8, '0').toUpperCase();
    return '#${(argb >>> 24) == 0xFF ? digits.substring(2) : digits}';
  }

  /// Reads `#RGB`, `#RRGGBB` or `#AARRGGBB`, with or without the `#`.
  static Color? parse(String text) {
    var t = text.trim().replaceFirst('#', '');
    if (t.length == 3) t = [for (final c in t.split('')) '$c$c'].join();
    if (t.length == 6) t = 'FF$t';
    if (t.length != 8) return null;
    final v = int.tryParse(t, radix: 16);
    return v == null ? null : Color(v);
  }

  @visibleForTesting
  void clear() {
    _on = false;
    _colours.clear();
    _numbers.clear();
  }
}

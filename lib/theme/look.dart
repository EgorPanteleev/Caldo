import 'dart:convert';

import 'package:flutter/foundation.dart';

/// How the app's surfaces are drawn, as Settings › Appearance › Surfaces
/// sets them: the frosted glass over the head and under the tab bar, the
/// grain, and the cards' glass. Out of the box every number is what was
/// built and judged on the phone, so a user who never opens the page sees
/// nothing change.
///
/// Read statically ([current]) by the painters and the few widgets that
/// had these as constants, as [AppColors]' signals read `Tweaks`: the
/// whole app's theme is built again when it changes (`main.dart` selects
/// it), so whatever reads the theme is redrawn with it. Kept by
/// `SettingsProvider`, and carried by a backup.
@immutable
class Look {
  /// The glass's blur, as a sigma: the head's, the tab bar's and the
  /// plus's. Other blurs (the chat's field) keep their share of it. None
  /// draws no blur at all, which also costs nothing.
  final double blur;

  /// How much of the ground is laid over the blur, as a share of what was
  /// built (65% under the head, 60% in the bar).
  final double glassFill;

  /// How many of the screen's pixels one grain takes across. One is as
  /// built: grain at the finest the screen has.
  final double grainSize;

  /// The cards' frost, as a share of what was built.
  final double cardGrain;

  /// How deep a card's colour is, and a done card's, as shares of what was
  /// built.
  final double cardInk;
  final double doneInk;

  /// How strong a card's coloured edge is, as a share of what was built.
  final double cardRim;

  /// The radius a card's corners are cut to.
  final double corners;

  const Look({
    this.blur = 17,
    this.glassFill = 1,
    this.grainSize = 1,
    this.cardGrain = 1,
    this.cardInk = 1,
    this.doneInk = 1,
    this.cardRim = 1,
    this.corners = 14,
  });

  static const defaults = Look();

  /// The look in force. Set by `SettingsProvider`, never elsewhere.
  static Look current = defaults;

  /// What [blur] makes of a blur built at [sigma] beside the glass's 17.
  double blurOf(double sigma) => sigma * blur / defaults.blur;

  /// What [glassFill] makes of a fill built at [alpha].
  double fillOf(double alpha) => (alpha * glassFill).clamp(0, 1);

  bool get isDefault => this == defaults;

  Map<String, double> get _fields => {
    'blur': blur,
    'glassFill': glassFill,
    'grainSize': grainSize,
    'cardGrain': cardGrain,
    'cardInk': cardInk,
    'doneInk': doneInk,
    'cardRim': cardRim,
    'corners': corners,
  };

  /// Only what differs from [defaults], so a later default still reaches
  /// a user who never moved it.
  String toStorage() => jsonEncode({
    for (final MapEntry(:key, :value) in _fields.entries)
      if (value != defaults._fields[key]) key: value,
  });

  /// Reads what [toStorage] wrote; anything unreadable is as built.
  factory Look.fromStorage(Object? value) {
    if (value is! String) return defaults;
    try {
      final json = jsonDecode(value) as Map<String, Object?>;
      double read(String key, double stock, double least, double most) =>
          switch (json[key]) {
            final num n => n.toDouble().clamp(least, most),
            _ => stock,
          };
      const d = defaults;
      return Look(
        blur: read('blur', d.blur, 0, 40),
        glassFill: read('glassFill', d.glassFill, 0, 1.5),
        grainSize: read('grainSize', d.grainSize, 1, 8),
        cardGrain: read('cardGrain', d.cardGrain, 0, 4),
        cardInk: read('cardInk', d.cardInk, 0, 2.5),
        doneInk: read('doneInk', d.doneInk, 0, 4),
        cardRim: read('cardRim', d.cardRim, 0, 1.75),
        corners: read('corners', d.corners, 0, 28),
      );
    } catch (_) {
      return defaults;
    }
  }

  Look copyWith({
    double? blur,
    double? glassFill,
    double? grainSize,
    double? cardGrain,
    double? cardInk,
    double? doneInk,
    double? cardRim,
    double? corners,
  }) => Look(
    blur: blur ?? this.blur,
    glassFill: glassFill ?? this.glassFill,
    grainSize: grainSize ?? this.grainSize,
    cardGrain: cardGrain ?? this.cardGrain,
    cardInk: cardInk ?? this.cardInk,
    doneInk: doneInk ?? this.doneInk,
    cardRim: cardRim ?? this.cardRim,
    corners: corners ?? this.corners,
  );

  @override
  bool operator ==(Object other) =>
      other is Look && mapEquals(other._fields, _fields);

  @override
  int get hashCode => Object.hashAll(_fields.values);
}

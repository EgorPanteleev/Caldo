import 'package:flutter/material.dart';

/// Obsidian-inspired palette: refined charcoal surfaces, thin borders,
/// muted text, and a violet→indigo accent.
///
/// The greys are as close to neutral as they get. An earlier set carried a
/// few points of extra blue in every surface, which over a whole screen read
/// as a violet wash rather than as grey.
class AppColors {
  // Accent (violet → indigo)
  static const accent = Color(0xFF7B61E8);
  static const accent2 = Color(0xFF5B4BC4);
  static const accentSoft = Color(0xFF9C87F0);

  // Dark surfaces. The ground is true black — the calendar's already was, and
  // the app around it reading a shade lighter put a seam down the screen on
  // every OLED panel. Everything above it is a raised grey instead.
  static const darkBg = Color(0xFF000000); // app background / content
  static const darkSidebar = Color(0xFF0C0C0D); // the menu, lifted off black
  static const darkPanel = Color(0xFF161618); // cards / fields
  static const darkPanelHi = Color(0xFF212124); // hovered / elevated
  static const darkField = Color(0xFF2C2C31); // the quick-add row, on black
  static const darkBorder = Color(0xFF2A2A2E); // hairline borders

  // Dark text
  static const darkText = Color(0xFFE9E9EB);
  static const darkMuted = Color(0xFF9B9BA1);
  static const darkFaint = Color(0xFF6A6A70);

  // Light surfaces
  static const lightBg = Color(0xFFF7F7F8);
  static const lightSidebar = Color(0xFFEFEFF1);
  static const lightPanel = Color(0xFFFFFFFF);
  static const lightPanelHi = Color(0xFFF1F1F3);
  static const lightField = Color(0xFFE6E6EB);
  static const lightBorder = Color(0xFFE4E4E8);

  static const lightText = Color(0xFF18181B);

  /// Shared semantic colours that do not change with the accent.
  static const danger = Color(0xFFE5686B);
  static const overdue = Color(0xFFE05252);

  /// Saturdays, Sundays and public holidays in the calendar.
  static const weekend = Color(0xFFE06C75);
  static const holiday = Color(0xFF35A06A);
}

/// Extra semantic colors resolved per-brightness, exposed via [AppTheme.of].
/// A [ThemeExtension] so the colours lerp smoothly during theme changes.
class AppPalette extends ThemeExtension<AppPalette> {
  final Color bg;
  final Color sidebar;
  final Color panel;
  final Color panelHi;

  /// The quick-add field and the button beside it. A filled grey rather than
  /// an outline on the ground: against true black an outlined pill read as a
  /// hole in the screen, and the pair are the one thing down there to press.
  final Color field;

  final Color border;
  final Color text;
  final Color muted;
  final Color faint;

  /// The calendar's own ground, set apart from the rest of the app.
  final Color calendar;

  const AppPalette({
    required this.bg,
    required this.sidebar,
    required this.panel,
    required this.panelHi,
    required this.field,
    required this.border,
    required this.text,
    required this.muted,
    required this.faint,
    required this.calendar,
  });

  static const dark = AppPalette(
    bg: AppColors.darkBg,
    sidebar: AppColors.darkSidebar,
    panel: AppColors.darkPanel,
    panelHi: AppColors.darkPanelHi,
    field: AppColors.darkField,
    border: AppColors.darkBorder,
    text: AppColors.darkText,
    muted: AppColors.darkMuted,
    faint: AppColors.darkFaint,
    calendar: Color(0xFF000000),
  );

  static const light = AppPalette(
    bg: AppColors.lightBg,
    sidebar: AppColors.lightSidebar,
    panel: AppColors.lightPanel,
    panelHi: AppColors.lightPanelHi,
    field: AppColors.lightField,
    border: AppColors.lightBorder,
    text: AppColors.lightText,
    muted: Color(0xFF5C5D6B),
    faint: Color(0xFF9394A1),
    calendar: Color(0xFFFFFFFF),
  );

  @override
  AppPalette copyWith({
    Color? bg,
    Color? sidebar,
    Color? panel,
    Color? panelHi,
    Color? field,
    Color? border,
    Color? text,
    Color? muted,
    Color? faint,
    Color? calendar,
  }) => AppPalette(
    bg: bg ?? this.bg,
    sidebar: sidebar ?? this.sidebar,
    panel: panel ?? this.panel,
    panelHi: panelHi ?? this.panelHi,
    field: field ?? this.field,
    border: border ?? this.border,
    text: text ?? this.text,
    muted: muted ?? this.muted,
    faint: faint ?? this.faint,
    calendar: calendar ?? this.calendar,
  );

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      bg: Color.lerp(bg, other.bg, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      panelHi: Color.lerp(panelHi, other.panelHi, t)!,
      field: Color.lerp(field, other.field, t)!,
      border: Color.lerp(border, other.border, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      faint: Color.lerp(faint, other.faint, t)!,
      calendar: Color.lerp(calendar, other.calendar, t)!,
    );
  }
}

/// A selectable accent identity: a main colour, a lighter "soft" variant,
/// and the two-colour gradient used on prominent surfaces.
class AppAccent {
  final String id;
  final String label;
  final Color color;
  final Color soft;
  final Color gradientEnd;

  const AppAccent({
    required this.id,
    required this.label,
    required this.color,
    required this.soft,
    required this.gradientEnd,
  });

  LinearGradient get gradient => LinearGradient(
    colors: [color, gradientEnd],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Available accent choices shown in Settings.
  static const presets = <AppAccent>[
    AppAccent(
      id: 'violet',
      label: 'Violet',
      color: Color(0xFF7B61E8),
      soft: Color(0xFF9C87F0),
      gradientEnd: Color(0xFF5B4BC4),
    ),
    AppAccent(
      id: 'blue',
      label: 'Blue',
      color: Color(0xFF3B7DD8),
      soft: Color(0xFF6BA1E6),
      gradientEnd: Color(0xFF2A5FAE),
    ),
    AppAccent(
      id: 'teal',
      label: 'Teal',
      color: Color(0xFF16A394),
      soft: Color(0xFF43C0B2),
      gradientEnd: Color(0xFF0E7F87),
    ),
    AppAccent(
      id: 'green',
      label: 'Green',
      color: Color(0xFF35A06A),
      soft: Color(0xFF5CBE8B),
      gradientEnd: Color(0xFF267E52),
    ),
    AppAccent(
      id: 'amber',
      label: 'Amber',
      color: Color(0xFFD99A2B),
      soft: Color(0xFFECBA5E),
      gradientEnd: Color(0xFFDB7A33),
    ),
    AppAccent(
      id: 'pink',
      label: 'Pink',
      color: Color(0xFFD9528A),
      soft: Color(0xFFE87FAA),
      gradientEnd: Color(0xFFB43A6D),
    ),
  ];

  static AppAccent byId(String? id) =>
      presets.firstWhere((a) => a.id == id, orElse: () => presets.first);
}

/// ThemeExtension carrying the active accent so widgets can read it via
/// `AppTheme.accentOf(context)` and re-theme when it changes.
class AccentColors extends ThemeExtension<AccentColors> {
  final Color color;
  final Color soft;
  final Gradient gradient;

  const AccentColors({
    required this.color,
    required this.soft,
    required this.gradient,
  });

  factory AccentColors.from(AppAccent a) =>
      AccentColors(color: a.color, soft: a.soft, gradient: a.gradient);

  @override
  AccentColors copyWith({Color? color, Color? soft, Gradient? gradient}) =>
      AccentColors(
        color: color ?? this.color,
        soft: soft ?? this.soft,
        gradient: gradient ?? this.gradient,
      );

  @override
  AccentColors lerp(ThemeExtension<AccentColors>? other, double t) {
    if (other is! AccentColors) return this;
    return AccentColors(
      color: Color.lerp(color, other.color, t)!,
      soft: Color.lerp(soft, other.soft, t)!,
      gradient: Gradient.lerp(gradient, other.gradient, t) ?? gradient,
    );
  }
}

class AppTheme {
  /// Semantic palette for the current brightness. Use in widgets:
  /// `final p = AppTheme.of(context);`
  static AppPalette of(BuildContext context) {
    return Theme.of(context).extension<AppPalette>() ??
        (Theme.of(context).brightness == Brightness.dark
            ? AppPalette.dark
            : AppPalette.light);
  }

  /// The active accent colours (from the [AccentColors] theme extension).
  static AccentColors accentOf(BuildContext context) =>
      Theme.of(context).extension<AccentColors>() ??
      AccentColors.from(AppAccent.presets.first);

  static ThemeData dark(AppAccent accent) =>
      _build(Brightness.dark, AppPalette.dark, accent);
  static ThemeData light(AppAccent accent) =>
      _build(Brightness.light, AppPalette.light, accent);

  static ThemeData _build(
    Brightness brightness,
    AppPalette p,
    AppAccent accent,
  ) {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent.color,
          brightness: brightness,
        ).copyWith(
          primary: accent.color,
          surface: p.bg,
          onSurface: p.text,
          outline: p.border,
        );

    // The platform's own font, not one of our own.
    //
    // It was Inter, downloaded by `google_fonts` on first launch. Two things
    // were wrong with that: the calendar sat beside other calendars on the
    // same phone and did not look like them — every one of those uses the
    // system font, which is what a date is expected to be set in — and an
    // emulator with no network silently falls back to Roboto, so nothing
    // checked by eye here was ever showing the font the app actually shipped.
    final baseText = ThemeData(
      brightness: brightness,
    ).textTheme.apply(bodyColor: p.text, displayColor: p.text);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      extensions: [AccentColors.from(accent), p],
      scaffoldBackgroundColor: p.bg,
      canvasColor: p.bg,
      textTheme: baseText,
      dividerColor: p.border,
      dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: p.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: p.text,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
        iconTheme: IconThemeData(color: p.muted),
      ),
      cardTheme: CardThemeData(
        color: p.panel,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: p.border),
        ),
        margin: EdgeInsets.zero,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: p.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.panel,
        hintStyle: TextStyle(color: p.faint),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.border),
        ),
        // Focus is said in the neutral, a step up from the resting outline.
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.muted, width: 1.5),
        ),
        floatingLabelStyle: TextStyle(color: p.muted),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: p.text,
        selectionColor: p.text.withValues(alpha: 0.25),
        selectionHandleColor: p.text,
      ),
      // The controls are neutral. The accent was on every switch, every
      // selected segment, every focused field and both buttons of every
      // dialog, and on a dark screen that was most of the colour there was —
      // "too many accent colours". It is kept for the few things that are an
      // action to take (Undo, Update) or a thing being touched (a clock
      // wheel under the finger), where it means something by being rare.
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? p.bg : p.faint,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? p.text : p.panelHi,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.transparent
              : p.border,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? p.field
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.selected) ? p.text : p.muted,
          ),
          side: WidgetStatePropertyAll(BorderSide(color: p.border)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: p.text),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.text,
          foregroundColor: p.bg,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.text,
          side: BorderSide(color: p.border),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.panelHi,
        contentTextStyle: TextStyle(color: p.text),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Obsidian-inspired palette: refined charcoal surfaces, thin borders,
/// muted text, and a violet→indigo accent.
class AppColors {
  // Accent (violet → indigo)
  static const accent = Color(0xFF8B5CF6);
  static const accent2 = Color(0xFF6366F1);
  static const accentSoft = Color(0xFFA78BFA);

  // Dark surfaces (Obsidian-like)
  static const darkBg = Color(0xFF16161A); // app background / content
  static const darkSidebar = Color(0xFF121216); // slightly darker rail
  static const darkPanel = Color(0xFF1E1E24); // cards / fields
  static const darkPanelHi = Color(0xFF26262E); // hovered / elevated
  static const darkBorder = Color(0xFF2E2E38); // hairline borders

  // Dark text
  static const darkText = Color(0xFFDCDDE1);
  static const darkMuted = Color(0xFF9A9BA6);
  static const darkFaint = Color(0xFF6B6C78);

  // Light surfaces
  static const lightBg = Color(0xFFF6F6FA);
  static const lightSidebar = Color(0xFFEDEDF3);
  static const lightPanel = Color(0xFFFFFFFF);
  static const lightPanelHi = Color(0xFFF0F0F6);
  static const lightBorder = Color(0xFFE2E2EC);

  static const lightText = Color(0xFF1F1F29);

  /// Shared semantic colours that do not change with the accent.
  static const danger = Color(0xFFF87171);
  static const overdue = Color(0xFFEF4444);

  /// Saturdays, Sundays and public holidays in the calendar.
  static const weekend = Color(0xFFE06C75);
  static const holiday = Color(0xFF22C55E);
}

/// Extra semantic colors resolved per-brightness, exposed via [AppTheme.of].
/// A [ThemeExtension] so the colours lerp smoothly during theme changes.
class AppPalette extends ThemeExtension<AppPalette> {
  final Color bg;
  final Color sidebar;
  final Color panel;
  final Color panelHi;
  final Color border;
  final Color text;
  final Color muted;
  final Color faint;

  const AppPalette({
    required this.bg,
    required this.sidebar,
    required this.panel,
    required this.panelHi,
    required this.border,
    required this.text,
    required this.muted,
    required this.faint,
  });

  static const dark = AppPalette(
    bg: AppColors.darkBg,
    sidebar: AppColors.darkSidebar,
    panel: AppColors.darkPanel,
    panelHi: AppColors.darkPanelHi,
    border: AppColors.darkBorder,
    text: AppColors.darkText,
    muted: AppColors.darkMuted,
    faint: AppColors.darkFaint,
  );

  static const light = AppPalette(
    bg: AppColors.lightBg,
    sidebar: AppColors.lightSidebar,
    panel: AppColors.lightPanel,
    panelHi: AppColors.lightPanelHi,
    border: AppColors.lightBorder,
    text: AppColors.lightText,
    muted: Color(0xFF5C5D6B),
    faint: Color(0xFF9394A1),
  );

  @override
  AppPalette copyWith({
    Color? bg,
    Color? sidebar,
    Color? panel,
    Color? panelHi,
    Color? border,
    Color? text,
    Color? muted,
    Color? faint,
  }) =>
      AppPalette(
        bg: bg ?? this.bg,
        sidebar: sidebar ?? this.sidebar,
        panel: panel ?? this.panel,
        panelHi: panelHi ?? this.panelHi,
        border: border ?? this.border,
        text: text ?? this.text,
        muted: muted ?? this.muted,
        faint: faint ?? this.faint,
      );

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      bg: Color.lerp(bg, other.bg, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      panelHi: Color.lerp(panelHi, other.panelHi, t)!,
      border: Color.lerp(border, other.border, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      faint: Color.lerp(faint, other.faint, t)!,
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
      color: Color(0xFF8B5CF6),
      soft: Color(0xFFA78BFA),
      gradientEnd: Color(0xFF6366F1),
    ),
    AppAccent(
      id: 'blue',
      label: 'Blue',
      color: Color(0xFF3B82F6),
      soft: Color(0xFF60A5FA),
      gradientEnd: Color(0xFF2563EB),
    ),
    AppAccent(
      id: 'teal',
      label: 'Teal',
      color: Color(0xFF14B8A6),
      soft: Color(0xFF2DD4BF),
      gradientEnd: Color(0xFF0EA5E9),
    ),
    AppAccent(
      id: 'green',
      label: 'Green',
      color: Color(0xFF22C55E),
      soft: Color(0xFF4ADE80),
      gradientEnd: Color(0xFF16A34A),
    ),
    AppAccent(
      id: 'amber',
      label: 'Amber',
      color: Color(0xFFF59E0B),
      soft: Color(0xFFFBBF24),
      gradientEnd: Color(0xFFF97316),
    ),
    AppAccent(
      id: 'pink',
      label: 'Pink',
      color: Color(0xFFEC4899),
      soft: Color(0xFFF472B6),
      gradientEnd: Color(0xFFDB2777),
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

  const AccentColors(
      {required this.color, required this.soft, required this.gradient});

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
      Brightness brightness, AppPalette p, AppAccent accent) {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent.color,
      brightness: brightness,
    ).copyWith(
      primary: accent.color,
      surface: p.bg,
      onSurface: p.text,
      outline: p.border,
    );

    final baseText = GoogleFonts.interTextTheme(
      ThemeData(brightness: brightness).textTheme,
    ).apply(bodyColor: p.text, displayColor: p.text);

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
        titleTextStyle: GoogleFonts.inter(
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
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: accent.color, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent.color,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: GoogleFonts.inter(fontWeight: FontWeight.w600),
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
          textStyle: GoogleFonts.inter(fontWeight: FontWeight.w600),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.panelHi,
        contentTextStyle: TextStyle(color: p.text),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }
}

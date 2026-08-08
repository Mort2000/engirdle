import 'package:flutter/material.dart';

import '../features/preferences/domain/reading_preferences.dart';

/// Color palette for one theme preset (design tokens, constraints §6.1).
///
/// Three presets only: 纸白 / 暖黄 / 暗色 (paper / warm / dark) — readable
/// contrast by construction, no arbitrary pickers (MOB-READ-004).
class AppPalette {
  const AppPalette._({
    required this.isDark,
    required this.paper,
    required this.paper2,
    required this.surface,
    required this.ink,
    required this.inkVariant,
    required this.outline,
    required this.playHighlight,
    required this.playHighlightBorder,
    required this.selectHighlight,
    required this.tapHighlight,
  });

  final bool isDark;
  final Color paper; // reader background
  final Color paper2; // secondary blocks (zh gloss background, empty art)
  final Color surface; // cards, sheets, bars
  final Color ink; // primary text
  final Color inkVariant; // secondary text
  final Color outline;
  final Color playHighlight; // playing sentence background
  final Color playHighlightBorder; // playing sentence left bar
  final Color selectHighlight; // selected word background
  final Color tapHighlight; // tapped sentence background

  static const primary = Color(0xFF35644D); // 森林绿
  static const primaryContainer = Color(0xFFD6E8DA);
  static const tertiary = Color(0xFF9A5B33); // 陶土
  static const tertiaryContainer = Color(0xFFF5E3CF);
  static const error = Color(0xFFB3261E);
  static const errorContainer = Color(0xFFF9DEDC);
  static const ok = Color(0xFF2E6B3F);
  static const okContainer = Color(0xFFDDEFDC);
  static const amber = Color(0xFF7A5200);
  static const amberContainer = Color(0xFFF7E7BD);

  static const paperPreset = AppPalette._(
    isDark: false,
    paper: Color(0xFFFDFAF3),
    paper2: Color(0xFFF4EFE2),
    surface: Color(0xFFFFFFFF),
    ink: Color(0xFF23281F),
    inkVariant: Color(0xFF5B6156),
    outline: Color(0xFFDDD5C3),
    playHighlight: Color(0xFFF9E9BF),
    playHighlightBorder: Color(0xFFCF9F3C),
    selectHighlight: Color(0xFFBFE0CC),
    tapHighlight: Color(0xFFECE5D2),
  );

  static final warm = AppPalette._(
    isDark: false,
    paper: const Color(0xFFF7ECD4),
    paper2: const Color(0xFFF0E3C6),
    surface: const Color(0xFFFBF4E3),
    ink: const Color(0xFF29251C),
    inkVariant: const Color(0xFF615A49),
    outline: const Color(0xFFDCCFAE),
    playHighlight: const Color(0xFFF5DEA6),
    playHighlightBorder: const Color(0xFFC1913A),
    selectHighlight: const Color(0xFFBBDDC4),
    tapHighlight: const Color(0xFFE9DDBB),
  );

  static const dark = AppPalette._(
    isDark: true,
    paper: Color(0xFF171B17),
    paper2: Color(0xFF21261F),
    surface: Color(0xFF21261F),
    ink: Color(0xFFE4E2D7),
    inkVariant: Color(0xFFA3A799),
    outline: Color(0xFF3A4036),
    playHighlight: Color(0xFF3A3320),
    playHighlightBorder: Color(0xFFA98B3F),
    selectHighlight: Color(0xFF2E4A3A),
    tapHighlight: Color(0xFF2A2F26),
  );

  static AppPalette of(ReaderThemePreset preset) => switch (preset) {
    ReaderThemePreset.paper => paperPreset,
    ReaderThemePreset.warm => warm,
    ReaderThemePreset.dark => dark,
  };
}

/// Reads the current palette; rebuilt when preferences change.
class PaletteScope extends InheritedWidget {
  const PaletteScope({required this.palette, required super.child, super.key});

  final AppPalette palette;

  static AppPalette of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PaletteScope>()!.palette;

  @override
  bool updateShouldNotify(PaletteScope oldWidget) =>
      palette != oldWidget.palette;
}

ThemeData buildTheme(AppPalette palette) {
  final scheme = ColorScheme(
    brightness: palette.isDark ? Brightness.dark : Brightness.light,
    primary: AppPalette.primary,
    onPrimary: Colors.white,
    primaryContainer: AppPalette.primaryContainer,
    onPrimaryContainer: const Color(0xFF234534),
    secondary: AppPalette.tertiary,
    onSecondary: Colors.white,
    secondaryContainer: AppPalette.tertiaryContainer,
    onSecondaryContainer: const Color(0xFF5C3A20),
    tertiary: AppPalette.tertiary,
    onTertiary: Colors.white,
    tertiaryContainer: AppPalette.tertiaryContainer,
    onTertiaryContainer: const Color(0xFF5C3A20),
    error: AppPalette.error,
    onError: Colors.white,
    errorContainer: AppPalette.errorContainer,
    onErrorContainer: const Color(0xFF6D1510),
    surface: palette.paper,
    onSurface: palette.ink,
    surfaceContainerHighest: palette.paper2,
    onSurfaceVariant: palette.inkVariant,
    outline: palette.outline,
    outlineVariant: palette.outline,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.paper,
    dividerColor: palette.outline,
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF2C2F28),
      contentTextStyle: const TextStyle(color: Color(0xFFEEF0E6)),
      actionTextColor: AppPalette.primaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    // Constraints §7.4: selected word = 浅绿底. The design also specifies an
    // outline around the selection, which the system selection overlay
    // cannot express — accepted deviation (background only).
    textSelectionTheme: TextSelectionThemeData(
      selectionColor: palette.selectHighlight,
      selectionHandleColor: AppPalette.primary,
    ),
  );
}

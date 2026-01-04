import 'package:flutter/material.dart';

/// App theme configuration supporting both light and dark modes.
class AppTheme {
  // Teal primary with complementary deep orange accents
  static const Color seed = Color(0xFF0E7C7B); // teal
  static const Color accent = Color(0xFFEF6C00); // deep orange

  /// Dark theme (default)
  static ThemeData darkTheme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    ).copyWith(
      secondary: accent,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFF111315),
      canvasColor: const Color(0xFF111315),
      cardColor: const Color(0xFF1A1C1E),
      dialogTheme: const DialogThemeData(
        backgroundColor: Color(0xFF1A1C1E),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xFF1A1C1E),
        modalBackgroundColor: Color(0xFF1A1C1E),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1A1C1E),
        foregroundColor: Colors.white,
        centerTitle: true,
        scrolledUnderElevation: 0,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Color(0xCC000000),
        contentTextStyle: TextStyle(color: Colors.white),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        insetPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        showCloseIcon: true,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF1C1E20),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
  }

  /// Light theme
  static ThemeData lightTheme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    ).copyWith(
      secondary: accent,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFF5F5F5),
      canvasColor: const Color(0xFFF5F5F5),
      cardColor: Colors.white,
      dialogTheme: const DialogThemeData(
        backgroundColor: Colors.white,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        modalBackgroundColor: Colors.white,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: scheme.onSurface,
        centerTitle: true,
        scrolledUnderElevation: 0,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        showCloseIcon: true,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFEEEEEE),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
  }

  /// Legacy method for backwards compatibility
  static ThemeData theme() => darkTheme();
}

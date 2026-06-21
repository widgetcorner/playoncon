import 'package:flutter/material.dart';

/// Color palette pulled from the Play On Con badge logo.
class PocColors {
  static const forest = Color(0xFF2D5E3E);
  static const forestDark = Color(0xFF1F4530);
  static const saddle = Color(0xFF8B6F47);
  static const saddleDark = Color(0xFF6B5232);
  static const cream = Color(0xFFF0E9D8);
  static const creamSoft = Color(0xFFE7DEC7);
  static const ink = Color(0xFF3A2818);
  static const inkSoft = Color(0xFF5C4632);
}

class PocTheme {
  static ThemeData light() {
    const scheme = ColorScheme(
      brightness: Brightness.light,
      primary: PocColors.forest,
      onPrimary: PocColors.cream,
      primaryContainer: Color(0xFFC9DDCC),
      onPrimaryContainer: PocColors.forestDark,
      secondary: PocColors.saddle,
      onSecondary: PocColors.cream,
      secondaryContainer: Color(0xFFE2D2B8),
      onSecondaryContainer: PocColors.saddleDark,
      tertiary: Color(0xFFB46A3F),
      onTertiary: PocColors.cream,
      tertiaryContainer: Color(0xFFF2D7C2),
      onTertiaryContainer: Color(0xFF5A2F12),
      error: Color(0xFFB3261E),
      onError: Colors.white,
      errorContainer: Color(0xFFF9DEDC),
      onErrorContainer: Color(0xFF410E0B),
      surface: PocColors.cream,
      onSurface: PocColors.ink,
      surfaceContainerHighest: PocColors.creamSoft,
      surfaceContainerHigh: Color(0xFFEBE2CC),
      surfaceContainer: PocColors.creamSoft,
      surfaceContainerLow: Color(0xFFF4EEDF),
      surfaceContainerLowest: Colors.white,
      outline: Color(0xFF8E7E63),
      outlineVariant: Color(0xFFC8B996),
      inverseSurface: PocColors.ink,
      onInverseSurface: PocColors.cream,
      inversePrimary: Color(0xFF8FC79A),
      shadow: Colors.black,
      scrim: Colors.black,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: const AppBarTheme(
        backgroundColor: PocColors.forest,
        foregroundColor: PocColors.cream,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 2,
        titleTextStyle: TextStyle(
          color: PocColors.cream,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
      tabBarTheme: TabBarThemeData(
        // TabBars live in the green AppBar; default M3 colors render the
        // selected label in colorScheme.primary (forest), which vanishes
        // against the matching background. Use the AppBar's cream foreground.
        labelColor: PocColors.cream,
        unselectedLabelColor: PocColors.cream.withValues(alpha: 0.6),
        indicatorColor: PocColors.cream,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: PocColors.cream,
        indicatorColor: PocColors.forest.withValues(alpha: 0.18),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? PocColors.forestDark : PocColors.inkSoft,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? PocColors.forestDark : PocColors.inkSoft,
          );
        }),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: PocColors.creamSoft,
        selectedColor: PocColors.forest,
        labelStyle: const TextStyle(color: PocColors.ink),
        secondaryLabelStyle: const TextStyle(color: PocColors.cream),
        side: const BorderSide(color: PocColors.saddle, width: 1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFD8CBA8),
        thickness: 0.6,
        space: 1,
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: PocColors.saddleDark,
        textColor: PocColors.ink,
      ),
      cardTheme: CardThemeData(
        color: PocColors.creamSoft,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFFD8CBA8)),
        ),
      ),
    );
  }
}

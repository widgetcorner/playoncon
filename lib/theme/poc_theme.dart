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

  // Dark-theme anchors ("the campground at night"): surfaces stay green-biased
  // rather than grey, cream flips from ground to text, and the forest primary
  // lightens to the moss the light scheme already uses as inversePrimary.
  static const moss = Color(0xFF8FC79A);
  static const pineNight = Color(0xFF151D17);
  static const tan = Color(0xFFC9AE85);
}

/// App-specific color roles that don't map cleanly onto Material's
/// [ColorScheme] (attribute pills, map chrome, brand accents). Widgets read
/// these via [PocPalette.of] instead of hardcoding [PocColors] members, so
/// both themes stay in sync from one place.
class PocPalette extends ThemeExtension<PocPalette> {
  final Color brand; // headings/badges (forestDark ↔ moss)
  final Color accent; // "live now" dot, highlights (forest ↔ moss)
  final Color textSoft; // secondary text (inkSoft ↔ warm grey)
  final Color pillBackground;
  final Color pillBorder;
  final Color pillText;
  final Color sheetSurface; // map info sheet
  final Color sheetBorder;
  final Color sheetDivider;
  final Color labelChipBackground; // map pin label chip (unselected)
  final Color labelChipBorder;
  final Color labelChipText;
  final Color controlSurface; // map Overview/Detail pill
  final Color controlIcon;
  final Color fabBackground; // map locate FAB
  final Color fabForeground;
  final Color youAreHere; // GPS dot

  const PocPalette({
    required this.brand,
    required this.accent,
    required this.textSoft,
    required this.pillBackground,
    required this.pillBorder,
    required this.pillText,
    required this.sheetSurface,
    required this.sheetBorder,
    required this.sheetDivider,
    required this.labelChipBackground,
    required this.labelChipBorder,
    required this.labelChipText,
    required this.controlSurface,
    required this.controlIcon,
    required this.fabBackground,
    required this.fabForeground,
    required this.youAreHere,
  });

  static const light = PocPalette(
    brand: PocColors.forestDark,
    accent: PocColors.forest,
    textSoft: PocColors.inkSoft,
    pillBackground: PocColors.creamSoft,
    pillBorder: PocColors.saddle,
    pillText: PocColors.inkSoft,
    sheetSurface: Colors.white,
    sheetBorder: Color(0xFFC8B996),
    sheetDivider: Color(0xFFD8CBA8),
    labelChipBackground: Color(0xE6FFFFFF),
    labelChipBorder: Color(0x668E7E63),
    labelChipText: PocColors.ink,
    controlSurface: Colors.white,
    controlIcon: PocColors.saddleDark,
    fabBackground: PocColors.forest,
    fabForeground: Colors.white,
    youAreHere: Color(0xFF2B6CB0),
  );

  static const dark = PocPalette(
    brand: PocColors.moss,
    accent: PocColors.moss,
    textSoft: Color(0xFFB9AF97),
    pillBackground: Color(0xFF26332A),
    pillBorder: Color(0xFFA08454),
    pillText: Color(0xFFD8CBA8),
    sheetSurface: Color(0xFF1E2A21),
    sheetBorder: Color(0xFF3E4A3F),
    sheetDivider: Color(0xFF3E4A3F),
    labelChipBackground: Color(0xEB1E2A21),
    labelChipBorder: Color(0x80A08454),
    labelChipText: PocColors.creamSoft,
    controlSurface: Color(0xFF26332A),
    controlIcon: PocColors.tan,
    fabBackground: Color(0xFF24503A),
    fabForeground: Color(0xFFC9DDCC),
    youAreHere: Color(0xFF6FA8DC),
  );

  static PocPalette of(BuildContext context) =>
      Theme.of(context).extension<PocPalette>() ?? light;

  @override
  PocPalette copyWith({
    Color? brand,
    Color? accent,
    Color? textSoft,
    Color? pillBackground,
    Color? pillBorder,
    Color? pillText,
    Color? sheetSurface,
    Color? sheetBorder,
    Color? sheetDivider,
    Color? labelChipBackground,
    Color? labelChipBorder,
    Color? labelChipText,
    Color? controlSurface,
    Color? controlIcon,
    Color? fabBackground,
    Color? fabForeground,
    Color? youAreHere,
  }) {
    return PocPalette(
      brand: brand ?? this.brand,
      accent: accent ?? this.accent,
      textSoft: textSoft ?? this.textSoft,
      pillBackground: pillBackground ?? this.pillBackground,
      pillBorder: pillBorder ?? this.pillBorder,
      pillText: pillText ?? this.pillText,
      sheetSurface: sheetSurface ?? this.sheetSurface,
      sheetBorder: sheetBorder ?? this.sheetBorder,
      sheetDivider: sheetDivider ?? this.sheetDivider,
      labelChipBackground: labelChipBackground ?? this.labelChipBackground,
      labelChipBorder: labelChipBorder ?? this.labelChipBorder,
      labelChipText: labelChipText ?? this.labelChipText,
      controlSurface: controlSurface ?? this.controlSurface,
      controlIcon: controlIcon ?? this.controlIcon,
      fabBackground: fabBackground ?? this.fabBackground,
      fabForeground: fabForeground ?? this.fabForeground,
      youAreHere: youAreHere ?? this.youAreHere,
    );
  }

  @override
  PocPalette lerp(PocPalette? other, double t) {
    if (other == null) return this;
    return PocPalette(
      brand: Color.lerp(brand, other.brand, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      textSoft: Color.lerp(textSoft, other.textSoft, t)!,
      pillBackground: Color.lerp(pillBackground, other.pillBackground, t)!,
      pillBorder: Color.lerp(pillBorder, other.pillBorder, t)!,
      pillText: Color.lerp(pillText, other.pillText, t)!,
      sheetSurface: Color.lerp(sheetSurface, other.sheetSurface, t)!,
      sheetBorder: Color.lerp(sheetBorder, other.sheetBorder, t)!,
      sheetDivider: Color.lerp(sheetDivider, other.sheetDivider, t)!,
      labelChipBackground:
          Color.lerp(labelChipBackground, other.labelChipBackground, t)!,
      labelChipBorder: Color.lerp(labelChipBorder, other.labelChipBorder, t)!,
      labelChipText: Color.lerp(labelChipText, other.labelChipText, t)!,
      controlSurface: Color.lerp(controlSurface, other.controlSurface, t)!,
      controlIcon: Color.lerp(controlIcon, other.controlIcon, t)!,
      fabBackground: Color.lerp(fabBackground, other.fabBackground, t)!,
      fabForeground: Color.lerp(fabForeground, other.fabForeground, t)!,
      youAreHere: Color.lerp(youAreHere, other.youAreHere, t)!,
    );
  }
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
      inversePrimary: PocColors.moss,
      shadow: Colors.black,
      scrim: Colors.black,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      extensions: const [PocPalette.light],
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

  /// "The campground at night" — same badge palette, inverted roles: pine
  /// ground, cream text, moss primary. Follows the light theme's component
  /// structure member-for-member so the two stay comparable side by side.
  static ThemeData dark() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: PocColors.moss,
      onPrimary: Color(0xFF0F2A18),
      primaryContainer: Color(0xFF24503A),
      onPrimaryContainer: Color(0xFFC9DDCC),
      secondary: PocColors.tan,
      onSecondary: PocColors.ink,
      secondaryContainer: Color(0xFF55452E),
      onSecondaryContainer: Color(0xFFE2D2B8),
      tertiary: Color(0xFFE0A277),
      onTertiary: Color(0xFF40200A),
      tertiaryContainer: Color(0xFF6A3D1E),
      onTertiaryContainer: Color(0xFFF2D7C2),
      error: Color(0xFFF2B8B5),
      onError: Color(0xFF601410),
      errorContainer: Color(0xFF8C1D18),
      onErrorContainer: Color(0xFFF9DEDC),
      surface: PocColors.pineNight,
      onSurface: PocColors.creamSoft,
      surfaceContainerHighest: Color(0xFF2C3A2E),
      surfaceContainerHigh: Color(0xFF26332A),
      surfaceContainer: Color(0xFF1E2A21),
      surfaceContainerLow: Color(0xFF1A241C),
      surfaceContainerLowest: Color(0xFF10160F),
      outline: Color(0xFF94886D),
      outlineVariant: Color(0xFF3E4A3F),
      inverseSurface: PocColors.creamSoft,
      onInverseSurface: PocColors.pineNight,
      inversePrimary: PocColors.forest,
      shadow: Colors.black,
      scrim: Colors.black,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      extensions: const [PocPalette.dark],
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1F3A2A),
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
        // Moss reads on the deep-green AppBar where cream-on-forest did the
        // job in light mode; unselected stays translucent cream.
        labelColor: PocColors.moss,
        unselectedLabelColor: PocColors.creamSoft.withValues(alpha: 0.55),
        indicatorColor: PocColors.moss,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF1A241C),
        indicatorColor: PocColors.moss.withValues(alpha: 0.22),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? PocColors.moss : const Color(0xFFA39A83),
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? PocColors.moss : const Color(0xFFA39A83),
          );
        }),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: const Color(0xFF26332A),
        selectedColor: PocColors.moss,
        labelStyle: const TextStyle(color: PocColors.creamSoft),
        secondaryLabelStyle: const TextStyle(color: Color(0xFF0F2A18)),
        side: const BorderSide(color: Color(0xFFA08454), width: 1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF3E4A3F),
        thickness: 0.6,
        space: 1,
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: PocColors.tan,
        textColor: PocColors.creamSoft,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF1E2A21),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF35402F)),
        ),
      ),
    );
  }
}

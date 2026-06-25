import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // ── Brand ──────────────────────────────────────────────────────────────────
  // The brand accent is RUNTIME-SWITCHABLE (Settings → Theme → Color).
  // [ThemeController] sets this + persists it + rebuilds the app. Everything
  // else derives from it, so a swatch tap re-skins the whole app.
  static Color accent = const Color(0xFFF2A93B); // default: gold

  /// accent @ 15% — used for glows / selected chips / nav indicator.
  static Color get accentGlow => accent.withValues(alpha: 0.15);

  /// Best foreground on the accent: dark text on light accents (gold,
  /// chartreuse), white on dark ones (cherry, blue). Keeps buttons legible
  /// whatever colour is picked.
  static Color get onAccent =>
      accent.computeLuminance() > 0.45 ? Colors.black : Colors.white;

  /// The selectable palette (Settings swatches), in display order.
  static const List<({String name, Color color})> palette = [
    (name: 'Gold', color: Color(0xFFF2A93B)),
    (name: 'Lipstick', color: Color(0xFFD2042D)),
    (name: 'Cherry', color: Color(0xFF3F1521)),
    (name: 'Pacific Blue', color: Color(0xFF009DC4)),
    (name: 'Tiger Orange', color: Color(0xFFF96815)),
    (name: 'Electric Violet', color: Color(0xFFBF37FF)),
    (name: 'Chartreuse', color: Color(0xFF7FFF00)),
  ];

  /// Lighten/darken in HSL space — lets the card gradient adapt to any accent.
  static Color _shiftL(Color c, double dl) {
    final h = HSLColor.fromColor(c);
    return h.withLightness((h.lightness + dl).clamp(0.0, 1.0)).toColor();
  }

  // ── Backgrounds / Surfaces ─────────────────────────────────────────────────
  static const Color bg = Color(0xFF080808);
  static const Color surface1 = Color(0xFF0E0E0E);
  static const Color surface2 = Color(0xFF151515);
  static const Color surface3 = Color(0xFF1E1E1E);

  // ── Borders ────────────────────────────────────────────────────────────────
  static const Color borderSubtle = Color(0xFF202020);
  static const Color borderMid = Color(0xFF2C2C2C);

  // ── Text ───────────────────────────────────────────────────────────────────
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0x99FFFFFF); // 60 %
  static const Color textTertiary = Color(0x59FFFFFF);  // 35 %
  static const Color textDisabled = Color(0x33FFFFFF);  // 20 %

  // ── Semantic ───────────────────────────────────────────────────────────────
  static const Color success = Color(0xFF22C55E);
  static const Color error = Color(0xFFEF4444);
  static const Color warning = Color(0xFFF59E0B);

  // ── Gradient helpers ───────────────────────────────────────────────────────
  // Brand card gradient — a soft lift → accent → deeper flesh, derived from the
  // current accent so it adapts to any picked colour. (Glossy sheen is layered
  // on top at the call site.)
  static LinearGradient get cardGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [accent, _shiftL(accent, -0.20)], // accent → darker; gloss on top
      );

  static const LinearGradient subtleGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF1A0A11), Color(0xFF0E0E1A)],
  );

  // ── Theme ──────────────────────────────────────────────────────────────────
  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);

    final colorScheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    ).copyWith(
      surface: bg,
      onSurface: textPrimary,
      surfaceContainer: surface2,
      surfaceContainerHighest: surface3,
      error: error,
    );

    final textTheme = GoogleFonts.dmSansTextTheme(base.textTheme).copyWith(
      // Display — Syne for big identity moments
      displayLarge: GoogleFonts.syne(
          fontSize: 48, fontWeight: FontWeight.w700, color: textPrimary),
      displayMedium: GoogleFonts.syne(
          fontSize: 40, fontWeight: FontWeight.w700, color: textPrimary),
      displaySmall: GoogleFonts.syne(
          fontSize: 32, fontWeight: FontWeight.w700, color: textPrimary),
      // Headline — Syne for section titles / screens
      headlineLarge: GoogleFonts.syne(
          fontSize: 26, fontWeight: FontWeight.w600, color: textPrimary),
      headlineMedium: GoogleFonts.syne(
          fontSize: 22, fontWeight: FontWeight.w600, color: textPrimary),
      headlineSmall: GoogleFonts.syne(
          fontSize: 18, fontWeight: FontWeight.w600, color: textPrimary),
      // Title — DM Sans bold
      titleLarge: GoogleFonts.dmSans(
          fontSize: 17, fontWeight: FontWeight.w600, color: textPrimary),
      titleMedium: GoogleFonts.dmSans(
          fontSize: 15, fontWeight: FontWeight.w600, color: textPrimary),
      titleSmall: GoogleFonts.dmSans(
          fontSize: 13, fontWeight: FontWeight.w600, color: textPrimary),
      // Body — DM Sans regular
      bodyLarge: GoogleFonts.dmSans(
          fontSize: 16, fontWeight: FontWeight.w400, color: textPrimary),
      bodyMedium: GoogleFonts.dmSans(
          fontSize: 14, fontWeight: FontWeight.w400, color: textPrimary),
      bodySmall: GoogleFonts.dmSans(
          fontSize: 12, fontWeight: FontWeight.w400, color: textSecondary),
      // Label
      labelLarge: GoogleFonts.dmSans(
          fontSize: 15, fontWeight: FontWeight.w600, color: textPrimary,
          letterSpacing: 0.1),
      labelMedium: GoogleFonts.dmSans(
          fontSize: 12, fontWeight: FontWeight.w500, color: textSecondary,
          letterSpacing: 0.6),
      labelSmall: GoogleFonts.dmSans(
          fontSize: 11, fontWeight: FontWeight.w500, color: textTertiary,
          letterSpacing: 0.8),
    );

    return base.copyWith(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: bg,
      textTheme: textTheme,

      // ── AppBar ──────────────────────────────────────────────────────────────
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
        ),
        titleTextStyle: GoogleFonts.syne(
          fontSize: 20, fontWeight: FontWeight.w600, color: textPrimary,
        ),
        iconTheme: const IconThemeData(color: textPrimary, size: 22),
      ),

      // ── Navigation Bar ──────────────────────────────────────────────────────
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface1,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 64,
        indicatorColor: accentGlow,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return GoogleFonts.dmSans(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? accent : textTertiary,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(color: selected ? accent : textTertiary, size: 22);
        }),
      ),

      // ── Card ────────────────────────────────────────────────────────────────
      cardTheme: CardThemeData(
        color: surface2,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: borderSubtle),
        ),
        margin: EdgeInsets.zero,
      ),

      // ── Filled Button ────────────────────────────────────────────────────────
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
          elevation: 0,
          textStyle: GoogleFonts.dmSans(
            fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0.1),
        ),
      ),

      // ── Outlined Button ──────────────────────────────────────────────────────
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
          side: const BorderSide(color: borderMid),
          textStyle: GoogleFonts.dmSans(
            fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0.1),
        ),
      ),

      // ── Text Button ──────────────────────────────────────────────────────────
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          textStyle: GoogleFonts.dmSans(
            fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),

      // ── Elevated Button ──────────────────────────────────────────────────────
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: surface3,
          foregroundColor: textPrimary,
          elevation: 0,
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
          textStyle: GoogleFonts.dmSans(
            fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),

      // ── Input Decoration ────────────────────────────────────────────────────
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface2,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: borderSubtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: borderSubtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: error, width: 1.5),
        ),
        labelStyle:
            GoogleFonts.dmSans(color: textTertiary, fontSize: 14),
        hintStyle:
            GoogleFonts.dmSans(color: textTertiary, fontSize: 14),
        helperStyle:
            GoogleFonts.dmSans(color: textTertiary, fontSize: 12),
        errorStyle:
            GoogleFonts.dmSans(color: error, fontSize: 12),
        floatingLabelStyle:
            GoogleFonts.dmSans(color: accent, fontSize: 12,
                fontWeight: FontWeight.w500),
      ),

      // ── List Tile ────────────────────────────────────────────────────────────
      listTileTheme: ListTileThemeData(
        tileColor: Colors.transparent,
        iconColor: textSecondary,
        textColor: textPrimary,
        titleTextStyle:
            GoogleFonts.dmSans(fontSize: 15, fontWeight: FontWeight.w500,
                color: textPrimary),
        subtitleTextStyle:
            GoogleFonts.dmSans(fontSize: 13, color: textTertiary),
        minLeadingWidth: 20,
      ),

      // ── Divider ─────────────────────────────────────────────────────────────
      dividerTheme: const DividerThemeData(
        color: borderSubtle, thickness: 1, space: 1),

      // ── Snack Bar ────────────────────────────────────────────────────────────
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surface3,
        contentTextStyle:
            GoogleFonts.dmSans(color: textPrimary, fontSize: 14),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
      ),

      // ── Dialog ───────────────────────────────────────────────────────────────
      dialogTheme: DialogThemeData(
        backgroundColor: surface2,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: GoogleFonts.syne(
          fontSize: 18, fontWeight: FontWeight.w600, color: textPrimary),
        contentTextStyle:
            GoogleFonts.dmSans(fontSize: 14, color: textSecondary),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
      ),

      // ── Bottom Sheet ─────────────────────────────────────────────────────────
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface2,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(24),
            topRight: Radius.circular(24),
          ),
        ),
      ),

      // ── Chip ─────────────────────────────────────────────────────────────────
      chipTheme: ChipThemeData(
        backgroundColor: surface3,
        selectedColor: accentGlow,
        side: const BorderSide(color: borderMid),
        labelStyle:
            GoogleFonts.dmSans(color: textSecondary, fontSize: 13),
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
      ),

      // ── Progress Indicator ───────────────────────────────────────────────────
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: borderSubtle,
        circularTrackColor: borderSubtle,
      ),

      // ── Icon ─────────────────────────────────────────────────────────────────
      iconTheme: const IconThemeData(color: textSecondary, size: 22),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'tokens.dart';

/// Builds the light and dark [ThemeData] for Dispatch from the tokens.
///
/// Type: Manrope for headings and numbers (display/headline/title + a
/// [numeric] helper), Inter for interface text (body/label).
class DispatchTheme {
  DispatchTheme._();

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  /// Manrope with tabular figures — for stat values, dates, refs, money.
  static TextStyle numeric({double size = 14, FontWeight weight = FontWeight.w700, Color? color, double? height}) =>
      GoogleFonts.manrope(fontSize: size, fontWeight: weight, color: color, height: height, fontFeatures: const [FontFeature.tabularFigures()]);

  static ThemeData _build(Brightness b) {
    final isDark = b == Brightness.dark;
    final bg = isDark ? DispatchColors.darkBg : DispatchColors.surface;
    final panel = isDark ? DispatchColors.darkPanel : DispatchColors.panel;
    final border = isDark ? DispatchColors.darkBorder : DispatchColors.border;
    final text = isDark ? DispatchColors.darkText : DispatchColors.ink;
    final muted = isDark ? DispatchColors.darkMuted : DispatchColors.muted;

    final scheme = ColorScheme(
      brightness: b,
      primary: DispatchColors.orange,
      onPrimary: Colors.white,
      primaryContainer: DispatchColors.tint(DispatchColors.orange, opacity: isDark ? 0.25 : 0.14),
      onPrimaryContainer: isDark ? const Color(0xFFFFC38A) : const Color(0xFF8A4A08),
      secondary: isDark ? const Color(0xFF7FA3E8) : DispatchColors.navy2,
      onSecondary: Colors.white,
      secondaryContainer: isDark ? const Color(0xFF243A63) : const Color(0xFFE4EAF5),
      onSecondaryContainer: text,
      tertiary: DispatchColors.typeBlue,
      onTertiary: Colors.white,
      error: DispatchColors.red,
      onError: Colors.white,
      errorContainer: DispatchColors.tint(DispatchColors.red),
      onErrorContainer: DispatchColors.red,
      surface: panel,
      onSurface: text,
      onSurfaceVariant: muted,
      surfaceContainerHighest: isDark ? const Color(0xFF1F2C47) : DispatchColors.surfaceAlt,
      surfaceContainerLow: bg,
      outline: border,
      outlineVariant: border,
      shadow: Colors.black,
      scrim: Colors.black54,
      inverseSurface: isDark ? DispatchColors.panel : DispatchColors.ink,
      onInverseSurface: isDark ? DispatchColors.ink : Colors.white,
      inversePrimary: DispatchColors.orange,
    );

    final inter = GoogleFonts.interTextTheme();
    TextStyle man(double size, FontWeight w, {double? height, double? spacing}) =>
        GoogleFonts.manrope(fontSize: size, fontWeight: w, color: text, height: height, letterSpacing: spacing);
    TextStyle inr(double size, FontWeight w, {Color? color, double? height}) =>
        GoogleFonts.inter(fontSize: size, fontWeight: w, color: color ?? text, height: height);

    final textTheme = inter.copyWith(
      displayLarge: man(40, FontWeight.w800, height: 1.1, spacing: -0.5),
      displayMedium: man(32, FontWeight.w800, height: 1.15, spacing: -0.5),
      displaySmall: man(28, FontWeight.w800, height: 1.15, spacing: -0.3),
      headlineLarge: man(26, FontWeight.w800, height: 1.2, spacing: -0.3),
      headlineMedium: man(22, FontWeight.w800, height: 1.2),
      headlineSmall: man(18, FontWeight.w700, height: 1.25),
      titleLarge: man(17, FontWeight.w700, height: 1.3),
      titleMedium: man(15, FontWeight.w700, height: 1.3),
      titleSmall: man(13, FontWeight.w700, height: 1.3),
      bodyLarge: inr(15, FontWeight.w400, height: 1.45),
      bodyMedium: inr(14, FontWeight.w400, height: 1.45),
      bodySmall: inr(12.5, FontWeight.w400, color: muted, height: 1.4),
      labelLarge: inr(14, FontWeight.w600, height: 1.2),
      labelMedium: inr(12.5, FontWeight.w600, height: 1.2),
      labelSmall: inr(11, FontWeight.w600, color: muted, height: 1.2),
    );

    final buttonShape = RoundedRectangleBorder(borderRadius: DispatchRadius.buttonR);
    const buttonPad = EdgeInsets.symmetric(horizontal: 16, vertical: 12);

    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: panel,
      dividerColor: border,
      textTheme: textTheme,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: panel,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.headlineSmall,
        shape: Border(bottom: BorderSide(color: border)),
      ),
      cardTheme: CardThemeData(
        color: panel,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: DispatchRadius.cardR, side: BorderSide(color: border)),
      ),
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panel,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        hintStyle: inr(14, FontWeight.w400, color: isDark ? DispatchColors.darkMuted : DispatchColors.faint),
        labelStyle: inr(13, FontWeight.w500, color: muted),
        border: OutlineInputBorder(borderRadius: DispatchRadius.buttonR, borderSide: BorderSide(color: border)),
        enabledBorder: OutlineInputBorder(borderRadius: DispatchRadius.buttonR, borderSide: BorderSide(color: border)),
        focusedBorder: OutlineInputBorder(borderRadius: DispatchRadius.buttonR, borderSide: const BorderSide(color: DispatchColors.orange, width: 1.5)),
        errorBorder: OutlineInputBorder(borderRadius: DispatchRadius.buttonR, borderSide: const BorderSide(color: DispatchColors.red)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: DispatchColors.orange,
          foregroundColor: Colors.white,
          shape: buttonShape,
          padding: buttonPad,
          textStyle: textTheme.labelLarge,
          elevation: 0,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: DispatchColors.orange,
          foregroundColor: Colors.white,
          shape: buttonShape,
          padding: buttonPad,
          textStyle: textTheme.labelLarge,
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: BorderSide(color: border),
          shape: buttonShape,
          padding: buttonPad,
          textStyle: textTheme.labelLarge,
          backgroundColor: panel,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: DispatchColors.typeBlue,
          shape: buttonShape,
          textStyle: textTheme.labelLarge,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: muted)),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: DispatchRadius.chipR),
        labelStyle: textTheme.labelMedium,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: DispatchColors.ink, borderRadius: DispatchRadius.chipR),
        textStyle: inr(12, FontWeight.w500, color: Colors.white),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: panel,
        shape: RoundedRectangleBorder(borderRadius: DispatchRadius.panelR),
        titleTextStyle: textTheme.headlineSmall,
        contentTextStyle: textTheme.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: panel,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(DispatchRadius.panel))),
        showDragHandle: true,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: panel,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: DispatchRadius.cardR, side: BorderSide(color: border)),
        textStyle: textTheme.bodyMedium,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: panel,
        indicatorColor: Colors.transparent,
        elevation: 0,
        height: 64,
        labelTextStyle: WidgetStateProperty.resolveWith((s) => inr(12, FontWeight.w600, color: s.contains(WidgetState.selected) ? text : muted)),
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: s.contains(WidgetState.selected) ? text : muted, size: 24)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: DispatchColors.ink,
        contentTextStyle: inr(14, FontWeight.w500, color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: DispatchRadius.cardR),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: DispatchColors.orange),
      listTileTheme: ListTileThemeData(iconColor: muted, textColor: text, shape: RoundedRectangleBorder(borderRadius: DispatchRadius.cardR)),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : muted),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? DispatchColors.orange : border),
      ),
    );
  }
}

/// Convenience accessors so screens can write `context.tokens.muted` etc.
extension DispatchContext on BuildContext {
  ThemeData get theme => Theme.of(this);
  ColorScheme get scheme => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
  Color get mutedColor => Theme.of(this).colorScheme.onSurfaceVariant;
  Color get borderColor => Theme.of(this).colorScheme.outline;
  Color get panelColor => Theme.of(this).colorScheme.surface;
  Color get inkColor => Theme.of(this).colorScheme.onSurface;
}

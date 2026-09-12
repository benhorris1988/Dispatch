import 'package:flutter/material.dart';

/// Design tokens for Dispatch. Colour, radius, spacing and type roles live
/// here so screens never hard-code a hex value. Use [DispatchColors] for hue
/// and [DispatchTheme] (app_theme.dart) for the ThemeData that applies them.
class DispatchColors {
  DispatchColors._();

  // Brand / structure
  static const Color ink = Color(0xFF16284D); // nav, headings, primary text, committed markers
  static const Color navy2 = Color(0xFF1F3A5F); // secondary headings, active nav
  static const Color surface = Color(0xFFF3F5F9); // app background
  static const Color panel = Color(0xFFFFFFFF); // panels/cards
  static const Color border = Color(0xFFE3E8F0);
  static const Color muted = Color(0xFF5B6B84);
  static const Color faint = Color(0xFF8A97AD); // placeholder / tertiary text
  static const Color surfaceAlt = Color(0xFFEDF1F7); // table header, subtle tint

  // Semantic
  static const Color orange = Color(0xFFF28C28); // primary action, in progress, today, changed
  static const Color green = Color(0xFF1F9D6B); // delivered / on track
  static const Color amber = Color(0xFFD99A00); // at risk / needs estimate
  static const Color red = Color(0xFFC8102E); // blocked / late / signal

  // Work-type defaults (real values come from the API's work_types.colour)
  static const Color typeBlue = Color(0xFF3B6BD6);
  static const Color typeTeal = Color(0xFF178F8A);
  static const Color typeRed = Color(0xFFC8102E);
  static const Color typeViolet = Color(0xFF6D5BD0);

  // Sidebar (always dark, regardless of theme mode)
  static const Color sidebar = ink;
  static const Color sidebarActive = Color(0xFF2A3F66);
  static const Color sidebarText = Color(0xFFDCE3EE);
  static const Color sidebarMuted = Color(0xFF9AA8C0);

  // Dark mode surfaces
  static const Color darkBg = Color(0xFF0E1728);
  static const Color darkPanel = Color(0xFF16213A);
  static const Color darkBorder = Color(0xFF283852);
  static const Color darkText = Color(0xFFE6ECF5);
  static const Color darkMuted = Color(0xFF9AA8C0);

  /// Tinted background for a status/type chip from its foreground colour.
  static Color tint(Color c, {double opacity = 0.12}) => c.withValues(alpha: opacity);

  /// Parse '#RRGGBB' (or 'RRGGBB'); falls back to [fallback] on garbage.
  static Color parseHex(String? hex, {Color fallback = typeBlue}) {
    if (hex == null || hex.isEmpty) return fallback;
    var h = hex.replaceFirst('#', '').trim();
    if (h.length == 6) h = 'FF$h';
    final v = int.tryParse(h, radix: 16);
    return v == null ? fallback : Color(v);
  }

  /// A stable colour for a person with no configured colour, from their id/name.
  static Color forSeed(Object seed) {
    const palette = [typeBlue, typeTeal, typeViolet, orange, green, amber, navy2, Color(0xFFB8336A)];
    return palette[seed.hashCode.abs() % palette.length];
  }
}

/// Corner radii by component role.
class DispatchRadius {
  DispatchRadius._();
  static const double panel = 14;
  static const double card = 10;
  static const double button = 8;
  static const double chip = 6;
  static const double stamp = 6;

  static BorderRadius get panelR => BorderRadius.circular(panel);
  static BorderRadius get cardR => BorderRadius.circular(card);
  static BorderRadius get buttonR => BorderRadius.circular(button);
  static BorderRadius get chipR => BorderRadius.circular(chip);
}

/// Spacing scale (4px base).
class Sp {
  Sp._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Shadows — only for floating elements (menus, dialogs, FABs). Panels use a
/// 1px border instead.
class DispatchShadow {
  DispatchShadow._();
  static const List<BoxShadow> floating = [
    BoxShadow(color: Color(0x1A16284D), blurRadius: 24, offset: Offset(0, 8)),
    BoxShadow(color: Color(0x0F16284D), blurRadius: 4, offset: Offset(0, 1)),
  ];
}

/// Shell dimensions.
class ShellDims {
  ShellDims._();
  static const double sidebarWide = 280;
  static const double sidebarRail = 72;
  static const double topBar = 64;
  static const double maxContent = 1600;
}

import 'package:flutter/widgets.dart';

/// Layout classes. Width-based (never shortestSide): a tablet in portrait is
/// ~768 wide and gets the tablet layout.
enum Pane { phone, tablet, desktop }

/// Single source of truth for breakpoints.
///
///   phone    < 700      bottom tabs, AppBar, one column
///   tablet   700–1099   72px icon rail, top bar
///   desktop  >= 1100    280px labelled sidebar, top bar
class Breaks {
  Breaks._();
  static const double tablet = 700;
  static const double desktop = 1100;
  static const double maxContent = 1600;

  static Pane of(BuildContext context) => forWidth(MediaQuery.sizeOf(context).width);

  static Pane forWidth(double width) {
    if (width >= desktop) return Pane.desktop;
    if (width >= tablet) return Pane.tablet;
    return Pane.phone;
  }

  static bool isPhone(BuildContext c) => of(c) == Pane.phone;
  static bool isTablet(BuildContext c) => of(c) == Pane.tablet;
  static bool isDesktop(BuildContext c) => of(c) == Pane.desktop;

  /// True at tablet and above.
  static bool wide(BuildContext c) => of(c) != Pane.phone;

  /// Default column count for card grids: 1 / 2 / 3.
  static int cols(BuildContext c) => switch (of(c)) {
        Pane.phone => 1,
        Pane.tablet => 2,
        Pane.desktop => 3,
      };

  /// Page gutter: 16 on phone, 24 on tablet, 32 on desktop.
  static double gutter(BuildContext c) => switch (of(c)) {
        Pane.phone => 16,
        Pane.tablet => 24,
        Pane.desktop => 32,
      };
}

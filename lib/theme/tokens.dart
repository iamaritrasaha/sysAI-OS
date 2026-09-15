/// Centralized design tokens for SysAI OS.
///
/// Spacing, radii, icon sizing, and motion durations are defined once here
/// so views stop hand-rolling magic numbers. Keep this file small — it is a
/// shared vocabulary, not a framework.
library;

import 'package:flutter/widgets.dart';

/// 4px-based spacing scale. Use these instead of arbitrary [SizedBox]/
/// [EdgeInsets] values so rhythm stays consistent across screens.
abstract final class Space {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

/// Corner radii. `sm` for inline chips/badges, `md` for controls and list
/// rows, `lg` for cards/panels, `xl` for large surfaces (dialogs, sheets).
abstract final class Radii {
  static const double sm = 6;
  static const double md = 10;
  static const double lg = 14;
  static const double xl = 20;

  static const BorderRadius smR = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdR = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgR = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlR = BorderRadius.all(Radius.circular(xl));
}

/// Icon sizes. Prefer `md` for inline/list icons and `lg` for standalone
/// action icons; avoid picking arbitrary sizes per-widget.
abstract final class IconSizes {
  static const double sm = 14;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 28;
}

/// Motion durations for state transitions, expansions, and page changes.
/// Kept short and consistent — SysAI OS uses motion to clarify state
/// changes, not to decorate.
abstract final class Motion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 320);
  static const Curve curve = Curves.easeOutCubic;
}

/// Border/hairline opacity used for subtle dividers on the Adwaita surfaces.
abstract final class Elevation {
  static const double hairlineOpacity = 0.08;
  static const double borderOpacity = 0.12;
  static const double focusBorderOpacity = 0.55;
}

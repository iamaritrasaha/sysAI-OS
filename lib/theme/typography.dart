/// SysAI OS typography system.
///
/// Two bundled, redistributable families (see assets/fonts/ for license
/// files): Inter for interface text, JetBrains Mono for anything that is
/// literally code, a path, a command, or a shell/terminal output — places
/// where character alignment and unambiguous glyphs (0 vs O, 1 vs l) matter.
///
/// This file defines the semantic scale the rest of the app should consume
/// (`AppText.pageTitle`, `AppText.body`, ...) instead of ad hoc `TextStyle`s
/// scattered across widgets. Colors are intentionally omitted here — callers
/// apply `Theme.of(context).colorScheme` so styles stay theme-aware.
library;

import 'package:flutter/material.dart';

const String _sans = 'Inter';
const String _mono = 'JetBrains Mono';

/// Tabular (fixed-width) numeral feature — use anywhere numbers appear in
/// a column or need to not visually jitter (durations, counters, stats).
const List<FontFeature> tabularNumbers = [FontFeature.tabularFigures()];

/// Semantic text styles for SysAI OS. All weights/sizes live here; views
/// should reference `AppText.*` rather than hand-writing `TextStyle`.
abstract final class AppText {
  // ── Display / Titles ────────────────────────────────────────────────────

  /// Large display text — reserved for empty states and hero moments.
  static const TextStyle display = TextStyle(
    fontFamily: _sans,
    fontSize: 28,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
    height: 1.15,
  );

  /// Page-level title (e.g. "Command Center", "Run Detail").
  static const TextStyle pageTitle = TextStyle(
    fontFamily: _sans,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    height: 1.2,
  );

  /// Section heading within a page (card headers, group titles).
  static const TextStyle sectionHeading = TextStyle(
    fontFamily: _sans,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.6,
    height: 1.3,
  );

  // ── Body ────────────────────────────────────────────────────────────────

  /// Default body text.
  static const TextStyle body = TextStyle(
    fontFamily: _sans,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.1,
    height: 1.45,
  );

  /// Emphasized body text (bold inline, list item titles).
  static const TextStyle bodyStrong = TextStyle(
    fontFamily: _sans,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.45,
  );

  /// De-emphasized supporting text under a heading or list item.
  static const TextStyle bodySecondary = TextStyle(
    fontFamily: _sans,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.05,
    height: 1.4,
  );

  /// Small print — metadata rows, timestamps, counts.
  static const TextStyle metadata = TextStyle(
    fontFamily: _sans,
    fontSize: 11.5,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.1,
    height: 1.3,
    fontFeatures: tabularNumbers,
  );

  // ── Controls ────────────────────────────────────────────────────────────

  /// Navigation rail / sidebar item label.
  static const TextStyle navigation = TextStyle(
    fontFamily: _sans,
    fontSize: 13.5,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.05,
    height: 1.2,
  );

  /// Button label.
  static const TextStyle button = TextStyle(
    fontFamily: _sans,
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.2,
  );

  /// Small uppercase badge / pill / tag label.
  static const TextStyle badge = TextStyle(
    fontFamily: _sans,
    fontSize: 10.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.5,
    height: 1.2,
  );

  /// Field/input label (small, muted caps or sentence case above a control).
  static const TextStyle label = TextStyle(
    fontFamily: _sans,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.4,
    height: 1.3,
  );

  // ── Monospace ───────────────────────────────────────────────────────────

  /// Inline code / model identifiers / short tokens.
  static const TextStyle code = TextStyle(
    fontFamily: _mono,
    fontSize: 12.5,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.4,
  );

  /// File paths and command text (shell capability, workspace tree).
  static const TextStyle path = TextStyle(
    fontFamily: _mono,
    fontSize: 12.5,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.4,
  );

  /// Multi-line terminal/command output blocks.
  static const TextStyle terminal = TextStyle(
    fontFamily: _mono,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.55,
    fontFeatures: tabularNumbers,
  );

  /// Builds a [TextTheme] for [ThemeData] rooted in Inter, so any widget
  /// that pulls from `Theme.of(context).textTheme` (Material defaults)
  /// still renders in the house typeface rather than falling back.
  static TextTheme textTheme(TextTheme base, Color bodyColor) => base
      .apply(fontFamily: _sans, bodyColor: bodyColor, displayColor: bodyColor)
      .copyWith(
        titleLarge: pageTitle.copyWith(color: bodyColor),
        titleMedium: sectionHeading.copyWith(color: bodyColor),
        bodyLarge: body.copyWith(color: bodyColor),
        bodyMedium: body.copyWith(color: bodyColor),
        bodySmall: bodySecondary.copyWith(color: bodyColor),
        labelLarge: button.copyWith(color: bodyColor),
        labelMedium: label.copyWith(color: bodyColor),
        labelSmall: badge.copyWith(color: bodyColor),
      );
}

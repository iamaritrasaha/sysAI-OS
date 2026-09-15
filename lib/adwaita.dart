import 'package:flutter/material.dart';

import 'theme/tokens.dart';
import 'theme/typography.dart';

/// GTK4/Adwaita-styled themes for SysAI.

/// Adwaita light theme. Dark surfaces, light text (GTK's default light variant).
ThemeData adwaitaLightTheme() {
  const onSurface = Color(0xff1d1d1f);
  return ThemeData(
    brightness: Brightness.light,
    useMaterial3: true,
    fontFamily: 'Inter',
    colorScheme: ColorScheme.light(
      primary: const Color(0xff1e88e5),
      secondary: const Color(0xff0fadb5),
      surface: Colors.white,
      onSurface: onSurface,
    ),
    scaffoldBackgroundColor: const Color(0xfffcfcfc),
    dividerColor: Colors.transparent,
    disabledColor: const Color(0xffb6b6b6),
    textTheme: AppText.textTheme(ThemeData.light().textTheme, onSurface),
    textSelectionTheme: const TextSelectionThemeData(
      selectionHandleColor: Color(0xff0a5a8f),
      cursorColor: Color(0xff0a5a8f),
    ),
    hoverColor: Colors.black.withAlpha(38),
    splashColor: Colors.black.withAlpha(34),
    visualDensity: VisualDensity.standard,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.linux: _FadeThroughPageTransitionsBuilder(),
        TargetPlatform.windows: _FadeThroughPageTransitionsBuilder(),
        TargetPlatform.macOS: _FadeThroughPageTransitionsBuilder(),
      },
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStatePropertyAll(0.0),
      radius: const Radius.circular(14),
    ),
    canvasColor: const Color(0xff0fadb5),
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      overlayColor: const Color(0xff5aaee0),
    ),
    chipTheme: ChipThemeData(
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: Radii.mdR),
      selectedColor: const Color(0xff1e88e5),
      disabledColor: const Color(0xffb6b6b6),
    ),
    tooltipTheme: TooltipThemeData(
      textStyle: AppText.metadata.copyWith(color: Colors.white),
      decoration: BoxDecoration(
        color: const Color(0xff1d1d1f),
        borderRadius: Radii.smR,
      ),
    ),
  );
}

/// Adwaita dark theme tuned for the SysAI command center.
ThemeData adwaitaDarkTheme() {
  const onSurface = Color(0xffe7eef2);
  return ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: 'Inter',
    colorScheme: ColorScheme.dark(
      primary: const Color(0xffa5e887),
      secondary: const Color(0xff65d5e8),
      surface: const Color(0xff141b22),
      onSurface: onSurface,
    ),
    scaffoldBackgroundColor: const Color(0xff0b1117),
    dividerColor: Colors.transparent,
    disabledColor: const Color(0xffb6b6b6),
    textTheme: AppText.textTheme(ThemeData.dark().textTheme, onSurface),
    textSelectionTheme: const TextSelectionThemeData(
      selectionHandleColor: Color(0xff7ba6f0),
      cursorColor: Color(0xff7ba6f0),
    ),
    hoverColor: Colors.white.withAlpha(38),
    splashColor: Colors.white.withAlpha(34),
    visualDensity: VisualDensity.standard,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.linux: _FadeThroughPageTransitionsBuilder(),
        TargetPlatform.windows: _FadeThroughPageTransitionsBuilder(),
        TargetPlatform.macOS: _FadeThroughPageTransitionsBuilder(),
      },
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStatePropertyAll(0.0),
      radius: const Radius.circular(14),
    ),
    canvasColor: const Color(0xff0b1117),
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      overlayColor: const Color(0xff0fadb5),
    ),
    chipTheme: ChipThemeData(
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: Radii.mdR),
      selectedColor: const Color(0xff0fadb5),
      disabledColor: const Color(0xffb6b6b6),
    ),
    tooltipTheme: TooltipThemeData(
      textStyle: AppText.metadata.copyWith(color: const Color(0xff0b1117)),
      decoration: BoxDecoration(
        color: const Color(0xffe7eef2),
        borderRadius: Radii.smR,
      ),
    ),
  );
}

/// A restrained cross-fade instead of Material's default directional slide —
/// calmer for a desktop shell where sibling pages (Home, Runs, System, ...)
/// aren't a navigation "stack" so much as tabs.
class _FadeThroughPageTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeThroughPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Motion.curve),
      child: child,
    );
  }
}

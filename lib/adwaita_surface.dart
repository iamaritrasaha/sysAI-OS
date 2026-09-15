import 'package:flutter/material.dart';

/// GTK4/Adwaita surface styling utilities.

/// 8px Adwaita corner radius - every GTK window, dialog and input shares this single value.
const double adwaitaRadiusValue = 8.0;

double adwaitaRadius() => adwaitaRadiusValue;

/// Flat Adwaita card. No shadow (Adwaita has elevation-0), just an 8px rounded
/// box with a faint 1px border.
class AdwaitaSurface extends StatelessWidget {
  const AdwaitaSurface({super.key, required this.child, this.filled = false});
  final Widget child;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.surface;
    final accent = theme.colorScheme.primary;

    return MouseRegion(
      cursor: SystemMouseCursors.text,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: filled ? color : null,
          borderRadius: BorderRadius.circular(adwaitaRadiusValue),
          border: filled == false
              ? Border.all(color: accent.withAlpha(20), width: 1)
              : null,
        ),
        child: child,
      ),
    );
  }
}

/// Adwaita dropdown toggle - round pill, 8px radius, dark on dark.
class AdwaitaSelectDialog extends StatelessWidget {
  const AdwaitaSelectDialog({
    super.key,
    required this.label,
    required this.content,
    this.trailing,
  });
  final Widget label;
  final Widget content;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.colorScheme.surface;

    return Container(
      width: 120,
      height: 34,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(adwaitaRadiusValue),
        border: Border.all(
          color: const Color(0xffb6b6b6).withAlpha(20),
          width: 1,
        ),
        color: base,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: label,
          ),
          const SizedBox(width: 6),
          const Icon(Icons.arrow_drop_down, size: 14),
          if (trailing != null) ...[
            const SizedBox(width: 6),
            trailing!,
          ],
        ],
      ),
    );
  }
}

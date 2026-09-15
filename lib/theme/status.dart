/// Unified status language for SysAI OS.
///
/// Runs, approvals, and providers all render state as short labels/badges.
/// Previously each view hand-rolled its own `RunStatus -> Color` switch with
/// different hex values for the same state (waiting-approval alone had three
/// different oranges across Home, Runs, and Run Detail). This file is the
/// single source of truth: one semantic tone per state, one place to change
/// it.
library;

import 'package:flutter/material.dart';

import '../models/run.dart';
import '../models/scheduled_automation.dart';

/// A semantic category of state, independent of the specific enum that
/// produced it. Every screen renders the same tone the same way.
enum StatusTone { neutral, info, progress, success, warning, danger }

extension StatusToneVisuals on StatusTone {
  /// Foreground (text/icon) color for this tone against [scheme].
  Color foreground(ColorScheme scheme) => switch (this) {
    StatusTone.neutral => scheme.onSurface.withAlpha(140),
    StatusTone.info => const Color(0xff6ac9e8),
    StatusTone.progress => const Color(0xff7ba6f0),
    StatusTone.success => const Color(0xff8fd67a),
    StatusTone.warning => const Color(0xfff0b84c),
    StatusTone.danger => const Color(0xffef6a6a),
  };

  /// Soft background tint for badges/pills. ~12% alpha of [foreground].
  Color background(ColorScheme scheme) =>
      foreground(scheme).withAlpha(31);

  IconData get icon => switch (this) {
    StatusTone.neutral => Icons.circle_outlined,
    StatusTone.info => Icons.schedule_rounded,
    StatusTone.progress => Icons.autorenew_rounded,
    StatusTone.success => Icons.check_circle_rounded,
    StatusTone.warning => Icons.error_outline_rounded,
    StatusTone.danger => Icons.cancel_rounded,
  };
}

/// Resolved visual treatment for a specific status value.
class StatusStyle {
  final StatusTone tone;
  final String label;
  final IconData icon;
  final Color foreground;
  final Color background;

  const StatusStyle({
    required this.tone,
    required this.label,
    required this.icon,
    required this.foreground,
    required this.background,
  });
}

/// Maps a [RunStatus] to its semantic tone. This is the one place run
/// lifecycle state is translated into "how alarming does this look."
StatusTone _toneForRunStatus(RunStatus status) => switch (status) {
  RunStatus.created || RunStatus.planning || RunStatus.ready => StatusTone.info,
  RunStatus.running || RunStatus.verifying => StatusTone.progress,
  RunStatus.waitingApproval || RunStatus.blocked => StatusTone.warning,
  RunStatus.completed => StatusTone.success,
  RunStatus.failed || RunStatus.interrupted => StatusTone.danger,
  RunStatus.cancelled => StatusTone.neutral,
};

/// Resolves the full [StatusStyle] (tone, label, icon, colors) for a
/// [RunStatus] against the active [ColorScheme]. All Run-status UI
/// (Home, Runs, Run Detail) should render through this single function.
StatusStyle statusStyleForRun(RunStatus status, ColorScheme scheme) {
  final tone = _toneForRunStatus(status);
  return StatusStyle(
    tone: tone,
    label: status.displayLabel,
    icon: tone.icon,
    foreground: tone.foreground(scheme),
    background: tone.background(scheme),
  );
}

StatusTone _toneForAutomationResult(AutomationResult result) => switch (result) {
  AutomationResult.none => StatusTone.neutral,
  AutomationResult.success => StatusTone.success,
  AutomationResult.failure => StatusTone.danger,
  AutomationResult.missed => StatusTone.warning,
};

/// Resolves the full [StatusStyle] for a [ScheduledAutomation]'s
/// [AutomationResult] — the Automations list/detail's equivalent of
/// [statusStyleForRun].
StatusStyle statusStyleForAutomationResult(AutomationResult result, ColorScheme scheme) {
  final tone = _toneForAutomationResult(result);
  return StatusStyle(
    tone: tone,
    label: result.displayLabel,
    icon: tone.icon,
    foreground: tone.foreground(scheme),
    background: tone.background(scheme),
  );
}

/// Compact pill rendering a [StatusStyle] — the canonical status badge used
/// across Home, Runs, and Run Detail.
class StatusPill extends StatelessWidget {
  final StatusStyle style;
  final bool dense;

  const StatusPill({super.key, required this.style, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final iconSize = dense ? 11.0 : 13.0;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 7 : 9,
        vertical: dense ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: style.background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.icon, size: iconSize, color: style.foreground),
          const SizedBox(width: 5),
          Text(
            style.label.toUpperCase(),
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: dense ? 9.5 : 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: style.foreground,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

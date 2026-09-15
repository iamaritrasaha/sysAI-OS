/// Visual language for structured Run events (`RunEvent.type`).
///
/// Reused by Run Detail's Activity timeline and the global Activity view so
/// the same event type always looks the same everywhere. Deliberately
/// reuses [StatusTone] rather than inventing a second palette — an event is
/// fundamentally informational, in-progress, successful, a warning, or an
/// error, the same six tones the rest of the app already uses for status.
library;

import 'package:flutter/material.dart';

import 'status.dart';

class EventVisual {
  final IconData icon;
  final StatusTone tone;

  /// Short human category shown before the raw event type in dense views
  /// (e.g. "Model", "Approval", "Capability") — never the raw dotted type
  /// string alone.
  final String category;

  const EventVisual({required this.icon, required this.tone, required this.category});
}

EventVisual eventVisualFor(String eventType) => switch (eventType) {
  'run.started' || 'run.resumed' => const EventVisual(icon: Icons.play_circle_outline, tone: StatusTone.info, category: 'Run'),
  'run.completed' => const EventVisual(icon: Icons.check_circle_outline, tone: StatusTone.success, category: 'Run'),
  'run.failed' => const EventVisual(icon: Icons.error_outline, tone: StatusTone.danger, category: 'Run'),
  'run.cancelled' => const EventVisual(icon: Icons.cancel_outlined, tone: StatusTone.neutral, category: 'Run'),
  'run.interrupted' => const EventVisual(icon: Icons.pause_circle_outline, tone: StatusTone.warning, category: 'Recovery'),
  'planning.started' || 'planning.completed' =>
    const EventVisual(icon: Icons.lightbulb_outline, tone: StatusTone.info, category: 'Planning'),
  'task.started' => const EventVisual(icon: Icons.task_alt, tone: StatusTone.progress, category: 'Task'),
  'task.completed' => const EventVisual(icon: Icons.task_alt, tone: StatusTone.success, category: 'Task'),
  'task.failed' => const EventVisual(icon: Icons.cancel, tone: StatusTone.danger, category: 'Task'),
  'task.retrying' => const EventVisual(icon: Icons.refresh, tone: StatusTone.warning, category: 'Task'),
  'model.selected' => const EventVisual(icon: Icons.memory_rounded, tone: StatusTone.info, category: 'Model'),
  'model.unavailable' => const EventVisual(icon: Icons.error_outline, tone: StatusTone.warning, category: 'Model'),
  'approval.requested' => const EventVisual(icon: Icons.gavel, tone: StatusTone.warning, category: 'Approval'),
  'approval.resolved' => const EventVisual(icon: Icons.verified_user_outlined, tone: StatusTone.success, category: 'Approval'),
  'capability.started' => const EventVisual(icon: Icons.bolt_outlined, tone: StatusTone.progress, category: 'Capability'),
  'capability.completed' => const EventVisual(icon: Icons.bolt_outlined, tone: StatusTone.success, category: 'Capability'),
  'capability.failed' || 'capability.denied' =>
    const EventVisual(icon: Icons.security, tone: StatusTone.danger, category: 'Capability'),
  'artifact.created' => const EventVisual(icon: Icons.save_outlined, tone: StatusTone.info, category: 'Artifact'),
  'checkpoint.created' => const EventVisual(icon: Icons.bookmark_outline, tone: StatusTone.info, category: 'Checkpoint'),
  'verification.started' => const EventVisual(icon: Icons.verified_outlined, tone: StatusTone.progress, category: 'Verification'),
  'verification.completed' => const EventVisual(icon: Icons.verified_outlined, tone: StatusTone.success, category: 'Verification'),
  _ => const EventVisual(icon: Icons.circle_outlined, tone: StatusTone.neutral, category: 'Event'),
};

/// SchedulerService — the entire "background" story for Phase 4.
///
/// A single central [Timer.periodic] (never one timer per automation)
/// checks for due [ScheduledAutomation]s and fires them by creating a
/// normal [Run] through the exact same pipeline a user-initiated Run goes
/// through (`runListProvider.notifier.createRun()` +
/// `runExecutorProvider.execute()`). There is no second execution engine
/// here — only scheduling logic on top of the existing one.
///
/// Lifecycle: active only while this process is alive. Closing the SysAI
/// OS window (if the app fully exits) stops the timer along with
/// everything else — see `docs/lifecycle.md`.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/notification.dart';
import '../models/run.dart';
import '../models/scheduled_automation.dart';
import '../providers/app_providers.dart';
import 'run_repository.dart';
import 'schedule_calculator.dart';

/// Grace window for a missed one-time automation: if SysAI OS wasn't
/// running at the scheduled instant but comes back within this window, it
/// still fires; past it, the automation is marked missed and disabled
/// rather than firing an arbitrarily-delayed one-time Run. This constant
/// *is* the entire "missed one-time automation" policy — deterministic and
/// documented, per the Phase 4 brief.
const Duration kOnceGraceWindow = Duration(minutes: 15);

/// How often the central timer checks for due automations.
const Duration kSchedulerTickInterval = Duration(seconds: 30);

/// Whether a *successful* automation firing also raises a desktop
/// notification (failures and missed automations always do, regardless of
/// this flag). Off by default so a healthy recurring automation doesn't
/// spam the desktop. Kept as one named constant so a future settings
/// screen can flip it without touching scheduler logic.
const bool kDesktopNotifyOnAutomationSuccess = false;

class SchedulerService {
  SchedulerService(this._ref);

  final Ref _ref;
  Timer? _timer;
  bool _disposed = false;
  bool _listening = false;

  /// run.id -> automation.id, for Runs this scheduler fired and is still
  /// waiting to reach a settled state. A single listener on
  /// [runListProvider] (registered once in [start]) drains this map rather
  /// than each firing registering its own listener.
  final Map<String, String> _pendingRuns = {};

  Future<RunRepository> _repo() => _ref.read(runRepositoryProvider.future);

  /// Starts the central timer and runs one immediate catch-up pass — this
  /// pass is what catches "the app wasn't running at the scheduled time."
  void start() {
    if (!_listening) {
      _listening = true;
      _ref.listen(runListProvider, (previous, next) {
        final runs = next.valueOrNull;
        if (runs == null || _pendingRuns.isEmpty) return;
        for (final run in runs) {
          final automationId = _pendingRuns[run.id];
          if (automationId == null) continue;
          // `blocked` is not a stopping point here: a rejected/paused task
          // does not itself end the Run — the runner keeps going and it
          // still reaches a real terminal status. Settling on `blocked`
          // would record an outcome the Run then goes on to contradict.
          if (!run.isTerminal) continue;
          _pendingRuns.remove(run.id);
          unawaited(_recordRunOutcome(automationId, run));
        }
      });
    }
    unawaited(processDueAutomations());
    _timer ??= Timer.periodic(kSchedulerTickInterval, (_) => processDueAutomations());
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  // ── CRUD ──────────────────────────────────────────────────────────────────

  Future<ScheduledAutomation> create({
    required String goal,
    required String workspacePath,
    required AutomationScheduleType scheduleType,
    Map<String, dynamic> scheduleExpression = const {},
    required String timezone,
    String? providerId,
    String? modelId,
    String? modelDisplayName,
    DateTime? onceAtUtc,
  }) async {
    final repo = await _repo();
    final id = 'auto-${DateTime.now().microsecondsSinceEpoch}';
    var automation = ScheduledAutomation.create(
      id: id,
      goal: goal,
      workspacePath: workspacePath,
      scheduleType: scheduleType,
      scheduleExpression: scheduleExpression,
      timezone: timezone,
      providerId: providerId,
      modelId: modelId,
      modelDisplayName: modelDisplayName,
    );
    final next = scheduleType == AutomationScheduleType.once
        ? onceAtUtc
        : computeNextTrigger(automation, DateTime.now().toUtc());
    automation = automation.copyWith(nextTriggerAt: next, clearNextTriggerAt: next == null);
    await repo.saveAutomation(automation);
    return automation;
  }

  Future<void> update(ScheduledAutomation automation) async {
    final repo = await _repo();
    await repo.saveAutomation(automation.copyWith(updatedAt: DateTime.now().toUtc()));
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final repo = await _repo();
    final automation = await repo.getAutomation(id);
    if (automation == null) return;
    // Re-enabling a schedule that has fallen behind (or was created
    // disabled and never had a next trigger) recomputes from now, rather
    // than firing immediately for however long it's been off.
    DateTime? next = automation.nextTriggerAt;
    if (enabled && automation.scheduleType != AutomationScheduleType.once) {
      next = computeNextTrigger(automation, DateTime.now().toUtc());
    }
    await repo.saveAutomation(automation.copyWith(
      enabled: enabled,
      nextTriggerAt: next,
      clearNextTriggerAt: next == null,
      updatedAt: DateTime.now().toUtc(),
    ));
  }

  Future<void> delete(String id) async {
    final repo = await _repo();
    await repo.deleteAutomation(id);
  }

  Future<List<ScheduledAutomation>> getAll() async => (await _repo()).getAllAutomations();

  /// Fires [automationId] immediately — the "Run now" UI action. Goes
  /// through the exact same claim + fire path as a due firing (keyed by a
  /// synthetic, always-unique occurrence key), so it can never collide
  /// with or duplicate the automation's regular schedule.
  Future<Run?> triggerNow(String automationId) async {
    final repo = await _repo();
    final automation = await repo.getAutomation(automationId);
    if (automation == null) return null;
    final occurrenceKey = 'manual-${DateTime.now().toUtc().toIso8601String()}-${automationId.hashCode}';
    final claimed = await repo.claimOccurrence(automationId, occurrenceKey);
    if (!claimed) return null;
    return _fire(automation, occurrenceKey, repo);
  }

  // ── Core loop ─────────────────────────────────────────────────────────────

  Future<void> processDueAutomations({DateTime? nowUtc}) async {
    if (_disposed) return;
    final now = nowUtc ?? DateTime.now().toUtc();
    final repo = await _repo();
    final due = await repo.getDueAutomations(now);

    for (final automation in due) {
      final trigger = automation.nextTriggerAt;
      if (trigger == null) continue;
      final occurrenceKey = trigger.toIso8601String();
      final claimed = await repo.claimOccurrence(automation.id, occurrenceKey);
      if (!claimed) {
        // Already handled — by a concurrent pass, or a prior process
        // before a crash/restart. Nothing to fire; just make sure
        // nextTriggerAt still reflects reality (it should already, but a
        // crash between claiming and recomputing could leave it stale).
        await _advancePastDue(automation, now, repo);
        continue;
      }

      if (automation.scheduleType == AutomationScheduleType.once) {
        if (!now.isAfter(trigger.add(kOnceGraceWindow))) {
          await _fire(automation, occurrenceKey, repo, dueInstant: trigger);
        } else {
          await _markMissed(automation, repo);
        }
        continue;
      }

      await _fire(automation, occurrenceKey, repo, dueInstant: trigger);

      // Recompute next trigger from the instant that just fired. For
      // `interval`, computeNextTrigger's own internal loop already
      // advances past every missed period in one call — this is what
      // keeps a long-closed app from queuing up a backlog of Runs, one
      // real Run fires "now" and every other missed period is just
      // skipped straight to the next future trigger.
      final refreshed = (await repo.getAutomation(automation.id))!;
      final next = computeNextTrigger(refreshed.copyWith(lastTriggeredAt: trigger), now);
      await repo.saveAutomation(refreshed.copyWith(nextTriggerAt: next, clearNextTriggerAt: next == null));
    }
  }

  Future<void> _advancePastDue(ScheduledAutomation automation, DateTime now, RunRepository repo) async {
    if (automation.scheduleType == AutomationScheduleType.once) return;
    final next = computeNextTrigger(automation, now);
    if (next != null) {
      await repo.saveAutomation(automation.copyWith(nextTriggerAt: next));
    }
  }

  Future<void> _markMissed(ScheduledAutomation automation, RunRepository repo) async {
    await repo.saveAutomation(automation.copyWith(
      enabled: false,
      lastResult: AutomationResult.missed,
      clearNextTriggerAt: true,
      updatedAt: DateTime.now().toUtc(),
    ));
    await _notify(
      type: NotificationType.automationMissed,
      title: 'Automation missed',
      message: '"${automation.title}" was not running in time and has been disabled.',
      urgency: 'critical',
    );
  }

  Future<Run> _fire(
    ScheduledAutomation automation,
    String occurrenceKey,
    RunRepository repo, {
    DateTime? dueInstant,
  }) async {
    // Persisted model selection travels with the automation, not whatever
    // the global default is *now* — createRun() only ever falls back to
    // the global default when no explicit provider/model is passed, so an
    // automation created against one model keeps using it even if the
    // user later changes their default elsewhere.
    final run = await _ref.read(runListProvider.notifier).createRun(
      automation.goal,
      providerId: automation.providerId,
      modelId: automation.modelId,
      modelDisplayName: automation.modelDisplayName,
      workspacePath: automation.workspacePath,
    );

    await repo.saveAutomation(automation.copyWith(
      lastRunId: run.id,
      lastTriggeredAt: dueInstant ?? DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));
    await repo.linkOccurrenceRun(automation.id, occurrenceKey, run.id);

    _pendingRuns[run.id] = automation.id;
    _ref.read(runExecutorProvider).execute(run.id);
    return run;
  }

  Future<void> _recordRunOutcome(String automationId, Run run) async {
    final repo = await _repo();
    final automation = await repo.getAutomation(automationId);
    if (automation == null) return;

    final success = run.status == RunStatus.completed;
    await repo.saveAutomation(automation.copyWith(
      lastResult: success ? AutomationResult.success : AutomationResult.failure,
      updatedAt: DateTime.now().toUtc(),
    ));

    if (!success) {
      final reason = run.errorMessage.isNotEmpty ? run.errorMessage : run.outcome;
      await _notify(
        type: NotificationType.automationFailed,
        title: 'Automation failed',
        message: reason.isNotEmpty ? '"${automation.title}": $reason' : '"${automation.title}" did not complete.',
        runId: run.id,
        urgency: 'critical',
      );
    } else {
      // Always visible in-app (the bell/Activity); a desktop ping only if
      // explicitly opted in — see kDesktopNotifyOnAutomationSuccess.
      await _notify(
        type: NotificationType.runCompleted,
        title: 'Automation completed',
        message: automation.title,
        runId: run.id,
        desktopNotify: kDesktopNotifyOnAutomationSuccess,
      );
    }
  }

  Future<void> _notify({
    required NotificationType type,
    required String title,
    required String message,
    String? runId,
    String urgency = 'normal',
    bool desktopNotify = true,
  }) async {
    final notification = AppNotification(
      id: 'notif-automation-${DateTime.now().microsecondsSinceEpoch}',
      type: type,
      title: title,
      message: message,
      runId: runId,
      createdAt: DateTime.now(),
    );
    await _ref.read(notificationsProvider.notifier).add(notification);
    if (desktopNotify) {
      await _ref.read(notificationServiceProvider).notify(title: title, body: message, urgency: urgency);
    }
  }
}

// ── Provider ──────────────────────────────────────────────────────────────

final schedulerServiceProvider = Provider<SchedulerService>((ref) {
  final service = SchedulerService(ref);
  ref.onDispose(service.dispose);
  return service;
});

/// One-shot load of all automations, refreshed by invalidating this
/// provider after any mutation (create/update/enable/disable/delete/run
/// now) — the same manual-refresh posture [RunsView] already uses for
/// [runListProvider], rather than a bespoke live-streaming list for a
/// screen that isn't the primary always-open surface.
final automationsListProvider = FutureProvider.autoDispose<List<ScheduledAutomation>>((ref) async {
  final scheduler = ref.watch(schedulerServiceProvider);
  return scheduler.getAll();
});

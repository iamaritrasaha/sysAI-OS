import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sysai/models/run.dart';
import 'package:sysai/models/scheduled_automation.dart';
import 'package:sysai/providers/app_providers.dart';
import 'package:sysai/services/run_repository.dart';
import 'package:sysai/services/scheduler_service.dart';

/// Pure repository/scheduler-logic tests — no bridge, no widgets. Mirrors
/// `background_run_test.dart`'s style: everything driven through the
/// provider graph against a real temp-file [RunRepository].
void main() {
  late Directory tempDir;
  late ProviderContainer container;
  late RunRepository repo;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sysai_scheduler_test_');
    final dbPath = p.join(tempDir.path, 'scheduler.db');
    repo = await RunRepository.open(dbPath);

    container = ProviderContainer(
      overrides: [
        runRepositoryProvider.overrideWith((ref) async => repo),
      ],
    );
    addTearDown(container.dispose);
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('CRUD', () {
    test('create computes an initial nextTriggerAt for a recurring schedule', () async {
      final scheduler = container.read(schedulerServiceProvider);
      final automation = await scheduler.create(
        goal: 'Check workspace health',
        workspacePath: tempDir.path,
        scheduleType: AutomationScheduleType.interval,
        scheduleExpression: {'minutes': 60},
        timezone: 'UTC',
      );
      expect(automation.nextTriggerAt, isNotNull);
      expect(automation.enabled, isTrue);

      final fetched = await repo.getAutomation(automation.id);
      expect(fetched, isNotNull);
    });

    test('once schedule keeps the caller-supplied instant, not a computed one', () async {
      final scheduler = container.read(schedulerServiceProvider);
      final at = DateTime.utc(2030, 1, 1, 9, 0);
      final automation = await scheduler.create(
        goal: 'One-off inspection',
        workspacePath: tempDir.path,
        scheduleType: AutomationScheduleType.once,
        timezone: 'UTC',
        onceAtUtc: at,
      );
      expect(automation.nextTriggerAt, at);
    });

    test('update, enable/disable, and delete round-trip through the repository', () async {
      final scheduler = container.read(schedulerServiceProvider);
      final automation = await scheduler.create(
        goal: 'g',
        workspacePath: tempDir.path,
        scheduleType: AutomationScheduleType.daily,
        scheduleExpression: {'hour': 9, 'minute': 0},
        timezone: 'UTC',
      );

      await scheduler.update(automation.copyWith(goal: 'updated goal'));
      expect((await repo.getAutomation(automation.id))!.goal, 'updated goal');

      await scheduler.setEnabled(automation.id, false);
      expect((await repo.getAutomation(automation.id))!.enabled, isFalse);

      await scheduler.setEnabled(automation.id, true);
      expect((await repo.getAutomation(automation.id))!.enabled, isTrue);

      await scheduler.delete(automation.id);
      expect(await repo.getAutomation(automation.id), isNull);
    });
  });

  group('duplicate-trigger protection', () {
    test('processing the same due instant twice creates exactly one Run', () async {
      final scheduler = container.read(schedulerServiceProvider);
      final due = DateTime.utc(2026, 1, 1, 9, 0);
      var automation = await scheduler.create(
        goal: 'Inspect the SysAI OS project and report whether its build environment is healthy.',
        workspacePath: tempDir.path,
        scheduleType: AutomationScheduleType.daily,
        scheduleExpression: {'hour': 9, 'minute': 0},
        timezone: 'UTC',
      );
      automation = automation.copyWith(nextTriggerAt: due);
      await repo.saveAutomation(automation);

      final now = due.add(const Duration(seconds: 1));
      await scheduler.processDueAutomations(nowUtc: now);
      await scheduler.processDueAutomations(nowUtc: now);

      final runs = await repo.getRunsCreatedByAutomation(automation.id);
      expect(runs.length, 1);

      // And the automation actually advanced past `now`, not stuck re-due.
      final refreshed = await repo.getAutomation(automation.id);
      expect(refreshed!.nextTriggerAt!.isAfter(now), isTrue);
    });

    test('surviving a repository close/reopen — simulating an app restart — still fires exactly once', () async {
      final due = DateTime.utc(2026, 1, 1, 9, 0);
      var automation = (await container.read(schedulerServiceProvider).create(
        goal: 'Inspect the SysAI OS project and report whether its build environment is healthy.',
        workspacePath: tempDir.path,
        scheduleType: AutomationScheduleType.daily,
        scheduleExpression: {'hour': 9, 'minute': 0},
        timezone: 'UTC',
      ));
      automation = automation.copyWith(nextTriggerAt: due);
      await repo.saveAutomation(automation);

      final now = due.add(const Duration(minutes: 1));
      await container.read(schedulerServiceProvider).processDueAutomations(nowUtc: now);

      // Simulate the app restarting: dispose this container/repo entirely
      // and open a fresh one against the same on-disk file.
      final dbPath = p.join(tempDir.path, 'scheduler.db');
      repo.close();
      container.dispose();

      final repo2 = await RunRepository.open(dbPath);
      addTearDown(repo2.close);
      final container2 = ProviderContainer(
        overrides: [runRepositoryProvider.overrideWith((ref) async => repo2)],
      );
      addTearDown(container2.dispose);

      // A second scheduler instance, backed by the same on-disk data,
      // processing the exact same due instant again after "restart."
      await container2.read(schedulerServiceProvider).processDueAutomations(nowUtc: now);

      final runs = await repo2.getRunsCreatedByAutomation(automation.id);
      expect(runs.length, 1, reason: 'restart must not duplicate the firing');
    });
  });

  group('missed-trigger policy', () {
    test('a one-time automation missed well past the grace window is marked missed, not fired', () async {
      final scheduler = container.read(schedulerServiceProvider);
      final at = DateTime.utc(2026, 1, 1, 9, 0);
      var automation = await scheduler.create(
        goal: 'One-off task',
        workspacePath: tempDir.path,
        scheduleType: AutomationScheduleType.once,
        timezone: 'UTC',
        onceAtUtc: at,
      );

      final farPast = at.add(const Duration(hours: 3)); // > kOnceGraceWindow
      await scheduler.processDueAutomations(nowUtc: farPast);

      final refreshed = await repo.getAutomation(automation.id);
      expect(refreshed!.lastResult, AutomationResult.missed);
      expect(refreshed.enabled, isFalse);
      expect(await repo.getRunsCreatedByAutomation(automation.id), isEmpty);
    });

    test('a one-time automation caught within the grace window still fires', () async {
      final scheduler = container.read(schedulerServiceProvider);
      final at = DateTime.utc(2026, 1, 1, 9, 0);
      var automation = await scheduler.create(
        goal: 'Inspect the SysAI OS project and report whether its build environment is healthy.',
        workspacePath: tempDir.path,
        scheduleType: AutomationScheduleType.once,
        timezone: 'UTC',
        onceAtUtc: at,
      );

      final withinGrace = at.add(const Duration(minutes: 5));
      await scheduler.processDueAutomations(nowUtc: withinGrace);

      final refreshed = await repo.getAutomation(automation.id);
      expect(refreshed!.lastRunId, isNotNull);
      expect(await repo.getRunsCreatedByAutomation(automation.id), hasLength(1));
    });

    test('a recurring automation missed for many periods fires once and lands strictly after now', () async {
      final scheduler = container.read(schedulerServiceProvider);
      var automation = await scheduler.create(
        goal: 'Inspect the SysAI OS project and report whether its build environment is healthy.',
        workspacePath: tempDir.path,
        scheduleType: AutomationScheduleType.interval,
        scheduleExpression: {'minutes': 60},
        timezone: 'UTC',
      );
      // Force it far into the past, as if the app was closed for days.
      automation = automation.copyWith(nextTriggerAt: DateTime.utc(2026, 1, 1, 0, 0));
      await repo.saveAutomation(automation);

      final now = DateTime.utc(2026, 1, 5, 12, 0); // many hourly periods missed
      await scheduler.processDueAutomations(nowUtc: now);

      final runs = await repo.getRunsCreatedByAutomation(automation.id);
      expect(runs.length, 1, reason: 'exactly one catch-up Run, not one per missed period');

      final refreshed = await repo.getAutomation(automation.id);
      expect(refreshed!.nextTriggerAt!.isAfter(now), isTrue);
    });
  });

  group('model persistence', () {
    test('an automation keeps its own persisted model even after the global default changes', () async {
      final scheduler = container.read(schedulerServiceProvider);
      final automation = await scheduler.create(
        goal: 'g',
        workspacePath: tempDir.path,
        scheduleType: AutomationScheduleType.daily,
        scheduleExpression: {'hour': 9, 'minute': 0},
        timezone: 'UTC',
        providerId: 'ollama',
        modelId: 'ollama:pinned-model',
        modelDisplayName: 'Pinned Model',
      );

      await container.read(defaultModelProvider.notifier).setDefault(
            providerId: 'ollama',
            modelId: 'ollama:some-other-default',
            modelDisplayName: 'Some Other Default',
          );

      final refreshed = await repo.getAutomation(automation.id);
      expect(refreshed!.modelId, 'ollama:pinned-model');
      expect(refreshed.providerId, 'ollama');
    });
  });

  group('triggerNow', () {
    test('fires immediately regardless of nextTriggerAt, exactly once', () async {
      final scheduler = container.read(schedulerServiceProvider);
      final automation = await scheduler.create(
        goal: 'Inspect the SysAI OS project and report whether its build environment is healthy.',
        workspacePath: tempDir.path,
        scheduleType: AutomationScheduleType.daily,
        scheduleExpression: {'hour': 9, 'minute': 0},
        timezone: 'UTC',
      );

      final run = await scheduler.triggerNow(automation.id);
      expect(run, isNotNull);

      final runs = await repo.getRunsCreatedByAutomation(automation.id);
      expect(runs, hasLength(1));
    });

    test('returns null for an unknown automation id', () async {
      final scheduler = container.read(schedulerServiceProvider);
      expect(await scheduler.triggerNow('does-not-exist'), isNull);
    });
  });

  group('end-to-end: firing produces a normal Run that completes and updates lastResult', () {
    test(
      'a scheduled automation drives a real Run to completion through the normal pipeline',
      () async {
        await container.read(bridgeStatusProvider.future);

        final scheduler = container.read(schedulerServiceProvider);
        scheduler.start();
        addTearDown(scheduler.dispose);

        final automation = await scheduler.create(
          goal: 'Inspect the SysAI OS project and report whether its build environment is healthy.',
          workspacePath: tempDir.path,
          scheduleType: AutomationScheduleType.daily,
          scheduleExpression: {'hour': 9, 'minute': 0},
          timezone: 'UTC',
        );

        await scheduler.triggerNow(automation.id);

        ScheduledAutomation? finalAutomation;
        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final current = await repo.getAutomation(automation.id);
          if (current != null && current.lastResult != AutomationResult.none) {
            finalAutomation = current;
            break;
          }
        }

        expect(finalAutomation, isNotNull, reason: 'lastResult should settle once the Run reaches a terminal state');
        expect(finalAutomation!.lastResult, AutomationResult.success);
        expect(finalAutomation.lastRunId, isNotNull);

        final run = await repo.getRun(finalAutomation.lastRunId!);
        expect(run!.status, RunStatus.completed);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('approval-gated scheduled Runs are never auto-approved', () {
    test(
      'a scheduled Run that hits REQUIRE_APPROVAL waits in waitingApproval, exactly like a manual Run',
      () async {
        await container.read(bridgeStatusProvider.future);

        final scheduler = container.read(schedulerServiceProvider);
        scheduler.start();
        addTearDown(scheduler.dispose);

        final automation = await scheduler.create(
          goal: 'Write a short status report to workspace_report.md',
          workspacePath: tempDir.path,
          scheduleType: AutomationScheduleType.daily,
          scheduleExpression: {'hour': 9, 'minute': 0},
          timezone: 'UTC',
        );

        await scheduler.triggerNow(automation.id);

        String? runId;
        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final current = await repo.getAutomation(automation.id);
          if (current?.lastRunId != null) {
            runId = current!.lastRunId;
            break;
          }
        }
        expect(runId, isNotNull);

        Run? waiting;
        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final run = await repo.getRun(runId!);
          if (run != null && run.status == RunStatus.waitingApproval) {
            waiting = run;
            break;
          }
        }

        expect(waiting, isNotNull, reason: 'scheduling a Run must not skip the approval gate');
        expect(waiting!.pendingApproval, isNotNull);

        // The safety property under test: nothing auto-resolved that
        // approval — it is still sitting there waiting for us. Reject it
        // explicitly, exactly as a human would for a manual Run.
        await container.read(runExecutorProvider).resolveApproval(
              runId!,
              waiting.pendingApproval!.id,
              false,
            );

        // A rejected task doesn't abort the whole Run (existing Phase 2/3
        // runner behavior — later tasks still execute), so wait for the
        // Run's own terminal state rather than assuming a specific one;
        // this also guarantees the bridge's event stream has fully drained
        // before the test (and its container) tears down.
        Run? finalRun;
        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final run = await repo.getRun(runId);
          if (run != null && run.isTerminal) {
            finalRun = run;
            break;
          }
        }
        expect(finalRun, isNotNull);

        ScheduledAutomation? settled;
        for (var i = 0; i < 50; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final current = await repo.getAutomation(automation.id);
          if (current != null && current.lastResult != AutomationResult.none) {
            settled = current;
            break;
          }
        }
        expect(settled, isNotNull);
        expect(
          settled!.lastResult,
          finalRun!.status == RunStatus.completed ? AutomationResult.success : AutomationResult.failure,
          reason: 'the automation must faithfully mirror the Run it produced, not invent a different outcome',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('unavailable persisted model', () {
    test(
      'surfaces as a failed Run instead of silently substituting another model',
      () async {
        await container.read(bridgeStatusProvider.future);

        final scheduler = container.read(schedulerServiceProvider);
        scheduler.start();
        addTearDown(scheduler.dispose);

        final automation = await scheduler.create(
          goal: 'Inspect the SysAI OS project and report whether its build environment is healthy.',
          workspacePath: tempDir.path,
          scheduleType: AutomationScheduleType.daily,
          scheduleExpression: {'hour': 9, 'minute': 0},
          timezone: 'UTC',
          providerId: 'ollama',
          modelId: 'definitely-not-a-real-model-xyz',
          modelDisplayName: 'Nonexistent Model',
        );

        await scheduler.triggerNow(automation.id);

        ScheduledAutomation? finalAutomation;
        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final current = await repo.getAutomation(automation.id);
          if (current != null && current.lastResult != AutomationResult.none) {
            finalAutomation = current;
            break;
          }
        }

        expect(finalAutomation, isNotNull);
        expect(finalAutomation!.lastResult, AutomationResult.failure);

        final run = await repo.getRun(finalAutomation.lastRunId!);
        expect(run!.status, RunStatus.failed);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}

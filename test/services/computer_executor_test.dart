import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sysai/models/approval.dart';
import 'package:sysai/models/run.dart';
import 'package:sysai/providers/app_providers.dart';
import 'package:sysai/services/run_repository.dart';
import 'package:sysai/services/test_surface_controller.dart';
import 'package:sysai/services/view_capture_service.dart';

/// Provider-graph-only tests for Controlled Computer Use — no widgets
/// (`captureBoundaryPng` against an unmounted key is itself part of what's
/// under test: it must fail gracefully, never crash), same style as
/// `background_run_test.dart`. Drives the real bridge, since the point is
/// proving the actual Python <-> Dart round-trip, not a mocked stand-in.
void main() {
  late Directory tempDir;
  late ProviderContainer container;
  late RunRepository repo;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sysai_computer_test_');
    final dbPath = p.join(tempDir.path, 'computer.db');
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

  test('click/type/key/scroll mutate the real TestSurfaceController state directly', () {
    final controller = container.read(testSurfaceControllerProvider.notifier);

    expect(controller.executeClick('submit_button')['success'], isTrue);
    expect(container.read(testSurfaceControllerProvider).submitted, isTrue);

    expect(controller.executeType('main_field', 'hello')['success'], isTrue);
    expect(container.read(testSurfaceControllerProvider).fieldValue, 'hello');

    expect(controller.executeKey('main_field', 'Backspace')['success'], isTrue);
    expect(container.read(testSurfaceControllerProvider).fieldValue, 'hell');

    final before = container.read(testSurfaceControllerProvider).scrollPosition;
    expect(controller.executeScroll('scroll_region', 'down')['success'], isTrue);
    expect(container.read(testSurfaceControllerProvider).scrollPosition, greaterThan(before));

    // Unknown selectors/targets fail cleanly, never throw.
    expect(controller.executeClick('does-not-exist')['success'], isFalse);
    expect(controller.executeType('does-not-exist', 'x')['success'], isFalse);
  });

  test('capturing when the test surface is not mounted fails gracefully, never crashes', () async {
    final bytes = await captureBoundaryPng(testSurfaceRepaintKey);
    expect(bytes, isNull);
  });

  group('end-to-end Controlled Computer Use through the real bridge', () {
    test(
      'observe -> type (approval-gated) -> click -> capture all execute for real against the registered target',
      () async {
        await container.read(bridgeStatusProvider.future);
        container.read(testSurfaceControllerProvider.notifier).reset();

        final run = await container.read(runListProvider.notifier).createRun(
              'Interact with the SysAI OS computer test surface: type into it and click submit.',
            );
        container.read(runExecutorProvider).execute(run.id);

        // The plan's `type` step requires approval — wait for it, exactly
        // like any other approval-gated capability.
        Run? waiting;
        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final current = container.read(runByIdProvider(run.id));
          if (current != null && current.status == RunStatus.waitingApproval) {
            waiting = current;
            break;
          }
        }
        expect(waiting, isNotNull, reason: 'computer.type against the test surface must require approval');
        final approval = waiting!.pendingApproval!;
        expect(approval.capabilityId, 'computer.type');

        await container.read(runExecutorProvider).resolveApproval(run.id, approval.id, true);

        Run? finalRun;
        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final current = container.read(runByIdProvider(run.id));
          if (current != null && current.isTerminal) {
            finalRun = current;
            break;
          }
        }
        expect(finalRun, isNotNull);
        // This provider-only test deliberately has no mounted ComputerView,
        // so the capture action cannot produce pixels.  A failed required
        // task must fail the Run rather than being reported as a false
        // success; the preceding observe/type/click actions still prove the
        // real target round-trip and are checked below.
        expect(finalRun!.status, RunStatus.failed);
        expect(finalRun.events.any((e) => e.type == 'task.failed'), isTrue);

        // The real, shared TestSurfaceController state actually changed —
        // proving this wasn't a mocked success path.
        final surfaceState = container.read(testSurfaceControllerProvider);
        expect(surfaceState.fieldValue, 'hello from sysai');
        expect(surfaceState.submitted, isTrue);

        // Structured events and persisted ComputerAction rows both exist.
        final actionEvents = finalRun.events.where((e) => e.type.startsWith('computer.action')).toList();
        expect(actionEvents, isNotEmpty);

        final persistedActions = await repo.getComputerActionsForRun(run.id);
        expect(persistedActions, isNotEmpty);
        expect(persistedActions.any((a) => a.type.serialized == 'type'), isTrue);
        expect(persistedActions.any((a) => a.type.serialized == 'click'), isTrue);

        final session = await repo.getComputerSessionForRun(run.id);
        expect(session, isNotNull);
        expect(session!.actionCount, greaterThan(0));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'a rejected approval means the type action never executes against the real surface',
      () async {
        await container.read(bridgeStatusProvider.future);
        container.read(testSurfaceControllerProvider.notifier).reset();

        final run = await container.read(runListProvider.notifier).createRun(
              'Interact with the SysAI OS computer test surface: type into it and click submit.',
            );
        container.read(runExecutorProvider).execute(run.id);

        ApprovalRequest? approval;
        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final current = container.read(runByIdProvider(run.id));
          if (current?.pendingApproval != null) {
            approval = current!.pendingApproval;
            break;
          }
        }
        expect(approval, isNotNull);

        await container.read(runExecutorProvider).resolveApproval(run.id, approval!.id, false);

        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final current = container.read(runByIdProvider(run.id));
          if (current != null && current.isTerminal) break;
        }

        // The field was never touched — rejection genuinely blocked
        // execution rather than the run silently proceeding anyway.
        expect(container.read(testSurfaceControllerProvider).fieldValue, isEmpty);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}

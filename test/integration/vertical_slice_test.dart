import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sysai/config/sysai_config.dart';
import 'package:sysai/models/run.dart';
import 'package:sysai/services/bridge_service.dart';
import 'package:sysai/services/run_repository.dart';

void main() {
  late Directory tempDir;
  late String dbPath;
  late BridgeService bridge;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sysai_e2e_');
    dbPath = p.join(tempDir.path, 'e2e_runs.db');
    bridge = BridgeService();
  });

  tearDown(() async {
    await bridge.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('Target Vertical Slice: Execute goal end-to-end and verify persistence', () async {
    // 1. Initialize SQLite repository
    final repo = await RunRepository.open(dbPath);

    // 2. Start bridge to real SysAI engine
    final bridgeScript = SysAIConfig.getBridgeScriptPath();
    final sysaiPath = SysAIConfig.discoverSysAIPathSync();
    await bridge.start(bridgeScript, sysaiPath);

    expect(bridge.isReady, isTrue);
    expect(bridge.sysaiAvailable, isTrue);

    // 3. Create persistent Run in DB
    const goal =
        'Inspect the SysAI OS project and report whether its test/build environment is healthy.';
    var run = Run.create(id: 'slice-test-1', goal: goal);
    await repo.saveRun(run);

    expect(run.status, equals(RunStatus.created));

    // 4. Stream execution events from bridge
    final stream = bridge.callStreaming('execute_run', params: {
      'run_id': run.id,
      'goal': run.goal,
    });

    final receivedEventTypes = <String>[];

    await for (final event in stream) {
      if (event.containsKey('_final_result')) {
        continue;
      }

      final type = event['type'] as String? ?? '';
      receivedEventTypes.add(type);

      final newEvent = RunEvent(
        type: type,
        timestamp: DateTime.now(),
        message: event['message'] as String? ?? '',
        data: event,
      );

      // Update run object
      var updatedPlan = run.plan;
      if (type == 'planning.completed' && event['plan'] is List) {
        updatedPlan = (event['plan'] as List)
            .map((t) => RunTask(
                  id: t['id'] as String? ?? '',
                  title: t['title'] as String? ?? '',
                ))
            .toList();
      } else if (type == 'task.completed' && event['task_id'] != null) {
        final tid = event['task_id'];
        updatedPlan = [
          for (final t in updatedPlan)
            if (t.id == tid) t.copyWith(status: 'completed') else t,
        ];
      }

      var newStatus = run.status;
      if (type == 'planning.started') newStatus = RunStatus.planning;
      if (type == 'run.started') newStatus = RunStatus.running;
      if (type == 'verification.started') newStatus = RunStatus.verifying;
      if (type == 'run.completed') newStatus = RunStatus.completed;

      run = run.copyWith(
        status: newStatus,
        plan: updatedPlan,
        events: [...run.events, newEvent],
        outcome: event['outcome'] as String? ?? run.outcome,
        updatedAt: DateTime.now(),
      );

      // Save to SQLite
      await repo.saveRun(run);
    }

    // 5. Verify run completed with structured output
    expect(run.status, equals(RunStatus.completed));
    expect(run.outcome.isNotEmpty, isTrue);
    expect(receivedEventTypes, contains('planning.started'));
    expect(receivedEventTypes, contains('planning.completed'));
    expect(receivedEventTypes, contains('run.started'));
    expect(receivedEventTypes, contains('capability.started'));
    expect(receivedEventTypes, contains('capability.completed'));
    expect(receivedEventTypes, contains('task.completed'));
    expect(receivedEventTypes, contains('verification.started'));
    expect(receivedEventTypes, contains('run.completed'));

    // 6. Simulate app shutdown: close repo and bridge
    repo.close();
    await bridge.stop();

    // 7. Simulate app restart: reopen database and check run
    final restartedRepo = await RunRepository.open(dbPath);
    final restoredRun = await restartedRepo.getRun('slice-test-1');

    expect(restoredRun, isNotNull);
    expect(restoredRun!.id, equals('slice-test-1'));
    expect(restoredRun.status, equals(RunStatus.completed));
    expect(restoredRun.goal, equals(goal));
    expect(restoredRun.plan.length, greaterThan(0));
    expect(restoredRun.events.length, greaterThan(5));
    expect(restoredRun.outcome, equals(run.outcome));

    restartedRepo.close();
  });
}

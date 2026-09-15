import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sysai/config/sysai_config.dart';
import 'package:sysai/models/approval.dart';
import 'package:sysai/models/artifact.dart';
import 'package:sysai/models/capability.dart';
import 'package:sysai/models/checkpoint.dart';
import 'package:sysai/models/run.dart';
import 'package:sysai/services/bridge_service.dart';
import 'package:sysai/services/run_repository.dart';

void main() {
  late Directory tempDir;
  late String dbPath;
  late BridgeService bridge;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sysai_p2_e2e_');
    dbPath = p.join(tempDir.path, 'p2_e2e_runs.db');
    bridge = BridgeService();
  });

  tearDown(() async {
    await bridge.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('Phase 2 Vertical Slice Integration Tests', () {
    test('Bridge exposes Capability Registry, Workspace browsing and Sandbox Policy', () async {
      final bridgeScript = SysAIConfig.getBridgeScriptPath();
      final sysaiPath = SysAIConfig.discoverSysAIPathSync();
      await bridge.start(bridgeScript, sysaiPath);

      expect(bridge.isReady, isTrue);
      expect(bridge.sysaiAvailable, isTrue);

      // 1. List capabilities
      final capabilities = await bridge.listCapabilities();
      expect(capabilities, isNotEmpty);

      final capIds = capabilities.map((c) => c.id).toSet();
      expect(capIds, contains('filesystem.read'));
      expect(capIds, contains('filesystem.write'));
      expect(capIds, contains('shell.execute'));
      expect(capIds, contains('git.status'));
      expect(capIds, contains('system.environment'));
      expect(capIds, contains('sysai.diagnostics'));

      final writeCap = capabilities.firstWhere((c) => c.id == 'filesystem.write');
      expect(writeCap.requiresApproval, isTrue);
      expect(writeCap.risk, equals(CapabilityRisk.high));

      // 2. Workspace browsing via bridge
      final files = await bridge.listWorkspaceFiles(path: '.');
      expect(files, isNotEmpty);
      final fileNames = files.map((f) => f['name']).toList();
      expect(fileNames, contains('pubspec.yaml'));

      final pubspec = await bridge.readWorkspaceFile('pubspec.yaml');
      expect(pubspec['content'], contains('name: sysai'));

      // 3. Sandboxing & path traversal prevention
      expect(
        () async => await bridge.readWorkspaceFile('../../../../../etc/passwd'),
        throwsA(isA<BridgeException>()),
      );
    });

    test('Agentic Execution with Approval Gating, Artifact Emission, and SQLite Persistence', () async {
      final repo = await RunRepository.open(dbPath);

      final bridgeScript = SysAIConfig.getBridgeScriptPath();
      final sysaiPath = SysAIConfig.discoverSysAIPathSync();
      await bridge.start(bridgeScript, sysaiPath);

      const runId = 'phase2-approval-slice-1';
      const testFileName = 'workspace_report.md';
      const goal = 'Write release notes to $testFileName for SysAI OS Phase 2.';

      var run = Run.create(id: runId, goal: goal);
      await repo.saveRun(run);
      expect(run.status, equals(RunStatus.created));

      final stream = bridge.callStreaming('execute_run', params: {
        'run_id': run.id,
        'goal': run.goal,
      });

      final receivedEventTypes = <String>[];
      final receivedArtifacts = <Artifact>[];
      ApprovalRequest? pendingApproval;

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

        if (type == 'planning.completed' && event['plan'] is List) {
          final planList = (event['plan'] as List)
              .map((t) => RunTask(
                    id: t['id'] as String? ?? '',
                    title: t['title'] as String? ?? '',
                    description: t['description'] as String? ?? '',
                    dependencies: (t['dependencies'] as List?)?.cast<String>() ?? const [],
                    capabilityHints: (t['capability_hints'] as List?)?.cast<String>() ?? const [],
                  ))
              .toList();
          run = run.copyWith(plan: planList);
        }

        if (type == 'approval.requested') {
          final approvalData = (event['data'] as Map?)?.cast<String, dynamic>() ?? event;
          final reqId = approvalData['approval_id'] as String? ??
              approvalData['request_id'] as String? ??
              event['approval_id'] as String? ??
              event['request_id'] as String? ??
              'app-1';
          final appReq = ApprovalRequest(
            id: reqId,
            runId: run.id,
            taskId: approvalData['task_id'] as String? ?? event['task_id'] as String?,
            capabilityId: approvalData['capability_id'] as String? ?? event['capability_id'] as String? ?? '',
            title: approvalData['title'] as String? ?? event['title'] as String? ?? 'Approval Required',
            explanation: approvalData['explanation'] as String? ?? event['explanation'] as String? ?? '',
            risk: CapabilityRisk.fromString(approvalData['risk'] as String? ?? event['risk'] as String?),
            payload: (approvalData['payload'] as Map?)?.cast<String, dynamic>() ?? {},
            status: ApprovalStatus.pending,
            createdAt: DateTime.now(),
          );
          pendingApproval = appReq;
          run = run.copyWith(
            status: RunStatus.waitingApproval,
            pendingApproval: appReq,
          );
          await repo.saveApproval(appReq);

          // Asynchronously resolve approval so runner can continue
          unawaited(Future.delayed(const Duration(milliseconds: 200), () async {
            await bridge.resolveApproval(appReq.id, true);
          }));
        }

        if (type == 'approval.resolved') {
          if (pendingApproval != null) {
            final resolved = pendingApproval.copyWith(
              status: ApprovalStatus.approved,
              resolvedAt: DateTime.now(),
            );
            pendingApproval = null;
            run = run.copyWith(
              status: RunStatus.running,
              pendingApproval: null,
            );
            await repo.saveApproval(resolved);
          }
        }

        if (type == 'artifact.created') {
          final artData = (event['data'] as Map?)?.cast<String, dynamic>() ?? event;
          final artifact = Artifact(
            id: artData['artifact_id'] as String? ?? 'art-${DateTime.now().millisecondsSinceEpoch}',
            runId: run.id,
            taskId: artData['task_id'] as String?,
            type: ArtifactType.fromString(artData['artifact_type'] as String?),
            title: artData['title'] as String? ?? 'Artifact',
            path: artData['path'] as String?,
            contentPreview: artData['content_preview'] as String?,
            metadata: (artData['metadata'] as Map?)?.cast<String, dynamic>() ?? {},
            createdAt: DateTime.now(),
          );
          receivedArtifacts.add(artifact);
          run = run.copyWith(artifacts: [...run.artifacts, artifact]);
          await repo.saveArtifact(artifact);
        }

        if (type == 'checkpoint.created') {
          final cpData = (event['data'] as Map?)?.cast<String, dynamic>() ?? event;
          final checkpoint = RunCheckpoint(
            id: cpData['checkpoint_id'] as String? ??
                'cp-${DateTime.now().microsecondsSinceEpoch}-${cpData['step_index']}',
            runId: runId,
            stepIndex: cpData['step_index'] as int? ?? 0,
            state: (cpData['state'] as Map?)?.cast<String, dynamic>() ?? {},
            createdAt: DateTime.now(),
          );
          await repo.saveCheckpoint(checkpoint);
        }

        var newStatus = run.status;
        if (type == 'planning.started') newStatus = RunStatus.planning;
        if (type == 'run.started') newStatus = RunStatus.running;
        if (type == 'verification.started') newStatus = RunStatus.verifying;
        if (type == 'run.completed') newStatus = RunStatus.completed;

        run = run.copyWith(
          status: newStatus,
          events: [...run.events, newEvent],
          outcome: event['outcome'] as String? ?? run.outcome,
          updatedAt: DateTime.now(),
        );

        await repo.saveRun(run);
      }

      // Assertions
      expect(run.status, equals(RunStatus.completed));
      expect(receivedEventTypes, contains('planning.completed'));
      expect(receivedEventTypes, contains('approval.requested'));
      expect(receivedEventTypes, contains('approval.resolved'));
      expect(receivedEventTypes, contains('artifact.created'));
      expect(receivedEventTypes, contains('checkpoint.created'));
      expect(receivedEventTypes, contains('run.completed'));

      // Check SQLite persistence
      final dbRun = await repo.getRun(runId);
      expect(dbRun, isNotNull);
      expect(dbRun!.status, equals(RunStatus.completed));
      expect(dbRun.artifacts, isNotEmpty);

      final dbArtifacts = await repo.getArtifactsForRun(runId);
      expect(dbArtifacts, isNotEmpty);
      expect(dbArtifacts.first.title, equals(testFileName));

      final latestCp = await repo.getLatestCheckpoint(runId);
      expect(latestCp, isNotNull);

      // Clean up test file generated in workspace
      final generatedFile = File(testFileName);
      if (await generatedFile.exists()) {
        await generatedFile.delete();
      }

      repo.close();
    });

    test('Recovery of Interrupted Runs on Startup', () async {
      final repo = await RunRepository.open(dbPath);

      // Simulate a run that was running when app crashed / closed
      final activeRun = Run.create(
        id: 'crashed-run-1',
        goal: 'Long running optimization task',
      ).copyWith(
        status: RunStatus.running,
        startedAt: DateTime.now().subtract(const Duration(minutes: 5)),
      );

      await repo.saveRun(activeRun);

      final beforeRecovery = await repo.getRun('crashed-run-1');
      expect(beforeRecovery!.status, equals(RunStatus.running));
      expect(beforeRecovery.needsAttention, isFalse);

      // Run startup recovery
      final recovered = await repo.recoverInterruptedRuns();
      expect(recovered.length, equals(1));

      final afterRecovery = await repo.getRun('crashed-run-1');
      expect(afterRecovery, isNotNull);
      expect(afterRecovery!.status, equals(RunStatus.interrupted));
      expect(afterRecovery.isInterrupted, isTrue);
      expect(afterRecovery.needsAttention, isTrue);
      expect(afterRecovery.events.any((e) => e.type == 'run.interrupted'), isTrue);

      repo.close();
    });
  });
}

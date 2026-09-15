import 'package:flutter_test/flutter_test.dart';
import 'package:sysai/models/approval.dart';
import 'package:sysai/models/artifact.dart';
import 'package:sysai/models/capability.dart';
import 'package:sysai/models/checkpoint.dart';
import 'package:sysai/models/run.dart';

void main() {
  group('Capability Model', () {
    test('serializes and deserializes correctly', () {
      final cap = Capability(
        id: 'filesystem.write',
        name: 'Write File',
        description: 'Writes content to a file inside the workspace',
        category: 'filesystem',
        risk: CapabilityRisk.high,
        requiresApproval: true,
        inputSchema: {'path': 'string', 'content': 'string'},
      );

      final json = cap.toJson();
      expect(json['id'], 'filesystem.write');
      expect(json['risk'], 'high');
      expect(json['requires_approval'], true);
      expect(json['input_schema'], isNotNull);

      final restored = Capability.fromJson(json);
      expect(restored.id, cap.id);
      expect(restored.name, cap.name);
      expect(restored.risk, CapabilityRisk.high);
      expect(restored.requiresApproval, true);
    });

    test('parses risk levels and labels', () {
      expect(CapabilityRisk.fromString('observe'), CapabilityRisk.observe);
      expect(CapabilityRisk.fromString('low'), CapabilityRisk.low);
      expect(CapabilityRisk.fromString('medium'), CapabilityRisk.medium);
      expect(CapabilityRisk.fromString('high'), CapabilityRisk.high);
      expect(CapabilityRisk.fromString('privileged'), CapabilityRisk.privileged);
      expect(CapabilityRisk.high.displayLabel, 'High Risk');
    });
  });

  group('Approval Model', () {
    test('serializes and tracks pending vs resolved', () {
      final now = DateTime.now();
      final approval = ApprovalRequest(
        id: 'appr-1',
        runId: 'run-1',
        taskId: 'task-1',
        capabilityId: 'shell.execute',
        title: 'Run rm command',
        explanation: 'Removing temporary files',
        risk: CapabilityRisk.high,
        payload: {'cmd': 'rm -rf tmp/'},
        status: ApprovalStatus.pending,
        createdAt: now,
      );

      expect(approval.isPending, isTrue);
      expect(approval.isResolved, isFalse);

      final json = approval.toJson();
      expect(json['id'], 'appr-1');
      expect(json['status'], 'pending');

      final restored = ApprovalRequest.fromJson(json);
      expect(restored.id, 'appr-1');
      expect(restored.risk, CapabilityRisk.high);

      final resolved = approval.copyWith(
        status: ApprovalStatus.approved,
        resolvedAt: DateTime.now(),
      );
      expect(resolved.isPending, isFalse);
      expect(resolved.isResolved, isTrue);
    });
  });

  group('Artifact Model', () {
    test('serializes and deserializes artifact types', () {
      final now = DateTime.now();
      final artifact = Artifact(
        id: 'art-1',
        runId: 'run-1',
        taskId: 'task-1',
        type: ArtifactType.file,
        title: 'report.txt',
        path: 'build/report.txt',
        contentPreview: 'All tests passed.',
        metadata: {'size': 123},
        createdAt: now,
      );

      final json = artifact.toJson();
      expect(json['type'], 'file');
      expect(json['content_preview'], 'All tests passed.');

      final restored = Artifact.fromJson(json);
      expect(restored.id, 'art-1');
      expect(restored.type, ArtifactType.file);
      expect(restored.title, 'report.txt');
    });
  });

  group('Checkpoint Model', () {
    test('serializes and preserves execution state', () {
      final now = DateTime.now();
      final chk = RunCheckpoint(
        id: 'chk-1',
        runId: 'run-1',
        stepIndex: 3,
        state: {'last_task': 't2', 'results_count': 2},
        createdAt: now,
      );

      final json = chk.toJson();
      expect(json['step_index'], 3);
      expect(json['state']['last_task'], 't2');

      final restored = RunCheckpoint.fromJson(json);
      expect(restored.id, 'chk-1');
      expect(restored.stepIndex, 3);
    });
  });

  group('Enhanced Run & RunTask Model', () {
    test('RunTask supports dependencies, attempts and errors', () {
      final task = RunTask(
        id: 't2',
        title: 'Run static analysis',
        status: 'pending',
        description: 'Verifies no lint issues exist',
        dependencies: ['t1'],
        capabilityHints: ['shell.execute'],
        attempts: 1,
        maxAttempts: 3,
      );

      final json = task.toJson();
      expect(json['dependencies'], ['t1']);
      expect(json['max_attempts'], 3);

      final restored = RunTask.fromJson(json);
      expect(restored.dependencies, ['t1']);
      expect(restored.maxAttempts, 3);
      expect(restored.description, 'Verifies no lint issues exist');
    });

    test('Run tracks pendingApproval, artifacts, and attention states', () {
      final now = DateTime.now();
      final run = Run(
        id: 'run-10',
        title: 'Refactor test',
        goal: 'Refactor test',
        status: RunStatus.waitingApproval,
        createdAt: now,
        updatedAt: now,
        pendingApproval: ApprovalRequest(
          id: 'appr-99',
          runId: 'run-10',
          capabilityId: 'filesystem.write',
          title: 'Write file',
          explanation: 'Updating source',
          risk: CapabilityRisk.medium,
          createdAt: now,
        ),
        artifacts: [
          Artifact(
            id: 'art-99',
            runId: 'run-10',
            type: ArtifactType.file,
            title: 'patch.diff',
            createdAt: now,
          ),
        ],
      );

      expect(run.needsAttention, isTrue);
      expect(run.needsApproval, isTrue);
      expect(run.hasPendingApproval, isTrue);
      expect(run.artifacts.length, 1);

      final json = run.toJson();
      expect(json['status'], 'waiting_approval');
      expect(json['pending_approval'], isNotNull);
      expect(json['artifacts'], isNotEmpty);

      final restored = Run.fromJson(json);
      expect(restored.status, RunStatus.waitingApproval);
      expect(restored.needsApproval, isTrue);
      expect(restored.artifacts.length, 1);
      expect(restored.pendingApproval?.id, 'appr-99');
    });
  });
}

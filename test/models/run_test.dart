import 'package:flutter_test/flutter_test.dart';
import 'package:sysai/models/run.dart';

void main() {
  group('RunStatus', () {
    test('serializes and deserializes correctly', () {
      for (final status in RunStatus.values) {
        final serialized = status.serialized;
        final restored = RunStatus.fromString(serialized);
        expect(restored, equals(status));
      }
    });

    test('waitingApproval handles both formats', () {
      expect(RunStatus.fromString('waiting_approval'),
          equals(RunStatus.waitingApproval));
      expect(RunStatus.fromString('waitingApproval'),
          equals(RunStatus.waitingApproval));
    });

    test('displayLabel is non-empty and human-readable', () {
      for (final status in RunStatus.values) {
        expect(status.displayLabel.isNotEmpty, isTrue);
      }
    });
  });

  group('RunTask', () {
    test('serializes and deserializes with all fields', () {
      final now = DateTime.now();
      final task = RunTask(
        id: 'task-1',
        title: 'Run test suite',
        status: 'running',
        startedAt: now,
      );

      final json = task.toJson();
      final restored = RunTask.fromJson(json);

      expect(restored.id, equals('task-1'));
      expect(restored.title, equals('Run test suite'));
      expect(restored.status, equals('running'));
      expect(restored.startedAt?.millisecondsSinceEpoch,
          equals(now.millisecondsSinceEpoch));
      expect(restored.completedAt, isNull);
    });

    test('copyWith works correctly', () {
      const task = RunTask(id: 't-1', title: 'Plan');
      final updated = task.copyWith(status: 'completed');
      expect(updated.id, equals('t-1'));
      expect(updated.status, equals('completed'));
    });
  });

  group('RunEvent', () {
    test('serializes and deserializes structured events', () {
      final now = DateTime.now();
      final event = RunEvent(
        type: 'capability.completed',
        timestamp: now,
        message: 'Doctor check passed',
        taskId: 't-1',
        data: {'exit_code': 0},
      );

      final json = event.toJson();
      final restored = RunEvent.fromJson(json);

      expect(restored.type, equals('capability.completed'));
      expect(restored.message, equals('Doctor check passed'));
      expect(restored.taskId, equals('t-1'));
      expect(restored.data?['exit_code'], equals(0));
    });
  });

  group('Run Domain Model', () {
    test('Run.create sets initial created status and truncated title', () {
      final run = Run.create(
        id: 'run-1',
        goal: 'Inspect the SysAI OS project and report whether its test/build environment is healthy.',
      );

      expect(run.id, equals('run-1'));
      expect(run.status, equals(RunStatus.created));
      expect(run.displayStatus, equals('Created'));
      expect(run.isActive, isFalse);
      expect(run.isTerminal, isFalse);
      expect(run.plan, isEmpty);
      expect(run.events, isEmpty);
    });

    test('isActive returns true only for active states', () {
      final base = Run.create(id: 'run-1', goal: 'Test goal');

      expect(base.copyWith(status: RunStatus.created).isActive, isFalse);
      expect(base.copyWith(status: RunStatus.planning).isActive, isTrue);
      expect(base.copyWith(status: RunStatus.ready).isActive, isTrue);
      expect(base.copyWith(status: RunStatus.running).isActive, isTrue);
      expect(base.copyWith(status: RunStatus.verifying).isActive, isTrue);
      expect(base.copyWith(status: RunStatus.completed).isActive, isFalse);
      expect(base.copyWith(status: RunStatus.failed).isActive, isFalse);
      expect(base.copyWith(status: RunStatus.cancelled).isActive, isFalse);
    });

    test('Run.create without a model has no override and a fallback label', () {
      final run = Run.create(id: 'run-nomodel', goal: 'Test goal');
      expect(run.hasModelOverride, isFalse);
      expect(run.modelLabel, equals('Default Model'));
    });

    test('Run.create with a model persists provider/model identity', () {
      final run = Run.create(
        id: 'run-model',
        goal: 'Test goal',
        providerId: 'ollama',
        modelId: 'ollama:qwen3:14b',
        modelDisplayName: 'qwen3:14b',
      );
      expect(run.hasModelOverride, isTrue);
      expect(run.providerId, equals('ollama'));
      expect(run.modelLabel, equals('qwen3:14b'));
    });

    test('changing the model on copyWith does not require a display name', () {
      final run = Run.create(id: 'run-x', goal: 'Test goal', providerId: 'ollama', modelId: 'ollama:qwen3:8b');
      expect(run.modelLabel, equals('ollama:qwen3:8b'));
    });

    test('isTerminal returns true only for terminal states', () {
      final base = Run.create(id: 'run-1', goal: 'Test goal');

      expect(base.copyWith(status: RunStatus.created).isTerminal, isFalse);
      expect(base.copyWith(status: RunStatus.running).isTerminal, isFalse);
      expect(base.copyWith(status: RunStatus.completed).isTerminal, isTrue);
      expect(base.copyWith(status: RunStatus.failed).isTerminal, isTrue);
      expect(base.copyWith(status: RunStatus.cancelled).isTerminal, isTrue);
      expect(base.copyWith(status: RunStatus.interrupted).isTerminal, isTrue);
    });

    test('full serialization roundtrip preserves all fields', () {
      final now = DateTime.now();
      final run = Run(
        id: 'run-roundtrip',
        title: 'Inspect environment',
        goal: 'Inspect environment thoroughly',
        status: RunStatus.completed,
        createdAt: now,
        updatedAt: now,
        startedAt: now,
        completedAt: now,
        plan: const [
          RunTask(id: 't-1', title: 'Task 1', status: 'completed'),
        ],
        events: [
          RunEvent(
            type: 'run.completed',
            timestamp: now,
            message: 'All done',
          ),
        ],
        outcome: 'Verification passed: 0 errors found.',
        errorMessage: '',
        providerId: 'ollama',
        modelId: 'ollama:qwen3:14b',
        modelDisplayName: 'qwen3:14b',
      );

      final json = run.toJson();
      final restored = Run.fromJson(json);

      expect(restored.id, equals(run.id));
      expect(restored.title, equals(run.title));
      expect(restored.providerId, equals('ollama'));
      expect(restored.modelId, equals('ollama:qwen3:14b'));
      expect(restored.modelDisplayName, equals('qwen3:14b'));
      expect(restored.goal, equals(run.goal));
      expect(restored.status, equals(RunStatus.completed));
      expect(restored.plan.length, equals(1));
      expect(restored.plan.first.status, equals('completed'));
      expect(restored.events.length, equals(1));
      expect(restored.events.first.type, equals('run.completed'));
      expect(restored.outcome, equals(run.outcome));
    });
  });
}

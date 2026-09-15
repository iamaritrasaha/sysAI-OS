import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sysai/models/browser_session.dart';
import 'package:sysai/models/notification.dart';
import 'package:sysai/models/run.dart';
import 'package:sysai/models/terminal_session.dart';
import 'package:sysai/services/run_repository.dart';

void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sysai_test_');
    dbPath = p.join(tempDir.path, 'test_runs.db');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('RunRepository', () {
    test('opens and initializes schema without errors', () async {
      final repo = await RunRepository.open(dbPath);
      expect(repo, isNotNull);
      repo.close();
    });

    test('saves and retrieves a Run', () async {
      final repo = await RunRepository.open(dbPath);

      final run = Run.create(id: 'run-1', goal: 'Test initial goal');
      await repo.saveRun(run);

      final fetched = await repo.getRun('run-1');
      expect(fetched, isNotNull);
      expect(fetched!.id, equals('run-1'));
      expect(fetched.goal, equals('Test initial goal'));
      expect(fetched.status, equals(RunStatus.created));

      repo.close();
    });

    test('updates a Run through state progression', () async {
      final repo = await RunRepository.open(dbPath);

      final run = Run.create(id: 'run-2', goal: 'Fix auth issue');
      await repo.saveRun(run);

      // Transition to running with plan
      final running = run.copyWith(
        status: RunStatus.running,
        startedAt: DateTime.now(),
        plan: const [
          RunTask(id: 't-1', title: 'Inspect code', status: 'completed'),
          RunTask(id: 't-2', title: 'Run tests', status: 'running'),
        ],
        events: [
          RunEvent(
            type: 'task.started',
            timestamp: DateTime.now(),
            message: 'Started task 2',
          ),
        ],
      );
      await repo.saveRun(running);

      final fetchedRunning = await repo.getRun('run-2');
      expect(fetchedRunning!.status, equals(RunStatus.running));
      expect(fetchedRunning.plan.length, equals(2));
      expect(fetchedRunning.plan.first.status, equals('completed'));
      expect(fetchedRunning.events.length, equals(1));

      // Transition to completed
      final completed = running.copyWith(
        status: RunStatus.completed,
        completedAt: DateTime.now(),
        outcome: 'All tests passed.',
      );
      await repo.saveRun(completed);

      final fetchedCompleted = await repo.getRun('run-2');
      expect(fetchedCompleted!.status, equals(RunStatus.completed));
      expect(fetchedCompleted.outcome, equals('All tests passed.'));

      repo.close();
    });

    test('persisted runs survive closing and reopening database (Application Restart)', () async {
      // Session 1: save a completed run
      final repo1 = await RunRepository.open(dbPath);
      final run = Run.create(id: 'run-persist', goal: 'Critical goal');
      final completed = run.copyWith(
        status: RunStatus.completed,
        outcome: 'Verified healthy.',
        completedAt: DateTime.now(),
      );
      await repo1.saveRun(completed);
      repo1.close();

      // Session 2: reopen database like an app restart
      final repo2 = await RunRepository.open(dbPath);
      final restored = await repo2.getRun('run-persist');

      expect(restored, isNotNull);
      expect(restored!.id, equals('run-persist'));
      expect(restored.status, equals(RunStatus.completed));
      expect(restored.outcome, equals('Verified healthy.'));
      repo2.close();
    });

    test('filters runs by status', () async {
      final repo = await RunRepository.open(dbPath);

      await repo.saveRun(Run.create(id: 'r-1', goal: 'G1').copyWith(status: RunStatus.completed));
      await repo.saveRun(Run.create(id: 'r-2', goal: 'G2').copyWith(status: RunStatus.running));
      await repo.saveRun(Run.create(id: 'r-3', goal: 'G3').copyWith(status: RunStatus.failed));

      final active = await repo.getRunsByStatus([RunStatus.running, RunStatus.planning]);
      expect(active.length, equals(1));
      expect(active.first.id, equals('r-2'));

      final completed = await repo.getRunsByStatus([RunStatus.completed]);
      expect(completed.length, equals(1));
      expect(completed.first.id, equals('r-1'));

      repo.close();
    });

    test('persists provider/model fields across save and reopen', () async {
      final repo = await RunRepository.open(dbPath);

      final run = Run.create(
        id: 'run-model-1',
        goal: 'Inspect environment',
        providerId: 'ollama',
        modelId: 'ollama:qwen3:14b',
        modelDisplayName: 'qwen3:14b',
      );
      await repo.saveRun(run);
      repo.close();

      final reopened = await RunRepository.open(dbPath);
      final fetched = await reopened.getRun('run-model-1');
      expect(fetched, isNotNull);
      expect(fetched!.providerId, equals('ollama'));
      expect(fetched.modelId, equals('ollama:qwen3:14b'));
      expect(fetched.modelDisplayName, equals('qwen3:14b'));
      expect(fetched.hasModelOverride, isTrue);

      reopened.close();
    });

    test('a run created without a model has null provider/model fields', () async {
      final repo = await RunRepository.open(dbPath);
      await repo.saveRun(Run.create(id: 'run-no-model', goal: 'Goal without model'));

      final fetched = await repo.getRun('run-no-model');
      expect(fetched!.providerId, isNull);
      expect(fetched.modelId, isNull);
      expect(fetched.hasModelOverride, isFalse);

      repo.close();
    });

    test('persists the SysAI OS default model as settings, independent of any Run', () async {
      final repo = await RunRepository.open(dbPath);

      expect(await repo.getSetting('default_model_id'), isNull);

      await repo.setSetting('default_provider_id', 'ollama');
      await repo.setSetting('default_model_id', 'ollama:qwen3:8b');
      await repo.setSetting('default_model_display_name', 'qwen3:8b');

      expect(await repo.getSetting('default_provider_id'), equals('ollama'));
      final all = await repo.getAllSettings();
      expect(all['default_model_id'], equals('ollama:qwen3:8b'));

      // Overwriting a setting replaces rather than duplicates it.
      await repo.setSetting('default_model_id', 'ollama:qwen3:14b');
      expect(await repo.getSetting('default_model_id'), equals('ollama:qwen3:14b'));
      expect((await repo.getAllSettings()).length, equals(3));

      repo.close();
    });

    test('changing the default model setting never mutates an existing run', () async {
      final repo = await RunRepository.open(dbPath);

      await repo.setSetting('default_provider_id', 'ollama');
      await repo.setSetting('default_model_id', 'ollama:qwen3:8b');

      final run = Run.create(
        id: 'run-fixed-model',
        goal: 'Goal locked to a specific model',
        providerId: 'ollama',
        modelId: 'ollama:qwen3:8b',
        modelDisplayName: 'qwen3:8b',
      );
      await repo.saveRun(run);

      // The default changes after the Run was created...
      await repo.setSetting('default_provider_id', 'ollama-cloud');
      await repo.setSetting('default_model_id', 'ollama-cloud:llama3.1:70b');

      // ...but the already-created Run keeps reporting what it actually used.
      final fetched = await repo.getRun('run-fixed-model');
      expect(fetched!.providerId, equals('ollama'));
      expect(fetched.modelId, equals('ollama:qwen3:8b'));
      expect(await repo.getSetting('default_model_id'), equals('ollama-cloud:llama3.1:70b'));

      repo.close();
    });

    test('deletes a run', () async {
      final repo = await RunRepository.open(dbPath);
      await repo.saveRun(Run.create(id: 'r-del', goal: 'To delete'));

      expect(await repo.getRun('r-del'), isNotNull);
      await repo.deleteRun('r-del');
      expect(await repo.getRun('r-del'), isNull);

      repo.close();
    });
  });

  group('TerminalSession persistence', () {
    test('saves a session summary once, not per output line, and it survives reopen', () async {
      final repo = await RunRepository.open(dbPath);
      await repo.saveRun(Run.create(id: 'run-term', goal: 'Run a command'));

      final now = DateTime.now();
      final session = TerminalSession(
        id: 'term-1',
        runId: 'run-term',
        taskId: 't1',
        command: 'flutter test',
        cwd: '.',
        status: TerminalSessionStatus.completed,
        exitCode: 0,
        outputPreview: 'All tests passed.',
        startedAt: now,
        completedAt: now.add(const Duration(seconds: 3)),
      );
      await repo.saveTerminalSession(session);
      repo.close();

      final reopened = await RunRepository.open(dbPath);
      final sessions = await reopened.getTerminalSessionsForRun('run-term');
      expect(sessions, hasLength(1));
      expect(sessions.first.command, 'flutter test');
      expect(sessions.first.status, TerminalSessionStatus.completed);
      expect(sessions.first.exitCode, 0);
      reopened.close();
    });

    test('updating a running session to completed replaces the same row, not a new one', () async {
      final repo = await RunRepository.open(dbPath);
      await repo.saveRun(Run.create(id: 'run-term-2', goal: 'Run a command'));

      final started = DateTime.now();
      final running = TerminalSession(
        id: 'term-2',
        runId: 'run-term-2',
        command: 'sleep 1',
        cwd: '.',
        status: TerminalSessionStatus.running,
        startedAt: started,
      );
      await repo.saveTerminalSession(running);
      await repo.saveTerminalSession(running.copyWith(
        status: TerminalSessionStatus.completed,
        exitCode: 0,
        completedAt: started.add(const Duration(seconds: 1)),
      ));

      final sessions = await repo.getTerminalSessionsForRun('run-term-2');
      expect(sessions, hasLength(1));
      expect(sessions.first.status, TerminalSessionStatus.completed);
      repo.close();
    });
  });

  group('BrowserSession persistence', () {
    test('upserts one session per run as browsing activity accumulates', () async {
      final repo = await RunRepository.open(dbPath);
      await repo.saveRun(Run.create(id: 'run-browse', goal: 'Research something'));

      final now = DateTime.now();
      await repo.saveBrowserSession(BrowserSession(
        id: 'browser-run-browse',
        runId: 'run-browse',
        currentUrl: 'https://example.com',
        currentTitle: 'Example',
        history: [BrowserNavigationEntry(url: 'https://example.com', title: 'Example', statusCode: 200, at: now)],
        updatedAt: now,
      ));
      await repo.saveBrowserSession(BrowserSession(
        id: 'browser-run-browse',
        runId: 'run-browse',
        currentUrl: 'https://example.com/next',
        currentTitle: 'Next',
        history: [
          BrowserNavigationEntry(url: 'https://example.com', title: 'Example', statusCode: 200, at: now),
          BrowserNavigationEntry(url: 'https://example.com/next', title: 'Next', statusCode: 200, at: now),
        ],
        updatedAt: now,
      ));

      final session = await repo.getBrowserSessionForRun('run-browse');
      expect(session, isNotNull);
      expect(session!.currentUrl, 'https://example.com/next');
      expect(session.history, hasLength(2));
      repo.close();
    });

    test('a run with no browsing activity has no session', () async {
      final repo = await RunRepository.open(dbPath);
      final session = await repo.getBrowserSessionForRun('nonexistent-run');
      expect(session, isNull);
      repo.close();
    });
  });

  group('Notification persistence', () {
    test('persists notifications and reads them back newest first', () async {
      final repo = await RunRepository.open(dbPath);
      final t0 = DateTime.now();

      await repo.saveNotification(AppNotification(
        id: 'notif-1', type: NotificationType.runCompleted,
        title: 'Run completed', message: 'Done.', runId: 'run-a', createdAt: t0,
      ));
      await repo.saveNotification(AppNotification(
        id: 'notif-2', type: NotificationType.approvalRequired,
        title: 'Approval needed', message: 'Wants to write a file.', runId: 'run-b',
        createdAt: t0.add(const Duration(seconds: 1)),
      ));

      final all = await repo.getAllNotifications();
      expect(all, hasLength(2));
      expect(all.first.id, 'notif-2'); // newest first
      expect(all.every((n) => !n.read), isTrue);

      repo.close();
    });

    test('marking a notification read persists across reopen', () async {
      final repo = await RunRepository.open(dbPath);
      await repo.saveNotification(AppNotification(
        id: 'notif-3', type: NotificationType.runFailed,
        title: 'Run failed', message: 'x', createdAt: DateTime.now(),
      ));
      await repo.markNotificationRead('notif-3');
      repo.close();

      final reopened = await RunRepository.open(dbPath);
      final all = await reopened.getAllNotifications();
      expect(all.single.read, isTrue);
      reopened.close();
    });
  });
}

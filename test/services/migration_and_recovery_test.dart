import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sysai/models/approval.dart';
import 'package:sysai/models/artifact.dart';
import 'package:sysai/models/capability.dart';
import 'package:sysai/models/checkpoint.dart';
import 'package:sysai/models/run.dart';
import 'package:sysai/services/run_repository.dart';

void _ensureSqlite() {
  if (Platform.isLinux) {
    try {
      open.overrideFor(OperatingSystem.linux, () {
        try {
          return DynamicLibrary.open('libsqlite3.so.0');
        } catch (_) {
          return DynamicLibrary.open('libsqlite3.so');
        }
      });
    } catch (_) {}
  }
}

void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    _ensureSqlite();
    tempDir = await Directory.systemTemp.createTemp('sysai_migration_test_');
    dbPath = p.join(tempDir.path, 'migration_test.db');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('RunRepository V1 to V2 Migration', () {
    test('successfully migrates V1 database to V2 without data loss', () async {
      // Step 1: Create a V1 database with raw sqlite
      final rawDb = sqlite3.open(dbPath);
      rawDb.execute('''
        CREATE TABLE runs (
          id            TEXT    PRIMARY KEY,
          title         TEXT    NOT NULL,
          goal          TEXT    NOT NULL,
          status        TEXT    NOT NULL,
          created_at    TEXT    NOT NULL,
          updated_at    TEXT    NOT NULL,
          started_at    TEXT,
          completed_at  TEXT,
          plan          TEXT    NOT NULL DEFAULT '[]',
          events        TEXT    NOT NULL DEFAULT '[]',
          outcome       TEXT    NOT NULL DEFAULT '',
          error_message TEXT    NOT NULL DEFAULT ''
        );
      ''');
      rawDb.execute('''
        INSERT INTO runs (id, title, goal, status, created_at, updated_at)
        VALUES ('run-v1', 'Goal V1', 'Goal V1', 'completed', '2026-09-01T12:00:00.000Z', '2026-09-01T12:00:00.000Z');
      ''');
      rawDb.execute('PRAGMA user_version = 1;');
      rawDb.dispose();

      // Step 2: Open with RunRepository
      final repo = await RunRepository.open(dbPath);

      // Verify user_version is now current (schema evolves; assert against
      // the repository's own constant rather than a hardcoded number so
      // this test doesn't need editing every time a migration is added).
      final rawCheck = sqlite3.open(dbPath);
      final verRow = rawCheck.select('PRAGMA user_version;');
      expect(verRow.first.columnAt(0), RunRepository.currentSchemaVersion);
      rawCheck.dispose();

      // Verify existing run was preserved
      final run = await repo.getRun('run-v1');
      expect(run, isNotNull);
      expect(run!.id, 'run-v1');
      expect(run.title, 'Goal V1');
      expect(run.status, RunStatus.completed);

      repo.close();
    });

    test('stores and queries approvals, artifacts, and checkpoints', () async {
      final repo = await RunRepository.open(dbPath);
      final now = DateTime.now();

      final run = Run.create(id: 'run-p2', goal: 'Test Phase 2 persistence');
      await repo.saveRun(run);

      // Approval
      final approval = ApprovalRequest(
        id: 'appr-10',
        runId: 'run-p2',
        taskId: 't-1',
        capabilityId: 'filesystem.write',
        title: 'Write config',
        explanation: 'Needs write access',
        risk: CapabilityRisk.high,
        payload: {'path': 'pubspec.yaml'},
        status: ApprovalStatus.pending,
        createdAt: now,
      );
      await repo.saveApproval(approval);

      final fetchedApproval = await repo.getApproval('appr-10');
      expect(fetchedApproval, isNotNull);
      expect(fetchedApproval!.title, 'Write config');
      expect(fetchedApproval.status, ApprovalStatus.pending);

      final pendingList = await repo.getPendingApprovals();
      expect(pendingList.any((a) => a.id == 'appr-10'), isTrue);

      // Artifact
      final artifact = Artifact(
        id: 'art-10',
        runId: 'run-p2',
        type: ArtifactType.file,
        title: 'output.log',
        contentPreview: 'Build succeeded',
        createdAt: now,
      );
      await repo.saveArtifact(artifact);

      final artifactsForRun = await repo.getArtifactsForRun('run-p2');
      expect(artifactsForRun.length, 1);
      expect(artifactsForRun.first.title, 'output.log');

      // Checkpoint
      final checkpoint = RunCheckpoint(
        id: 'chk-10',
        runId: 'run-p2',
        stepIndex: 2,
        state: {'completed_tasks': ['t-1']},
        createdAt: now,
      );
      await repo.saveCheckpoint(checkpoint);

      final latestChk = await repo.getLatestCheckpoint('run-p2');
      expect(latestChk, isNotNull);
      expect(latestChk!.stepIndex, 2);

      repo.close();
    });

    test('recovers interrupted runs on startup', () async {
      final repo = await RunRepository.open(dbPath);
      final now = DateTime.now();

      // Create an active run that did not complete (e.g. abrupt exit)
      final runningRun = Run(
        id: 'run-interrupted-1',
        title: 'Running run',
        goal: 'Running run',
        status: RunStatus.running,
        createdAt: now,
        updatedAt: now,
      );
      await repo.saveRun(runningRun);

      final completedRun = Run(
        id: 'run-completed-1',
        title: 'Completed run',
        goal: 'Completed run',
        status: RunStatus.completed,
        createdAt: now,
        updatedAt: now,
      );
      await repo.saveRun(completedRun);

      // Run recovery
      final recovered = await repo.recoverInterruptedRuns();
      expect(recovered.length, 1);
      expect(recovered.first.id, 'run-interrupted-1');
      expect(recovered.first.status, RunStatus.interrupted);
      expect(recovered.first.events.any((e) => e.type == 'run.interrupted'), isTrue);

      // Verify DB reflects interrupted status
      final fromDb = await repo.getRun('run-interrupted-1');
      expect(fromDb!.status, RunStatus.interrupted);

      final completedDb = await repo.getRun('run-completed-1');
      expect(completedDb!.status, RunStatus.completed);

      repo.close();
    });
  });

  group('RunRepository V3 to V4 Migration (Phase 3 operational surfaces)', () {
    test('migrates a real V3 database to V4 without losing existing data', () async {
      // Step 1: build a database matching the actual, current V3 schema —
      // no terminal_sessions/browser_sessions/notifications tables yet.
      final rawDb = sqlite3.open(dbPath);
      rawDb.execute('''
        CREATE TABLE runs (
          id TEXT PRIMARY KEY, title TEXT NOT NULL, goal TEXT NOT NULL, status TEXT NOT NULL,
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL, started_at TEXT, completed_at TEXT,
          plan TEXT NOT NULL DEFAULT '[]', events TEXT NOT NULL DEFAULT '[]',
          outcome TEXT NOT NULL DEFAULT '', error_message TEXT NOT NULL DEFAULT '',
          provider_id TEXT, model_id TEXT, model_display_name TEXT
        );
      ''');
      rawDb.execute('''
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      ''');
      rawDb.execute('''
        CREATE TABLE approvals (
          id TEXT PRIMARY KEY, run_id TEXT NOT NULL, task_id TEXT, capability_id TEXT NOT NULL,
          title TEXT NOT NULL, explanation TEXT NOT NULL, risk TEXT NOT NULL,
          payload TEXT NOT NULL DEFAULT '{}', status TEXT NOT NULL, created_at TEXT NOT NULL, resolved_at TEXT
        );
      ''');
      rawDb.execute('''
        CREATE TABLE artifacts (
          id TEXT PRIMARY KEY, run_id TEXT NOT NULL, task_id TEXT, type TEXT NOT NULL,
          title TEXT NOT NULL, path TEXT, content_preview TEXT,
          metadata TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL
        );
      ''');
      rawDb.execute('''
        CREATE TABLE checkpoints (
          id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_index INTEGER NOT NULL,
          state TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL
        );
      ''');
      rawDb.execute('''
        INSERT INTO runs (id, title, goal, status, created_at, updated_at, provider_id, model_id)
        VALUES ('run-v3', 'Pre-Phase-3 run', 'Pre-Phase-3 run', 'completed',
                '2026-10-01T00:00:00.000Z', '2026-10-01T00:00:00.000Z', 'ollama', 'ollama:qwen3:8b');
      ''');
      rawDb.execute("INSERT INTO settings (key, value) VALUES ('default_model_id', 'ollama:qwen3:8b');");
      rawDb.execute('PRAGMA user_version = 3;');
      rawDb.dispose();

      // Step 2: open with the current repository.
      final repo = await RunRepository.open(dbPath);

      final rawCheck = sqlite3.open(dbPath);
      expect(rawCheck.select('PRAGMA user_version;').first.columnAt(0), RunRepository.currentSchemaVersion);
      // New tables must exist and be empty, not merely "not error."
      expect(rawCheck.select('SELECT COUNT(*) FROM terminal_sessions;').first.columnAt(0), 0);
      expect(rawCheck.select('SELECT COUNT(*) FROM browser_sessions;').first.columnAt(0), 0);
      expect(rawCheck.select('SELECT COUNT(*) FROM notifications;').first.columnAt(0), 0);
      rawCheck.dispose();

      // Step 3: pre-existing data (a V2/V3-era run and a setting) survived.
      final run = await repo.getRun('run-v3');
      expect(run, isNotNull);
      expect(run!.modelId, 'ollama:qwen3:8b');
      expect(await repo.getSetting('default_model_id'), 'ollama:qwen3:8b');

      repo.close();
    });

    test('is idempotent — opening an already-current database changes nothing', () async {
      final repo1 = await RunRepository.open(dbPath);
      repo1.close();

      // Re-opening a database already at the current version must not
      // raise (e.g. from a non-idempotent CREATE TABLE) and must leave the
      // version untouched.
      final repo2 = await RunRepository.open(dbPath);
      final rawCheck = sqlite3.open(dbPath);
      expect(rawCheck.select('PRAGMA user_version;').first.columnAt(0), RunRepository.currentSchemaVersion);
      rawCheck.dispose();
      repo2.close();
    });
  });
}

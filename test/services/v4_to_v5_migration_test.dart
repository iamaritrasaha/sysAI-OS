import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sysai/models/scheduled_automation.dart';
import 'package:sysai/services/run_repository.dart';

/// [RunRepository] applies this same override internally before opening
/// its own connection — replicated here because this test opens a raw
/// connection directly (to build a V4-shaped fixture) before
/// [RunRepository] ever touches the file.
void _ensureSqliteInitializedForTest() {
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

/// Builds a real V4-shaped SQLite file — the exact schema
/// `RunRepository`'s `_createAllV3Tables()` + `_createV4Tables()` produced
/// before Phase 4 — independently of the current repository code, so this
/// test actually exercises the upgrade path rather than a tautology.
void _createV4Database(Database db) {
  db.execute('''
    CREATE TABLE runs (
      id TEXT PRIMARY KEY, title TEXT NOT NULL, goal TEXT NOT NULL, status TEXT NOT NULL,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, started_at TEXT, completed_at TEXT,
      plan TEXT NOT NULL DEFAULT '[]', events TEXT NOT NULL DEFAULT '[]',
      outcome TEXT NOT NULL DEFAULT '', error_message TEXT NOT NULL DEFAULT '',
      provider_id TEXT, model_id TEXT, model_display_name TEXT
    );
  ''');
  db.execute('''
    CREATE TABLE approvals (
      id TEXT PRIMARY KEY, run_id TEXT NOT NULL, task_id TEXT, capability_id TEXT NOT NULL,
      title TEXT NOT NULL, explanation TEXT NOT NULL, risk TEXT NOT NULL,
      payload TEXT NOT NULL DEFAULT '{}', status TEXT NOT NULL, created_at TEXT NOT NULL, resolved_at TEXT
    );
  ''');
  db.execute('''
    CREATE TABLE artifacts (
      id TEXT PRIMARY KEY, run_id TEXT NOT NULL, task_id TEXT, type TEXT NOT NULL, title TEXT NOT NULL,
      path TEXT, content_preview TEXT, metadata TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL
    );
  ''');
  db.execute('''
    CREATE TABLE checkpoints (
      id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_index INTEGER NOT NULL,
      state TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL
    );
  ''');
  db.execute('CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);');
  db.execute('''
    CREATE TABLE terminal_sessions (
      id TEXT PRIMARY KEY, run_id TEXT NOT NULL, task_id TEXT, command TEXT NOT NULL,
      cwd TEXT NOT NULL DEFAULT '.', status TEXT NOT NULL, exit_code INTEGER,
      truncated INTEGER NOT NULL DEFAULT 0, output_preview TEXT NOT NULL DEFAULT '',
      started_at TEXT NOT NULL, completed_at TEXT
    );
  ''');
  db.execute('''
    CREATE TABLE browser_sessions (
      id TEXT PRIMARY KEY, run_id TEXT NOT NULL, current_url TEXT, current_title TEXT,
      history TEXT NOT NULL DEFAULT '[]', download_count INTEGER NOT NULL DEFAULT 0,
      capture_count INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL
    );
  ''');
  db.execute('''
    CREATE TABLE notifications (
      id TEXT PRIMARY KEY, type TEXT NOT NULL, title TEXT NOT NULL, message TEXT NOT NULL,
      run_id TEXT, created_at TEXT NOT NULL, read INTEGER NOT NULL DEFAULT 0
    );
  ''');
  db.execute('PRAGMA user_version = 4;');

  // Seed pre-existing V4 data that must survive the migration untouched.
  db.execute(
    "INSERT INTO runs (id, title, goal, status, created_at, updated_at) VALUES ('run-v4-1', 'Pre-existing run', 'do the thing', 'completed', '2026-01-01T00:00:00.000Z', '2026-01-01T00:05:00.000Z');",
  );
  db.execute(
    "INSERT INTO notifications (id, type, title, message, created_at) VALUES ('notif-v4-1', 'runCompleted', 'Done', 'Pre-existing run completed', '2026-01-01T00:05:00.000Z');",
  );
}

void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    _ensureSqliteInitializedForTest();
    tempDir = await Directory.systemTemp.createTemp('sysai_v4v5_migration_');
    dbPath = p.join(tempDir.path, 'v4_migrated.db');

    final rawDb = sqlite3.open(dbPath);
    _createV4Database(rawDb);
    rawDb.dispose();
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('opening a real V4 database upgrades it to V5 without touching existing rows', () async {
    final repo = await RunRepository.open(dbPath);
    addTearDown(repo.close);

    // Pre-existing data survives untouched.
    final preExistingRun = await repo.getRun('run-v4-1');
    expect(preExistingRun, isNotNull);
    expect(preExistingRun!.title, 'Pre-existing run');

    final notifications = await repo.getAllNotifications();
    expect(notifications.any((n) => n.id == 'notif-v4-1'), isTrue);

    // New V5 tables are live and queryable.
    expect(await repo.getAllAutomations(), isEmpty);

    final automation = ScheduledAutomation.create(
      id: 'auto-1',
      goal: 'Inspect the workspace daily',
      workspacePath: tempDir.path,
      scheduleType: AutomationScheduleType.daily,
      scheduleExpression: {'hour': 9, 'minute': 0},
      timezone: 'UTC',
      nextTriggerAt: DateTime.utc(2026, 1, 2, 9, 0),
    );
    await repo.saveAutomation(automation);

    final fetched = await repo.getAutomation('auto-1');
    expect(fetched, isNotNull);
    expect(fetched!.goal, 'Inspect the workspace daily');
    expect(fetched.scheduleExpression['hour'], 9);

    // Duplicate-trigger claim table is live too.
    expect(await repo.claimOccurrence('auto-1', '2026-01-02T09:00:00.000Z'), isTrue);
    expect(await repo.claimOccurrence('auto-1', '2026-01-02T09:00:00.000Z'), isFalse);
  });

  test('user_version is stamped to the current schema version after migration', () async {
    final repo = await RunRepository.open(dbPath);
    addTearDown(repo.close);

    final rawDb = sqlite3.open(dbPath);
    final version = rawDb.select('PRAGMA user_version;').first.columnAt(0) as int;
    rawDb.dispose();

    expect(version, RunRepository.currentSchemaVersion);
    expect(version, 5);
  });

  test('a fresh (no prior file) database lands directly on V5 with all tables present', () async {
    final freshDir = await Directory.systemTemp.createTemp('sysai_fresh_v5_');
    addTearDown(() async {
      try {
        await freshDir.delete(recursive: true);
      } catch (_) {}
    });
    final freshPath = p.join(freshDir.path, 'fresh.db');

    final repo = await RunRepository.open(freshPath);
    addTearDown(repo.close);

    expect(await repo.getAllAutomations(), isEmpty);
    expect(await repo.getComputerSessionForRun('nonexistent'), isNull);
    expect(await repo.getComputerActionsForRun('nonexistent'), isEmpty);
  });
}

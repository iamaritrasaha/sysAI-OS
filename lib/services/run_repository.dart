import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import '../models/approval.dart';
import '../models/artifact.dart';
import '../models/browser_session.dart';
import '../models/capability.dart';
import '../models/checkpoint.dart';
import '../models/computer_action.dart';
import '../models/computer_session.dart';
import '../models/notification.dart';
import '../models/run.dart';
import '../models/scheduled_automation.dart';
import '../models/terminal_session.dart';

/// Runtime ownership helper kept as an extension so existing repository test
/// doubles do not need to implement a new interface member.
extension RunRepositoryRuntimePath on RunRepository {
  String get databasePath => _databasePath;
}

void _ensureSqliteInitialized() {
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

/// Returns the default path for the SysAI OS SQLite database.
Future<String> getDefaultDbPath() async {
  final dir = await getApplicationSupportDirectory();
  return p.join(dir.path, 'sysai_os.db');
}

/// SQLite-backed persistence layer for [Run] objects, artifacts, approvals, and checkpoints.
///
/// Handles migrations using `PRAGMA user_version`.
class RunRepository {
  RunRepository._(this._db, this._databasePath) {
    _initSchemaAndMigrate();
  }

  final Database _db;
  final String _databasePath;

  /// Schema version implemented by this repository.
  static const int currentSchemaVersion = 5;

  /// Opens (or creates) the SQLite database at [dbPath].
  static Future<RunRepository> open(String dbPath) async {
    _ensureSqliteInitialized();
    await Directory(p.dirname(dbPath)).create(recursive: true);
    final db = sqlite3.open(dbPath);
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute('PRAGMA foreign_keys=ON;');
    db.execute('PRAGMA busy_timeout=30000;');
    return RunRepository._(db, dbPath);
  }

  void _initSchemaAndMigrate() {
    final versionResult = _db.select('PRAGMA user_version;');
    final currentVersion = versionResult.first.columnAt(0) as int? ?? 0;

    if (currentVersion == 0) {
      _createAllV3Tables();
      _createV4Tables();
      _createV5Tables();
      _db.execute('PRAGMA user_version = $currentSchemaVersion;');
    } else if (currentVersion < currentSchemaVersion) {
      _migrate(currentVersion);
      _db.execute('PRAGMA user_version = $currentSchemaVersion;');
    }
  }

  void _createAllV3Tables() {
    // Runs table
    _db.execute('''
      CREATE TABLE IF NOT EXISTS runs (
        id                  TEXT    PRIMARY KEY,
        title               TEXT    NOT NULL,
        goal                TEXT    NOT NULL,
        status              TEXT    NOT NULL,
        created_at          TEXT    NOT NULL,
        updated_at          TEXT    NOT NULL,
        started_at          TEXT,
        completed_at        TEXT,
        plan                TEXT    NOT NULL DEFAULT '[]',
        events              TEXT    NOT NULL DEFAULT '[]',
        outcome             TEXT    NOT NULL DEFAULT '',
        error_message       TEXT    NOT NULL DEFAULT '',
        provider_id         TEXT,
        model_id            TEXT,
        model_display_name  TEXT
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_runs_created_at ON runs (created_at DESC);',
    );
    _db.execute('CREATE INDEX IF NOT EXISTS idx_runs_status ON runs (status);');

    // Approvals table
    _db.execute('''
      CREATE TABLE IF NOT EXISTS approvals (
        id            TEXT    PRIMARY KEY,
        run_id        TEXT    NOT NULL,
        task_id       TEXT,
        capability_id TEXT    NOT NULL,
        title         TEXT    NOT NULL,
        explanation   TEXT    NOT NULL,
        risk          TEXT    NOT NULL,
        payload       TEXT    NOT NULL DEFAULT '{}',
        status        TEXT    NOT NULL,
        created_at    TEXT    NOT NULL,
        resolved_at   TEXT,
        FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_approvals_run_id ON approvals (run_id);',
    );
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_approvals_status ON approvals (status);',
    );

    // Artifacts table
    _db.execute('''
      CREATE TABLE IF NOT EXISTS artifacts (
        id              TEXT    PRIMARY KEY,
        run_id          TEXT    NOT NULL,
        task_id         TEXT,
        type            TEXT    NOT NULL,
        title           TEXT    NOT NULL,
        path            TEXT,
        content_preview TEXT,
        metadata        TEXT    NOT NULL DEFAULT '{}',
        created_at      TEXT    NOT NULL,
        FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_artifacts_run_id ON artifacts (run_id);',
    );
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_artifacts_type ON artifacts (type);',
    );

    // Checkpoints table
    _db.execute('''
      CREATE TABLE IF NOT EXISTS checkpoints (
        id          TEXT    PRIMARY KEY,
        run_id      TEXT    NOT NULL,
        step_index  INTEGER NOT NULL,
        state       TEXT    NOT NULL DEFAULT '{}',
        created_at  TEXT    NOT NULL,
        FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_checkpoints_run_id ON checkpoints (run_id, step_index DESC);',
    );

    // Settings table
    _db.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
  }

  void _migrate(int fromVersion) {
    if (fromVersion < 2) {
      // Migrate V1 -> V2: create approvals, artifacts, checkpoints
      _db.execute('''
        CREATE TABLE IF NOT EXISTS approvals (
          id            TEXT    PRIMARY KEY,
          run_id        TEXT    NOT NULL,
          task_id       TEXT,
          capability_id TEXT    NOT NULL,
          title         TEXT    NOT NULL,
          explanation   TEXT    NOT NULL,
          risk          TEXT    NOT NULL,
          payload       TEXT    NOT NULL DEFAULT '{}',
          status        TEXT    NOT NULL,
          created_at    TEXT    NOT NULL,
          resolved_at   TEXT,
          FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE
        );
      ''');
      _db.execute(
        'CREATE INDEX IF NOT EXISTS idx_approvals_run_id ON approvals (run_id);',
      );
      _db.execute(
        'CREATE INDEX IF NOT EXISTS idx_approvals_status ON approvals (status);',
      );

      _db.execute('''
        CREATE TABLE IF NOT EXISTS artifacts (
          id              TEXT    PRIMARY KEY,
          run_id          TEXT    NOT NULL,
          task_id         TEXT,
          type            TEXT    NOT NULL,
          title           TEXT    NOT NULL,
          path            TEXT,
          content_preview TEXT,
          metadata        TEXT    NOT NULL DEFAULT '{}',
          created_at      TEXT    NOT NULL,
          FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE
        );
      ''');
      _db.execute(
        'CREATE INDEX IF NOT EXISTS idx_artifacts_run_id ON artifacts (run_id);',
      );
      _db.execute(
        'CREATE INDEX IF NOT EXISTS idx_artifacts_type ON artifacts (type);',
      );

      _db.execute('''
        CREATE TABLE IF NOT EXISTS checkpoints (
          id          TEXT    PRIMARY KEY,
          run_id      TEXT    NOT NULL,
          step_index  INTEGER NOT NULL,
          state       TEXT    NOT NULL DEFAULT '{}',
          created_at  TEXT    NOT NULL,
          FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE
        );
      ''');
      _db.execute(
        'CREATE INDEX IF NOT EXISTS idx_checkpoints_run_id ON checkpoints (run_id, step_index DESC);',
      );
    }

    if (fromVersion < 3) {
      // Migrate V2 -> V3: add settings table and model columns to runs table
      _db.execute('''
        CREATE TABLE IF NOT EXISTS settings (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
      ''');
      try {
        _db.execute('ALTER TABLE runs ADD COLUMN provider_id TEXT;');
      } catch (_) {}
      try {
        _db.execute('ALTER TABLE runs ADD COLUMN model_id TEXT;');
      } catch (_) {}
      try {
        _db.execute('ALTER TABLE runs ADD COLUMN model_display_name TEXT;');
      } catch (_) {}
    }

    if (fromVersion < 4) {
      // Migrate V3 -> V4: Phase 3 operational surfaces — terminal sessions,
      // browser sessions, and attention notifications.
      _createV4Tables();
    }

    if (fromVersion < 5) {
      // Migrate V4 -> V5: Phase 4 — scheduled automations and Controlled
      // Computer Use sessions/actions.
      _createV5Tables();
    }
  }

  void _createV4Tables() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS terminal_sessions (
        id              TEXT    PRIMARY KEY,
        run_id          TEXT    NOT NULL,
        task_id         TEXT,
        command         TEXT    NOT NULL,
        cwd             TEXT    NOT NULL DEFAULT '.',
        status          TEXT    NOT NULL,
        exit_code       INTEGER,
        truncated       INTEGER NOT NULL DEFAULT 0,
        output_preview  TEXT    NOT NULL DEFAULT '',
        started_at      TEXT    NOT NULL,
        completed_at    TEXT,
        FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_terminal_sessions_run_id ON terminal_sessions (run_id, started_at ASC);',
    );

    _db.execute('''
      CREATE TABLE IF NOT EXISTS browser_sessions (
        id              TEXT    PRIMARY KEY,
        run_id          TEXT    NOT NULL,
        current_url     TEXT,
        current_title   TEXT,
        history         TEXT    NOT NULL DEFAULT '[]',
        download_count  INTEGER NOT NULL DEFAULT 0,
        capture_count   INTEGER NOT NULL DEFAULT 0,
        updated_at      TEXT    NOT NULL,
        FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_browser_sessions_run_id ON browser_sessions (run_id);',
    );

    _db.execute('''
      CREATE TABLE IF NOT EXISTS notifications (
        id          TEXT    PRIMARY KEY,
        type        TEXT    NOT NULL,
        title       TEXT    NOT NULL,
        message     TEXT    NOT NULL,
        run_id      TEXT,
        created_at  TEXT    NOT NULL,
        read        INTEGER NOT NULL DEFAULT 0
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_notifications_created_at ON notifications (created_at DESC);',
    );
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_notifications_read ON notifications (read);',
    );
  }

  void _createV5Tables() {
    // `runs.workspace_path` — same ALTER-with-try/catch pattern the V3
    // migration used for provider_id/model_id/model_display_name: needed
    // on an upgrade (the column doesn't exist yet); a no-op failure on a
    // fresh install would also be fine, but harmless to attempt either way
    // since `_createAllV3Tables()` never defines it.
    try {
      _db.execute('ALTER TABLE runs ADD COLUMN workspace_path TEXT;');
    } catch (_) {}

    // ── Scheduled Automations (Phase 4) ──────────────────────────────────
    _db.execute('''
      CREATE TABLE IF NOT EXISTS scheduled_automations (
        id                  TEXT    PRIMARY KEY,
        title               TEXT    NOT NULL,
        goal                TEXT    NOT NULL,
        workspace_path      TEXT    NOT NULL,
        provider_id         TEXT,
        model_id            TEXT,
        model_display_name  TEXT,
        schedule_type       TEXT    NOT NULL,
        schedule_expression TEXT    NOT NULL DEFAULT '{}',
        timezone            TEXT    NOT NULL DEFAULT 'UTC',
        enabled             INTEGER NOT NULL DEFAULT 1,
        created_at          TEXT    NOT NULL,
        updated_at          TEXT    NOT NULL,
        last_triggered_at   TEXT,
        next_trigger_at     TEXT,
        last_run_id         TEXT,
        last_result         TEXT    NOT NULL DEFAULT 'none'
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_automations_next_trigger ON scheduled_automations (enabled, next_trigger_at);',
    );

    // Duplicate-trigger guard: one row per (automation, specific due
    // instant) that actually fired. The UNIQUE constraint is the atomic
    // claim — `claimOccurrence()` relies on the insert failing when an
    // occurrence has already been claimed, whether by a concurrent
    // `processDueAutomations()` pass or a prior run before a crash.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS automation_occurrences (
        automation_id   TEXT    NOT NULL,
        occurrence_key  TEXT    NOT NULL,
        run_id          TEXT,
        created_at      TEXT    NOT NULL,
        UNIQUE(automation_id, occurrence_key),
        FOREIGN KEY (automation_id) REFERENCES scheduled_automations(id) ON DELETE CASCADE
      );
    ''');

    // ── Controlled Computer Use (Phase 4) ────────────────────────────────
    _db.execute('''
      CREATE TABLE IF NOT EXISTS computer_sessions (
        id                    TEXT    PRIMARY KEY,
        run_id                TEXT    NOT NULL,
        target_id             TEXT    NOT NULL,
        target_title          TEXT    NOT NULL,
        latest_capture_path   TEXT,
        action_count          INTEGER NOT NULL DEFAULT 0,
        updated_at            TEXT    NOT NULL,
        FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_computer_sessions_run_id ON computer_sessions (run_id);',
    );

    _db.execute('''
      CREATE TABLE IF NOT EXISTS computer_actions (
        id              TEXT    PRIMARY KEY,
        session_id      TEXT,
        run_id          TEXT    NOT NULL,
        task_id         TEXT,
        type            TEXT    NOT NULL,
        target_id       TEXT    NOT NULL,
        selector        TEXT,
        coordinates     TEXT,
        text_metadata   TEXT,
        status          TEXT    NOT NULL,
        requested_at    TEXT    NOT NULL,
        started_at      TEXT,
        completed_at    TEXT,
        result          TEXT    NOT NULL DEFAULT '{}',
        failure         TEXT,
        FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_computer_actions_run_id ON computer_actions (run_id, requested_at ASC);',
    );
  }

  // ---------------------------------------------------------------------------
  // Runs
  // ---------------------------------------------------------------------------

  /// Persists [run] to the database atomically (INSERT OR REPLACE).
  Future<void> saveRun(Run run) async {
    final planJson = jsonEncode(run.plan.map((s) => s.toJson()).toList());
    final eventsJson = jsonEncode(run.events.map((e) => e.toJson()).toList());

    _db.execute(
      '''
      INSERT INTO runs (
        id, title, goal, status,
        created_at, updated_at, started_at, completed_at,
        plan, events, outcome, error_message,
        provider_id, model_id, model_display_name, workspace_path
      ) VALUES (
        ?, ?, ?, ?,
        ?, ?, ?, ?,
        ?, ?, ?, ?,
        ?, ?, ?, ?
      ) ON CONFLICT(id) DO UPDATE SET
        title = excluded.title,
        goal = excluded.goal,
        status = excluded.status,
        created_at = excluded.created_at,
        updated_at = excluded.updated_at,
        started_at = excluded.started_at,
        completed_at = excluded.completed_at,
        plan = excluded.plan,
        events = excluded.events,
        outcome = excluded.outcome,
        error_message = excluded.error_message,
        provider_id = excluded.provider_id,
        model_id = excluded.model_id,
        model_display_name = excluded.model_display_name,
        workspace_path = excluded.workspace_path;
      ''',
      [
        run.id,
        run.title,
        run.goal,
        run.status.serialized,
        run.createdAt.toIso8601String(),
        run.updatedAt.toIso8601String(),
        run.startedAt?.toIso8601String(),
        run.completedAt?.toIso8601String(),
        planJson,
        eventsJson,
        run.outcome,
        run.errorMessage,
        run.providerId,
        run.modelId,
        run.modelDisplayName,
        run.workspacePath,
      ],
    );

    // Save pending approval if present
    if (run.pendingApproval != null) {
      await saveApproval(run.pendingApproval!);
    }

    // Save artifacts if present
    for (final art in run.artifacts) {
      await saveArtifact(art);
    }
  }

  /// Permanently removes the run with [id] from the database.
  Future<void> deleteRun(String id) async {
    _db.execute('DELETE FROM runs WHERE id = ?;', [id]);
  }

  /// Returns the [Run] with [id], or `null` if it does not exist.
  Future<Run?> getRun(String id) async {
    final result = _db.select('SELECT * FROM runs WHERE id = ? LIMIT 1;', [id]);
    if (result.isEmpty) return null;

    final run = _rowToRun(result.first);
    final artifacts = await getArtifactsForRun(id);
    final pendingApproval = await _getPendingApprovalForRun(id);

    return run.copyWith(artifacts: artifacts, pendingApproval: pendingApproval);
  }

  /// Returns all persisted runs, ordered by creation time (newest first).
  Future<List<Run>> getAllRuns() async {
    final result = _db.select('SELECT * FROM runs ORDER BY created_at DESC;');
    final runs = <Run>[];
    for (final row in result) {
      final run = _rowToRun(row);
      final artifacts = await getArtifactsForRun(run.id);
      final pendingApproval = await _getPendingApprovalForRun(run.id);
      runs.add(
        run.copyWith(artifacts: artifacts, pendingApproval: pendingApproval),
      );
    }
    return runs;
  }

  /// Returns all runs whose [RunStatus] is in [statuses], newest first.
  Future<List<Run>> getRunsByStatus(List<RunStatus> statuses) async {
    if (statuses.isEmpty) return [];

    final placeholders = List.filled(statuses.length, '?').join(', ');
    final params = statuses.map((s) => s.serialized).toList();

    final result = _db.select(
      'SELECT * FROM runs WHERE status IN ($placeholders) ORDER BY created_at DESC;',
      params,
    );
    final runs = <Run>[];
    for (final row in result) {
      final run = _rowToRun(row);
      final artifacts = await getArtifactsForRun(run.id);
      final pendingApproval = await _getPendingApprovalForRun(run.id);
      runs.add(
        run.copyWith(artifacts: artifacts, pendingApproval: pendingApproval),
      );
    }
    return runs;
  }

  // ---------------------------------------------------------------------------
  // Approvals
  // ---------------------------------------------------------------------------

  Future<void> saveApproval(ApprovalRequest request) async {
    _db.execute(
      '''
      INSERT OR REPLACE INTO approvals (
        id, run_id, task_id, capability_id,
        title, explanation, risk, payload,
        status, created_at, resolved_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      [
        request.id,
        request.runId,
        request.taskId,
        request.capabilityId,
        request.title,
        request.explanation,
        request.risk.serialized,
        jsonEncode(request.payload),
        request.status.serialized,
        request.createdAt.toIso8601String(),
        request.resolvedAt?.toIso8601String(),
      ],
    );
  }

  Future<ApprovalRequest?> getApproval(String id) async {
    final rows = _db.select('SELECT * FROM approvals WHERE id = ? LIMIT 1;', [
      id,
    ]);
    if (rows.isEmpty) return null;
    return _rowToApproval(rows.first);
  }

  Future<List<ApprovalRequest>> getApprovalsForRun(String runId) async {
    final rows = _db.select(
      'SELECT * FROM approvals WHERE run_id = ? ORDER BY created_at ASC;',
      [runId],
    );
    return rows.map(_rowToApproval).toList();
  }

  Future<List<ApprovalRequest>> getPendingApprovals() async {
    final rows = _db.select(
      'SELECT * FROM approvals WHERE status = ? ORDER BY created_at ASC;',
      [ApprovalStatus.pending.serialized],
    );
    return rows.map(_rowToApproval).toList();
  }

  Future<ApprovalRequest?> _getPendingApprovalForRun(String runId) async {
    final rows = _db.select(
      'SELECT * FROM approvals WHERE run_id = ? AND status = ? LIMIT 1;',
      [runId, ApprovalStatus.pending.serialized],
    );
    if (rows.isEmpty) return null;
    return _rowToApproval(rows.first);
  }

  // ---------------------------------------------------------------------------
  // Artifacts
  // ---------------------------------------------------------------------------

  Future<void> saveArtifact(Artifact artifact) async {
    _db.execute(
      '''
      INSERT OR REPLACE INTO artifacts (
        id, run_id, task_id, type,
        title, path, content_preview, metadata, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      [
        artifact.id,
        artifact.runId,
        artifact.taskId,
        artifact.type.serialized,
        artifact.title,
        artifact.path,
        artifact.contentPreview,
        jsonEncode(artifact.metadata),
        artifact.createdAt.toIso8601String(),
      ],
    );
  }

  Future<Artifact?> getArtifact(String id) async {
    final rows = _db.select('SELECT * FROM artifacts WHERE id = ? LIMIT 1;', [
      id,
    ]);
    if (rows.isEmpty) return null;
    return _rowToArtifact(rows.first);
  }

  Future<List<Artifact>> getArtifactsForRun(String runId) async {
    final rows = _db.select(
      'SELECT * FROM artifacts WHERE run_id = ? ORDER BY created_at ASC;',
      [runId],
    );
    return rows.map(_rowToArtifact).toList();
  }

  // ---------------------------------------------------------------------------
  // Checkpoints
  // ---------------------------------------------------------------------------

  Future<void> saveCheckpoint(RunCheckpoint checkpoint) async {
    _db.execute(
      '''
      INSERT OR REPLACE INTO checkpoints (
        id, run_id, step_index, state, created_at
      ) VALUES (?, ?, ?, ?, ?);
      ''',
      [
        checkpoint.id,
        checkpoint.runId,
        checkpoint.stepIndex,
        jsonEncode(checkpoint.state),
        checkpoint.createdAt.toIso8601String(),
      ],
    );
  }

  Future<RunCheckpoint?> getLatestCheckpoint(String runId) async {
    final rows = _db.select(
      'SELECT * FROM checkpoints WHERE run_id = ? ORDER BY step_index DESC LIMIT 1;',
      [runId],
    );
    if (rows.isEmpty) return null;
    return _rowToCheckpoint(rows.first);
  }

  // ---------------------------------------------------------------------------
  // Settings (SysAI OS Preferences)
  // ---------------------------------------------------------------------------

  /// Persists a key-value setting.
  Future<void> setSetting(String key, String value) async {
    _db.execute(
      '''
      INSERT INTO settings (key, value) VALUES (?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value;
      ''',
      [key, value],
    );
  }

  /// Retrieves a persisted setting by [key], or null if not set.
  Future<String?> getSetting(String key) async {
    final rows = _db.select(
      'SELECT value FROM settings WHERE key = ? LIMIT 1;',
      [key],
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  /// Retrieves all persisted settings as a Map.
  Future<Map<String, String>> getAllSettings() async {
    final rows = _db.select('SELECT key, value FROM settings;');
    final map = <String, String>{};
    for (final row in rows) {
      map[row['key'] as String] = row['value'] as String;
    }
    return map;
  }

  // ---------------------------------------------------------------------------
  // Terminal Sessions (Phase 3)
  // ---------------------------------------------------------------------------

  /// Persists a session summary — not individual output lines. Called once
  /// when a session completes (and optionally once at creation to mark it
  /// as running), never per output line.
  Future<void> saveTerminalSession(TerminalSession session) async {
    _db.execute(
      '''
      INSERT INTO terminal_sessions (
        id, run_id, task_id, command, cwd, status, exit_code, truncated, output_preview, started_at, completed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        status = excluded.status,
        exit_code = excluded.exit_code,
        truncated = excluded.truncated,
        output_preview = excluded.output_preview,
        completed_at = excluded.completed_at;
      ''',
      [
        session.id,
        session.runId,
        session.taskId,
        session.command,
        session.cwd,
        session.status.serialized,
        session.exitCode,
        session.truncated ? 1 : 0,
        session.outputPreview,
        session.startedAt.toIso8601String(),
        session.completedAt?.toIso8601String(),
      ],
    );
  }

  Future<List<TerminalSession>> getTerminalSessionsForRun(String runId) async {
    final rows = _db.select(
      'SELECT * FROM terminal_sessions WHERE run_id = ? ORDER BY started_at ASC;',
      [runId],
    );
    return rows.map(_rowToTerminalSession).toList();
  }

  // ---------------------------------------------------------------------------
  // Browser Sessions (Phase 3)
  // ---------------------------------------------------------------------------

  /// One session per Run — upserted as browsing activity accumulates.
  Future<void> saveBrowserSession(BrowserSession session) async {
    _db.execute(
      '''
      INSERT INTO browser_sessions (
        id, run_id, current_url, current_title, history, download_count, capture_count, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        current_url = excluded.current_url,
        current_title = excluded.current_title,
        history = excluded.history,
        download_count = excluded.download_count,
        capture_count = excluded.capture_count,
        updated_at = excluded.updated_at;
      ''',
      [
        session.id,
        session.runId,
        session.currentUrl,
        session.currentTitle,
        jsonEncode(session.history.map((h) => h.toJson()).toList()),
        session.downloadCount,
        session.captureCount,
        session.updatedAt.toIso8601String(),
      ],
    );
  }

  Future<BrowserSession?> getBrowserSessionForRun(String runId) async {
    final rows = _db.select(
      'SELECT * FROM browser_sessions WHERE run_id = ? LIMIT 1;',
      [runId],
    );
    if (rows.isEmpty) return null;
    return _rowToBrowserSession(rows.first);
  }

  // ---------------------------------------------------------------------------
  // Notifications (Phase 3)
  // ---------------------------------------------------------------------------

  Future<void> saveNotification(AppNotification notification) async {
    _db.execute(
      '''
      INSERT OR REPLACE INTO notifications (id, type, title, message, run_id, created_at, read)
      VALUES (?, ?, ?, ?, ?, ?, ?);
      ''',
      [
        notification.id,
        notification.type.serialized,
        notification.title,
        notification.message,
        notification.runId,
        notification.createdAt.toIso8601String(),
        notification.read ? 1 : 0,
      ],
    );
  }

  Future<List<AppNotification>> getAllNotifications({int limit = 100}) async {
    final rows = _db.select(
      'SELECT * FROM notifications ORDER BY created_at DESC LIMIT ?;',
      [limit],
    );
    return rows.map(_rowToNotification).toList();
  }

  Future<void> markNotificationRead(String id, {bool read = true}) async {
    _db.execute('UPDATE notifications SET read = ? WHERE id = ?;', [
      read ? 1 : 0,
      id,
    ]);
  }

  // ---------------------------------------------------------------------------
  // Scheduled Automations (Phase 4)
  // ---------------------------------------------------------------------------

  Future<void> saveAutomation(ScheduledAutomation automation) async {
    _db.execute(
      '''
      INSERT INTO scheduled_automations (
        id, title, goal, workspace_path, provider_id, model_id, model_display_name,
        schedule_type, schedule_expression, timezone,
        enabled, created_at, updated_at, last_triggered_at, next_trigger_at,
        last_run_id, last_result
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        title = excluded.title,
        goal = excluded.goal,
        workspace_path = excluded.workspace_path,
        provider_id = excluded.provider_id,
        model_id = excluded.model_id,
        model_display_name = excluded.model_display_name,
        schedule_type = excluded.schedule_type,
        schedule_expression = excluded.schedule_expression,
        timezone = excluded.timezone,
        enabled = excluded.enabled,
        updated_at = excluded.updated_at,
        last_triggered_at = excluded.last_triggered_at,
        next_trigger_at = excluded.next_trigger_at,
        last_run_id = excluded.last_run_id,
        last_result = excluded.last_result;
      ''',
      [
        automation.id,
        automation.title,
        automation.goal,
        automation.workspacePath,
        automation.providerId,
        automation.modelId,
        automation.modelDisplayName,
        automation.scheduleType.serialized,
        jsonEncode(automation.scheduleExpression),
        automation.timezone,
        automation.enabled ? 1 : 0,
        automation.createdAt.toIso8601String(),
        automation.updatedAt.toIso8601String(),
        automation.lastTriggeredAt?.toIso8601String(),
        automation.nextTriggerAt?.toIso8601String(),
        automation.lastRunId,
        automation.lastResult.serialized,
      ],
    );
  }

  Future<ScheduledAutomation?> getAutomation(String id) async {
    final rows = _db.select(
      'SELECT * FROM scheduled_automations WHERE id = ? LIMIT 1;',
      [id],
    );
    if (rows.isEmpty) return null;
    return _rowToAutomation(rows.first);
  }

  Future<List<ScheduledAutomation>> getAllAutomations() async {
    final rows = _db.select(
      'SELECT * FROM scheduled_automations ORDER BY created_at DESC;',
    );
    return rows.map(_rowToAutomation).toList();
  }

  /// Automations that are enabled and due at or before [nowUtc].
  Future<List<ScheduledAutomation>> getDueAutomations(DateTime nowUtc) async {
    final rows = _db.select(
      'SELECT * FROM scheduled_automations WHERE enabled = 1 AND next_trigger_at IS NOT NULL AND next_trigger_at <= ? ORDER BY next_trigger_at ASC;',
      [nowUtc.toUtc().toIso8601String()],
    );
    return rows.map(_rowToAutomation).toList();
  }

  Future<void> deleteAutomation(String id) async {
    _db.execute('DELETE FROM scheduled_automations WHERE id = ?;', [id]);
  }

  /// Atomically claims one occurrence of [automationId] due at
  /// [occurrenceKey] (the ISO8601 UTC instant that was due). Returns `true`
  /// if this call won the claim (the occurrence had not been recorded
  /// before) and `false` if it had already been claimed — by a concurrent
  /// `processDueAutomations()` pass, or a previous process before a crash.
  /// This is the entire duplicate-trigger guard: the `UNIQUE` constraint on
  /// `automation_occurrences` makes the insert itself the atomic check.
  Future<bool> claimOccurrence(
    String automationId,
    String occurrenceKey, {
    String? runId,
  }) async {
    try {
      _db.execute(
        'INSERT INTO automation_occurrences (automation_id, occurrence_key, run_id, created_at) VALUES (?, ?, ?, ?);',
        [
          automationId,
          occurrenceKey,
          runId,
          DateTime.now().toUtc().toIso8601String(),
        ],
      );
      return true;
    } on SqliteException catch (e) {
      // SQLite reports a UNIQUE violation as a specific extended result
      // code (2067 = SQLITE_CONSTRAINT_UNIQUE) — anything else is a real
      // error and should propagate rather than being swallowed as "lost
      // the claim".
      if (e.extendedResultCode == 2067) return false;
      rethrow;
    }
  }

  /// Records which Run a previously-claimed occurrence actually produced.
  /// `claimOccurrence()` reserves the row before the Run exists (that
  /// ordering is what makes the claim race-safe); this fills in `run_id`
  /// once Run creation has actually succeeded.
  Future<void> linkOccurrenceRun(
    String automationId,
    String occurrenceKey,
    String runId,
  ) async {
    _db.execute(
      'UPDATE automation_occurrences SET run_id = ? WHERE automation_id = ? AND occurrence_key = ?;',
      [runId, automationId, occurrenceKey],
    );
  }

  /// Runs created by firing [automationId], newest first — the automation
  /// detail view's "past executions" list. Deliberately just a filtered
  /// view over the normal `runs` table, not a parallel history system.
  Future<List<Run>> getRunsCreatedByAutomation(String automationId) async {
    final occRows = _db.select(
      'SELECT run_id FROM automation_occurrences WHERE automation_id = ? AND run_id IS NOT NULL ORDER BY created_at DESC;',
      [automationId],
    );
    final runIds = occRows.map((r) => r['run_id'] as String).toList();
    if (runIds.isEmpty) return [];
    final placeholders = List.filled(runIds.length, '?').join(', ');
    final rows = _db.select(
      'SELECT * FROM runs WHERE id IN ($placeholders) ORDER BY created_at DESC;',
      runIds,
    );
    return rows.map(_rowToRun).toList();
  }

  ScheduledAutomation _rowToAutomation(Row row) {
    Map<String, dynamic> expr = const {};
    final exprRaw = row['schedule_expression'] as String?;
    if (exprRaw != null && exprRaw.isNotEmpty) {
      try {
        expr = jsonDecode(exprRaw) as Map<String, dynamic>;
      } catch (_) {}
    }
    return ScheduledAutomation(
      id: row['id'] as String,
      title: row['title'] as String,
      goal: row['goal'] as String,
      workspacePath: row['workspace_path'] as String,
      providerId: row['provider_id'] as String?,
      modelId: row['model_id'] as String?,
      modelDisplayName: row['model_display_name'] as String?,
      scheduleType: AutomationScheduleType.fromString(
        row['schedule_type'] as String?,
      ),
      scheduleExpression: expr,
      timezone: row['timezone'] as String? ?? 'UTC',
      enabled: (row['enabled'] as int? ?? 1) != 0,
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
      lastTriggeredAt: row['last_triggered_at'] != null
          ? DateTime.tryParse(row['last_triggered_at'] as String)?.toUtc()
          : null,
      nextTriggerAt: row['next_trigger_at'] != null
          ? DateTime.tryParse(row['next_trigger_at'] as String)?.toUtc()
          : null,
      lastRunId: row['last_run_id'] as String?,
      lastResult: AutomationResult.fromString(row['last_result'] as String?),
    );
  }

  // ---------------------------------------------------------------------------
  // Controlled Computer Use (Phase 4)
  // ---------------------------------------------------------------------------

  Future<void> saveComputerSession(ComputerSession session) async {
    _db.execute(
      '''
      INSERT INTO computer_sessions (
        id, run_id, target_id, target_title, latest_capture_path, action_count, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        latest_capture_path = excluded.latest_capture_path,
        action_count = excluded.action_count,
        updated_at = excluded.updated_at;
      ''',
      [
        session.id,
        session.runId,
        session.targetId,
        session.targetTitle,
        session.latestCapturePath,
        session.actionCount,
        session.updatedAt.toIso8601String(),
      ],
    );
  }

  Future<ComputerSession?> getComputerSessionForRun(String runId) async {
    final rows = _db.select(
      'SELECT * FROM computer_sessions WHERE run_id = ? LIMIT 1;',
      [runId],
    );
    if (rows.isEmpty) return null;
    return _rowToComputerSession(rows.first);
  }

  Future<void> saveComputerAction(ComputerAction action) async {
    _db.execute(
      '''
      INSERT INTO computer_actions (
        id, session_id, run_id, task_id, type, target_id, selector, coordinates,
        text_metadata, status, requested_at, started_at, completed_at, result, failure
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        status = excluded.status,
        started_at = excluded.started_at,
        completed_at = excluded.completed_at,
        result = excluded.result,
        failure = excluded.failure;
      ''',
      [
        action.id,
        action.sessionId,
        action.runId,
        action.taskId,
        action.type.serialized,
        action.targetId,
        action.selector,
        action.coordinates != null ? jsonEncode(action.coordinates) : null,
        action.textMetadata,
        action.status.serialized,
        action.requestedAt.toIso8601String(),
        action.startedAt?.toIso8601String(),
        action.completedAt?.toIso8601String(),
        jsonEncode(action.result),
        action.failure,
      ],
    );
  }

  Future<List<ComputerAction>> getComputerActionsForRun(String runId) async {
    final rows = _db.select(
      'SELECT * FROM computer_actions WHERE run_id = ? ORDER BY requested_at ASC;',
      [runId],
    );
    return rows.map(_rowToComputerAction).toList();
  }

  ComputerSession _rowToComputerSession(Row row) => ComputerSession(
    id: row['id'] as String,
    runId: row['run_id'] as String,
    targetId: row['target_id'] as String,
    targetTitle: row['target_title'] as String,
    latestCapturePath: row['latest_capture_path'] as String?,
    actionCount: row['action_count'] as int? ?? 0,
    updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
  );

  ComputerAction _rowToComputerAction(Row row) {
    Map<String, dynamic>? coordinates;
    final coordRaw = row['coordinates'] as String?;
    if (coordRaw != null && coordRaw.isNotEmpty) {
      try {
        coordinates = jsonDecode(coordRaw) as Map<String, dynamic>;
      } catch (_) {}
    }
    Map<String, dynamic> result = const {};
    final resultRaw = row['result'] as String?;
    if (resultRaw != null && resultRaw.isNotEmpty) {
      try {
        result = jsonDecode(resultRaw) as Map<String, dynamic>;
      } catch (_) {}
    }
    return ComputerAction(
      id: row['id'] as String,
      sessionId: row['session_id'] as String?,
      runId: row['run_id'] as String,
      taskId: row['task_id'] as String?,
      type: ComputerActionType.fromString(row['type'] as String?),
      targetId: row['target_id'] as String,
      selector: row['selector'] as String?,
      coordinates: coordinates,
      textMetadata: row['text_metadata'] as String?,
      status: ComputerActionStatus.fromString(row['status'] as String?),
      requestedAt: DateTime.parse(row['requested_at'] as String).toUtc(),
      startedAt: row['started_at'] != null
          ? DateTime.tryParse(row['started_at'] as String)?.toUtc()
          : null,
      completedAt: row['completed_at'] != null
          ? DateTime.tryParse(row['completed_at'] as String)?.toUtc()
          : null,
      result: result,
      failure: row['failure'] as String?,
    );
  }

  // ---------------------------------------------------------------------------
  // Startup Interruption Recovery
  // ---------------------------------------------------------------------------

  /// Scans for runs left in an incomplete/non-terminal active state
  /// (e.g. from an app crash or abrupt termination) and transitions them
  /// to [RunStatus.interrupted].
  Future<List<Run>> recoverInterruptedRuns() async {
    final activeStatuses = [
      RunStatus.running.serialized,
      RunStatus.planning.serialized,
      RunStatus.waitingApproval.serialized,
      'waitingApproval',
      RunStatus.ready.serialized,
      RunStatus.verifying.serialized,
    ];
    final placeholders = List.filled(activeStatuses.length, '?').join(', ');
    final rows = _db.select(
      'SELECT * FROM runs WHERE status IN ($placeholders);',
      activeStatuses,
    );

    final recovered = <Run>[];
    final now = DateTime.now();

    for (final row in rows) {
      final run = _rowToRun(row);
      final interruptionEvent = RunEvent(
        type: 'run.interrupted',
        timestamp: now,
        message: 'Run was unexpectedly interrupted (app crash or termination). Ready to resume from checkpoint.',
      );

      final updated = run.copyWith(
        status: RunStatus.interrupted,
        updatedAt: now,
        events: [...run.events, interruptionEvent],
      );

      await saveRun(updated);
      recovered.add(updated);
    }

    return recovered;
  }

  /// Closes the underlying SQLite connection.
  void close() {
    _db.dispose();
  }

  // ---------------------------------------------------------------------------
  // Row mappers
  // ---------------------------------------------------------------------------

  Run _rowToRun(Row row) {
    List<RunTask> plan = const [];
    List<RunEvent> events = const [];

    final planRaw = row['plan'] as String?;
    if (planRaw != null && planRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(planRaw) as List<dynamic>;
        plan = decoded
            .map((s) => RunTask.fromJson(s as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }

    final eventsRaw = row['events'] as String?;
    if (eventsRaw != null && eventsRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(eventsRaw) as List<dynamic>;
        events = decoded
            .map((e) => RunEvent.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }

    return Run(
      id: row['id'] as String,
      title: row['title'] as String,
      goal: row['goal'] as String,
      status: RunStatus.fromString(row['status'] as String),
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
      startedAt: row['started_at'] != null
          ? DateTime.tryParse(row['started_at'] as String)
          : null,
      completedAt: row['completed_at'] != null
          ? DateTime.tryParse(row['completed_at'] as String)
          : null,
      plan: plan,
      events: events,
      outcome: row['outcome'] as String? ?? '',
      errorMessage: row['error_message'] as String? ?? '',
      providerId: row['provider_id'] as String?,
      modelId: row['model_id'] as String?,
      modelDisplayName: row['model_display_name'] as String?,
      workspacePath: row['workspace_path'] as String?,
    );
  }

  ApprovalRequest _rowToApproval(Row row) {
    Map<String, dynamic> payload = const {};
    final payloadRaw = row['payload'] as String?;
    if (payloadRaw != null && payloadRaw.isNotEmpty) {
      try {
        payload = jsonDecode(payloadRaw) as Map<String, dynamic>;
      } catch (_) {}
    }

    return ApprovalRequest(
      id: row['id'] as String,
      runId: row['run_id'] as String,
      taskId: row['task_id'] as String?,
      capabilityId: row['capability_id'] as String,
      title: row['title'] as String,
      explanation: row['explanation'] as String,
      risk: CapabilityRisk.fromString(row['risk'] as String?),
      payload: payload,
      status: ApprovalStatus.fromString(row['status'] as String?),
      createdAt: DateTime.parse(row['created_at'] as String),
      resolvedAt: row['resolved_at'] != null
          ? DateTime.tryParse(row['resolved_at'] as String)
          : null,
    );
  }

  Artifact _rowToArtifact(Row row) {
    Map<String, dynamic> metadata = const {};
    final metaRaw = row['metadata'] as String?;
    if (metaRaw != null && metaRaw.isNotEmpty) {
      try {
        metadata = jsonDecode(metaRaw) as Map<String, dynamic>;
      } catch (_) {}
    }

    return Artifact(
      id: row['id'] as String,
      runId: row['run_id'] as String,
      taskId: row['task_id'] as String?,
      type: ArtifactType.fromString(row['type'] as String?),
      title: row['title'] as String,
      path: row['path'] as String?,
      contentPreview: row['content_preview'] as String?,
      metadata: metadata,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  RunCheckpoint _rowToCheckpoint(Row row) {
    Map<String, dynamic> state = const {};
    final stateRaw = row['state'] as String?;
    if (stateRaw != null && stateRaw.isNotEmpty) {
      try {
        state = jsonDecode(stateRaw) as Map<String, dynamic>;
      } catch (_) {}
    }

    return RunCheckpoint(
      id: row['id'] as String,
      runId: row['run_id'] as String,
      stepIndex: row['step_index'] as int? ?? 0,
      state: state,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  TerminalSession _rowToTerminalSession(Row row) {
    return TerminalSession(
      id: row['id'] as String,
      runId: row['run_id'] as String,
      taskId: row['task_id'] as String?,
      command: row['command'] as String,
      cwd: row['cwd'] as String? ?? '.',
      status: TerminalSessionStatus.fromString(row['status'] as String),
      exitCode: row['exit_code'] as int?,
      truncated: (row['truncated'] as int? ?? 0) != 0,
      outputPreview: row['output_preview'] as String? ?? '',
      startedAt: DateTime.parse(row['started_at'] as String),
      completedAt: row['completed_at'] != null
          ? DateTime.tryParse(row['completed_at'] as String)
          : null,
    );
  }

  BrowserSession _rowToBrowserSession(Row row) {
    List<BrowserNavigationEntry> history = const [];
    final historyRaw = row['history'] as String?;
    if (historyRaw != null && historyRaw.isNotEmpty) {
      try {
        history = (jsonDecode(historyRaw) as List<dynamic>)
            .map(
              (h) => BrowserNavigationEntry.fromJson(h as Map<String, dynamic>),
            )
            .toList();
      } catch (_) {}
    }
    return BrowserSession(
      id: row['id'] as String,
      runId: row['run_id'] as String,
      currentUrl: row['current_url'] as String?,
      currentTitle: row['current_title'] as String?,
      history: history,
      downloadCount: row['download_count'] as int? ?? 0,
      captureCount: row['capture_count'] as int? ?? 0,
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  AppNotification _rowToNotification(Row row) {
    return AppNotification(
      id: row['id'] as String,
      type: NotificationType.fromString(row['type'] as String),
      title: row['title'] as String,
      message: row['message'] as String,
      runId: row['run_id'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
      read: (row['read'] as int? ?? 0) != 0,
    );
  }
}

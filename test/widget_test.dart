import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sysai/main.dart';
import 'package:sysai/models/approval.dart';
import 'package:sysai/models/artifact.dart';
import 'package:sysai/models/browser_session.dart';
import 'package:sysai/models/checkpoint.dart';
import 'package:sysai/models/computer_action.dart';
import 'package:sysai/models/computer_session.dart';
import 'package:sysai/models/notification.dart';
import 'package:sysai/models/run.dart';
import 'package:sysai/models/scheduled_automation.dart';
import 'package:sysai/models/terminal_session.dart';
import 'package:sysai/providers/app_providers.dart';
import 'package:sysai/services/bridge_service.dart';
import 'package:sysai/services/run_repository.dart';

/// Fake repository for widget testing
class _TestRunRepository implements RunRepository {
  final List<Run> _runs = [];
  final List<ApprovalRequest> _approvals = [];
  final List<Artifact> _artifacts = [];
  final List<RunCheckpoint> _checkpoints = [];

  @override
  Future<void> saveRun(Run run) async {
    _runs.removeWhere((r) => r.id == run.id);
    _runs.insert(0, run);
  }

  @override
  Future<Run?> getRun(String id) async {
    try {
      return _runs.firstWhere((r) => r.id == id);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<Run>> getAllRuns() async => List.unmodifiable(_runs);

  @override
  Future<List<Run>> getRunsByStatus(List<RunStatus> statuses) async {
    return _runs.where((r) => statuses.contains(r.status)).toList();
  }

  @override
  Future<void> deleteRun(String id) async {
    _runs.removeWhere((r) => r.id == id);
  }

  @override
  Future<void> saveApproval(ApprovalRequest request) async {
    _approvals.removeWhere((a) => a.id == request.id);
    _approvals.add(request);
  }

  @override
  Future<ApprovalRequest?> getApproval(String id) async {
    try {
      return _approvals.firstWhere((a) => a.id == id);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<ApprovalRequest>> getApprovalsForRun(String runId) async {
    return _approvals.where((a) => a.runId == runId).toList();
  }

  @override
  Future<List<ApprovalRequest>> getPendingApprovals() async {
    return _approvals.where((a) => a.isPending).toList();
  }

  @override
  Future<void> saveArtifact(Artifact artifact) async {
    _artifacts.removeWhere((a) => a.id == artifact.id);
    _artifacts.add(artifact);
  }

  @override
  Future<Artifact?> getArtifact(String id) async {
    try {
      return _artifacts.firstWhere((a) => a.id == id);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<Artifact>> getArtifactsForRun(String runId) async {
    return _artifacts.where((a) => a.runId == runId).toList();
  }

  @override
  Future<void> saveCheckpoint(RunCheckpoint checkpoint) async {
    _checkpoints.removeWhere((c) => c.id == checkpoint.id);
    _checkpoints.add(checkpoint);
  }

  @override
  Future<RunCheckpoint?> getLatestCheckpoint(String runId) async {
    try {
      return _checkpoints.where((c) => c.runId == runId).last;
    } catch (_) {
      return null;
    }
  }

  final Map<String, String> _settings = {};

  @override
  Future<void> setSetting(String key, String value) async {
    _settings[key] = value;
  }

  @override
  Future<String?> getSetting(String key) async => _settings[key];

  @override
  Future<Map<String, String>> getAllSettings() async => Map.unmodifiable(_settings);

  @override
  Future<List<Run>> recoverInterruptedRuns() async => [];

  final List<TerminalSession> _terminalSessions = [];

  @override
  Future<void> saveTerminalSession(TerminalSession session) async {
    _terminalSessions.removeWhere((s) => s.id == session.id);
    _terminalSessions.add(session);
  }

  @override
  Future<List<TerminalSession>> getTerminalSessionsForRun(String runId) async =>
      _terminalSessions.where((s) => s.runId == runId).toList();

  final Map<String, BrowserSession> _browserSessions = {};

  @override
  Future<void> saveBrowserSession(BrowserSession session) async {
    _browserSessions[session.runId] = session;
  }

  @override
  Future<BrowserSession?> getBrowserSessionForRun(String runId) async => _browserSessions[runId];

  final List<AppNotification> _notifications = [];

  @override
  Future<void> saveNotification(AppNotification notification) async {
    _notifications.removeWhere((n) => n.id == notification.id);
    _notifications.add(notification);
  }

  @override
  Future<List<AppNotification>> getAllNotifications({int limit = 100}) async =>
      _notifications.reversed.take(limit).toList();

  @override
  Future<void> markNotificationRead(String id, {bool read = true}) async {
    final index = _notifications.indexWhere((n) => n.id == id);
    if (index != -1) {
      _notifications[index] = _notifications[index].copyWith(read: read);
    }
  }

  @override
  void close() {}

  final Map<String, ScheduledAutomation> _automations = {};
  final List<Map<String, String?>> _occurrences = [];

  @override
  Future<void> saveAutomation(ScheduledAutomation automation) async {
    _automations[automation.id] = automation;
  }

  @override
  Future<ScheduledAutomation?> getAutomation(String id) async => _automations[id];

  @override
  Future<List<ScheduledAutomation>> getAllAutomations() async => _automations.values.toList();

  @override
  Future<List<ScheduledAutomation>> getDueAutomations(DateTime nowUtc) async => _automations.values
      .where((a) => a.enabled && a.nextTriggerAt != null && !a.nextTriggerAt!.isAfter(nowUtc))
      .toList();

  @override
  Future<void> deleteAutomation(String id) async => _automations.remove(id);

  @override
  Future<bool> claimOccurrence(String automationId, String occurrenceKey, {String? runId}) async {
    final exists = _occurrences.any(
      (o) => o['automation_id'] == automationId && o['occurrence_key'] == occurrenceKey,
    );
    if (exists) return false;
    _occurrences.add({'automation_id': automationId, 'occurrence_key': occurrenceKey, 'run_id': runId});
    return true;
  }

  @override
  Future<void> linkOccurrenceRun(String automationId, String occurrenceKey, String runId) async {
    for (final o in _occurrences) {
      if (o['automation_id'] == automationId && o['occurrence_key'] == occurrenceKey) {
        o['run_id'] = runId;
      }
    }
  }

  @override
  Future<List<Run>> getRunsCreatedByAutomation(String automationId) async {
    final runIds = _occurrences
        .where((o) => o['automation_id'] == automationId && o['run_id'] != null)
        .map((o) => o['run_id']!)
        .toSet();
    return _runs.where((r) => runIds.contains(r.id)).toList();
  }

  final Map<String, ComputerSession> _computerSessions = {};
  final List<ComputerAction> _computerActions = [];

  @override
  Future<void> saveComputerSession(ComputerSession session) async {
    _computerSessions[session.runId] = session;
  }

  @override
  Future<ComputerSession?> getComputerSessionForRun(String runId) async => _computerSessions[runId];

  @override
  Future<void> saveComputerAction(ComputerAction action) async {
    _computerActions.removeWhere((a) => a.id == action.id);
    _computerActions.add(action);
  }

  @override
  Future<List<ComputerAction>> getComputerActionsForRun(String runId) async =>
      _computerActions.where((a) => a.runId == runId).toList();
}

class _TestBridgeNotifier extends BridgeNotifier {
  @override
  Future<BridgeStatus> build() async => BridgeStatus.connected;
}

void main() {
  testWidgets('renders SysAI OS desktop shell with navigation and command center',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final testRepo = _TestRunRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          runRepositoryProvider.overrideWith((ref) async => testRepo),
          bridgeStatusProvider.overrideWith(_TestBridgeNotifier.new),
        ],
        child: const SysAIApp(),
      ),
    );

    await tester.pumpAndSettle();

    // Verify Branding
    expect(find.text('SysAI'), findsOneWidget);
    expect(find.text('AGENTIC OS'), findsOneWidget);

    // Verify Sidebar Navigation
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Runs'), findsOneWidget);
    expect(find.text('Workspace'), findsOneWidget);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Experience'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);

    // Verify Command Center contents
    expect(find.text('Command Center'), findsOneWidget);
    expect(find.text('What do you want SysAI to accomplish?'), findsOneWidget);
    expect(find.text('Execute Goal'), findsOneWidget);

    // Verify the engine status line replaced the old metric-card dashboard
    expect(find.text('No active Runs'), findsOneWidget);
    expect(find.textContaining('learned records'), findsOneWidget);
  });

  testWidgets('navigates to Runs, Workspace, Experience, and System views',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final testRepo = _TestRunRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          runRepositoryProvider.overrideWith((ref) async => testRepo),
          bridgeStatusProvider.overrideWith(_TestBridgeNotifier.new),
        ],
        child: const SysAIApp(),
      ),
    );

    await tester.pumpAndSettle();

    // Tap Runs
    await tester.tap(find.text('Runs'));
    await tester.pumpAndSettle();
    expect(find.text('Persisted execution records from SysAI OS runtime'),
        findsOneWidget);

    // Tap Workspace
    await tester.tap(find.text('Workspace'));
    await tester.pumpAndSettle();
    expect(find.text('REPOSITORY ROOT'), findsOneWidget);

    // Tap Activity
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(find.text('Structured events across every Run, newest first'),
        findsOneWidget);

    // Tap Experience
    await tester.tap(find.text('Experience'));
    await tester.pumpAndSettle();
    expect(find.text('Experience'), findsWidgets);

    // Tap System
    await tester.tap(find.text('System').last);
    await tester.pumpAndSettle();
    expect(find.text('Models, engine health, capabilities, and storage'), findsOneWidget);
  });

  testWidgets('navigates to Automations and Computer (Phase 4) without crashing',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final testRepo = _TestRunRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          runRepositoryProvider.overrideWith((ref) async => testRepo),
          bridgeStatusProvider.overrideWith(_TestBridgeNotifier.new),
        ],
        child: const SysAIApp(),
      ),
    );

    await tester.pumpAndSettle();

    // Tap Automations
    await tester.tap(find.text('Automations'));
    await tester.pumpAndSettle();
    expect(find.text('Scheduled goals that create a normal Run when due'), findsOneWidget);
    expect(find.text('New Automation'), findsOneWidget);
    expect(find.textContaining('No automations yet'), findsOneWidget);

    // Open and cancel the automation editor — proves the dialog builds and
    // tears down cleanly, without actually creating one.
    await tester.tap(find.text('New Automation'));
    await tester.pumpAndSettle();
    expect(find.text('New Automation'), findsWidgets);
    expect(find.text('GOAL'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Tap Computer
    await tester.tap(find.text('Computer'));
    await tester.pumpAndSettle();
    expect(find.text('Controlled Computer Use — real actions against a SysAI-owned test surface only'), findsOneWidget);
    expect(find.text('SysAI OS Test Surface'), findsOneWidget);

    // The test surface is real and interactive: typing and submitting
    // actually mutate TestSurfaceController's shared state.
    await tester.enterText(find.byType(TextField).first, 'hello from the widget test');
    await tester.pumpAndSettle();
    await tester.tap(find.text('submit_button'));
    await tester.pumpAndSettle();
    expect(find.textContaining('submitted'), findsOneWidget);
  });
}

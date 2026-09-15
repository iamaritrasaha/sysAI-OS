/// Riverpod providers for the SysAI OS application state.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/sysai_config.dart';
import '../models/approval.dart';
import '../models/artifact.dart';
import '../models/browser_session.dart';
import '../models/capability.dart';
import '../models/checkpoint.dart';
import '../models/computer_action.dart';
import '../models/computer_session.dart';
import '../models/computer_target.dart';
import '../models/model_info.dart';
import '../models/notification.dart';
import '../models/run.dart';
import '../models/terminal_session.dart';
import '../services/bridge_service.dart';
import '../services/notification_service.dart';
import '../services/run_repository.dart';
import '../services/test_surface_controller.dart';
import '../services/view_capture_service.dart';

const _kSettingDefaultProviderId = 'default_provider_id';
const _kSettingDefaultModelId = 'default_model_id';
const _kSettingDefaultModelDisplayName = 'default_model_display_name';

// ── Bridge Provider ───────────────────────────────────────────────────────────

/// Global singleton bridge service.
final bridgeServiceProvider = Provider<BridgeService>((ref) {
  final service = BridgeService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Async notifier that starts the bridge and tracks its status.
class BridgeNotifier extends AsyncNotifier<BridgeStatus> {
  @override
  Future<BridgeStatus> build() async {
    final bridge = ref.watch(bridgeServiceProvider);
    final sysaiPath = SysAIConfig.discoverSysAIPathSync();
    final bridgeScript = SysAIConfig.getBridgeScriptPath();

    // Listen to status changes
    bridge.statusChanges.listen((_) {
      if (!state.isLoading) {
        state = AsyncValue.data(bridge.status);
      }
      if (bridge.status == BridgeStatus.connected) {
        unawaited(_restoreRuntimeState());
      }
    });

    String? databasePath;
    try {
      databasePath = await getDefaultDbPath();
    } catch (_) {
      // Pure ProviderContainer tests do not install ServicesBinding. The
      // runtime has a portable per-user default when path_provider is absent.
    }
    await bridge.start(bridgeScript, sysaiPath, databasePath: databasePath);
    return bridge.status;
  }

  Future<void> retry() async {
    state = const AsyncValue.loading();
    final bridge = ref.read(bridgeServiceProvider);
    await bridge.stop();
    state = await AsyncValue.guard(() async {
      final sysaiPath = SysAIConfig.discoverSysAIPathSync();
      final bridgeScript = SysAIConfig.getBridgeScriptPath();
      String? databasePath;
      try {
        databasePath = await getDefaultDbPath();
      } catch (_) {}
      await bridge.start(bridgeScript, sysaiPath, databasePath: databasePath);
      return bridge.status;
    });
  }

  Future<void> _restoreRuntimeState() async {
    try {
      await ref.read(runListProvider.notifier).refreshFromRuntime();
      await ref.read(runExecutorProvider).reconnectActiveRuns();
    } catch (_) {
      // A reconnect race is expected while the runtime is restarting.
    }
  }
}

final bridgeStatusProvider =
    AsyncNotifierProvider<BridgeNotifier, BridgeStatus>(BridgeNotifier.new);

// ── Capabilities Provider ─────────────────────────────────────────────────────

/// Registered capabilities exposed by the bridge.
final capabilitiesProvider = FutureProvider<List<Capability>>((ref) async {
  await ref.watch(bridgeStatusProvider.future);
  final bridge = ref.read(bridgeServiceProvider);
  if (!bridge.isReady) return [];
  try {
    return await bridge.listCapabilities();
  } catch (_) {
    return [];
  }
});

/// Compact service-health snapshot. It is deliberately separate from the
/// engine doctor result: the runtime can be healthy even when SysAI itself is
/// unavailable, and vice versa.
final runtimeStatusProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  await ref.watch(bridgeStatusProvider.future);
  final bridge = ref.read(bridgeServiceProvider);
  if (!bridge.isReady) return {};
  try {
    return await bridge.runtimeStatus();
  } catch (_) {
    return {};
  }
});

// ── Repository Provider ───────────────────────────────────────────────────────

final runRepositoryProvider = FutureProvider<RunRepository>((ref) async {
  final dbPath = await getDefaultDbPath();
  final repo = await RunRepository.open(dbPath);
  ref.onDispose(repo.close);
  return repo;
});

// ── System Status Provider ────────────────────────────────────────────────────

/// Holds the latest system status from SysAI doctor.
class SystemStatusNotifier extends AsyncNotifier<Map<String, dynamic>> {
  @override
  Future<Map<String, dynamic>> build() async {
    // Wait for bridge to be ready
    await ref.watch(bridgeStatusProvider.future);
    return _fetchStatus();
  }

  Future<Map<String, dynamic>> _fetchStatus() async {
    final bridge = ref.read(bridgeServiceProvider);
    if (!bridge.sysaiAvailable) {
      return {
        'available': false,
        'error': 'SysAI engine not available',
        'sysai_path': bridge.sysaiPath,
      };
    }
    try {
      final result = await bridge.call(
        'get_doctor',
        params: {'probe_model': false},
      );
      return {'available': true, ...result};
    } on BridgeException catch (e) {
      return {'available': false, 'error': e.message};
    }
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_fetchStatus);
  }
}

final systemStatusProvider =
    AsyncNotifierProvider<SystemStatusNotifier, Map<String, dynamic>>(
      SystemStatusNotifier.new,
    );

/// Provider for SysAI configuration.
final sysaiConfigProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  await ref.watch(bridgeStatusProvider.future);
  final bridge = ref.read(bridgeServiceProvider);
  if (!bridge.sysaiAvailable) return {};
  try {
    return await bridge.call('get_config');
  } catch (_) {
    return {};
  }
});

// ── Model & Provider Discovery ────────────────────────────────────────────────

/// Providers discovered live from the SysAI installation (Ollama local,
/// Ollama Cloud, remote Ollama, OpenAI-compatible). Never fabricated —
/// availability reflects what the bridge actually observed.
final providersListProvider = FutureProvider<List<ProviderInfo>>((ref) async {
  await ref.watch(bridgeStatusProvider.future);
  final bridge = ref.read(bridgeServiceProvider);
  if (!bridge.sysaiAvailable) return [];
  try {
    return await bridge.listProviders();
  } catch (_) {
    return [];
  }
});

/// Models discovered live from the SysAI installation across all providers.
final modelsListProvider = FutureProvider<List<ModelInfo>>((ref) async {
  await ref.watch(bridgeStatusProvider.future);
  final bridge = ref.read(bridgeServiceProvider);
  if (!bridge.sysaiAvailable) return [];
  try {
    return await bridge.listModels();
  } catch (_) {
    return [];
  }
});

/// SysAI OS's own persisted default model, independent of any single Run.
/// Changing this affects only Runs created *after* the change — it never
/// mutates a Run that already exists.
class DefaultModelNotifier extends AsyncNotifier<DefaultModelSelection> {
  @override
  Future<DefaultModelSelection> build() async {
    final repo = await ref.watch(runRepositoryProvider.future);
    final settings = await repo.getAllSettings();
    return DefaultModelSelection(
      providerId: settings[_kSettingDefaultProviderId],
      modelId: settings[_kSettingDefaultModelId],
      modelDisplayName: settings[_kSettingDefaultModelDisplayName],
    );
  }

  /// Persists a new default. Does not touch any existing Run.
  Future<void> setDefault({
    required String providerId,
    required String modelId,
    String? modelDisplayName,
  }) async {
    final repo = await ref.read(runRepositoryProvider.future);
    await repo.setSetting(_kSettingDefaultProviderId, providerId);
    await repo.setSetting(_kSettingDefaultModelId, modelId);
    if (modelDisplayName != null) {
      await repo.setSetting(_kSettingDefaultModelDisplayName, modelDisplayName);
    }
    state = AsyncValue.data(
      DefaultModelSelection(
        providerId: providerId,
        modelId: modelId,
        modelDisplayName: modelDisplayName,
      ),
    );
  }
}

final defaultModelProvider =
    AsyncNotifierProvider<DefaultModelNotifier, DefaultModelSelection>(
      DefaultModelNotifier.new,
    );

// ── Terminal Sessions (Phase 3) ───────────────────────────────────────────────

/// Structured command-execution sessions, keyed by Run id. This is the
/// live, in-memory source of truth (updated directly as
/// `terminal.session.*` events arrive) — [RunRepository] holds the durable
/// copy for history/restart, loaded on demand via [ensureLoaded].
class TerminalSessionsNotifier
    extends StateNotifier<Map<String, List<TerminalSession>>> {
  TerminalSessionsNotifier() : super({});

  void upsert(TerminalSession session) {
    final existing = state[session.runId] ?? const <TerminalSession>[];
    final updated = [
      for (final s in existing)
        if (s.id != session.id) s,
      session,
    ];
    state = {...state, session.runId: updated};
  }

  /// Loads a Run's sessions from the database once, if they aren't already
  /// in memory — covers viewing a historical Run after an app restart.
  Future<void> ensureLoaded(String runId, RunRepository repo) async {
    if (state.containsKey(runId)) return;
    final sessions = await repo.getTerminalSessionsForRun(runId);
    state = {...state, runId: sessions};
  }
}

final terminalSessionsProvider =
    StateNotifierProvider<
      TerminalSessionsNotifier,
      Map<String, List<TerminalSession>>
    >((ref) => TerminalSessionsNotifier());

/// Sessions for one Run, newest first.
final terminalSessionsForRunProvider =
    Provider.family<List<TerminalSession>, String>((ref, runId) {
      final sessions = ref.watch(terminalSessionsProvider)[runId] ?? const [];
      return sessions.reversed.toList();
    });

/// Ephemeral, bounded, per-session output buffer. Never persisted and never
/// routed through [RunListNotifier.updateRun] — a chatty command can emit
/// hundreds of lines a second, and neither SQLite nor the Run's `events`
/// list should absorb that. Only the session summary (see above) is durable.
class TerminalLiveOutputNotifier
    extends StateNotifier<Map<String, List<TerminalOutputLine>>> {
  TerminalLiveOutputNotifier() : super({});

  static const _maxBufferedLines = 500;

  void appendLine(String sessionId, TerminalOutputLine line) {
    final existing = state[sessionId] ?? const <TerminalOutputLine>[];
    final updated = existing.length >= _maxBufferedLines
        ? [...existing.skip(existing.length - _maxBufferedLines + 1), line]
        : [...existing, line];
    state = {...state, sessionId: updated};
  }
}

final terminalLiveOutputProvider =
    StateNotifierProvider<
      TerminalLiveOutputNotifier,
      Map<String, List<TerminalOutputLine>>
    >((ref) => TerminalLiveOutputNotifier());

// ── Browser Sessions (Phase 3) ────────────────────────────────────────────────

class BrowserSessionsNotifier
    extends StateNotifier<Map<String, BrowserSession>> {
  BrowserSessionsNotifier() : super({});

  void upsert(BrowserSession session) {
    state = {...state, session.runId: session};
  }

  Future<void> ensureLoaded(String runId, RunRepository repo) async {
    if (state.containsKey(runId)) return;
    final session = await repo.getBrowserSessionForRun(runId);
    if (session != null) {
      state = {...state, runId: session};
    }
  }
}

final browserSessionsProvider =
    StateNotifierProvider<BrowserSessionsNotifier, Map<String, BrowserSession>>(
      (ref) => BrowserSessionsNotifier(),
    );

final browserSessionForRunProvider = Provider.family<BrowserSession?, String>((
  ref,
  runId,
) {
  return ref.watch(browserSessionsProvider)[runId];
});

// ── Notifications (Phase 3) ───────────────────────────────────────────────────

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService(),
);

class NotificationsNotifier extends AsyncNotifier<List<AppNotification>> {
  @override
  Future<List<AppNotification>> build() async {
    final repo = await ref.watch(runRepositoryProvider.future);
    final bridge = ref.read(bridgeServiceProvider);
    if (bridge.isReady) {
      try {
        final response = await bridge.call('notification.list');
        return (response['notifications'] as List<dynamic>? ?? [])
            .map((n) => AppNotification.fromJson(n as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }
    return repo.getAllNotifications();
  }

  Future<void> add(AppNotification notification) async {
    final repo = await ref.read(runRepositoryProvider.future);
    await repo.saveNotification(notification);
    final current = state.valueOrNull ?? [];
    state = AsyncValue.data([notification, ...current]);
  }

  Future<void> markRead(String id) async {
    final repo = await ref.read(runRepositoryProvider.future);
    final bridge = ref.read(bridgeServiceProvider);
    if (bridge.isReady) {
      try {
        await bridge.call('notification.mark_read', params: {'id': id});
      } catch (_) {}
    }
    await repo.markNotificationRead(id);
    final current = state.valueOrNull ?? [];
    state = AsyncValue.data([
      for (final n in current)
        if (n.id == id) n.copyWith(read: true) else n,
    ]);
  }
}

final notificationsProvider =
    AsyncNotifierProvider<NotificationsNotifier, List<AppNotification>>(
      NotificationsNotifier.new,
    );

final unreadNotificationCountProvider = Provider<int>((ref) {
  final notifications =
      ref.watch(notificationsProvider).valueOrNull ?? const [];
  return notifications.where((n) => !n.read).length;
});

// ── Run Providers ─────────────────────────────────────────────────────────────

/// In-memory list of Runs (source of truth for the UI after loading).
class RunListNotifier extends AsyncNotifier<List<Run>> {
  @override
  Future<List<Run>> build() async {
    final repo = await ref.watch(runRepositoryProvider.future);
    final bridge = ref.read(bridgeServiceProvider);
    final localRuns = await repo.getAllRuns();
    List<Run> runtimeRuns = const [];
    if (bridge.isReady && bridge.databasePath != null) {
      try {
        final response = await bridge.call('run.list');
        runtimeRuns = (response['runs'] as List<dynamic>? ?? [])
            .map((r) => Run.fromJson(Map<String, dynamic>.from(r as Map)))
            .toList();
      } catch (_) {}
    }
    // Recover any active runs that were interrupted by crash or restart
    // only when no runtime is connected. A live runtime owns those active
    // Runs and must never be mistaken for stale Flutter work.
    final recovered = bridge.isReady
        ? const <Run>[]
        : await repo.recoverInterruptedRuns();
    for (final run in recovered) {
      final notification = AppNotification(
        id: 'notif-interrupted-${run.id}-${DateTime.now().microsecondsSinceEpoch}',
        type: NotificationType.runInterrupted,
        title: 'Run interrupted',
        message: '"${run.title}" was interrupted and is ready to resume.',
        runId: run.id,
        createdAt: DateTime.now(),
      );
      await repo.saveNotification(notification);
      await ref
          .read(notificationServiceProvider)
          .notify(
            title: notification.title,
            body: notification.message,
            urgency: 'critical',
          );
    }
    if (runtimeRuns.isEmpty) {
      return bridge.isReady ? localRuns : await repo.getAllRuns();
    }
    final runtimeIds = runtimeRuns.map((r) => r.id).toSet();
    return [
      ...runtimeRuns,
      ...localRuns.where((r) => !runtimeIds.contains(r.id)),
    ];
  }

  Future<Run> createRun(
    String goal, {
    String? providerId,
    String? modelId,
    String? modelDisplayName,
    String? workspacePath,
  }) async {
    final repo = await ref.read(runRepositoryProvider.future);
    final run = Run.create(
      id: _generateId(),
      goal: goal,
      providerId: providerId,
      modelId: modelId,
      modelDisplayName: modelDisplayName,
      workspacePath: workspacePath,
    );
    await repo.saveRun(run);
    final bridge = ref.read(bridgeServiceProvider);
    if (bridge.isReady) {
      try {
        await bridge.call('run.create', params: {'run': run.toJson()});
      } catch (_) {}
    }
    final current = state.valueOrNull ?? [];
    state = AsyncValue.data([run, ...current]);
    return run;
  }

  Future<void> updateRun(Run run) async {
    final updated = run.copyWith(updatedAt: DateTime.now());
    final repo = await ref.read(runRepositoryProvider.future);
    await repo.saveRun(updated);

    final current = state.valueOrNull ?? [];
    state = AsyncValue.data([
      for (final r in current)
        if (r.id == updated.id) updated else r,
    ]);
  }

  Future<void> refreshFromDb() async {
    final bridge = ref.read(bridgeServiceProvider);
    if (bridge.isReady && bridge.databasePath != null) {
      await refreshFromRuntime();
      return;
    }
    final repo = await ref.read(runRepositoryProvider.future);
    state = AsyncValue.data(await repo.getAllRuns());
  }

  Future<void> refreshFromRuntime() async {
    final bridge = ref.read(bridgeServiceProvider);
    if (!bridge.isReady || bridge.databasePath == null) return;
    final response = await bridge.call('run.list');
    final runtimeRuns = (response['runs'] as List<dynamic>? ?? [])
        .map((r) => Run.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList();
    if (runtimeRuns.isEmpty) return;
    final local = state.valueOrNull ?? const <Run>[];
    final ids = runtimeRuns.map((r) => r.id).toSet();
    state = AsyncValue.data([
      ...runtimeRuns,
      ...local.where((r) => !ids.contains(r.id)),
    ]);
  }

  static String _generateId() {
    return 'run-${DateTime.now().microsecondsSinceEpoch}';
  }
}

final runListProvider = AsyncNotifierProvider<RunListNotifier, List<Run>>(
  RunListNotifier.new,
);

/// Provides a single Run by ID.
final runByIdProvider = Provider.family<Run?, String>((ref, id) {
  final runs = ref.watch(runListProvider).valueOrNull ?? [];
  try {
    return runs.firstWhere((r) => r.id == id);
  } catch (_) {
    return null;
  }
});

/// Active runs (planning/running/verifying/waiting).
final activeRunsProvider = Provider<List<Run>>((ref) {
  final runs = ref.watch(runListProvider).valueOrNull ?? [];
  return runs.where((r) => r.isActive || r.needsAttention).toList();
});

/// Terminal runs (completed/failed/cancelled/interrupted).
final terminalRunsProvider = Provider<List<Run>>((ref) {
  final runs = ref.watch(runListProvider).valueOrNull ?? [];
  return runs.where((r) => r.isTerminal).toList();
});

/// Global list of pending approvals across all runs.
final pendingApprovalsProvider = Provider<List<ApprovalRequest>>((ref) {
  final runs = ref.watch(runListProvider).valueOrNull ?? [];
  final pending = <ApprovalRequest>[];
  for (final r in runs) {
    if (r.pendingApproval != null && r.pendingApproval!.isPending) {
      pending.add(r.pendingApproval!);
    }
  }
  return pending;
});

// ── Run Execution ─────────────────────────────────────────────────────────────

/// Executes a Run and streams events back to update the Run's state.
class RunExecutor {
  final Ref _ref;
  final Map<String, StreamSubscription<Map<String, dynamic>>> _subscriptions =
      {};
  final Set<String> _startingRuns = {};
  final Map<String, Future<void>> _eventTails = {};
  bool _disposed = false;

  RunExecutor(this._ref);

  /// Starts executing a run by submitting its goal to the bridge.
  Future<void> execute(String runId) async {
    if (_disposed) return;
    if (_subscriptions.containsKey(runId) || !_startingRuns.add(runId)) return;
    final runs = _ref.read(runListProvider).valueOrNull ?? [];
    Run? run;
    try {
      run = runs.firstWhere((r) => r.id == runId);
    } catch (_) {
      _startingRuns.remove(runId);
      return;
    }

    final bridge = _ref.read(bridgeServiceProvider);
    if (!bridge.isReady) {
      _startingRuns.remove(runId);
      return;
    }

    // Transition to planning
    await _updateRun(
      run.copyWith(
        status: RunStatus.planning,
        startedAt: DateTime.now(),
        events: run.events,
      ),
    );
    if (_disposed) {
      _startingRuns.remove(runId);
      return;
    }

    final stream = bridge.callStreaming(
      'execute_run',
      params: {
        'run_id': runId,
        'goal': run.goal,
        if (bridge.databasePath == null) 'legacy_direct': true,
        if (run.providerId != null) 'provider': run.providerId,
        if (run.modelId != null) 'model': run.modelId,
        if (run.workspacePath != null) 'workspace_root': run.workspacePath,
      },
    );

    final sub = stream.listen(
      (event) {
        if (!_disposed) _enqueueEvent(runId, event);
      },
      onError: (e) async {
        if (_disposed) return;
        final current = _ref.read(runByIdProvider(runId));
        if (current != null) {
          await _updateRun(
            current.copyWith(
              status: RunStatus.failed,
              errorMessage: e.toString(),
              completedAt: DateTime.now(),
            ),
          );
        }
      },
      onDone: () {
        _subscriptions.remove(runId);
      },
    );

    _subscriptions[runId] = sub;
    _startingRuns.remove(runId);
  }

  /// Reattaches live event streams after a UI reconnect. The runtime keeps
  /// executing independently; the cursor makes this a replay-plus-live
  /// subscription rather than a second execution request.
  Future<void> reconnectActiveRuns() async {
    if (_disposed) return;
    final runs = _ref.read(runListProvider).valueOrNull ?? const <Run>[];
    final bridge = _ref.read(bridgeServiceProvider);
    if (!bridge.isReady) return;
    for (final run in runs.where((r) => !r.isTerminal)) {
      if (_subscriptions.containsKey(run.id)) continue;
      final lastEventId = run.events.fold<int>(0, (max, event) {
        final value = event.data?['event_id'];
        return value is int && value > max ? value : max;
      });
      final stream = bridge.callStreaming(
        'events.subscribe',
        params: {'run_id': run.id, 'after_event_id': lastEventId},
      );
      _subscriptions[run.id] = stream.listen(
        (event) {
          if (!_disposed) _enqueueEvent(run.id, event);
        },
        onError: (_) => _subscriptions.remove(run.id),
        onDone: () => _subscriptions.remove(run.id),
      );
    }
  }

  /// Resolves an interactive approval request.
  Future<void> resolveApproval(
    String runId,
    String requestId,
    bool approved,
  ) async {
    final bridge = _ref.read(bridgeServiceProvider);
    final resolvedByRuntime = await bridge.resolveApproval(
      requestId,
      approved,
      runId: runId,
    );
    if (!resolvedByRuntime) return;

    final current = _ref.read(runByIdProvider(runId));
    if (current == null) return;

    final appr = current.pendingApproval;
    if (appr != null) {
      final resolved = appr.copyWith(
        status: approved ? ApprovalStatus.approved : ApprovalStatus.rejected,
        resolvedAt: DateTime.now(),
      );
      final repo = await _ref.read(runRepositoryProvider.future);
      await repo.saveApproval(resolved);
    }

    final updated = current.copyWith(
      status: approved ? RunStatus.running : RunStatus.blocked,
      clearPendingApproval: true,
    );
    await _updateRun(updated);
  }

  /// Pauses an active run.
  Future<void> pauseRun(String runId) async {
    final bridge = _ref.read(bridgeServiceProvider);
    if (!await bridge.pauseRun(runId)) return;
    final current = _ref.read(runByIdProvider(runId));
    if (current != null) {
      await _updateRun(current.copyWith(status: RunStatus.blocked));
    }
  }

  /// Resumes a paused run.
  Future<void> resumeRun(String runId) async {
    final bridge = _ref.read(bridgeServiceProvider);
    if (!await bridge.resumeRun(runId)) return;
    final current = _ref.read(runByIdProvider(runId));
    if (current != null) {
      await _updateRun(current.copyWith(status: RunStatus.running));
    }
  }

  /// Cancels an active run.
  Future<void> cancelRun(String runId) async {
    final bridge = _ref.read(bridgeServiceProvider);
    if (!await bridge.cancelRun(runId)) return;
    final current = _ref.read(runByIdProvider(runId));
    if (current != null) {
      await _updateRun(
        current.copyWith(
          status: RunStatus.cancelled,
          completedAt: DateTime.now(),
          outcome: 'Run cancelled by user.',
        ),
      );
    }
    await _subscriptions[runId]?.cancel();
    _subscriptions.remove(runId);
  }

  /// Resumes execution of an interrupted run.
  Future<void> resumeInterruptedRun(String runId) async {
    final current = _ref.read(runByIdProvider(runId));
    if (current == null) return;

    final resumeEvent = RunEvent(
      type: 'run.resumed',
      timestamp: DateTime.now(),
      message: 'Resuming execution from last checkpoint.',
    );
    await _updateRun(
      current.copyWith(
        status: RunStatus.running,
        events: [...current.events, resumeEvent],
      ),
    );

    await execute(runId);
  }

  void _enqueueEvent(String runId, Map<String, dynamic> event) {
    final previous = _eventTails[runId] ?? Future<void>.value();
    final next = previous.then<void>((_) async {
      try {
        await _handleEventNow(runId, event);
      } catch (_) {
        // Keep later events flowing when a stale/malformed projection event
        // cannot be applied.
      }
    });
    _eventTails[runId] = next;
    unawaited(
      next.whenComplete(() {
        if (identical(_eventTails[runId], next)) _eventTails.remove(runId);
      }),
    );
  }

  Future<void> _handleEventNow(String runId, Map<String, dynamic> event) async {
    if (_disposed) return;
    final current = _ref.read(runByIdProvider(runId));
    if (current == null) return;

    // Runtime event IDs are stable across disconnect/reconnect. Ignore a
    // replayed cursor that the UI already applied.
    final replayId = event['event_id'];
    if (replayId is int &&
        current.events.any((e) => e.data?['event_id'] == replayId)) {
      return;
    }

    final type = event['type'] as String? ?? '';
    final message = event['message'] as String? ?? '';
    final taskId = event['task_id'] as String?;
    final timestamp = DateTime.now();

    // High-frequency stream: a single command can emit hundreds of lines a
    // second. This goes straight to the ephemeral, bounded live-output
    // buffer — never into `run.events`, never through `saveRun()`. Nothing
    // else in this function should ever be this chatty; if a future event
    // type is, give it the same treatment rather than routing it below.
    if (type == 'terminal.output') {
      final sessionId = event['session_id'] as String?;
      if (sessionId != null) {
        _ref
            .read(terminalLiveOutputProvider.notifier)
            .appendLine(
              sessionId,
              TerminalOutputLine(
                stream: event['stream'] as String? ?? 'stdout',
                text: event['line'] as String? ?? '',
              ),
            );
      }
      return;
    }

    final repo = await _ref.read(runRepositoryProvider.future);
    if (_disposed) return;

    // Phase 3 session aggregation — terminal/browser events update their
    // own durable summaries in addition to flowing into `run.events` below
    // like any other event (these are low-frequency: one per command or
    // navigation, not per line).
    if (type == 'terminal.session.created' ||
        type == 'terminal.session.completed') {
      await _handleTerminalSessionEvent(
        runId,
        taskId,
        type,
        event,
        timestamp,
        repo,
      );
    } else if (type.startsWith('browser.')) {
      await _handleBrowserEvent(runId, type, event, timestamp, repo);
    } else if (type == 'computer.action.requested') {
      // Not awaited: this performs the actual widget action and reports
      // the result back over the bridge, which is what unblocks the
      // Python capability handler still waiting on the other end. It must
      // not block this event-stream listener itself.
      unawaited(
        _handleComputerActionRequested(current, taskId, event, timestamp, repo),
      );
    }
    if (_disposed) return;

    // 1. Create structured RunEvent
    final newEvent = RunEvent(
      type: type,
      timestamp: timestamp,
      message: message,
      data: Map<String, dynamic>.from(event)
        ..remove('type')
        ..remove('message'),
      taskId: taskId,
    );

    var updated = current.copyWith(
      events: [...current.events, newEvent],
      updatedAt: timestamp,
    );

    // 2. Handle Phase 2 specific events
    if (type == 'approval.requested') {
      final req = ApprovalRequest(
        id:
            event['request_id'] as String? ??
            'appr-$runId-${DateTime.now().millisecondsSinceEpoch}',
        runId: runId,
        taskId: taskId,
        capabilityId: event['capability_id'] as String? ?? '',
        title: event['title'] as String? ?? 'Approval Required',
        explanation: event['explanation'] as String? ?? '',
        risk: CapabilityRisk.fromString(event['risk'] as String?),
        payload: (event['payload'] as Map<String, dynamic>?) ?? const {},
        status: ApprovalStatus.pending,
        createdAt: timestamp,
      );
      await repo.saveApproval(req);
      updated = updated.copyWith(
        status: RunStatus.waitingApproval,
        pendingApproval: req,
      );
      await _notify(
        type: NotificationType.approvalRequired,
        title: 'Approval needed',
        message: '"${updated.title}" wants to: ${req.title}',
        runId: runId,
        urgency: 'critical',
      );
      if (_disposed) return;
    } else if (type == 'approval.resolved') {
      final approved = event['approved'] as bool? ?? false;
      if (updated.pendingApproval != null) {
        final resolvedAppr = updated.pendingApproval!.copyWith(
          status: approved ? ApprovalStatus.approved : ApprovalStatus.rejected,
          resolvedAt: timestamp,
        );
        await repo.saveApproval(resolvedAppr);
      }
      updated = updated.copyWith(
        status: approved ? RunStatus.running : RunStatus.blocked,
        clearPendingApproval: true,
      );
    } else if (type == 'artifact.created') {
      final art = Artifact(
        id:
            event['artifact_id'] as String? ??
            'art-$runId-${DateTime.now().millisecondsSinceEpoch}',
        runId: runId,
        taskId: taskId,
        type: ArtifactType.fromString(event['type'] as String?),
        title: event['title'] as String? ?? 'Artifact',
        path: event['path'] as String?,
        contentPreview: event['content_preview'] as String?,
        metadata: (event['metadata'] as Map<String, dynamic>?) ?? const {},
        createdAt: timestamp,
      );
      await repo.saveArtifact(art);
      updated = updated.copyWith(artifacts: [...updated.artifacts, art]);
    } else if (type == 'checkpoint.created') {
      final chk = RunCheckpoint(
        id: 'chk-$runId-${event['step_index'] ?? 0}',
        runId: runId,
        stepIndex: event['step_index'] as int? ?? 0,
        state: (event['state'] as Map<String, dynamic>?) ?? const {},
        createdAt: timestamp,
      );
      await repo.saveCheckpoint(chk);
    } else if (type == 'task.retrying') {
      final attempt = event['attempt'] as int? ?? 1;
      updated = updated.copyWith(
        plan: [
          for (final t in updated.plan)
            if (t.id == taskId)
              t.copyWith(attempts: attempt, status: 'running')
            else
              t,
        ],
      );
    } else if (type == 'model.selected') {
      // The bridge resolves a default when a Run is created without an
      // explicit override — record what actually ran so Run Detail shows
      // truth, not the empty selection the Run started with.
      final resolvedProvider = event['provider'] as String?;
      final resolvedModel = event['model'] as String?;
      if (resolvedProvider != null && resolvedModel != null) {
        updated = updated.copyWith(
          providerId: updated.providerId ?? resolvedProvider,
          modelId: updated.modelId ?? resolvedModel,
          modelDisplayName: updated.modelDisplayName ?? resolvedModel,
        );
      }
    } else if (type == 'run.paused') {
      updated = updated.copyWith(status: RunStatus.blocked);
    } else if (type == 'run.cancelled') {
      updated = updated.copyWith(
        status: RunStatus.cancelled,
        completedAt: timestamp,
        outcome: message,
      );
    }

    // 3. Status progression
    updated = switch (type) {
      'planning.started' => updated.copyWith(status: RunStatus.planning),
      'planning.completed' => updated.copyWith(
        status: RunStatus.ready,
        plan: _buildPlan(event, current.plan),
      ),
      'run.started' => updated.copyWith(status: RunStatus.running),
      'task.started' => updated.copyWith(
        status: RunStatus.running,
        plan: _updateTaskStatus(current.plan, taskId, 'running'),
      ),
      'task.completed' => updated.copyWith(
        plan: _updateTaskStatus(current.plan, taskId, 'completed'),
      ),
      'task.failed' => updated.copyWith(
        plan: _updateTaskStatus(current.plan, taskId, 'failed'),
      ),
      'verification.started' => updated.copyWith(status: RunStatus.verifying),
      'run.completed' => updated.copyWith(
        status: RunStatus.completed,
        completedAt: timestamp,
        outcome: event['outcome'] as String? ?? message,
      ),
      'run.failed' => updated.copyWith(
        status: RunStatus.failed,
        completedAt: timestamp,
        errorMessage: message,
      ),
      _ => updated,
    };

    // Attention notifications — deliberately narrow. These fire on state
    // transitions the user actually needs to know about, not on every
    // structured event (that's what Activity is for).
    if (type == 'run.completed') {
      await _notify(
        type: NotificationType.runCompleted,
        title: 'Run completed',
        message: updated.title,
        runId: runId,
      );
    } else if (type == 'run.failed') {
      await _notify(
        type: NotificationType.runFailed,
        title: 'Run failed',
        message: updated.title,
        runId: runId,
        urgency: 'critical',
      );
    }

    if (!_disposed) await _updateRun(updated);
  }

  Future<void> _notify({
    required NotificationType type,
    required String title,
    required String message,
    String? runId,
    String urgency = 'normal',
  }) async {
    if (_disposed) return;
    // The canonical runtime persists and produces native notifications. The
    // Flutter-side copy is retained only for isolated/legacy repositories.
    final bridge = _ref.read(bridgeServiceProvider);
    if (bridge.isReady && bridge.databasePath != null) return;
    final notification = AppNotification(
      id: 'notif-${DateTime.now().microsecondsSinceEpoch}',
      type: type,
      title: title,
      message: message,
      runId: runId,
      createdAt: DateTime.now(),
    );
    await _ref.read(notificationsProvider.notifier).add(notification);
    await _ref
        .read(notificationServiceProvider)
        .notify(title: title, body: message, urgency: urgency);
  }

  Future<void> _handleTerminalSessionEvent(
    String runId,
    String? taskId,
    String type,
    Map<String, dynamic> event,
    DateTime timestamp,
    RunRepository repo,
  ) async {
    final sessionId = event['session_id'] as String?;
    if (sessionId == null) return;

    final existing = _ref
        .read(terminalSessionsProvider)[runId]
        ?.cast<TerminalSession?>()
        .firstWhere((s) => s!.id == sessionId, orElse: () => null);

    final TerminalSession session;
    if (type == 'terminal.session.created') {
      session = TerminalSession(
        id: sessionId,
        runId: runId,
        taskId: taskId,
        command: event['command'] as String? ?? '',
        cwd: event['cwd'] as String? ?? '.',
        status: TerminalSessionStatus.running,
        startedAt: timestamp,
      );
    } else {
      final timedOut = event['timed_out'] as bool? ?? false;
      final success = event['success'] as bool? ?? false;
      session =
          (existing ??
                  TerminalSession(
                    id: sessionId,
                    runId: runId,
                    taskId: taskId,
                    command: '',
                    cwd: '.',
                    status: TerminalSessionStatus.running,
                    startedAt: timestamp,
                  ))
              .copyWith(
                status: timedOut
                    ? TerminalSessionStatus.timedOut
                    : (success
                          ? TerminalSessionStatus.completed
                          : TerminalSessionStatus.failed),
                exitCode: event['exit_code'] as int?,
                truncated: event['truncated'] as bool? ?? false,
                completedAt: timestamp,
              );
    }

    _ref.read(terminalSessionsProvider.notifier).upsert(session);
    await repo.saveTerminalSession(session);
  }

  Future<void> _handleBrowserEvent(
    String runId,
    String type,
    Map<String, dynamic> event,
    DateTime timestamp,
    RunRepository repo,
  ) async {
    final sessionId = event['session_id'] as String?;
    if (sessionId == null) return;

    final existing =
        _ref.read(browserSessionsProvider)[runId] ??
        BrowserSession(id: sessionId, runId: runId, updatedAt: timestamp);

    BrowserSession updated = existing;
    switch (type) {
      case 'browser.navigation.completed':
        final url = event['url'] as String? ?? existing.currentUrl;
        updated = existing.copyWith(
          currentUrl: url,
          currentTitle: event['title'] as String?,
          history: [
            ...existing.history,
            BrowserNavigationEntry(
              url: url ?? '',
              title: event['title'] as String?,
              statusCode: event['status_code'] as int?,
              at: timestamp,
            ),
          ],
          updatedAt: timestamp,
        );
      case 'browser.download.completed':
        updated = existing.copyWith(
          downloadCount: existing.downloadCount + 1,
          updatedAt: timestamp,
        );
      case 'browser.capture.created':
        updated = existing.copyWith(
          captureCount: existing.captureCount + 1,
          updatedAt: timestamp,
        );
      default:
        updated = existing.copyWith(updatedAt: timestamp);
    }

    _ref.read(browserSessionsProvider.notifier).upsert(updated);
    await repo.saveBrowserSession(updated);
  }

  /// Executes a Controlled Computer Use action for real, then reports the
  /// result back over the bridge — the entire in-process round-trip this
  /// phase's design settled on. `target_id` is checked again here (Python
  /// already enforced it via the Policy Engine) purely as a second,
  /// independent guard: this is the one place Dart could otherwise be
  /// tricked into acting on a target it doesn't actually own.
  Future<void> _handleComputerActionRequested(
    Run run,
    String? taskId,
    Map<String, dynamic> event,
    DateTime timestamp,
    RunRepository repo,
  ) async {
    final requestId = event['request_id'] as String?;
    final actionTypeStr = event['action'] as String? ?? '';
    final targetId = event['target_id'] as String? ?? '';
    if (requestId == null) return;

    Map<String, dynamic> result;
    String? capturePath;

    if (targetId != ComputerTarget.sysaiTestSurface.id) {
      result = {
        'success': false,
        'error': 'Unregistered computer target: $targetId',
      };
    } else {
      final controller = _ref.read(testSurfaceControllerProvider.notifier);
      final selector = event['selector'] as String?;
      switch (actionTypeStr) {
        case 'observe':
          result = controller.observe();
        case 'click':
          result = controller.executeClick(selector);
        case 'type':
          result = controller.executeType(
            selector,
            event['text_metadata'] as String?,
          );
        case 'key':
          result = controller.executeKey(
            selector,
            event['text_metadata'] as String?,
          );
        case 'scroll':
          result = controller.executeScroll(
            selector,
            event['text_metadata'] as String?,
          );
        case 'capture':
          final pngBytes = await captureBoundaryPng(testSurfaceRepaintKey);
          if (pngBytes == null) {
            result = {
              'success': false,
              'reason':
                  'The Computer test surface is not currently rendered — open the Computer view '
                  'in SysAI OS so the capture has something to render from.',
            };
          } else {
            final workspaceRoot =
                run.workspacePath ?? SysAIConfig.defaultWorkspacePath;
            capturePath = await saveCapture(
              workspaceRoot,
              pngBytes,
              prefix: 'computer',
            );
            result = {
              'success': true,
              'path': capturePath,
              'artifact': {
                'type': 'screenshot',
                'title': 'Computer capture',
                'path': capturePath,
                'metadata': {'target_id': targetId},
              },
            };
          }
        default:
          result = {
            'success': false,
            'error': 'Unsupported action type: $actionTypeStr',
          };
      }
    }

    final actionType = ComputerActionType.fromString(actionTypeStr);
    final action = ComputerAction(
      id: requestId,
      runId: run.id,
      taskId: taskId,
      type: actionType,
      targetId: targetId,
      selector: event['selector'] as String?,
      coordinates: event['coordinates'] as Map<String, dynamic>?,
      textMetadata: event['text_metadata'] as String?,
      status: (result['success'] as bool? ?? false)
          ? ComputerActionStatus.completed
          : ComputerActionStatus.failed,
      requestedAt: timestamp,
      startedAt: timestamp,
      completedAt: DateTime.now(),
      result: result,
      failure: (result['success'] as bool? ?? false)
          ? null
          : (result['error'] as String? ?? result['reason'] as String?),
    );
    await repo.saveComputerAction(action);

    final existingSession = await repo.getComputerSessionForRun(run.id);
    final session =
        (existingSession ??
                ComputerSession(
                  id: 'comp-${run.id}',
                  runId: run.id,
                  targetId: targetId,
                  targetTitle: ComputerTarget.sysaiTestSurface.title,
                  updatedAt: timestamp,
                ))
            .copyWith(
              latestCapturePath: capturePath,
              actionCount: (existingSession?.actionCount ?? 0) + 1,
              updatedAt: DateTime.now(),
            );
    await repo.saveComputerSession(session);

    // Unblocks the Python capability handler still waiting on the other
    // end of ComputerActionManager.wait_for_result().
    await _ref
        .read(bridgeServiceProvider)
        .reportComputerActionResult(
          requestId,
          result,
          runId: run.id,
          targetId: targetId,
        );
  }

  List<RunTask> _buildPlan(Map<String, dynamic> event, List<RunTask> current) {
    final planData = event['plan'] as List<dynamic>?;
    if (planData == null) return current;
    return planData
        .map(
          (t) => RunTask(
            id: t['id'] as String? ?? '',
            title: t['title'] as String? ?? '',
            description: t['description'] as String? ?? '',
            dependencies:
                (t['dependencies'] as List<dynamic>?)
                    ?.map((e) => e.toString())
                    .toList() ??
                const [],
            capabilityHints:
                (t['capability_hints'] as List<dynamic>?)
                    ?.map((e) => e.toString())
                    .toList() ??
                const [],
          ),
        )
        .toList();
  }

  List<RunTask> _updateTaskStatus(
    List<RunTask> plan,
    String? taskId,
    String status,
  ) {
    if (taskId == null) return plan;
    return [
      for (final t in plan)
        if (t.id == taskId) t.copyWith(status: status) else t,
    ];
  }

  Future<void> _updateRun(Run run) async {
    await _ref.read(runListProvider.notifier).updateRun(run);
  }

  void dispose() {
    _disposed = true;
    for (final sub in _subscriptions.values) {
      sub.cancel();
    }
    _subscriptions.clear();
  }
}

final runExecutorProvider = Provider((ref) {
  final executor = RunExecutor(ref);
  ref.onDispose(executor.dispose);
  return executor;
});

// ── Experience Provider ───────────────────────────────────────────────────────

class ExperienceNotifier extends AsyncNotifier<Map<String, dynamic>> {
  @override
  Future<Map<String, dynamic>> build() async {
    await ref.watch(bridgeStatusProvider.future);
    return _fetch();
  }

  Future<Map<String, dynamic>> _fetch() async {
    final bridge = ref.read(bridgeServiceProvider);
    if (!bridge.sysaiAvailable) {
      return {'available': false, 'memories': [], 'stats': {}};
    }
    try {
      final stats = await bridge.call('get_memory_stats');
      final memories = await bridge.call(
        'list_memories',
        params: {'limit': 50},
      );
      return {
        'available': true,
        'stats': stats,
        'memories': memories['memories'] ?? [],
      };
    } on BridgeException catch (e) {
      return {'available': false, 'error': e.message};
    }
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_fetch);
  }
}

final experienceProvider =
    AsyncNotifierProvider<ExperienceNotifier, Map<String, dynamic>>(
      ExperienceNotifier.new,
    );

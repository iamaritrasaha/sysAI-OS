/// SysAI domain model: Run, RunTask, RunEvent, RunStatus
library;

import 'approval.dart';
import 'artifact.dart';

// ── RunStatus ─────────────────────────────────────────────────────────────────

enum RunStatus {
  created,
  planning,
  ready,
  running,
  waitingApproval,
  blocked,
  verifying,
  completed,
  failed,
  cancelled,
  interrupted;

  /// Human-readable label for the UI.
  String get displayLabel => switch (this) {
    RunStatus.created => 'Created',
    RunStatus.planning => 'Planning',
    RunStatus.ready => 'Ready',
    RunStatus.running => 'Running',
    RunStatus.waitingApproval => 'Waiting Approval',
    RunStatus.blocked => 'Blocked',
    RunStatus.verifying => 'Verifying',
    RunStatus.completed => 'Completed',
    RunStatus.failed => 'Failed',
    RunStatus.cancelled => 'Cancelled',
    RunStatus.interrupted => 'Interrupted',
  };

  String get serialized => switch (this) {
    RunStatus.waitingApproval => 'waiting_approval',
    _ => name,
  };

  static RunStatus fromString(String s) => switch (s) {
    'created' => RunStatus.created,
    'planning' => RunStatus.planning,
    'ready' => RunStatus.ready,
    'running' => RunStatus.running,
    'waiting_approval' || 'waitingApproval' => RunStatus.waitingApproval,
    'blocked' => RunStatus.blocked,
    'verifying' => RunStatus.verifying,
    'completed' => RunStatus.completed,
    'failed' => RunStatus.failed,
    'cancelled' => RunStatus.cancelled,
    'interrupted' => RunStatus.interrupted,
    _ => RunStatus.created,
  };
}

// ── RunTask ───────────────────────────────────────────────────────────────────

/// A single task/step within a Run's execution plan.
class RunTask {
  final String id;
  final String title;
  final String status; // 'pending' | 'running' | 'completed' | 'failed'
  final DateTime? startedAt;
  final DateTime? completedAt;
  final String description;
  final List<String> dependencies;
  final List<String> capabilityHints;
  final int attempts;
  final int maxAttempts;
  final String? error;
  final Map<String, dynamic>? result;

  const RunTask({
    required this.id,
    required this.title,
    this.status = 'pending',
    this.startedAt,
    this.completedAt,
    this.description = '',
    this.dependencies = const [],
    this.capabilityHints = const [],
    this.attempts = 1,
    this.maxAttempts = 1,
    this.error,
    this.result,
  });

  RunTask copyWith({
    String? id,
    String? title,
    String? status,
    DateTime? startedAt,
    DateTime? completedAt,
    String? description,
    List<String>? dependencies,
    List<String>? capabilityHints,
    int? attempts,
    int? maxAttempts,
    String? error,
    Map<String, dynamic>? result,
  }) => RunTask(
    id: id ?? this.id,
    title: title ?? this.title,
    status: status ?? this.status,
    startedAt: startedAt ?? this.startedAt,
    completedAt: completedAt ?? this.completedAt,
    description: description ?? this.description,
    dependencies: dependencies ?? this.dependencies,
    capabilityHints: capabilityHints ?? this.capabilityHints,
    attempts: attempts ?? this.attempts,
    maxAttempts: maxAttempts ?? this.maxAttempts,
    error: error ?? this.error,
    result: result ?? this.result,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'status': status,
    if (startedAt != null) 'started_at': startedAt!.toIso8601String(),
    if (completedAt != null) 'completed_at': completedAt!.toIso8601String(),
    if (description.isNotEmpty) 'description': description,
    if (dependencies.isNotEmpty) 'dependencies': dependencies,
    if (capabilityHints.isNotEmpty) 'capability_hints': capabilityHints,
    'attempts': attempts,
    'max_attempts': maxAttempts,
    if (error != null) 'error': error,
    if (result != null) 'result': result,
  };

  factory RunTask.fromJson(Map<String, dynamic> json) => RunTask(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    status: json['status'] as String? ?? 'pending',
    startedAt: json['started_at'] != null
        ? DateTime.tryParse(json['started_at'] as String)
        : null,
    completedAt: json['completed_at'] != null
        ? DateTime.tryParse(json['completed_at'] as String)
        : null,
    description: json['description'] as String? ?? '',
    dependencies: (json['dependencies'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        const [],
    capabilityHints: (json['capability_hints'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        const [],
    attempts: json['attempts'] as int? ?? 1,
    maxAttempts: json['max_attempts'] as int? ?? 1,
    error: json['error'] as String?,
    result: json['result'] as Map<String, dynamic>?,
  );
}

// ── RunEvent ──────────────────────────────────────────────────────────────────

/// A structured event emitted by the SysAI OS runtime during a Run.
/// The UI renders these as the Activity Timeline.
class RunEvent {
  final String type; // e.g. 'task.started', 'capability.completed'
  final DateTime timestamp;
  final String message;
  final Map<String, dynamic>? data;
  final String? taskId; // Associated task, if any

  const RunEvent({
    required this.type,
    required this.timestamp,
    required this.message,
    this.data,
    this.taskId,
  });

  Map<String, dynamic> toJson() => {
    'type': type,
    'timestamp': timestamp.toIso8601String(),
    'message': message,
    if (data != null) 'data': data,
    if (taskId != null) 'task_id': taskId,
  };

  factory RunEvent.fromJson(Map<String, dynamic> json) => RunEvent(
    type: json['type'] as String? ?? 'unknown',
    timestamp: json['timestamp'] != null
        ? DateTime.tryParse(json['timestamp'] as String) ?? DateTime.now()
        : DateTime.now(),
    message: json['message'] as String? ?? '',
    data: json['data'] as Map<String, dynamic>?,
    taskId: json['task_id'] as String?,
  );
}

// ── Run ───────────────────────────────────────────────────────────────────────

/// A persistent Run representing one user goal executed by SysAI OS.
///
/// Runs survive application restarts. Their state is the source of truth
/// for the UI — not in-memory or ephemeral widget state.
class Run {
  final String id;
  final String title;
  final String goal;
  final RunStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final List<RunTask> plan;
  final List<RunEvent> events;
  final String outcome;
  final String errorMessage;
  final ApprovalRequest? pendingApproval;
  final List<Artifact> artifacts;
  final String? providerId;
  final String? modelId;
  final String? modelDisplayName;

  /// Absolute path the bridge should treat as `workspace_root` for this
  /// Run. Null means "the bridge's own default" (the SysAI_OS project root
  /// itself) — the same implicit behavior every Run had before this field
  /// existed.
  final String? workspacePath;

  const Run({
    required this.id,
    required this.title,
    required this.goal,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.startedAt,
    this.completedAt,
    this.plan = const [],
    this.events = const [],
    this.outcome = '',
    this.errorMessage = '',
    this.pendingApproval,
    this.artifacts = const [],
    this.providerId,
    this.modelId,
    this.modelDisplayName,
    this.workspacePath,
  });

  /// Creates a new Run in CREATED status.
  factory Run.create({
    required String id,
    required String goal,
    String? providerId,
    String? modelId,
    String? modelDisplayName,
    String? workspacePath,
  }) {
    final now = DateTime.now();
    final title = _titleFromGoal(goal);
    return Run(
      id: id,
      title: title,
      goal: goal,
      status: RunStatus.created,
      createdAt: now,
      updatedAt: now,
      providerId: providerId,
      modelId: modelId,
      modelDisplayName: modelDisplayName,
      workspacePath: workspacePath,
    );
  }

  static String _titleFromGoal(String goal) {
    final trimmed = goal.trim();
    if (trimmed.length <= 60) return trimmed;
    return '${trimmed.substring(0, 57)}...';
  }

  Run copyWith({
    String? id,
    String? title,
    String? goal,
    RunStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? startedAt,
    DateTime? completedAt,
    List<RunTask>? plan,
    List<RunEvent>? events,
    String? outcome,
    String? errorMessage,
    ApprovalRequest? pendingApproval,
    bool clearPendingApproval = false,
    List<Artifact>? artifacts,
    String? providerId,
    String? modelId,
    String? modelDisplayName,
    String? workspacePath,
  }) => Run(
    id: id ?? this.id,
    title: title ?? this.title,
    goal: goal ?? this.goal,
    status: status ?? this.status,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    startedAt: startedAt ?? this.startedAt,
    completedAt: completedAt ?? this.completedAt,
    plan: plan ?? this.plan,
    events: events ?? this.events,
    outcome: outcome ?? this.outcome,
    errorMessage: errorMessage ?? this.errorMessage,
    pendingApproval: clearPendingApproval
        ? null
        : (pendingApproval ?? this.pendingApproval),
    artifacts: artifacts ?? this.artifacts,
    providerId: providerId ?? this.providerId,
    modelId: modelId ?? this.modelId,
    modelDisplayName: modelDisplayName ?? this.modelDisplayName,
    workspacePath: workspacePath ?? this.workspacePath,
  );

  /// Human-readable status for display.
  String get displayStatus => status.displayLabel;

  /// Returns a clean label for the model used by this run.
  String get modelLabel =>
      modelDisplayName ?? modelId ?? 'Default Model';

  /// True if this run was configured with an explicit model.
  bool get hasModelOverride => modelId != null && modelId!.isNotEmpty;

  /// True when the Run is actively being worked on.
  bool get isActive => switch (status) {
    RunStatus.planning ||
    RunStatus.ready ||
    RunStatus.running ||
    RunStatus.verifying => true,
    _ => false,
  };

  /// True when no further state changes are expected.
  bool get isTerminal => switch (status) {
    RunStatus.completed ||
    RunStatus.failed ||
    RunStatus.cancelled ||
    RunStatus.interrupted => true,
    _ => false,
  };

  /// True when the Run needs user action.
  bool get needsAttention => switch (status) {
    RunStatus.waitingApproval ||
    RunStatus.blocked ||
    RunStatus.interrupted => true,
    _ => false,
  };

  /// True when waiting for an approval resolution.
  bool get needsApproval => status == RunStatus.waitingApproval;

  /// True when run was interrupted.
  bool get isInterrupted => status == RunStatus.interrupted;

  /// True when an active pending approval request exists.
  bool get hasPendingApproval =>
      pendingApproval != null && pendingApproval!.isPending;

  /// Returns the most recent event message, or empty string.
  String get latestEventMessage => events.isNotEmpty
      ? events.last.message
      : '';

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'goal': goal,
    'status': status.serialized,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    if (startedAt != null) 'started_at': startedAt!.toIso8601String(),
    if (completedAt != null) 'completed_at': completedAt!.toIso8601String(),
    'plan': plan.map((t) => t.toJson()).toList(),
    'events': events.map((e) => e.toJson()).toList(),
    'outcome': outcome,
    'error_message': errorMessage,
    if (pendingApproval != null) 'pending_approval': pendingApproval!.toJson(),
    if (artifacts.isNotEmpty)
      'artifacts': artifacts.map((a) => a.toJson()).toList(),
    if (providerId != null) 'provider_id': providerId,
    if (modelId != null) 'model_id': modelId,
    if (modelDisplayName != null) 'model_display_name': modelDisplayName,
    if (workspacePath != null) 'workspace_path': workspacePath,
  };

  factory Run.fromJson(Map<String, dynamic> json) => Run(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    goal: json['goal'] as String? ?? '',
    status: RunStatus.fromString(json['status'] as String? ?? 'created'),
    createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ?? DateTime.now(),
    updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ?? DateTime.now(),
    startedAt: json['started_at'] != null
        ? DateTime.tryParse(json['started_at'] as String)
        : null,
    completedAt: json['completed_at'] != null
        ? DateTime.tryParse(json['completed_at'] as String)
        : null,
    plan: (json['plan'] as List<dynamic>?)
            ?.map((t) => RunTask.fromJson(t as Map<String, dynamic>))
            .toList() ??
        const [],
    events: (json['events'] as List<dynamic>?)
            ?.map((e) => RunEvent.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
    outcome: json['outcome'] as String? ?? '',
    errorMessage: json['error_message'] as String? ?? '',
    pendingApproval: json['pending_approval'] != null
        ? ApprovalRequest.fromJson(json['pending_approval'] as Map<String, dynamic>)
        : null,
    artifacts: (json['artifacts'] as List<dynamic>?)
            ?.map((a) => Artifact.fromJson(a as Map<String, dynamic>))
            .toList() ??
        const [],
    providerId: json['provider_id'] as String?,
    modelId: json['model_id'] as String?,
    modelDisplayName: json['model_display_name'] as String?,
    workspacePath: json['workspace_path'] as String?,
  );
}

/// SysAI domain model: ComputerAction — one requested/executed Controlled
/// Computer Use action against a [ComputerTarget].
library;

enum ComputerActionType {
  observe,
  capture,
  click,
  type,
  key,
  scroll;

  String get serialized => name;

  static ComputerActionType fromString(String? s) => switch (s) {
    'observe' => ComputerActionType.observe,
    'capture' => ComputerActionType.capture,
    'click' => ComputerActionType.click,
    'type' => ComputerActionType.type,
    'key' => ComputerActionType.key,
    'scroll' => ComputerActionType.scroll,
    _ => ComputerActionType.observe,
  };
}

enum ComputerActionStatus {
  requested,
  waitingApproval,
  running,
  completed,
  failed,
  cancelled;

  String get serialized => switch (this) {
    ComputerActionStatus.waitingApproval => 'waiting_approval',
    _ => name,
  };

  static ComputerActionStatus fromString(String? s) => switch (s) {
    'requested' => ComputerActionStatus.requested,
    'waiting_approval' || 'waitingApproval' => ComputerActionStatus.waitingApproval,
    'running' => ComputerActionStatus.running,
    'completed' => ComputerActionStatus.completed,
    'failed' => ComputerActionStatus.failed,
    'cancelled' => ComputerActionStatus.cancelled,
    _ => ComputerActionStatus.requested,
  };
}

class ComputerAction {
  final String id;
  final String? sessionId;
  final String runId;
  final String? taskId;
  final ComputerActionType type;
  final String targetId;
  final String? selector;
  final Map<String, dynamic>? coordinates;
  final String? textMetadata;
  final ComputerActionStatus status;
  final DateTime requestedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final Map<String, dynamic> result;
  final String? failure;

  const ComputerAction({
    required this.id,
    this.sessionId,
    required this.runId,
    this.taskId,
    required this.type,
    required this.targetId,
    this.selector,
    this.coordinates,
    this.textMetadata,
    required this.status,
    required this.requestedAt,
    this.startedAt,
    this.completedAt,
    this.result = const {},
    this.failure,
  });

  ComputerAction copyWith({
    ComputerActionStatus? status,
    DateTime? startedAt,
    DateTime? completedAt,
    Map<String, dynamic>? result,
    String? failure,
  }) => ComputerAction(
    id: id,
    sessionId: sessionId,
    runId: runId,
    taskId: taskId,
    type: type,
    targetId: targetId,
    selector: selector,
    coordinates: coordinates,
    textMetadata: textMetadata,
    status: status ?? this.status,
    requestedAt: requestedAt,
    startedAt: startedAt ?? this.startedAt,
    completedAt: completedAt ?? this.completedAt,
    result: result ?? this.result,
    failure: failure ?? this.failure,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    if (sessionId != null) 'session_id': sessionId,
    'run_id': runId,
    if (taskId != null) 'task_id': taskId,
    'type': type.serialized,
    'target_id': targetId,
    if (selector != null) 'selector': selector,
    if (coordinates != null) 'coordinates': coordinates,
    if (textMetadata != null) 'text_metadata': textMetadata,
    'status': status.serialized,
    'requested_at': requestedAt.toIso8601String(),
    if (startedAt != null) 'started_at': startedAt!.toIso8601String(),
    if (completedAt != null) 'completed_at': completedAt!.toIso8601String(),
    'result': result,
    if (failure != null) 'failure': failure,
  };

  factory ComputerAction.fromJson(Map<String, dynamic> json) => ComputerAction(
    id: json['id'] as String? ?? '',
    sessionId: json['session_id'] as String?,
    runId: json['run_id'] as String? ?? '',
    taskId: json['task_id'] as String?,
    type: ComputerActionType.fromString(json['type'] as String?),
    targetId: json['target_id'] as String? ?? '',
    selector: json['selector'] as String?,
    coordinates: json['coordinates'] as Map<String, dynamic>?,
    textMetadata: json['text_metadata'] as String?,
    status: ComputerActionStatus.fromString(json['status'] as String?),
    requestedAt: DateTime.tryParse(json['requested_at'] as String? ?? '')?.toUtc() ?? DateTime.now().toUtc(),
    startedAt: json['started_at'] != null ? DateTime.tryParse(json['started_at'] as String)?.toUtc() : null,
    completedAt: json['completed_at'] != null ? DateTime.tryParse(json['completed_at'] as String)?.toUtc() : null,
    result: (json['result'] as Map<String, dynamic>?) ?? const {},
    failure: json['failure'] as String?,
  );
}

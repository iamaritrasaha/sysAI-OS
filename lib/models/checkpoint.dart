/// SysAI OS domain model: RunCheckpoint
library;

/// A point-in-time snapshot of an active Run enabling pause/resume and crash recovery.
class RunCheckpoint {
  final String id;
  final String runId;
  final int stepIndex;
  final Map<String, dynamic> state;
  final DateTime createdAt;

  const RunCheckpoint({
    required this.id,
    required this.runId,
    required this.stepIndex,
    required this.state,
    required this.createdAt,
  });

  RunCheckpoint copyWith({
    String? id,
    String? runId,
    int? stepIndex,
    Map<String, dynamic>? state,
    DateTime? createdAt,
  }) => RunCheckpoint(
    id: id ?? this.id,
    runId: runId ?? this.runId,
    stepIndex: stepIndex ?? this.stepIndex,
    state: state ?? this.state,
    createdAt: createdAt ?? this.createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'run_id': runId,
    'step_index': stepIndex,
    'state': state,
    'created_at': createdAt.toIso8601String(),
  };

  factory RunCheckpoint.fromJson(Map<String, dynamic> json) => RunCheckpoint(
    id: json['id'] as String? ?? '',
    runId: json['run_id'] as String? ?? '',
    stepIndex: json['step_index'] as int? ?? 0,
    state: (json['state'] as Map<String, dynamic>?) ?? const {},
    createdAt: json['created_at'] != null
        ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
        : DateTime.now(),
  );
}

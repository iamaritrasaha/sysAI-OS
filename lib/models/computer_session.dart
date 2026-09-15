/// SysAI domain model: ComputerSession — one Run's aggregated Controlled
/// Computer Use activity against a single target. Mirrors
/// [BrowserSession]'s shape/role for consistency with the existing
/// per-Run session aggregates in this codebase.
library;

class ComputerSession {
  final String id;
  final String runId;
  final String targetId;
  final String targetTitle;
  final String? latestCapturePath;
  final int actionCount;
  final DateTime updatedAt;

  const ComputerSession({
    required this.id,
    required this.runId,
    required this.targetId,
    required this.targetTitle,
    this.latestCapturePath,
    this.actionCount = 0,
    required this.updatedAt,
  });

  ComputerSession copyWith({
    String? latestCapturePath,
    int? actionCount,
    DateTime? updatedAt,
  }) => ComputerSession(
    id: id,
    runId: runId,
    targetId: targetId,
    targetTitle: targetTitle,
    latestCapturePath: latestCapturePath ?? this.latestCapturePath,
    actionCount: actionCount ?? this.actionCount,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'run_id': runId,
    'target_id': targetId,
    'target_title': targetTitle,
    if (latestCapturePath != null) 'latest_capture_path': latestCapturePath,
    'action_count': actionCount,
    'updated_at': updatedAt.toIso8601String(),
  };

  factory ComputerSession.fromJson(Map<String, dynamic> json) => ComputerSession(
    id: json['id'] as String? ?? '',
    runId: json['run_id'] as String? ?? '',
    targetId: json['target_id'] as String? ?? '',
    targetTitle: json['target_title'] as String? ?? '',
    latestCapturePath: json['latest_capture_path'] as String?,
    actionCount: json['action_count'] as int? ?? 0,
    updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '')?.toUtc() ?? DateTime.now().toUtc(),
  );
}

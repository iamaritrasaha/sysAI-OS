/// SysAI OS domain model: ApprovalRequest and ApprovalStatus
library;

import 'capability.dart';

/// Current resolution state of an approval request.
enum ApprovalStatus {
  pending,
  approved,
  rejected,
  expired,
  cancelled;

  String get displayLabel => switch (this) {
    ApprovalStatus.pending => 'Pending',
    ApprovalStatus.approved => 'Approved',
    ApprovalStatus.rejected => 'Rejected',
    ApprovalStatus.expired => 'Expired',
    ApprovalStatus.cancelled => 'Cancelled',
  };

  String get serialized => name;

  static ApprovalStatus fromString(String? s) => switch (s?.toLowerCase()) {
    'pending' => ApprovalStatus.pending,
    'approved' => ApprovalStatus.approved,
    'rejected' => ApprovalStatus.rejected,
    'expired' => ApprovalStatus.expired,
    'cancelled' => ApprovalStatus.cancelled,
    _ => ApprovalStatus.pending,
  };
}

/// An interactive gating request requiring human review before proceeding.
class ApprovalRequest {
  final String id;
  final String runId;
  final String? taskId;
  final String capabilityId;
  final String title;
  final String explanation;
  final CapabilityRisk risk;
  final Map<String, dynamic> payload;
  final ApprovalStatus status;
  final DateTime createdAt;
  final DateTime? resolvedAt;

  const ApprovalRequest({
    required this.id,
    required this.runId,
    this.taskId,
    required this.capabilityId,
    required this.title,
    required this.explanation,
    required this.risk,
    this.payload = const {},
    this.status = ApprovalStatus.pending,
    required this.createdAt,
    this.resolvedAt,
  });

  bool get isPending => status == ApprovalStatus.pending;
  bool get isResolved => status != ApprovalStatus.pending;

  ApprovalRequest copyWith({
    String? id,
    String? runId,
    String? taskId,
    String? capabilityId,
    String? title,
    String? explanation,
    CapabilityRisk? risk,
    Map<String, dynamic>? payload,
    ApprovalStatus? status,
    DateTime? createdAt,
    DateTime? resolvedAt,
  }) => ApprovalRequest(
    id: id ?? this.id,
    runId: runId ?? this.runId,
    taskId: taskId ?? this.taskId,
    capabilityId: capabilityId ?? this.capabilityId,
    title: title ?? this.title,
    explanation: explanation ?? this.explanation,
    risk: risk ?? this.risk,
    payload: payload ?? this.payload,
    status: status ?? this.status,
    createdAt: createdAt ?? this.createdAt,
    resolvedAt: resolvedAt ?? this.resolvedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'run_id': runId,
    if (taskId != null) 'task_id': taskId,
    'capability_id': capabilityId,
    'title': title,
    'explanation': explanation,
    'risk': risk.serialized,
    'payload': payload,
    'status': status.serialized,
    'created_at': createdAt.toIso8601String(),
    if (resolvedAt != null) 'resolved_at': resolvedAt!.toIso8601String(),
  };

  factory ApprovalRequest.fromJson(Map<String, dynamic> json) => ApprovalRequest(
    id: json['id'] as String? ?? '',
    runId: json['run_id'] as String? ?? '',
    taskId: json['task_id'] as String?,
    capabilityId: json['capability_id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    explanation: json['explanation'] as String? ?? '',
    risk: CapabilityRisk.fromString(json['risk'] as String?),
    payload: (json['payload'] as Map<String, dynamic>?) ?? const {},
    status: ApprovalStatus.fromString(json['status'] as String?),
    createdAt: json['created_at'] != null
        ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
        : DateTime.now(),
    resolvedAt: json['resolved_at'] != null
        ? DateTime.tryParse(json['resolved_at'] as String)
        : null,
  );
}

/// SysAI domain model: AppNotification — a user-attention object.
///
/// Distinct from the Activity timeline: Activity is "what happened,"
/// notifications are "what requires or required the user's attention."
/// Not every structured event becomes one.
library;

enum NotificationType {
  runCompleted,
  runFailed,
  runInterrupted,
  approvalRequired,
  runBlocked,
  automationFailed,
  automationMissed;

  String get displayLabel => switch (this) {
    NotificationType.runCompleted => 'Run Completed',
    NotificationType.runFailed => 'Run Failed',
    NotificationType.runInterrupted => 'Run Interrupted',
    NotificationType.approvalRequired => 'Approval Required',
    NotificationType.runBlocked => 'Run Blocked',
    NotificationType.automationFailed => 'Automation Failed',
    NotificationType.automationMissed => 'Automation Missed',
  };

  static NotificationType fromString(String s) => switch (s) {
    'run_completed' => NotificationType.runCompleted,
    'run_failed' => NotificationType.runFailed,
    'run_interrupted' => NotificationType.runInterrupted,
    'approval_required' => NotificationType.approvalRequired,
    'run_blocked' => NotificationType.runBlocked,
    'automation_failed' => NotificationType.automationFailed,
    'automation_missed' => NotificationType.automationMissed,
    _ => NotificationType.runCompleted,
  };

  String get serialized => switch (this) {
    NotificationType.runCompleted => 'run_completed',
    NotificationType.runFailed => 'run_failed',
    NotificationType.runInterrupted => 'run_interrupted',
    NotificationType.approvalRequired => 'approval_required',
    NotificationType.runBlocked => 'run_blocked',
    NotificationType.automationFailed => 'automation_failed',
    NotificationType.automationMissed => 'automation_missed',
  };
}

class AppNotification {
  final String id;
  final NotificationType type;
  final String title;
  final String message;
  final String? runId;
  final DateTime createdAt;
  final bool read;

  const AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.message,
    this.runId,
    required this.createdAt,
    this.read = false,
  });

  AppNotification copyWith({bool? read}) => AppNotification(
    id: id,
    type: type,
    title: title,
    message: message,
    runId: runId,
    createdAt: createdAt,
    read: read ?? this.read,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.serialized,
    'title': title,
    'message': message,
    if (runId != null) 'run_id': runId,
    'created_at': createdAt.toIso8601String(),
    'read': read,
  };

  factory AppNotification.fromJson(Map<String, dynamic> json) => AppNotification(
    id: json['id'] as String,
    type: NotificationType.fromString(json['type'] as String? ?? ''),
    title: json['title'] as String? ?? '',
    message: json['message'] as String? ?? '',
    runId: json['run_id'] as String?,
    createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ?? DateTime.now(),
    read: json['read'] as bool? ?? false,
  );
}

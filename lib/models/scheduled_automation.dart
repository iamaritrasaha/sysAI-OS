/// SysAI domain model: ScheduledAutomation — a persistent, recurring or
/// one-time trigger that creates a normal Run when due.
///
/// A ScheduledAutomation is never itself a unit of execution — firing one
/// only ever creates a normal [Run] through the same pipeline a
/// user-initiated Run goes through. This model holds only durable domain
/// state (schedule, persisted model selection, last outcome) — never
/// UI-specific state like "which editor tab was open."
library;

// ── AutomationScheduleType ──────────────────────────────────────────────────

enum AutomationScheduleType {
  once,
  interval,
  daily,
  weekly;

  String get serialized => name;

  static AutomationScheduleType fromString(String? s) => switch (s) {
    'once' => AutomationScheduleType.once,
    'interval' => AutomationScheduleType.interval,
    'daily' => AutomationScheduleType.daily,
    'weekly' => AutomationScheduleType.weekly,
    _ => AutomationScheduleType.once,
  };

  String get displayLabel => switch (this) {
    AutomationScheduleType.once => 'Once',
    AutomationScheduleType.interval => 'Every N hours',
    AutomationScheduleType.daily => 'Daily',
    AutomationScheduleType.weekly => 'Weekly',
  };
}

// ── AutomationResult ─────────────────────────────────────────────────────────

/// The outcome of the automation's most recent firing. Distinct from
/// [Run.status] — this is what the Automations list shows without having
/// to join against the Run it produced.
enum AutomationResult {
  none,
  success,
  failure,
  missed;

  String get serialized => name;

  static AutomationResult fromString(String? s) => switch (s) {
    'success' => AutomationResult.success,
    'failure' => AutomationResult.failure,
    'missed' => AutomationResult.missed,
    _ => AutomationResult.none,
  };

  String get displayLabel => switch (this) {
    AutomationResult.none => 'Never run',
    AutomationResult.success => 'Succeeded',
    AutomationResult.failure => 'Failed',
    AutomationResult.missed => 'Missed',
  };
}

// ── ScheduledAutomation ───────────────────────────────────────────────────────

class ScheduledAutomation {
  final String id;
  final String title;
  final String goal;
  final String workspacePath;
  final String? providerId;
  final String? modelId;
  final String? modelDisplayName;

  final AutomationScheduleType scheduleType;

  /// Type-dependent structured schedule fields — never raw UI widget
  /// state. Keys used per [scheduleType]:
  ///  - once:     (none — the single instant lives in [nextTriggerAt])
  ///  - interval: {'minutes': int}
  ///  - daily:    {'hour': int, 'minute': int}
  ///  - weekly:   {'hour': int, 'minute': int, 'weekday': int} (1=Mon..7=Sun)
  final Map<String, dynamic> scheduleExpression;

  /// IANA timezone name (e.g. "Australia/Sydney") the schedule's wall-clock
  /// fields are interpreted in. Irrelevant for [AutomationScheduleType.interval]
  /// (pure elapsed duration) but always persisted for display purposes.
  final String timezone;

  final bool enabled;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// UTC instant this automation last actually fired, or null if never.
  final DateTime? lastTriggeredAt;

  /// UTC instant this automation is next due. Null only for a `once`
  /// automation that has already fired (nothing further is scheduled).
  final DateTime? nextTriggerAt;

  final String? lastRunId;
  final AutomationResult lastResult;

  const ScheduledAutomation({
    required this.id,
    required this.title,
    required this.goal,
    required this.workspacePath,
    this.providerId,
    this.modelId,
    this.modelDisplayName,
    required this.scheduleType,
    this.scheduleExpression = const {},
    required this.timezone,
    this.enabled = true,
    required this.createdAt,
    required this.updatedAt,
    this.lastTriggeredAt,
    this.nextTriggerAt,
    this.lastRunId,
    this.lastResult = AutomationResult.none,
  });

  factory ScheduledAutomation.create({
    required String id,
    required String goal,
    required String workspacePath,
    required AutomationScheduleType scheduleType,
    Map<String, dynamic> scheduleExpression = const {},
    required String timezone,
    String? providerId,
    String? modelId,
    String? modelDisplayName,
    DateTime? nextTriggerAt,
  }) {
    final now = DateTime.now().toUtc();
    return ScheduledAutomation(
      id: id,
      title: _titleFromGoal(goal),
      goal: goal,
      workspacePath: workspacePath,
      providerId: providerId,
      modelId: modelId,
      modelDisplayName: modelDisplayName,
      scheduleType: scheduleType,
      scheduleExpression: scheduleExpression,
      timezone: timezone,
      createdAt: now,
      updatedAt: now,
      nextTriggerAt: nextTriggerAt,
    );
  }

  static String _titleFromGoal(String goal) {
    final trimmed = goal.trim();
    if (trimmed.length <= 60) return trimmed;
    return '${trimmed.substring(0, 57)}...';
  }

  ScheduledAutomation copyWith({
    String? title,
    String? goal,
    String? workspacePath,
    String? providerId,
    String? modelId,
    String? modelDisplayName,
    AutomationScheduleType? scheduleType,
    Map<String, dynamic>? scheduleExpression,
    String? timezone,
    bool? enabled,
    DateTime? updatedAt,
    DateTime? lastTriggeredAt,
    DateTime? nextTriggerAt,
    bool clearNextTriggerAt = false,
    String? lastRunId,
    AutomationResult? lastResult,
  }) => ScheduledAutomation(
    id: id,
    title: title ?? this.title,
    goal: goal ?? this.goal,
    workspacePath: workspacePath ?? this.workspacePath,
    providerId: providerId ?? this.providerId,
    modelId: modelId ?? this.modelId,
    modelDisplayName: modelDisplayName ?? this.modelDisplayName,
    scheduleType: scheduleType ?? this.scheduleType,
    scheduleExpression: scheduleExpression ?? this.scheduleExpression,
    timezone: timezone ?? this.timezone,
    enabled: enabled ?? this.enabled,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    lastTriggeredAt: lastTriggeredAt ?? this.lastTriggeredAt,
    nextTriggerAt: clearNextTriggerAt ? null : (nextTriggerAt ?? this.nextTriggerAt),
    lastRunId: lastRunId ?? this.lastRunId,
    lastResult: lastResult ?? this.lastResult,
  );

  /// True when this automation was configured with an explicit model,
  /// mirroring [Run.hasModelOverride] — an automation without one resolves
  /// against the global default *at firing time*, same as a manual Run.
  bool get hasModelOverride => modelId != null && modelId!.isNotEmpty;

  String get modelLabel => modelDisplayName ?? modelId ?? 'Default Model';

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'goal': goal,
    'workspace_path': workspacePath,
    if (providerId != null) 'provider_id': providerId,
    if (modelId != null) 'model_id': modelId,
    if (modelDisplayName != null) 'model_display_name': modelDisplayName,
    'schedule_type': scheduleType.serialized,
    'schedule_expression': scheduleExpression,
    'timezone': timezone,
    'enabled': enabled,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    if (lastTriggeredAt != null) 'last_triggered_at': lastTriggeredAt!.toIso8601String(),
    if (nextTriggerAt != null) 'next_trigger_at': nextTriggerAt!.toIso8601String(),
    if (lastRunId != null) 'last_run_id': lastRunId,
    'last_result': lastResult.serialized,
  };

  factory ScheduledAutomation.fromJson(Map<String, dynamic> json) => ScheduledAutomation(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    goal: json['goal'] as String? ?? '',
    workspacePath: json['workspace_path'] as String? ?? '',
    providerId: json['provider_id'] as String?,
    modelId: json['model_id'] as String?,
    modelDisplayName: json['model_display_name'] as String?,
    scheduleType: AutomationScheduleType.fromString(json['schedule_type'] as String?),
    scheduleExpression: (json['schedule_expression'] as Map<String, dynamic>?) ?? const {},
    timezone: json['timezone'] as String? ?? 'UTC',
    enabled: json['enabled'] as bool? ?? true,
    createdAt: DateTime.tryParse(json['created_at'] as String? ?? '')?.toUtc() ?? DateTime.now().toUtc(),
    updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '')?.toUtc() ?? DateTime.now().toUtc(),
    lastTriggeredAt: json['last_triggered_at'] != null
        ? DateTime.tryParse(json['last_triggered_at'] as String)?.toUtc()
        : null,
    nextTriggerAt: json['next_trigger_at'] != null
        ? DateTime.tryParse(json['next_trigger_at'] as String)?.toUtc()
        : null,
    lastRunId: json['last_run_id'] as String?,
    lastResult: AutomationResult.fromString(json['last_result'] as String?),
  );
}

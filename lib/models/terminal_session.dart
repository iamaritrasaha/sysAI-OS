/// SysAI domain model: TerminalSession — a structured command execution.
///
/// Individual output lines are NOT part of this model or persisted here;
/// they stream through an ephemeral, bounded in-memory buffer
/// (`terminalLiveOutputProvider`) while the session is active. Only the
/// session's summary — command, status, exit code, a bounded output
/// preview — is durable, so a Run with a very chatty command doesn't turn
/// into thousands of SQLite writes.
library;

enum TerminalSessionStatus {
  running,
  completed,
  failed,
  timedOut;

  String get displayLabel => switch (this) {
    TerminalSessionStatus.running => 'Running',
    TerminalSessionStatus.completed => 'Completed',
    TerminalSessionStatus.failed => 'Failed',
    TerminalSessionStatus.timedOut => 'Timed Out',
  };

  static TerminalSessionStatus fromString(String s) => switch (s) {
    'running' => TerminalSessionStatus.running,
    'completed' => TerminalSessionStatus.completed,
    'timed_out' || 'timedout' => TerminalSessionStatus.timedOut,
    _ => TerminalSessionStatus.failed,
  };

  String get serialized => switch (this) {
    TerminalSessionStatus.timedOut => 'timed_out',
    _ => name,
  };
}

class TerminalSession {
  final String id;
  final String runId;
  final String? taskId;
  final String command;
  final String cwd;
  final TerminalSessionStatus status;
  final int? exitCode;
  final bool truncated;
  final String outputPreview;
  final DateTime startedAt;
  final DateTime? completedAt;

  const TerminalSession({
    required this.id,
    required this.runId,
    this.taskId,
    required this.command,
    required this.cwd,
    required this.status,
    this.exitCode,
    this.truncated = false,
    this.outputPreview = '',
    required this.startedAt,
    this.completedAt,
  });

  TerminalSession copyWith({
    TerminalSessionStatus? status,
    int? exitCode,
    bool? truncated,
    String? outputPreview,
    DateTime? completedAt,
  }) => TerminalSession(
    id: id,
    runId: runId,
    taskId: taskId,
    command: command,
    cwd: cwd,
    status: status ?? this.status,
    exitCode: exitCode ?? this.exitCode,
    truncated: truncated ?? this.truncated,
    outputPreview: outputPreview ?? this.outputPreview,
    startedAt: startedAt,
    completedAt: completedAt ?? this.completedAt,
  );

  Duration? get elapsed => completedAt?.difference(startedAt);

  Map<String, dynamic> toJson() => {
    'id': id,
    'run_id': runId,
    if (taskId != null) 'task_id': taskId,
    'command': command,
    'cwd': cwd,
    'status': status.serialized,
    if (exitCode != null) 'exit_code': exitCode,
    'truncated': truncated,
    'output_preview': outputPreview,
    'started_at': startedAt.toIso8601String(),
    if (completedAt != null) 'completed_at': completedAt!.toIso8601String(),
  };

  factory TerminalSession.fromJson(Map<String, dynamic> json) => TerminalSession(
    id: json['id'] as String,
    runId: json['run_id'] as String,
    taskId: json['task_id'] as String?,
    command: json['command'] as String? ?? '',
    cwd: json['cwd'] as String? ?? '.',
    status: TerminalSessionStatus.fromString(json['status'] as String? ?? 'running'),
    exitCode: json['exit_code'] as int?,
    truncated: json['truncated'] as bool? ?? false,
    outputPreview: json['output_preview'] as String? ?? '',
    startedAt: DateTime.tryParse(json['started_at'] as String? ?? '') ?? DateTime.now(),
    completedAt: json['completed_at'] != null ? DateTime.tryParse(json['completed_at'] as String) : null,
  );
}

/// One streamed line of terminal output — ephemeral only, never persisted.
class TerminalOutputLine {
  final String stream; // 'stdout' | 'stderr'
  final String text;

  const TerminalOutputLine({required this.stream, required this.text});
}

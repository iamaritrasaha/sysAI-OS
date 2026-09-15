/// SysAI OS domain model: Artifact and ArtifactType
library;

/// Category of an artifact generated during a Run.
enum ArtifactType {
  file,
  diff,
  report,
  commandOutput,
  diagnostic,
  terminalLog,
  browserCapture,
  downloadedFile,
  screenshot;

  String get displayLabel => switch (this) {
    ArtifactType.file => 'File',
    ArtifactType.diff => 'Diff',
    ArtifactType.report => 'Report',
    ArtifactType.commandOutput => 'Output Log',
    ArtifactType.diagnostic => 'Diagnostic',
    ArtifactType.terminalLog => 'Terminal Log',
    ArtifactType.browserCapture => 'Page Capture',
    ArtifactType.downloadedFile => 'Download',
    ArtifactType.screenshot => 'Screenshot',
  };

  String get serialized => switch (this) {
    ArtifactType.commandOutput => 'command_output',
    ArtifactType.terminalLog => 'terminal_log',
    ArtifactType.browserCapture => 'browser_capture',
    ArtifactType.downloadedFile => 'downloaded_file',
    _ => name,
  };

  static ArtifactType fromString(String? s) => switch (s?.toLowerCase()) {
    'file' => ArtifactType.file,
    'diff' => ArtifactType.diff,
    'report' => ArtifactType.report,
    'command_output' || 'commandoutput' => ArtifactType.commandOutput,
    'diagnostic' => ArtifactType.diagnostic,
    'terminal_log' || 'terminallog' => ArtifactType.terminalLog,
    'browser_capture' || 'browsercapture' => ArtifactType.browserCapture,
    'downloaded_file' || 'downloadedfile' => ArtifactType.downloadedFile,
    'screenshot' => ArtifactType.screenshot,
    _ => ArtifactType.report,
  };
}

/// A durable artifact produced by an autonomous run.
class Artifact {
  final String id;
  final String runId;
  final String? taskId;
  final ArtifactType type;
  final String title;
  final String? path;
  final String? contentPreview;
  final Map<String, dynamic> metadata;
  final DateTime createdAt;

  const Artifact({
    required this.id,
    required this.runId,
    this.taskId,
    required this.type,
    required this.title,
    this.path,
    this.contentPreview,
    this.metadata = const {},
    required this.createdAt,
  });

  Artifact copyWith({
    String? id,
    String? runId,
    String? taskId,
    ArtifactType? type,
    String? title,
    String? path,
    String? contentPreview,
    Map<String, dynamic>? metadata,
    DateTime? createdAt,
  }) => Artifact(
    id: id ?? this.id,
    runId: runId ?? this.runId,
    taskId: taskId ?? this.taskId,
    type: type ?? this.type,
    title: title ?? this.title,
    path: path ?? this.path,
    contentPreview: contentPreview ?? this.contentPreview,
    metadata: metadata ?? this.metadata,
    createdAt: createdAt ?? this.createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'run_id': runId,
    if (taskId != null) 'task_id': taskId,
    'type': type.serialized,
    'title': title,
    if (path != null) 'path': path,
    if (contentPreview != null) 'content_preview': contentPreview,
    'metadata': metadata,
    'created_at': createdAt.toIso8601String(),
  };

  factory Artifact.fromJson(Map<String, dynamic> json) => Artifact(
    id: json['id'] as String? ?? '',
    runId: json['run_id'] as String? ?? '',
    taskId: json['task_id'] as String?,
    type: ArtifactType.fromString(json['type'] as String?),
    title: json['title'] as String? ?? '',
    path: json['path'] as String?,
    contentPreview: json['content_preview'] as String?,
    metadata: (json['metadata'] as Map<String, dynamic>?) ?? const {},
    createdAt: json['created_at'] != null
        ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
        : DateTime.now(),
  );
}

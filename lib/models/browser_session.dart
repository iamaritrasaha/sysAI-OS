/// SysAI domain model: BrowserSession — an agent's aggregated browsing
/// activity for one Run.
///
/// Phase 3's browser capability fetches and extracts pages over HTTP; it
/// does not run a live rendering browser process, so there is no live
/// process state to persist here — only the meaningful trail of what was
/// visited, which is exactly what a user reviewing the Run would want.
library;

class BrowserNavigationEntry {
  final String url;
  final String? title;
  final int? statusCode;
  final DateTime at;

  const BrowserNavigationEntry({
    required this.url,
    this.title,
    this.statusCode,
    required this.at,
  });

  Map<String, dynamic> toJson() => {
    'url': url,
    if (title != null) 'title': title,
    if (statusCode != null) 'status_code': statusCode,
    'at': at.toIso8601String(),
  };

  factory BrowserNavigationEntry.fromJson(Map<String, dynamic> json) => BrowserNavigationEntry(
    url: json['url'] as String? ?? '',
    title: json['title'] as String?,
    statusCode: json['status_code'] as int?,
    at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
  );
}

class BrowserSession {
  final String id;
  final String runId;
  final String? currentUrl;
  final String? currentTitle;
  final List<BrowserNavigationEntry> history;
  final int downloadCount;
  final int captureCount;
  final DateTime updatedAt;

  const BrowserSession({
    required this.id,
    required this.runId,
    this.currentUrl,
    this.currentTitle,
    this.history = const [],
    this.downloadCount = 0,
    this.captureCount = 0,
    required this.updatedAt,
  });

  BrowserSession copyWith({
    String? currentUrl,
    String? currentTitle,
    List<BrowserNavigationEntry>? history,
    int? downloadCount,
    int? captureCount,
    DateTime? updatedAt,
  }) => BrowserSession(
    id: id,
    runId: runId,
    currentUrl: currentUrl ?? this.currentUrl,
    currentTitle: currentTitle ?? this.currentTitle,
    history: history ?? this.history,
    downloadCount: downloadCount ?? this.downloadCount,
    captureCount: captureCount ?? this.captureCount,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'run_id': runId,
    if (currentUrl != null) 'current_url': currentUrl,
    if (currentTitle != null) 'current_title': currentTitle,
    'history': history.map((h) => h.toJson()).toList(),
    'download_count': downloadCount,
    'capture_count': captureCount,
    'updated_at': updatedAt.toIso8601String(),
  };

  factory BrowserSession.fromJson(Map<String, dynamic> json) => BrowserSession(
    id: json['id'] as String,
    runId: json['run_id'] as String,
    currentUrl: json['current_url'] as String?,
    currentTitle: json['current_title'] as String?,
    history: (json['history'] as List<dynamic>?)
            ?.map((h) => BrowserNavigationEntry.fromJson(h as Map<String, dynamic>))
            .toList() ??
        const [],
    downloadCount: json['download_count'] as int? ?? 0,
    captureCount: json['capture_count'] as int? ?? 0,
    updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ?? DateTime.now(),
  );
}

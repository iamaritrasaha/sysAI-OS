/// Model and Provider domain models for SysAI OS.
library;

/// Represents a model discovered from SysAI providers.
class ModelInfo {
  final String id;
  final String name;
  final String provider;
  final String displayName;
  final bool available;
  final String? unavailableReason;
  final int? contextWindow;
  final List<String> capabilities;
  final bool local;
  final Map<String, dynamic> metadata;

  const ModelInfo({
    required this.id,
    required this.name,
    required this.provider,
    required this.displayName,
    this.available = true,
    this.unavailableReason,
    this.contextWindow,
    this.capabilities = const [],
    this.local = true,
    this.metadata = const {},
  });

  ModelInfo copyWith({
    String? id,
    String? name,
    String? provider,
    String? displayName,
    bool? available,
    String? unavailableReason,
    int? contextWindow,
    List<String>? capabilities,
    bool? local,
    Map<String, dynamic>? metadata,
  }) =>
      ModelInfo(
        id: id ?? this.id,
        name: name ?? this.name,
        provider: provider ?? this.provider,
        displayName: displayName ?? this.displayName,
        available: available ?? this.available,
        unavailableReason: unavailableReason ?? this.unavailableReason,
        contextWindow: contextWindow ?? this.contextWindow,
        capabilities: capabilities ?? this.capabilities,
        local: local ?? this.local,
        metadata: metadata ?? this.metadata,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'provider': provider,
        'display_name': displayName,
        'available': available,
        if (unavailableReason != null) 'unavailable_reason': unavailableReason,
        if (contextWindow != null) 'context_window': contextWindow,
        if (capabilities.isNotEmpty) 'capabilities': capabilities,
        'local': local,
        if (metadata.isNotEmpty) 'metadata': metadata,
      };

  factory ModelInfo.fromJson(Map<String, dynamic> json) => ModelInfo(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        provider: json['provider'] as String? ?? 'ollama',
        displayName: json['display_name'] as String? ?? json['name'] as String? ?? '',
        available: json['available'] as bool? ?? true,
        unavailableReason: json['unavailable_reason'] as String?,
        contextWindow: json['context_window'] as int?,
        capabilities: (json['capabilities'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        local: json['local'] as bool? ?? true,
        metadata: (json['metadata'] as Map<String, dynamic>?) ?? const {},
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelInfo &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          provider == other.provider;

  @override
  int get hashCode => Object.hash(id, name, provider);

  @override
  String toString() => 'ModelInfo($id, $provider, available: $available)';
}

/// Represents an LLM provider and its connectivity / configuration status.
class ProviderInfo {
  final String id;
  final String name;
  final bool available;
  final bool configured;
  final String? statusMessage;
  final bool local;
  final int modelsCount;
  final List<ModelInfo> models;

  const ProviderInfo({
    required this.id,
    required this.name,
    this.available = false,
    this.configured = false,
    this.statusMessage,
    this.local = true,
    this.modelsCount = 0,
    this.models = const [],
  });

  ProviderInfo copyWith({
    String? id,
    String? name,
    bool? available,
    bool? configured,
    String? statusMessage,
    bool? local,
    int? modelsCount,
    List<ModelInfo>? models,
  }) =>
      ProviderInfo(
        id: id ?? this.id,
        name: name ?? this.name,
        available: available ?? this.available,
        configured: configured ?? this.configured,
        statusMessage: statusMessage ?? this.statusMessage,
        local: local ?? this.local,
        modelsCount: modelsCount ?? this.modelsCount,
        models: models ?? this.models,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'available': available,
        'configured': configured,
        if (statusMessage != null) 'status_message': statusMessage,
        'local': local,
        'models_count': modelsCount,
        if (models.isNotEmpty) 'models': models.map((m) => m.toJson()).toList(),
      };

  factory ProviderInfo.fromJson(Map<String, dynamic> json) => ProviderInfo(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        available: json['available'] as bool? ?? false,
        configured: json['configured'] as bool? ?? false,
        statusMessage: json['status_message'] as String?,
        local: json['local'] as bool? ?? true,
        modelsCount: json['models_count'] as int? ?? 0,
        models: (json['models'] as List<dynamic>?)
                ?.map((m) => ModelInfo.fromJson(m as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProviderInfo &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'ProviderInfo($id, available: $available, configured: $configured)';
}

/// SysAI OS's own persisted default model choice — independent of whatever
/// SysAI's own config.toml says. Resolved when a new [Run] is created unless
/// the user picks a one-time override in the goal composer.
class DefaultModelSelection {
  final String? providerId;
  final String? modelId;
  final String? modelDisplayName;

  const DefaultModelSelection({this.providerId, this.modelId, this.modelDisplayName});

  bool get isSet => providerId != null && modelId != null;

  static const DefaultModelSelection unset = DefaultModelSelection();

  DefaultModelSelection copyWith({
    String? providerId,
    String? modelId,
    String? modelDisplayName,
  }) =>
      DefaultModelSelection(
        providerId: providerId ?? this.providerId,
        modelId: modelId ?? this.modelId,
        modelDisplayName: modelDisplayName ?? this.modelDisplayName,
      );
}

/// SysAI OS domain model: Capability and CapabilityRisk
library;

/// Risk tiers for capabilities and operations.
enum CapabilityRisk {
  observe,
  low,
  medium,
  high,
  privileged;

  String get displayLabel => switch (this) {
    CapabilityRisk.observe => 'Observe',
    CapabilityRisk.low => 'Low Risk',
    CapabilityRisk.medium => 'Medium Risk',
    CapabilityRisk.high => 'High Risk',
    CapabilityRisk.privileged => 'Privileged',
  };

  String get serialized => name;

  static CapabilityRisk fromString(String? s) => switch (s?.toLowerCase()) {
    'observe' => CapabilityRisk.observe,
    'low' => CapabilityRisk.low,
    'medium' => CapabilityRisk.medium,
    'high' => CapabilityRisk.high,
    'privileged' => CapabilityRisk.privileged,
    _ => CapabilityRisk.medium,
  };
}

/// A capability exposed to autonomous runs by the SysAI OS engine.
class Capability {
  final String id;
  final String name;
  final String description;
  final String category; // 'filesystem', 'shell', 'git', 'system', 'sysai'
  final CapabilityRisk risk;
  final bool requiresApproval;
  final Map<String, dynamic>? inputSchema;

  const Capability({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.risk,
    this.requiresApproval = false,
    this.inputSchema,
  });

  Capability copyWith({
    String? id,
    String? name,
    String? description,
    String? category,
    CapabilityRisk? risk,
    bool? requiresApproval,
    Map<String, dynamic>? inputSchema,
  }) => Capability(
    id: id ?? this.id,
    name: name ?? this.name,
    description: description ?? this.description,
    category: category ?? this.category,
    risk: risk ?? this.risk,
    requiresApproval: requiresApproval ?? this.requiresApproval,
    inputSchema: inputSchema ?? this.inputSchema,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'category': category,
    'risk': risk.serialized,
    'requires_approval': requiresApproval,
    if (inputSchema != null) 'input_schema': inputSchema,
  };

  factory Capability.fromJson(Map<String, dynamic> json) => Capability(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
    category: json['category'] as String? ?? 'general',
    risk: CapabilityRisk.fromString(json['risk'] as String?),
    requiresApproval: json['requires_approval'] as bool? ?? false,
    inputSchema: json['input_schema'] as Map<String, dynamic>?,
  );
}

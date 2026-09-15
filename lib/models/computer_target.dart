/// SysAI domain model: ComputerTarget — an explicit, identity-checked
/// surface Controlled Computer Use is allowed to act on.
///
/// There is deliberately no representation of "the desktop" as a target.
/// A capability call whose `target_id` doesn't match a registered
/// [ComputerTarget] is denied by the Policy Engine on identity, not left to
/// UI convention — see `policy_engine.py::_evaluate_computer`.
library;

enum ComputerTargetType {
  /// A SysAI-owned Flutter surface, executed in-process — the only type
  /// with a real handler in this phase.
  sysaiTestSurface,

  /// An explicitly registered external development/test window. Modeled
  /// so the architecture doesn't preclude it, but — like Phase 3's
  /// click/type/key before this phase — intentionally not implemented:
  /// there is no OS-level input executor behind it yet.
  registeredWindow;

  String get serialized => name;
}

enum ComputerTrustLevel {
  /// Fully controlled: SysAI owns the surface end-to-end.
  trusted,

  /// Explicitly registered by a developer, but not SysAI-owned.
  registered;

  String get serialized => name;
}

class ComputerTarget {
  final String id;
  final ComputerTargetType type;
  final String title;
  final List<String> allowedActions;
  final ComputerTrustLevel trustLevel;

  const ComputerTarget({
    required this.id,
    required this.type,
    required this.title,
    required this.allowedActions,
    required this.trustLevel,
  });

  /// The single target implemented this phase — a deterministic,
  /// SysAI-owned Flutter surface (see `computer_test_surface_view.dart`).
  static const sysaiTestSurface = ComputerTarget(
    id: 'sysai-test-surface',
    type: ComputerTargetType.sysaiTestSurface,
    title: 'SysAI OS Test Surface',
    allowedActions: ['observe', 'capture', 'click', 'type', 'key', 'scroll'],
    trustLevel: ComputerTrustLevel.trusted,
  );
}

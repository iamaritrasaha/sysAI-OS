/// Linux desktop notification integration via `notify-send`.
///
/// Deliberately not a pub package: `notify-send` ships with every
/// freedesktop-notification-spec desktop (GNOME, KDE, XFCE, ...) already
/// installed, so shelling out to it needs zero new dependencies and no
/// platform channel / FFI binding to maintain. If it's missing, notifications
/// are silently skipped — never a crash.
library;

import 'dart:io';

class NotificationService {
  bool? _available;

  Future<bool> _isAvailable() async {
    if (_available != null) return _available!;
    try {
      final result = await Process.run('which', ['notify-send']);
      _available = result.exitCode == 0;
    } catch (_) {
      _available = false;
    }
    return _available!;
  }

  /// Fires a desktop notification. Never throws — a missing/broken
  /// notification daemon must never affect Run execution.
  Future<void> notify({
    required String title,
    required String body,
    String urgency = 'normal', // low | normal | critical
  }) async {
    try {
      if (!await _isAvailable()) return;
      await Process.run('notify-send', [
        '--app-name=SysAI OS',
        '--urgency=$urgency',
        title,
        body,
      ]);
    } catch (_) {
      // Best-effort only.
    }
  }
}

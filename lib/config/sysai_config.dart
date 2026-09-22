import 'dart:io';
import 'package:path/path.dart' as p;

/// Static configuration and path-resolution helpers for SysAI_OS.
///
/// At runtime the app needs to locate:
/// 1. The SysAI Python source tree.
/// 2. The bridge script itself (`bridge/sysai_bridge.py` or installed `runtime/sysai_bridge.py`).
abstract final class SysAIConfig {
  static const String appName = 'SysAI OS';
  static const String appVersion = '1.0.0';

  static String get xdgDataHome {
    final env = Platform.environment['XDG_DATA_HOME'];
    if (env != null && env.trim().isNotEmpty) return env.trim();
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return p.join(home, '.local', 'share');
  }

  static String get xdgStateHome {
    final env = Platform.environment['XDG_STATE_HOME'];
    if (env != null && env.trim().isNotEmpty) return env.trim();
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return p.join(home, '.local', 'state');
  }

  static String get xdgConfigHome {
    final env = Platform.environment['XDG_CONFIG_HOME'];
    if (env != null && env.trim().isNotEmpty) return env.trim();
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return p.join(home, '.config');
  }

  static String get xdgCacheHome {
    final env = Platform.environment['XDG_CACHE_HOME'];
    if (env != null && env.trim().isNotEmpty) return env.trim();
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return p.join(home, '.cache');
  }

  static String get xdgRuntimeDir {
    final env = Platform.environment['XDG_RUNTIME_DIR'];
    if (env != null && env.trim().isNotEmpty) return env.trim();
    return p.join(xdgStateHome, 'sysai-os', 'runtime');
  }

  /// True if running in installed mode (e.g. from ~/.local/share/sysai-os).
  static bool get isInstalledMode {
    final installedBridge = p.join(xdgDataHome, 'sysai-os', 'runtime', bridgeScriptName);
    if (File(installedBridge).existsSync()) return true;

    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final relBridge = p.join(p.dirname(exeDir), 'runtime', bridgeScriptName);
      if (File(relBridge).existsSync()) return true;
    } catch (_) {}

    return false;
  }

  /// Python executable: installed venv python if available, else 'python3'.
  static String get python3Executable {
    final venvPython = p.join(xdgDataHome, 'sysai-os', 'venv', 'bin', 'python3');
    if (File(venvPython).existsSync()) return venvPython;

    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final relVenvPython = p.join(p.dirname(exeDir), 'venv', 'bin', 'python3');
      if (File(relVenvPython).existsSync()) return relVenvPython;
    } catch (_) {}

    return 'python3';
  }

  /// Last-resort default path to the SysAI Python source tree, used only
  /// when neither `SYSAI_PATH` nor a `.sysai_path` file is set. Mirrors
  /// the same portable sibling-directory guess
  /// `bridge/sysai_bridge.py::_find_sysai_path()` already tries on the
  /// Python side — a structural guess relative to this repo's own
  /// location, never one developer's absolute home directory.
  static String get defaultSysAIPath {
    final root = _projectRoot ?? Directory.current.path;
    return p.join(p.dirname(p.dirname(root)), 'Projects', 'sysai', 'src');
  }

  /// The filename of the Python bridge script.
  static const String bridgeScriptName = 'sysai_bridge.py';

  /// Default workspace root for a new Run/Automation — the same implicit
  /// default the bridge itself falls back to (`workspace_root` omitted)
  /// when no explicit path is supplied: the SysAI_OS project root.
  static String get defaultWorkspacePath => _projectRoot ?? Directory.current.path;

  /// Discovers the project root of SysAI_OS.
  static String? get _projectRoot {
    // 1. Current working directory
    try {
      final cwd = Directory.current.path;
      if (File(p.join(cwd, 'bridge', bridgeScriptName)).existsSync()) {
        return cwd;
      }
    } catch (_) {}

    // 2. Walk up from executable
    try {
      var dir = Directory(p.dirname(Platform.resolvedExecutable));
      for (int i = 0; i < 6; i++) {
        if (File(p.join(dir.path, 'bridge', bridgeScriptName)).existsSync()) {
          return dir.path;
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    } catch (_) {}

    return null;
  }

  /// Absolute path to the bridge script. Falls back to a path relative to
  /// the current working directory (rather than a hardcoded machine path)
  /// if [_projectRoot] discovery comes up empty.
  static String get bridgeScriptPath {
    final root = _projectRoot;
    if (root != null) {
      final candidate = p.join(root, 'bridge', bridgeScriptName);
      if (File(candidate).existsSync()) return candidate;
    }

    final installed = p.join(xdgDataHome, 'sysai-os', 'runtime', bridgeScriptName);
    if (File(installed).existsSync()) return installed;

    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final relBridge = p.join(p.dirname(exeDir), 'runtime', bridgeScriptName);
      if (File(relBridge).existsSync()) return relBridge;
    } catch (_) {}

    return p.join(Directory.current.path, 'bridge', bridgeScriptName);
  }

  static String getBridgeScriptPath() => bridgeScriptPath;

  /// Synchronously discovers the SysAI source path.
  static String discoverSysAIPathSync() {
    // 1. Environment variable
    final env = Platform.environment['SYSAI_PATH'];
    if (env != null && env.trim().isNotEmpty) {
      return env.trim();
    }

    // 2. .sysai_path file in project root
    final root = _projectRoot ?? Directory.current.path;
    final dotFile = File(p.join(root, '.sysai_path'));
    if (dotFile.existsSync()) {
      try {
        final content = dotFile.readAsStringSync().trim();
        if (content.isNotEmpty) return content;
      } catch (_) {}
    }

    // 3. Installed venv packages
    final venvSitePackages = Directory(p.join(xdgDataHome, 'sysai-os', 'venv', 'lib'));
    if (venvSitePackages.existsSync()) {
      try {
        for (final entity in venvSitePackages.listSync()) {
          if (entity is Directory && entity.path.contains('python')) {
            final sp = p.join(entity.path, 'site-packages', 'sysai');
            if (Directory(sp).existsSync()) {
              return p.join(entity.path, 'site-packages');
            }
          }
        }
      } catch (_) {}
    }

    // 4. Fallback
    return defaultSysAIPath;
  }

  /// Asynchronously discovers the SysAI source path.
  static Future<String> discoverSysAIPath() async {
    return discoverSysAIPathSync();
  }
}

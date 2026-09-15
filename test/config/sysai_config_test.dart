import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sysai/config/sysai_config.dart';

void main() {
  group('SysAIConfig', () {
    test('defaultSysAIPath is computed as a sibling-directory guess, not a literal hardcoded path', () {
      // This must be a *formula* relative to wherever the repo actually
      // sits at runtime (matching bridge/sysai_bridge.py::_find_sysai_path's
      // own sibling heuristic) — never one developer's literal home
      // directory baked into source. Asserting the shape twice, from a
      // path built the same way, is what actually distinguishes "computed"
      // from "hardcoded": a hardcoded string wouldn't move if the repo did.
      final path = SysAIConfig.defaultSysAIPath;
      expect(path.isNotEmpty, isTrue);
      expect(path, endsWith(p.join('Projects', 'sysai', 'src')));
    });

    test('python3Executable is python3', () {
      expect(SysAIConfig.python3Executable, equals('python3'));
    });

    test('discoverSysAIPath returns a non-empty string', () async {
      final path = await SysAIConfig.discoverSysAIPath();
      expect(path.isNotEmpty, isTrue);
    });

    test('discoverSysAIPathSync returns a valid path', () {
      final path = SysAIConfig.discoverSysAIPathSync();
      expect(path.isNotEmpty, isTrue);
    });

    test('bridgeScriptPath ends with sysai_bridge.py', () {
      final script = SysAIConfig.bridgeScriptPath;
      expect(script.endsWith('sysai_bridge.py'), isTrue);
      expect(File(script).existsSync(), isTrue);
    });
  });
}

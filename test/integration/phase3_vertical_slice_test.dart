import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sysai/config/sysai_config.dart';
import 'package:sysai/models/run.dart';
import 'package:sysai/services/bridge_service.dart';
import 'package:sysai/services/run_repository.dart';

void main() {
  late Directory tempDir;
  late String dbPath;
  late BridgeService bridge;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sysai_p3_e2e_');
    dbPath = p.join(tempDir.path, 'p3_e2e_runs.db');
    bridge = BridgeService();
  });

  tearDown(() async {
    await bridge.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('Phase 3 Vertical Slice: Terminal + Browser in one real Run', () {
    test('bridge exposes browser and computer capabilities alongside the existing set', () async {
      final bridgeScript = SysAIConfig.getBridgeScriptPath();
      final sysaiPath = SysAIConfig.discoverSysAIPathSync();
      await bridge.start(bridgeScript, sysaiPath);

      final capabilities = await bridge.listCapabilities();
      final capIds = capabilities.map((c) => c.id).toSet();

      for (final id in ['browser.search', 'browser.navigate', 'browser.read',
          'browser.follow_link', 'browser.download', 'browser.capture']) {
        expect(capIds, contains(id), reason: '$id should be registered');
      }
      for (final id in ['computer.observe', 'computer.capture', 'computer.click',
          'computer.type', 'computer.key', 'computer.scroll']) {
        expect(capIds, contains(id), reason: '$id should be registered');
      }
    });

    test(
      'a dependency-research goal spans filesystem, browser, and terminal — real network, real shell',
      () async {
        final repo = await RunRepository.open(dbPath);
        final bridgeScript = SysAIConfig.getBridgeScriptPath();
        final sysaiPath = SysAIConfig.discoverSysAIPathSync();
        await bridge.start(bridgeScript, sysaiPath);

        final run = Run.create(id: 'p3-slice-1', goal: 'Check our Flutter dependency for a newer stable version');
        await repo.saveRun(run);

        // Deliberately NOT the SysAI_OS project itself: the plan's terminal
        // step runs `flutter test`, and running this project's own (large,
        // network-touching) suite recursively inside a test would be slow
        // and self-referential. A workspace with no Flutter project makes
        // that step fail fast while still emitting real terminal session
        // events — which is all this test needs to verify.
        final workspaceDir = await Directory.systemTemp.createTemp('sysai_p3_slice_ws_');
        addTearDown(() => workspaceDir.delete(recursive: true).catchError((_) => workspaceDir));

        final stream = bridge.callStreaming('execute_run', params: {
          'run_id': run.id,
          'goal': run.goal,
          'workspace_root': workspaceDir.path,
        });

        final seenTypes = <String>[];
        String? terminalSessionId;
        String? browserSessionId;
        var sawTerminalOutput = false;
        var sawBrowserNavigationCompleted = false;

        await for (final event in stream) {
          if (event.containsKey('_final_result')) continue;
          final type = event['type'] as String? ?? '';
          seenTypes.add(type);

          if (type == 'terminal.session.created') terminalSessionId = event['session_id'] as String?;
          if (type == 'terminal.output') sawTerminalOutput = true;
          if (type == 'browser.session.created') browserSessionId = event['session_id'] as String?;
          if (type == 'browser.navigation.completed') sawBrowserNavigationCompleted = true;

          if (type == 'run.completed' || type == 'run.failed') break;
        }

        // The plan touches all three operational surfaces in one Run.
        expect(seenTypes, contains('planning.completed'));
        expect(terminalSessionId, isNotNull, reason: 'shell.execute should open a terminal session');
        expect(sawTerminalOutput, isTrue, reason: 'the test command produces output');
        expect(browserSessionId, isNotNull, reason: 'browser.search/navigate should open a browser session');
        expect(sawBrowserNavigationCompleted, isTrue, reason: 'at least one page fetch should complete');
        expect(seenTypes.last == 'run.completed' || seenTypes.last == 'run.failed', isTrue);

        repo.close();
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('an unavailable model still blocks a Terminal+Browser Run before any capability executes', () async {
      final bridgeScript = SysAIConfig.getBridgeScriptPath();
      final sysaiPath = SysAIConfig.discoverSysAIPathSync();
      await bridge.start(bridgeScript, sysaiPath);

      final stream = bridge.callStreaming('execute_run', params: {
        'run_id': 'p3-slice-unavailable',
        'goal': 'Check our Flutter dependency for a newer stable version',
        'provider': 'ollama',
        'model': 'definitely-not-installed-xyz-123',
      });

      var sawModelUnavailable = false;
      var sawAnyCapabilityEvent = false;

      await for (final event in stream) {
        if (event.containsKey('_final_result')) continue;
        final type = event['type'] as String? ?? '';
        if (type == 'model.unavailable') sawModelUnavailable = true;
        if (type.startsWith('terminal.') || type.startsWith('browser.') || type.startsWith('capability.')) {
          sawAnyCapabilityEvent = true;
        }
        if (type == 'run.failed') break;
      }

      expect(sawModelUnavailable, isTrue);
      expect(sawAnyCapabilityEvent, isFalse,
          reason: 'no capability should run once the selected model is known-unavailable');
    });
  });
}

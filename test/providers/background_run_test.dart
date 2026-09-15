import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sysai/models/run.dart';
import 'package:sysai/providers/app_providers.dart';
import 'package:sysai/services/run_repository.dart';

/// Proves a Run is driven to completion by the provider graph alone — no
/// widget ever watches it. [runExecutorProvider] is a plain (non-
/// `autoDispose`) `Provider`, so its subscription to the bridge's event
/// stream lives with the `ProviderContainer`, not with any particular
/// screen. This is the actual mechanism behind "navigating away from Run
/// Detail must never stop the Run" — there is no widget-scoped state to
/// tear down in the first place.
void main() {
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sysai_bg_run_test_');
    final dbPath = p.join(tempDir.path, 'bg_run.db');
    final repo = await RunRepository.open(dbPath);

    container = ProviderContainer(
      overrides: [
        runRepositoryProvider.overrideWith((ref) async => repo),
      ],
    );
    addTearDown(container.dispose);
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test(
    'a Run reaches a terminal state through the provider graph with no widget ever reading it',
    () async {
      // Force the bridge to actually start, exactly as the app would on
      // launch — via provider reads, never a widget.
      await container.read(bridgeStatusProvider.future);

      final run = await container.read(runListProvider.notifier).createRun(
            'Inspect the SysAI OS project and report whether its test/build environment is healthy.',
          );

      // Nothing in this test ever builds a widget or a BuildContext.
      container.read(runExecutorProvider).execute(run.id);

      Run? finalRun;
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final current = container.read(runByIdProvider(run.id));
        if (current != null && current.isTerminal) {
          finalRun = current;
          break;
        }
      }

      expect(finalRun, isNotNull, reason: 'Run should reach a terminal state without any UI involvement');
      expect(finalRun!.status, RunStatus.completed);

      // And the result was actually persisted — not just held in memory —
      // confirming the background path writes through like the foreground
      // path does.
      final repo = await container.read(runRepositoryProvider.future);
      final persisted = await repo.getRun(run.id);
      expect(persisted, isNotNull);
      expect(persisted!.status, RunStatus.completed);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

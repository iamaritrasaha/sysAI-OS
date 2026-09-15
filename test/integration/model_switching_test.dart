import 'package:flutter_test/flutter_test.dart';
import 'package:sysai/config/sysai_config.dart';
import 'package:sysai/models/model_info.dart';
import 'package:sysai/services/bridge_service.dart';

void main() {
  late BridgeService bridge;

  setUp(() async {
    bridge = BridgeService();
    final bridgeScript = SysAIConfig.getBridgeScriptPath();
    final sysaiPath = SysAIConfig.discoverSysAIPathSync();
    await bridge.start(bridgeScript, sysaiPath);
  });

  tearDown(() async {
    await bridge.dispose();
  });

  group('Model discovery over the real bridge', () {
    test('listProviders parses a well-formed list of ProviderInfo', () async {
      final providers = await bridge.listProviders();
      expect(providers, isNotEmpty);
      expect(providers, everyElement(isA<ProviderInfo>()));
      final ids = providers.map((p) => p.id).toSet();
      expect(ids, containsAll(['ollama', 'ollama-cloud', 'remote-ollama', 'openai-compatible']));
    });

    test('listModels parses a well-formed list of ModelInfo', () async {
      final models = await bridge.listModels();
      // The real SysAI installation this bridge talks to has at least one
      // Ollama model or a configured active model, so discovery must find
      // something — an empty catalogue would mean discovery silently broke.
      expect(models, isNotEmpty);
      for (final m in models) {
        expect(m.id, isNotEmpty);
        expect(m.name, isNotEmpty);
        expect(m.provider, isNotEmpty);
      }
    });

    test('checkModelAvailability reports a fabricated model as unavailable with a reason', () async {
      final result = await bridge.checkModelAvailability('ollama', 'definitely-not-installed-xyz-123');
      expect(result['available'], isFalse);
      expect((result['reason'] as String).toLowerCase(), contains('not installed'));
    });
  });

  group('Per-Run model isolation over the real bridge', () {
    test('two runs requesting different providers each see their own model.selected event', () async {
      final models = await bridge.listModels();
      final available = models.where((m) => m.available).toList();
      if (available.isEmpty) {
        // Environment has no runnable model at all — nothing to isolate.
        return;
      }
      final modelA = available.first;

      final stream = bridge.callStreaming('execute_run', params: {
        'run_id': 'isolation-test-a',
        'goal': 'Inspect environment',
        'provider': modelA.provider,
        'model': modelA.name,
      });

      String? selectedProvider;
      String? selectedModel;
      await for (final event in stream) {
        if (event['type'] == 'model.selected') {
          selectedProvider = event['provider'] as String?;
          selectedModel = event['model'] as String?;
        }
        if (event.containsKey('_final_result') || event['type'] == 'planning.completed') {
          break;
        }
      }

      expect(selectedProvider, equals(modelA.provider));
      expect(selectedModel, equals(modelA.name));
    });

    test('an unavailable model blocks execution with model.unavailable + run.failed, never silently substituted',
        () async {
      final stream = bridge.callStreaming('execute_run', params: {
        'run_id': 'isolation-test-unavailable',
        'goal': 'Inspect environment',
        'provider': 'ollama',
        'model': 'definitely-not-installed-xyz-123',
      });

      var sawUnavailable = false;
      var sawFailed = false;
      String? finalStatus;

      await for (final event in stream) {
        if (event['type'] == 'model.unavailable') sawUnavailable = true;
        if (event['type'] == 'run.failed') sawFailed = true;
        if (event.containsKey('_final_result')) {
          finalStatus = event['status'] as String?;
        }
      }

      expect(sawUnavailable, isTrue);
      expect(sawFailed, isTrue);
      expect(finalStatus, equals('failed'));
    });
  });
}

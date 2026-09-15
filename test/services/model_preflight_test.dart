import 'package:flutter_test/flutter_test.dart';
import 'package:sysai/models/model_info.dart';
import 'package:sysai/services/model_preflight.dart';

void main() {
  const availableModel = ModelInfo(
    id: 'ollama:llama3.2:latest',
    name: 'llama3.2:latest',
    provider: 'ollama',
    displayName: 'llama3.2:latest',
    available: true,
  );

  const unavailableModel = ModelInfo(
    id: 'ollama:qwen3:8b',
    name: 'qwen3:8b',
    provider: 'ollama',
    displayName: 'qwen3:8b',
    available: false,
    unavailableReason: "Model 'qwen3:8b' is not installed in local Ollama",
  );

  group('checkModelPreflight', () {
    test('an available default model does not block launch', () {
      final check = checkModelPreflight(
        modelId: availableModel.id,
        knownModels: [availableModel, unavailableModel],
      );
      expect(check.result, PreflightResult.available);
      expect(check.blocksLaunch, isFalse);
    });

    test('a known-unavailable default model blocks launch with its reason', () {
      final check = checkModelPreflight(
        modelId: unavailableModel.id,
        knownModels: [availableModel, unavailableModel],
      );
      expect(check.result, PreflightResult.unavailable);
      expect(check.blocksLaunch, isTrue);
      expect(check.reason, contains('not installed'));
      expect(check.model, equals(unavailableModel));
    });

    test('a known-unavailable override blocks launch identically to a default', () {
      // The composer resolves override-or-default to a single modelId before
      // calling this function, so overrides and defaults share this path.
      final check = checkModelPreflight(
        modelId: unavailableModel.id,
        knownModels: [unavailableModel],
      );
      expect(check.blocksLaunch, isTrue);
    });

    test('a model absent from the discovery snapshot is unknown, not blocked', () {
      final check = checkModelPreflight(
        modelId: 'ollama:some-brand-new-model',
        knownModels: [availableModel, unavailableModel],
      );
      expect(check.result, PreflightResult.unknown);
      expect(check.blocksLaunch, isFalse);
    });

    test('no resolved model id at all is unknown, not blocked', () {
      final check = checkModelPreflight(modelId: null, knownModels: [unavailableModel]);
      expect(check.result, PreflightResult.unknown);
      expect(check.blocksLaunch, isFalse);
    });

    test('refreshed availability data changes the outcome for the same model id', () {
      // Simulates "changing the default after a failed preflight": the same
      // modelId now reports available after a refresh/reinstall.
      final blocked = checkModelPreflight(modelId: unavailableModel.id, knownModels: [unavailableModel]);
      expect(blocked.blocksLaunch, isTrue);

      final nowAvailable = unavailableModel.copyWith(available: true, unavailableReason: null);
      final unblocked = checkModelPreflight(modelId: unavailableModel.id, knownModels: [nowAvailable]);
      expect(unblocked.blocksLaunch, isFalse);
    });
  });
}

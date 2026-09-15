import 'package:flutter_test/flutter_test.dart';
import 'package:sysai/models/model_info.dart';

void main() {
  group('ModelInfo', () {
    test('serializes and deserializes preserving availability and reason', () {
      const model = ModelInfo(
        id: 'ollama:qwen3:14b',
        name: 'qwen3:14b',
        provider: 'ollama',
        displayName: 'qwen3:14b',
        available: false,
        unavailableReason: "Model 'qwen3:14b' is not installed in local Ollama",
        local: true,
        capabilities: ['streaming'],
        metadata: {'configured': true},
      );

      final json = model.toJson();
      final restored = ModelInfo.fromJson(json);

      expect(restored.id, model.id);
      expect(restored.name, model.name);
      expect(restored.provider, model.provider);
      expect(restored.available, isFalse);
      expect(restored.unavailableReason, model.unavailableReason);
      expect(restored.local, isTrue);
      expect(restored.capabilities, contains('streaming'));
    });

    test('fromJson tolerates missing optional fields with sane defaults', () {
      final restored = ModelInfo.fromJson(const {'id': 'ollama:qwen3:8b', 'name': 'qwen3:8b'});
      expect(restored.provider, 'ollama');
      expect(restored.available, isTrue);
      expect(restored.local, isTrue);
      expect(restored.unavailableReason, isNull);
    });

    test('equality is based on id, name, and provider', () {
      const a = ModelInfo(id: 'x', name: 'x', provider: 'ollama', displayName: 'x');
      const b = ModelInfo(id: 'x', name: 'x', provider: 'ollama', displayName: 'different display');
      expect(a, equals(b));
    });
  });

  group('ProviderInfo', () {
    test('serializes and deserializes with nested models', () {
      const provider = ProviderInfo(
        id: 'ollama',
        name: 'Ollama Local',
        available: true,
        configured: true,
        statusMessage: 'Online',
        local: true,
        modelsCount: 1,
        models: [
          ModelInfo(id: 'ollama:qwen3:8b', name: 'qwen3:8b', provider: 'ollama', displayName: 'qwen3:8b'),
        ],
      );

      final restored = ProviderInfo.fromJson(provider.toJson());

      expect(restored.id, 'ollama');
      expect(restored.available, isTrue);
      expect(restored.configured, isTrue);
      expect(restored.models, hasLength(1));
      expect(restored.models.first.id, 'ollama:qwen3:8b');
    });

    test('fromJson defaults to unavailable/unconfigured when absent', () {
      final restored = ProviderInfo.fromJson(const {'id': 'openai-compatible', 'name': 'Compatible API'});
      expect(restored.available, isFalse);
      expect(restored.configured, isFalse);
      expect(restored.models, isEmpty);
    });
  });

  group('DefaultModelSelection', () {
    test('isSet requires both providerId and modelId', () {
      expect(DefaultModelSelection.unset.isSet, isFalse);
      expect(const DefaultModelSelection(providerId: 'ollama').isSet, isFalse);
      expect(
        const DefaultModelSelection(providerId: 'ollama', modelId: 'ollama:qwen3:8b').isSet,
        isTrue,
      );
    });

    test('copyWith only overrides provided fields', () {
      const original = DefaultModelSelection(
        providerId: 'ollama',
        modelId: 'ollama:qwen3:8b',
        modelDisplayName: 'qwen3:8b',
      );
      final updated = original.copyWith(modelId: 'ollama:qwen3:14b');
      expect(updated.providerId, 'ollama');
      expect(updated.modelId, 'ollama:qwen3:14b');
      expect(updated.modelDisplayName, 'qwen3:8b');
    });
  });
}

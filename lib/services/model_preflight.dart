/// Pure resolution logic for the pre-Run model availability check.
///
/// Deliberately Flutter/Riverpod-free so it can be unit tested directly:
/// given the model id a new Run would actually use and the last-known
/// discovery snapshot, decide whether launching should be blocked.
///
/// This is a convenience check, not the source of truth — the backend
/// (`sysai_runner.execute_run`'s preflight in Python) still performs the
/// authoritative availability check before a Run is allowed to invoke a
/// model. If discovery hasn't reported on a model at all, this resolves to
/// [PreflightResult.unknown] and the caller should let the Run proceed;
/// silently refusing to launch just because discovery is slow or a model is
/// simply new would be worse than the backend catching it a moment later.
library;

import '../models/model_info.dart';

enum PreflightResult { available, unavailable, unknown }

class ModelPreflightCheck {
  final PreflightResult result;
  final ModelInfo? model;
  final String? reason;

  const ModelPreflightCheck({required this.result, this.model, this.reason});

  bool get blocksLaunch => result == PreflightResult.unavailable;
}

/// Resolves whether the model a new Run would use (an explicit override, or
/// else the persisted SysAI OS default) is known-unavailable.
///
/// [modelId] should already be the *effective* id — i.e. the caller has
/// already applied "override if set, otherwise default."
ModelPreflightCheck checkModelPreflight({
  required String? modelId,
  required List<ModelInfo> knownModels,
}) {
  if (modelId == null || modelId.isEmpty) {
    // No model resolved at all (e.g. discovery hasn't loaded and there's no
    // override or default yet) — nothing to block on; the backend will
    // resolve a model or fail clearly.
    return const ModelPreflightCheck(result: PreflightResult.unknown);
  }

  for (final m in knownModels) {
    if (m.id == modelId) {
      if (m.available) {
        return ModelPreflightCheck(result: PreflightResult.available, model: m);
      }
      return ModelPreflightCheck(
        result: PreflightResult.unavailable,
        model: m,
        reason: m.unavailableReason ?? 'This model is currently unavailable.',
      );
    }
  }

  // Not in the last discovery snapshot — could be stale/not-yet-loaded
  // data, not proof the model is bad. Let the backend decide.
  return const ModelPreflightCheck(result: PreflightResult.unknown);
}

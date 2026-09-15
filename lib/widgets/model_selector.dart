/// Reusable model-selection control.
///
/// Used in three places with three different trigger visuals: the Home
/// goal composer (per-Run override), the Shell quick switcher (changes the
/// SysAI OS default for future Runs), and System → Models (same as the
/// quick switcher, in list form). All three read the same live discovery
/// data — nothing here is a hard-coded model catalogue.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/model_info.dart';
import '../providers/app_providers.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';

/// Dropdown trigger + menu that lets the user pick a [ModelInfo] from
/// everything SysAI currently reports, grouped by provider. Models that
/// aren't genuinely runnable are shown but disabled with their reason.
class ModelSelectorButton extends ConsumerWidget {
  /// Label shown on the trigger when no model is explicitly chosen.
  final String placeholder;

  /// Currently selected model id (`ModelInfo.id`), or null.
  final String? selectedModelId;

  final ValueChanged<ModelInfo> onSelected;

  /// Compact rendering for tight spaces (shell quick switcher).
  final bool compact;

  /// Stretches the trigger to fill its parent's width instead of
  /// shrink-wrapping its label (used in the sidebar quick switcher).
  final bool fillWidth;

  const ModelSelectorButton({
    super.key,
    required this.onSelected,
    this.selectedModelId,
    this.placeholder = 'Default model',
    this.compact = false,
    this.fillWidth = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final modelsAsync = ref.watch(modelsListProvider);
    final providersAsync = ref.watch(providersListProvider);

    final models = modelsAsync.valueOrNull ?? const <ModelInfo>[];
    final providers = providersAsync.valueOrNull ?? const <ProviderInfo>[];

    ModelInfo? selected;
    if (selectedModelId != null) {
      for (final m in models) {
        if (m.id == selectedModelId) {
          selected = m;
          break;
        }
      }
    }

    final isLoading = modelsAsync.isLoading && models.isEmpty;
    final label = selected?.displayName ?? placeholder;

    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(theme.colorScheme.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: Radii.mdR,
            side: BorderSide(
              color: theme.colorScheme.onSurface.withAlpha(26),
            ),
          ),
        ),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
      ),
      menuChildren: [
        SizedBox(
          width: 300,
          child: isLoading
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              : _ModelMenuList(
                  models: models,
                  providers: providers,
                  selectedId: selected?.id,
                  onSelected: onSelected,
                ),
        ),
      ],
      builder: (context, controller, child) {
        return _Trigger(
          label: label,
          subtitle: selected != null
              ? _providerDisplayName(providers, selected.provider)
              : (models.isEmpty && !isLoading ? 'No models discovered' : null),
          unavailable: selected != null && !selected.available,
          compact: compact,
          fillWidth: fillWidth,
          onTap: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
        );
      },
    );
  }
}

String _providerDisplayName(List<ProviderInfo> providers, String providerId) {
  for (final p in providers) {
    if (p.id == providerId) return p.name;
  }
  return providerId;
}

class _Trigger extends StatelessWidget {
  final String label;
  final String? subtitle;
  final bool unavailable;
  final bool compact;
  final bool fillWidth;
  final VoidCallback onTap;

  const _Trigger({
    required this.label,
    required this.onTap,
    this.subtitle,
    this.unavailable = false,
    this.compact = false,
    this.fillWidth = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final dotColor = unavailable
        ? const Color(0xffef6a6a)
        : theme.colorScheme.primary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.mdR,
        child: Container(
          width: fillWidth ? double.infinity : null,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 10,
            vertical: compact ? 5 : 7,
          ),
          decoration: BoxDecoration(
            borderRadius: Radii.mdR,
            border: Border.all(color: onSurface.withAlpha(28)),
            color: onSurface.withAlpha(8),
          ),
          child: Row(
            mainAxisSize: fillWidth ? MainAxisSize.max : MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 7),
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
              Flexible(
                fit: fillWidth ? FlexFit.tight : FlexFit.loose,
                child: ConstrainedBox(
                  // A bound independent of the ancestor chain so a long model
                  // id (e.g. a verbose cloud model name) always ellipsizes
                  // instead of pushing this control past the window edge —
                  // Flexible alone only helps when something upstream is
                  // already width-constrained, which isn't guaranteed here
                  // (the Home composer places this inside a Wrap).
                  constraints: BoxConstraints(maxWidth: fillWidth ? double.infinity : (compact ? 128 : 180)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.code.copyWith(
                          fontSize: compact ? 11.5 : 12.5,
                          color: onSurface,
                        ),
                      ),
                      if (subtitle != null && !compact)
                        Text(
                          subtitle!,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.metadata.copyWith(
                            color: onSurface.withAlpha(130),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.unfold_more_rounded,
                  size: IconSizes.sm, color: onSurface.withAlpha(120)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelMenuList extends StatelessWidget {
  final List<ModelInfo> models;
  final List<ProviderInfo> providers;
  final String? selectedId;
  final ValueChanged<ModelInfo> onSelected;

  const _ModelMenuList({
    required this.models,
    required this.providers,
    required this.onSelected,
    this.selectedId,
  });

  @override
  Widget build(BuildContext context) {
    if (models.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Text(
          'No models discovered from SysAI. Check Ollama or provider configuration in System → Models.',
          style: AppText.bodySecondary,
        ),
      );
    }

    final byProvider = <String, List<ModelInfo>>{};
    for (final m in models) {
      byProvider.putIfAbsent(m.provider, () => []).add(m);
    }

    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 360),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final entry in byProvider.entries) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    Space.md, Space.sm, Space.md, Space.xs),
                child: Text(
                  _providerDisplayName(providers, entry.key).toUpperCase(),
                  style: AppText.label.copyWith(
                    color: onSurface.withAlpha(120),
                  ),
                ),
              ),
              for (final model in entry.value)
                _ModelMenuItem(
                  model: model,
                  selected: model.id == selectedId,
                  onTap: () => onSelected(model),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModelMenuItem extends StatelessWidget {
  final ModelInfo model;
  final bool selected;
  final VoidCallback onTap;

  const _ModelMenuItem({
    required this.model,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final disabled = !model.available;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: disabled ? null : onTap,
        borderRadius: Radii.smR,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          padding: const EdgeInsets.symmetric(
              horizontal: Space.sm, vertical: Space.sm),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.primary.withAlpha(26)
                : Colors.transparent,
            borderRadius: Radii.smR,
          ),
          child: Row(
            children: [
              Icon(
                model.local ? Icons.dns_rounded : Icons.cloud_outlined,
                size: IconSizes.sm,
                color: disabled
                    ? onSurface.withAlpha(70)
                    : onSurface.withAlpha(150),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      model.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.code.copyWith(
                        fontSize: 12,
                        color: disabled
                            ? onSurface.withAlpha(90)
                            : onSurface,
                      ),
                    ),
                    if (disabled && model.unavailableReason != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          model.unavailableReason!,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.metadata.copyWith(
                            color: const Color(0xffef6a6a),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_rounded,
                    size: IconSizes.md, color: theme.colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

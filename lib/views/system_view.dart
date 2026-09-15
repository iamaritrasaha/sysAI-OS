/// SysAI OS System View — Hardware, Runtime & Engine Diagnostics
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:io';

import '../models/capability.dart';
import '../models/model_info.dart';
import '../providers/app_providers.dart';
import '../services/bridge_service.dart';
import '../services/run_repository.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/model_selector.dart';
import '../widgets/state_panels.dart';

class SystemView extends ConsumerWidget {
  const SystemView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final surface = theme.colorScheme.surface;
    final primary = theme.colorScheme.primary;

    final bridge = ref.watch(bridgeServiceProvider);
    final bridgeStatus = ref.watch(bridgeStatusProvider);
    final runtimeStatus = ref.watch(runtimeStatusProvider).valueOrNull ?? {};
    final doctorStatus = ref.watch(systemStatusProvider);
    final sysaiConfig = ref.watch(sysaiConfigProvider).valueOrNull ?? {};

    return Scaffold(
      backgroundColor: surface,
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'System',
                        style: AppText.pageTitle.copyWith(color: onSurface),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Models, engine health, capabilities, and storage',
                        style: AppText.bodySecondary.copyWith(
                          color: onSurface.withAlpha(140),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                OutlinedButton.icon(
                  onPressed: () =>
                      ref.read(systemStatusProvider.notifier).refresh(),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Re-run Doctor'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: primary,
                    side: BorderSide(color: primary.withAlpha(80)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: Space.xl),

            // ── Models — the section users touch most often ──────────────
            const _ModelsSection(),

            const SizedBox(height: Space.xxl),

            // ── Engine ────────────────────────────────────────────────────
            _SectionLabel('ENGINE'),
            const SizedBox(height: Space.sm),
            _ConnectivityCard(
              bridge: bridge,
              bridgeStatus: bridgeStatus,
              onRetry: () => ref.read(bridgeStatusProvider.notifier).retry(),
            ),
            const SizedBox(height: Space.md),
            _RuntimeCard(status: runtimeStatus),
            const SizedBox(height: Space.md),
            Container(
              padding: const EdgeInsets.all(Space.lg),
              decoration: BoxDecoration(
                color: onSurface.withAlpha(6),
                borderRadius: Radii.mdR,
                border: Border.all(color: onSurface.withAlpha(15)),
              ),
              child: Column(
                children: [
                  _InfoRow(
                    label: 'SysAI OS Frontend',
                    value: 'Flutter 3.47.3 / Dart 3.13.3',
                  ),
                  const Divider(height: 16),
                  _InfoRow(
                    label: 'SysAI OS Bridge',
                    value: 'v1.0.0 (Python subprocess NDJSON protocol)',
                  ),
                  const Divider(height: 16),
                  _InfoRow(
                    label: 'SysAI Engine Version',
                    value: bridge.sysaiVersion ?? 'Unknown',
                  ),
                  const Divider(height: 16),
                  _InfoRow(
                    label: 'SysAI Source Location',
                    value: bridge.sysaiPath ?? 'Not discovered',
                    isPath: true,
                  ),
                  const Divider(height: 16),
                  _InfoRow(
                    label: 'Config Directory',
                    value:
                        sysaiConfig['config_dir'] as String? ??
                        '${Platform.environment['HOME'] ?? '~'}/.config/sysai',
                    isPath: true,
                  ),
                ],
              ),
            ),

            const SizedBox(height: Space.xxl),

            // ── Storage ───────────────────────────────────────────────────
            _SectionLabel('STORAGE'),
            const SizedBox(height: Space.sm),
            const _StorageSection(),

            const SizedBox(height: Space.xxl),

            // ── Capabilities & Policy ────────────────────────────────────
            _SectionLabel('CAPABILITIES & POLICY'),
            const SizedBox(height: Space.sm),
            const _CapabilityRegistrySection(),

            const SizedBox(height: Space.xxl),

            // ── Diagnostics ───────────────────────────────────────────────
            _SectionLabel('DIAGNOSTICS'),
            const SizedBox(height: Space.sm),
            doctorStatus.when(
              loading: () =>
                  const LoadingStatePanel(message: 'Running diagnostics…'),
              error: (err, _) => ErrorStatePanel(
                message: 'Failed to load doctor results: $err',
                onRetry: () =>
                    ref.read(systemStatusProvider.notifier).refresh(),
              ),
              data: (data) {
                final checks = data['checks'] as List<dynamic>? ?? [];
                final overall = data['overall'] as String? ?? 'Healthy';
                final attentionCount = data['attention_count'] as int? ?? 0;
                final tone = attentionCount > 0
                    ? const Color(0xfff0b84c)
                    : const Color(0xff8fd67a);

                return Column(
                  children: [
                    // Overall status banner
                    Container(
                      padding: const EdgeInsets.all(Space.md),
                      margin: const EdgeInsets.only(bottom: Space.md),
                      decoration: BoxDecoration(
                        color: tone.withAlpha(15),
                        borderRadius: Radii.mdR,
                        border: Border.all(color: tone.withAlpha(60)),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            attentionCount > 0
                                ? Icons.warning_amber
                                : Icons.check_circle_outline,
                            size: IconSizes.lg,
                            color: tone,
                          ),
                          const SizedBox(width: Space.sm),
                          Text(
                            'Overall Status: $overall',
                            style: AppText.bodyStrong.copyWith(
                              color: onSurface,
                            ),
                          ),
                          const Spacer(),
                          if (attentionCount > 0)
                            Text(
                              '$attentionCount item${attentionCount == 1 ? '' : 's'} need attention',
                              style: AppText.bodySecondary.copyWith(
                                color: tone,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                    ),

                    // Checks list
                    Container(
                      decoration: BoxDecoration(
                        color: onSurface.withAlpha(6),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: onSurface.withAlpha(15)),
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: checks.length,
                        separatorBuilder: (context, index) =>
                            Divider(height: 1, color: onSurface.withAlpha(12)),
                        itemBuilder: (context, index) {
                          final check = (checks[index] as Map)
                              .cast<String, dynamic>();
                          return _CheckItem(check: check);
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _RuntimeCard extends StatelessWidget {
  final Map<String, dynamic> status;
  const _RuntimeCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final running = status['scheduler_running'] == true;
    final value = status.isEmpty ? 'Offline' : 'Connected';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: onSurface.withAlpha(6),
        borderRadius: Radii.mdR,
        border: Border.all(color: onSurface.withAlpha(15)),
      ),
      child: Row(
        children: [
          Icon(
            running ? Icons.dns_outlined : Icons.cloud_off,
            size: 18,
            color: running ? const Color(0xffa5e887) : onSurface.withAlpha(120),
          ),
          const SizedBox(width: 10),
          Text(
            'Runtime',
            style: TextStyle(fontWeight: FontWeight.w700, color: onSurface),
          ),
          const Spacer(),
          Text(
            '$value  •  PID ${status['pid'] ?? '—'}  •  ${status['active_runs'] ?? 0} active Runs',
            style: TextStyle(fontSize: 12, color: onSurface.withAlpha(150)),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Text(
      text,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        color: onSurface.withAlpha(120),
      ),
    );
  }
}

class _ConnectivityCard extends StatelessWidget {
  final BridgeService bridge;
  final AsyncValue<BridgeStatus> bridgeStatus;
  final VoidCallback onRetry;

  const _ConnectivityCard({
    required this.bridge,
    required this.bridgeStatus,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;

    if (!bridge.sysaiAvailable) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xffff6b6b).withAlpha(15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xffff6b6b).withAlpha(60)),
        ),
        child: Row(
          children: [
            const Icon(Icons.cloud_off, size: 28, color: Color(0xffff6b6b)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'SysAI Engine Unavailable',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xffff6b6b),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Expected installation: ${bridge.sysaiPath ?? 'undiscovered'}. Ensure SYSAI_PATH is set or the .sysai_path file exists.',
                    style: TextStyle(
                      fontSize: 12,
                      color: onSurface.withAlpha(150),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xffff6b6b),
                foregroundColor: Colors.white,
              ),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xffa5e887).withAlpha(12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffa5e887).withAlpha(50)),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle, size: 22, color: Color(0xffa5e887)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SysAI Engine Connected',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: onSurface,
                  ),
                ),
                Text(
                  'Ready to accept and execute autonomous goals.',
                  style: TextStyle(
                    fontSize: 12,
                    color: onSurface.withAlpha(140),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isPath;

  const _InfoRow({
    required this.label,
    required this.value,
    this.isPath = false,
  });

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Row(
      children: [
        SizedBox(
          width: 200,
          child: Text(
            label,
            style: AppText.bodySecondary.copyWith(
              color: onSurface.withAlpha(140),
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: (isPath ? AppText.path : AppText.bodyStrong).copyWith(
              fontSize: 12.5,
              color: onSurface.withAlpha(210),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

// ── Storage ──────────────────────────────────────────────────────────────────

class _StorageSection extends StatelessWidget {
  const _StorageSection();

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return FutureBuilder<String>(
      future: getDefaultDbPath(),
      builder: (context, snapshot) {
        final dbPath = snapshot.data;
        String sizeLabel = '—';
        if (dbPath != null) {
          try {
            final bytes = File(dbPath).statSync().size;
            sizeLabel = bytes < 1024 * 1024
                ? '${(bytes / 1024).toStringAsFixed(1)} KB'
                : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
          } catch (_) {}
        }
        return Container(
          padding: const EdgeInsets.all(Space.lg),
          decoration: BoxDecoration(
            color: onSurface.withAlpha(6),
            borderRadius: Radii.mdR,
            border: Border.all(color: onSurface.withAlpha(15)),
          ),
          child: Column(
            children: [
              _InfoRow(
                label: 'Runs Database',
                value: dbPath ?? 'Resolving…',
                isPath: true,
              ),
              const Divider(height: 16),
              _InfoRow(label: 'Database Size', value: sizeLabel),
              const Divider(height: 16),
              const _InfoRow(
                label: 'Contents',
                value: 'Runs, approvals, artifacts, checkpoints, settings',
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Models Section ──────────────────────────────────────────────────────────

class _ModelsSection extends ConsumerWidget {
  const _ModelsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final providersAsync = ref.watch(providersListProvider);
    final modelsAsync = ref.watch(modelsListProvider);
    final defaultModel = ref.watch(defaultModelProvider).valueOrNull;

    final providers = providersAsync.valueOrNull ?? const <ProviderInfo>[];
    final models = modelsAsync.valueOrNull ?? const <ModelInfo>[];
    final isLoading = providersAsync.isLoading || modelsAsync.isLoading;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _SectionLabel('MODELS'),
            const Spacer(),
            IconButton(
              onPressed: () {
                ref.invalidate(providersListProvider);
                ref.invalidate(modelsListProvider);
              },
              icon: Icon(
                Icons.refresh,
                size: IconSizes.md,
                color: onSurface.withAlpha(150),
              ),
              tooltip: 'Refresh providers & models',
              splashRadius: 18,
            ),
          ],
        ),
        const SizedBox(height: Space.sm),

        // Default model
        Container(
          padding: const EdgeInsets.all(Space.lg),
          decoration: BoxDecoration(
            color: onSurface.withAlpha(6),
            borderRadius: Radii.mdR,
            border: Border.all(color: onSurface.withAlpha(15)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SysAI OS Default Model',
                      style: AppText.bodyStrong.copyWith(color: onSurface),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Used for every new Run unless overridden in the goal composer.',
                      style: AppText.bodySecondary.copyWith(
                        color: onSurface.withAlpha(140),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.lg),
              ModelSelectorButton(
                placeholder:
                    defaultModel?.modelDisplayName ??
                    defaultModel?.modelId ??
                    'Not set',
                selectedModelId: defaultModel?.modelId,
                onSelected: (m) => ref
                    .read(defaultModelProvider.notifier)
                    .setDefault(
                      providerId: m.provider,
                      modelId: m.id,
                      modelDisplayName: m.displayName,
                    ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.lg),

        // Providers
        Text(
          'PROVIDERS',
          style: AppText.label.copyWith(color: onSurface.withAlpha(120)),
        ),
        const SizedBox(height: Space.sm),
        if (isLoading && providers.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: Space.lg),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: onSurface.withAlpha(6),
              borderRadius: Radii.mdR,
              border: Border.all(color: onSurface.withAlpha(15)),
            ),
            child: Column(
              children: [
                for (int i = 0; i < providers.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: onSurface.withAlpha(12)),
                  _ProviderRow(provider: providers[i]),
                ],
                if (providers.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(Space.lg),
                    child: Text(
                      'No providers discovered.',
                      style: AppText.bodySecondary.copyWith(
                        color: onSurface.withAlpha(140),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: Space.lg),

        // Models
        Text(
          'DISCOVERED MODELS (${models.length})',
          style: AppText.label.copyWith(color: onSurface.withAlpha(120)),
        ),
        const SizedBox(height: Space.sm),
        Container(
          decoration: BoxDecoration(
            color: onSurface.withAlpha(6),
            borderRadius: Radii.mdR,
            border: Border.all(color: onSurface.withAlpha(15)),
          ),
          child: Column(
            children: [
              for (int i = 0; i < models.length; i++) ...[
                if (i > 0) Divider(height: 1, color: onSurface.withAlpha(12)),
                _ModelRow(model: models[i]),
              ],
              if (models.isEmpty && !isLoading)
                Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Text(
                    'No models discovered. Check that Ollama is running or a provider is configured.',
                    style: AppText.bodySecondary.copyWith(
                      color: onSurface.withAlpha(140),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProviderRow extends StatelessWidget {
  final ProviderInfo provider;

  const _ProviderRow({required this.provider});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final tone = provider.available
        ? const Color(0xff8fd67a)
        : (provider.configured
              ? const Color(0xfff0b84c)
              : onSurface.withAlpha(110));

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.md,
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      provider.name,
                      style: AppText.bodyStrong.copyWith(color: onSurface),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      provider.local ? Icons.dns_rounded : Icons.cloud_outlined,
                      size: IconSizes.sm,
                      color: onSurface.withAlpha(120),
                    ),
                  ],
                ),
                if (provider.statusMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      provider.statusMessage!,
                      style: AppText.metadata.copyWith(
                        color: onSurface.withAlpha(130),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Text(
            provider.available
                ? 'Available'
                : (provider.configured ? 'Configured' : 'Not configured'),
            style: AppText.metadata.copyWith(color: tone),
          ),
        ],
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  final ModelInfo model;

  const _ModelRow({required this.model});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final tone = model.available
        ? const Color(0xff8fd67a)
        : const Color(0xffef6a6a);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.md,
      ),
      child: Row(
        children: [
          Icon(
            model.local ? Icons.dns_rounded : Icons.cloud_outlined,
            size: IconSizes.sm,
            color: onSurface.withAlpha(130),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  model.displayName,
                  style: AppText.code.copyWith(
                    fontSize: 12.5,
                    color: onSurface,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    model.available
                        ? model.provider
                        : (model.unavailableReason ?? 'Unavailable'),
                    style: AppText.metadata.copyWith(
                      color: model.available ? onSurface.withAlpha(130) : tone,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Text(
            model.available ? 'Available' : 'Unavailable',
            style: AppText.metadata.copyWith(color: tone),
          ),
        ],
      ),
    );
  }
}

class _CheckItem extends StatelessWidget {
  final Map<String, dynamic> check;

  const _CheckItem({required this.check});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final status = check['status'] as String? ?? 'unknown';
    final label = check['label'] as String? ?? '';
    final detail = check['detail'] as String? ?? '';

    final (color, icon) = switch (status) {
      'ok' => (const Color(0xffa5e887), Icons.check_circle_outline),
      'attention' => (const Color(0xffffc46b), Icons.warning_amber),
      'info' => (const Color(0xff65d5e8), Icons.info_outline),
      _ => (const Color(0xff91a2ab), Icons.remove_circle_outline),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 12),
          SizedBox(
            width: 160,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: onSurface.withAlpha(200),
              ),
            ),
          ),
          Expanded(
            child: Text(
              detail,
              style: TextStyle(
                fontSize: 12,
                color: onSurface.withAlpha(140),
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CapabilityRegistrySection extends ConsumerWidget {
  const _CapabilityRegistrySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final capabilitiesAsync = ref.watch(capabilitiesProvider);

    return capabilitiesAsync.when(
      loading: () => Container(
        padding: const EdgeInsets.all(28),
        alignment: Alignment.center,
        child: const CircularProgressIndicator(),
      ),
      error: (err, _) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xffff6b6b).withAlpha(15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'Failed to load capabilities: $err',
          style: const TextStyle(color: Color(0xffff6b6b)),
        ),
      ),
      data: (caps) {
        if (caps.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: onSurface.withAlpha(6),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: onSurface.withAlpha(15)),
            ),
            child: Text(
              'No capabilities registered or engine disconnected.',
              style: TextStyle(color: onSurface.withAlpha(140)),
            ),
          );
        }

        final grouped = <String, List<Capability>>{};
        for (final c in caps) {
          grouped.putIfAbsent(c.category, () => []).add(c);
        }

        final categoryOrder = ['filesystem', 'shell', 'git', 'system', 'sysai'];
        final sortedKeys = grouped.keys.toList()
          ..sort((a, b) {
            final ai = categoryOrder.indexOf(a);
            final bi = categoryOrder.indexOf(b);
            if (ai != -1 && bi != -1) return ai.compareTo(bi);
            if (ai != -1) return -1;
            if (bi != -1) return 1;
            return a.compareTo(b);
          });

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final cat in sortedKeys) ...[
              _CapabilityCategoryGroup(
                category: cat,
                capabilities: grouped[cat]!,
              ),
              const SizedBox(height: 16),
            ],
          ],
        );
      },
    );
  }
}

class _CapabilityCategoryGroup extends StatelessWidget {
  final String category;
  final List<Capability> capabilities;

  const _CapabilityCategoryGroup({
    required this.category,
    required this.capabilities,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final primary = theme.colorScheme.primary;

    final (icon, label) = switch (category) {
      'filesystem' => (Icons.folder_outlined, 'FILESYSTEM'),
      'shell' => (Icons.terminal, 'SHELL EXECUTION'),
      'git' => (Icons.source, 'VERSION CONTROL (GIT)'),
      'system' => (Icons.computer, 'SYSTEM ENVIRONMENT'),
      'sysai' => (Icons.psychology_outlined, 'SYSAI INTELLIGENCE'),
      _ => (Icons.extension_outlined, category.toUpperCase()),
    };

    return Container(
      decoration: BoxDecoration(
        color: onSurface.withAlpha(6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: onSurface.withAlpha(15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(icon, size: 16, color: primary),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                    color: primary,
                  ),
                ),
                const Spacer(),
                Text(
                  '${capabilities.length} capabilities',
                  style: TextStyle(
                    fontSize: 11,
                    color: onSurface.withAlpha(100),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: onSurface.withAlpha(12)),
          Material(
            type: MaterialType.transparency,
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: capabilities.length,
              separatorBuilder: (context, index) =>
                  Divider(height: 1, color: onSurface.withAlpha(8)),
              itemBuilder: (context, index) {
                final cap = capabilities[index];
                return _CapabilityItemRow(capability: cap);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CapabilityItemRow extends StatelessWidget {
  final Capability capability;

  const _CapabilityItemRow({required this.capability});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      capability.name,
                      style: TextStyle(
                        fontFamily: 'JetBrains Mono',
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: onSurface.withAlpha(220),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  capability.description,
                  style: TextStyle(
                    fontSize: 12,
                    color: onSurface.withAlpha(140),
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (capability.requiresApproval) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xffff9f43).withAlpha(20),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: const Color(0xffff9f43).withAlpha(80),
                ),
              ),
              child: const Text(
                'APPROVAL REQUIRED',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  color: Color(0xffff9f43),
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          _RiskBadge(risk: capability.risk),
        ],
      ),
    );
  }
}

class _RiskBadge extends StatelessWidget {
  final CapabilityRisk risk;

  const _RiskBadge({required this.risk});

  @override
  Widget build(BuildContext context) {
    final (bg, border, fg) = switch (risk) {
      CapabilityRisk.observe => (
        const Color(0xff65d5e8).withAlpha(20),
        const Color(0xff65d5e8).withAlpha(80),
        const Color(0xff65d5e8),
      ),
      CapabilityRisk.low => (
        const Color(0xffa5e887).withAlpha(20),
        const Color(0xffa5e887).withAlpha(80),
        const Color(0xffa5e887),
      ),
      CapabilityRisk.medium => (
        const Color(0xffffc46b).withAlpha(20),
        const Color(0xffffc46b).withAlpha(80),
        const Color(0xffffc46b),
      ),
      CapabilityRisk.high => (
        const Color(0xffff9f43).withAlpha(25),
        const Color(0xffff9f43).withAlpha(90),
        const Color(0xffff9f43),
      ),
      CapabilityRisk.privileged => (
        const Color(0xffff5252).withAlpha(30),
        const Color(0xffff5252).withAlpha(100),
        const Color(0xffff5252),
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: border),
      ),
      child: Text(
        risk.displayLabel.toUpperCase(),
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          color: fg,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

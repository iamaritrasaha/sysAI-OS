/// SysAI OS Home View — Command Center
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/model_info.dart';
import '../models/run.dart';
import '../providers/app_providers.dart';
import '../services/bridge_service.dart';
import '../services/model_preflight.dart';
import '../theme/status.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/model_selector.dart';
import '../widgets/markdown_preview.dart';

class HomeView extends ConsumerStatefulWidget {
  final void Function(String runId) onRunCreated;

  const HomeView({super.key, required this.onRunCreated});

  @override
  ConsumerState<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends ConsumerState<HomeView> {
  final TextEditingController _goalController = TextEditingController();
  bool _submitting = false;

  /// A one-time override for this Run only. Null means "use the SysAI OS
  /// default model" — picking one here never changes that default.
  ModelInfo? _modelOverride;

  /// Set when a pre-launch check found the effective model (override or
  /// default) to be known-unavailable. Cleared as soon as the user picks a
  /// different model or availability data refreshes.
  ModelPreflightCheck? _blockedPreflight;

  @override
  void dispose() {
    _goalController.dispose();
    super.dispose();
  }

  void _selectOverride(ModelInfo model) {
    setState(() {
      _modelOverride = model;
      _blockedPreflight = null;
    });
  }

  Future<void> _submitGoal([String? preset]) async {
    final text = (preset ?? _goalController.text).trim();
    if (text.isEmpty || _submitting) return;

    final override = _modelOverride;
    final defaultModel = ref.read(defaultModelProvider).valueOrNull;
    final effectiveProviderId = override?.provider ?? defaultModel?.providerId;
    final effectiveModelId = override?.id ?? defaultModel?.modelId;
    final effectiveDisplayName =
        override?.displayName ?? defaultModel?.modelDisplayName;

    // Preflight: block on a *known* unavailable model before creating the
    // Run at all. Unknown availability (discovery hasn't reported on this
    // model) is not blocked here — the backend still performs the
    // authoritative check when the Run actually executes.
    final knownModels = ref.read(modelsListProvider).valueOrNull ?? const [];
    final check = checkModelPreflight(modelId: effectiveModelId, knownModels: knownModels);
    if (check.blocksLaunch) {
      setState(() => _blockedPreflight = check);
      return;
    }

    setState(() {
      _submitting = true;
      _blockedPreflight = null;
    });

    try {
      final run = await ref.read(runListProvider.notifier).createRun(
            text,
            providerId: effectiveProviderId,
            modelId: effectiveModelId,
            modelDisplayName: effectiveDisplayName,
          );
      _goalController.clear();
      setState(() => _modelOverride = null);

      // Start execution in background
      ref.read(runExecutorProvider).execute(run.id);

      // Navigate to the run
      widget.onRunCreated(run.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start run: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final primary = theme.colorScheme.primary;
    final surface = theme.colorScheme.surface;

    final activeRuns = ref.watch(activeRunsProvider);
    final allRuns = ref.watch(runListProvider).valueOrNull ?? [];
    final attentionRuns = allRuns.where((r) => r.needsAttention).toList();
    final recentRuns = allRuns.where((r) => r.isTerminal).take(5).toList();
    final systemStatus = ref.watch(systemStatusProvider);
    final bridgeStatus = ref.watch(bridgeStatusProvider);
    final bridge = ref.watch(bridgeServiceProvider);

    return Scaffold(
      backgroundColor: surface,
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Top Title & System State Bar ──────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Command Center',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: onSurface,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Autonomous agent runtime powered by the SysAI engine',
                        style: TextStyle(
                          fontSize: 13,
                          color: onSurface.withAlpha(140),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                _SystemHealthBadge(
                  bridgeStatus: bridgeStatus,
                  sysaiAvailable: bridge.sysaiAvailable,
                  systemStatus: systemStatus,
                ),
              ],
            ),

            const SizedBox(height: Space.lg),

            // A single scannable status line rather than a row of stat
            // cards — this is a command center, not a metrics dashboard.
            const _EngineStatusLine(),

            if (attentionRuns.isNotEmpty) ...[
              const SizedBox(height: 24),
              _NeedsAttentionBanner(
                runs: attentionRuns,
                onSelectRun: widget.onRunCreated,
              ),
            ],

            const SizedBox(height: 28),

            // ── Goal Composer (Centerpiece) ────────────────────────────────
            Container(
              decoration: BoxDecoration(
                color: surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: primary.withAlpha(50), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(20),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.terminal, size: 18, color: primary),
                      const SizedBox(width: 8),
                      Text(
                        'What do you want SysAI to accomplish?',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: onSurface,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _goalController,
                    maxLines: 3,
                    minLines: 2,
                    onSubmitted: (_) => _submitGoal(),
                    decoration: InputDecoration(
                      hintText:
                          'Enter an operational goal (e.g. Inspect the SysAI OS project and report whether its test/build environment is healthy)...',
                      hintStyle:
                          TextStyle(color: onSurface.withAlpha(90), fontSize: 13),
                      filled: true,
                      fillColor: onSurface.withAlpha(8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: onSurface.withAlpha(20)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: onSurface.withAlpha(20)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: primary, width: 1.5),
                      ),
                      contentPadding: const EdgeInsets.all(14),
                    ),
                    style: TextStyle(color: onSurface, fontSize: 14),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          Text(
                            'Quick targets:',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: onSurface.withAlpha(120),
                            ),
                          ),
                          _TargetChip(
                            label: 'Inspect Environment',
                            onTap: () => _submitGoal(
                                'Inspect the SysAI OS project and report whether its test/build environment is healthy.'),
                          ),
                          _TargetChip(
                            label: 'Run Workspace Tests',
                            onTap: () => _submitGoal(
                                'Run the tests for this workspace and diagnose any failures.'),
                          ),
                          _TargetChip(
                            label: 'Query Experience',
                            onTap: () => _submitGoal(
                                'Query SysAI experience store and summarize learned patterns.'),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Builder(builder: (context) {
                            final defaultModel =
                                ref.watch(defaultModelProvider).valueOrNull;
                            return ModelSelectorButton(
                              compact: true,
                              placeholder: defaultModel?.modelDisplayName ??
                                  defaultModel?.modelId ??
                                  'Default model',
                              selectedModelId:
                                  _modelOverride?.id ?? defaultModel?.modelId,
                              onSelected: _selectOverride,
                            );
                          }),
                          const SizedBox(width: 10),
                          ElevatedButton.icon(
                            onPressed: _submitting ? null : () => _submitGoal(),
                            icon: _submitting
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child:
                                        CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.play_arrow, size: 16),
                            label: Text(
                                _submitting ? 'Initiating...' : 'Execute Goal'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: primary,
                              foregroundColor: const Color(0xff0a1a0a),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 18, vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              textStyle: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (_blockedPreflight != null) ...[
                    const SizedBox(height: Space.md),
                    _ModelBlockedBanner(
                      check: _blockedPreflight!,
                      onDismiss: () => setState(() => _blockedPreflight = null),
                      onRefresh: () {
                        ref.invalidate(modelsListProvider);
                        setState(() => _blockedPreflight = null);
                      },
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 32),

            // ── Active Work Section ────────────────────────────────────────
            if (activeRuns.isNotEmpty) ...[
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'ACTIVE WORK (${activeRuns.length})',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                      color: onSurface.withAlpha(160),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (final run in activeRuns)
                _ActiveRunCard(
                  run: run,
                  onTap: () => widget.onRunCreated(run.id),
                ),
              const SizedBox(height: 28),
            ],

            // ── Recent Runs Section ────────────────────────────────────────
            Row(
              children: [
                Icon(Icons.history, size: 16, color: onSurface.withAlpha(140)),
                const SizedBox(width: 8),
                Text(
                  'RECENT RUNS',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                    color: onSurface.withAlpha(160),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (recentRuns.isEmpty && activeRuns.isEmpty)
              Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: onSurface.withAlpha(6),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: onSurface.withAlpha(15)),
                ),
                alignment: Alignment.center,
                child: Column(
                  children: [
                    Icon(Icons.hub_outlined,
                        size: 36, color: onSurface.withAlpha(60)),
                    const SizedBox(height: 10),
                    Text(
                      'No runs executed yet',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: onSurface.withAlpha(150),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Submit a goal above to start SysAI OS autonomous work.',
                      style: TextStyle(
                        fontSize: 12,
                        color: onSurface.withAlpha(100),
                      ),
                    ),
                  ],
                ),
              )
            else
              for (final run in recentRuns)
                _RecentRunRow(
                  run: run,
                  onTap: () => widget.onRunCreated(run.id),
                ),
          ],
        ),
      ),
    );
  }
}

// ── Model Blocked Banner ─────────────────────────────────────────────────────

/// Inline, in-composer explanation shown when the model a Run would launch
/// with is known-unavailable. Deliberately lives next to the composer
/// rather than as a toast — the fix (pick another model) is right there.
class _ModelBlockedBanner extends StatelessWidget {
  final ModelPreflightCheck check;
  final VoidCallback onDismiss;
  final VoidCallback onRefresh;

  const _ModelBlockedBanner({
    required this.check,
    required this.onDismiss,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    const danger = Color(0xffef6a6a);
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final name = check.model?.displayName ?? 'This model';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
      decoration: BoxDecoration(
        color: danger.withAlpha(18),
        borderRadius: Radii.mdR,
        border: Border.all(color: danger.withAlpha(70)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, size: IconSizes.md, color: danger),
          const SizedBox(width: Space.sm),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: AppText.bodySecondary.copyWith(color: onSurface.withAlpha(210)),
                children: [
                  TextSpan(text: '$name is unavailable — ', style: AppText.bodyStrong.copyWith(color: onSurface, fontSize: 13)),
                  TextSpan(text: check.reason ?? 'reason unknown.'),
                ],
              ),
            ),
          ),
          TextButton(
            onPressed: onRefresh,
            child: const Text('Refresh'),
          ),
          IconButton(
            icon: Icon(Icons.close, size: IconSizes.sm, color: onSurface.withAlpha(140)),
            onPressed: onDismiss,
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

// ── Target Chip ───────────────────────────────────────────────────────────────

class _TargetChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _TargetChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) return onSurface.withAlpha(24);
        if (states.contains(WidgetState.hovered)) return onSurface.withAlpha(10);
        return null;
      }),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: onSurface.withAlpha(10),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: onSurface.withAlpha(25)),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 11, color: onSurface.withAlpha(180)),
        ),
      ),
    );
  }
}

// ── System Health Badge ───────────────────────────────────────────────────────

class _SystemHealthBadge extends StatelessWidget {
  final AsyncValue<BridgeStatus> bridgeStatus;
  final bool sysaiAvailable;
  final AsyncValue<Map<String, dynamic>> systemStatus;

  const _SystemHealthBadge({
    required this.bridgeStatus,
    required this.sysaiAvailable,
    required this.systemStatus,
  });

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;

    if (!sysaiAvailable) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xffff6b6b).withAlpha(20),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xffff6b6b).withAlpha(80)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.warning_amber,
                size: 15, color: Color(0xffff6b6b)),
            const SizedBox(width: 6),
            Text(
              'SysAI Engine Unavailable',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: const Color(0xffff6b6b),
              ),
            ),
          ],
        ),
      );
    }

    final overall = systemStatus.valueOrNull?['overall'] as String? ?? 'Healthy';
    final attention =
        systemStatus.valueOrNull?['attention_count'] as int? ?? 0;

    final color = attention > 0
        ? const Color(0xffffc46b)
        : const Color(0xffa5e887);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withAlpha(70)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            attention > 0 ? 'SysAI · $overall ($attention items)' : 'SysAI · Online',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: onSurface.withAlpha(200),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Metrics Row ───────────────────────────────────────────────────────────────

/// A single scannable line of engine facts — active Runs and learned-record
/// count — instead of three equal-weight stat cards competing with the
/// composer for attention. The model itself is not repeated here: the
/// Shell quick switcher and the composer's own selector already own that.
class _EngineStatusLine extends ConsumerWidget {
  const _EngineStatusLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final expData = ref.watch(experienceProvider).valueOrNull ?? {};
    final runs = ref.watch(runListProvider).valueOrNull ?? [];
    final activeCount = runs.where((r) => r.isActive).length;
    final totalMem = ((expData['stats'] as Map?)?['total']) ?? 0;

    Widget item(IconData icon, String text) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: IconSizes.sm, color: onSurface.withAlpha(120)),
            const SizedBox(width: 5),
            Text(text, style: AppText.bodySecondary.copyWith(color: onSurface.withAlpha(160))),
          ],
        );

    return Row(
      children: [
        item(Icons.run_circle_outlined, activeCount == 0 ? 'No active Runs' : '$activeCount active Run${activeCount == 1 ? '' : 's'}'),
        const SizedBox(width: Space.lg),
        item(Icons.auto_awesome_outlined, '$totalMem learned records'),
      ],
    );
  }
}

// ── Active Run Card ───────────────────────────────────────────────────────────

class _ActiveRunCard extends StatelessWidget {
  final Run run;
  final VoidCallback onTap;

  const _ActiveRunCard({required this.run, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final primary = Theme.of(context).colorScheme.primary;

    return InkWell(
      onTap: onTap,
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) return primary.withAlpha(32);
        if (states.contains(WidgetState.hovered)) return primary.withAlpha(16);
        return null;
      }),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: Space.sm),
        padding: const EdgeInsets.all(Space.lg),
        decoration: BoxDecoration(
          color: primary.withAlpha(12),
          borderRadius: Radii.mdR,
          border: Border.all(color: primary.withAlpha(60)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _StatusBadge(status: run.status),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(
                    run.goal,
                    style: AppText.bodyStrong.copyWith(fontSize: 14, color: onSurface),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (run.hasModelOverride || run.modelId != null) ...[
                  const SizedBox(width: Space.sm),
                  Icon(Icons.memory_rounded, size: IconSizes.sm, color: onSurface.withAlpha(110)),
                  const SizedBox(width: 3),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 110),
                    child: Text(
                      run.modelLabel,
                      style: AppText.code.copyWith(fontSize: 11, color: onSurface.withAlpha(150)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                const SizedBox(width: Space.sm),
                Icon(Icons.arrow_forward, size: IconSizes.md, color: primary),
              ],
            ),
            if (run.latestEventMessage.isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              Row(
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: primary,
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(
                      run.latestEventMessage,
                      style: AppText.bodySecondary.copyWith(
                        color: onSurface.withAlpha(160),
                        fontStyle: FontStyle.italic,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Recent Run Row ────────────────────────────────────────────────────────────

class _RecentRunRow extends StatelessWidget {
  final Run run;
  final VoidCallback onTap;

  const _RecentRunRow({required this.run, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return InkWell(
      onTap: onTap,
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) return onSurface.withAlpha(22);
        if (states.contains(WidgetState.hovered)) return onSurface.withAlpha(8);
        return null;
      }),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: onSurface.withAlpha(6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: onSurface.withAlpha(15)),
        ),
        child: Row(
          children: [
            _StatusBadge(status: run.status),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    run.goal,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (run.outcome.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    MarkdownPreview(
                      data: run.outcome,
                      style: TextStyle(
                        fontSize: 11,
                        color: onSurface.withAlpha(120),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _formatDate(run.createdAt),
              style: TextStyle(fontSize: 11, color: onSurface.withAlpha(100)),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 16, color: onSurface.withAlpha(80)),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${dt.month}/${dt.day}';
  }
}

// ── Status Badge ──────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final RunStatus status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StatusPill(style: statusStyleForRun(status, scheme), dense: true);
  }
}

// ── Needs Attention Banner ───────────────────────────────────────────────────

class _NeedsAttentionBanner extends ConsumerWidget {
  final List<Run> runs;
  final void Function(String runId) onSelectRun;

  const _NeedsAttentionBanner({
    required this.runs,
    required this.onSelectRun,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const warningColor = Color(0xffff9f43);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: warningColor.withAlpha(15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: warningColor.withAlpha(100), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded, size: 20, color: warningColor),
              const SizedBox(width: 8),
              const Text(
                'NEEDS ATTENTION',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: warningColor,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: warningColor.withAlpha(40),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${runs.length}',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: warningColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final run in runs)
            _AttentionRunItem(
              run: run,
              onSelectRun: onSelectRun,
            ),
        ],
      ),
    );
  }
}

class _AttentionRunItem extends ConsumerWidget {
  final Run run;
  final void Function(String runId) onSelectRun;

  const _AttentionRunItem({
    required this.run,
    required this.onSelectRun,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    final (label, actionText, actionColor) = switch (run.status) {
      RunStatus.waitingApproval => (
          'Approval requested for "${run.pendingApproval?.title ?? run.title}"',
          'Review & Approve',
          const Color(0xffff9f43),
        ),
      RunStatus.interrupted => (
          'Run was interrupted during app restart. Ready to resume.',
          'Resume',
          const Color(0xff3584e4),
        ),
      _ => (
          'Run is currently paused.',
          'Inspect',
          const Color(0xfff6d365),
        ),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: onSurface.withAlpha(8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: onSurface.withAlpha(20)),
      ),
      child: Row(
        children: [
          _StatusBadge(status: run.status),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  run.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: onSurface,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: onSurface.withAlpha(140),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: () {
              if (run.isInterrupted) {
                ref.read(runExecutorProvider).resumeInterruptedRun(run.id);
              }
              onSelectRun(run.id);
            },
            style: FilledButton.styleFrom(
              backgroundColor: actionColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            child: Text(actionText),
          ),
        ],
      ),
    );
  }
}

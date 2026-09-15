/// SysAI OS Run Detail View — The Core Agentic OS Experience
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/approval.dart';
import '../models/artifact.dart';
import '../models/capability.dart';
import '../models/model_info.dart';
import '../models/run.dart';
import '../providers/app_providers.dart';
import '../theme/status.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'run_workspace_panel.dart';

class RunDetailView extends ConsumerWidget {
  final String runId;
  final VoidCallback? onBack;

  const RunDetailView({super.key, required this.runId, this.onBack});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final primary = theme.colorScheme.primary;
    final surface = theme.colorScheme.surface;

    final run = ref.watch(runByIdProvider(runId));

    if (run == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 40, color: onSurface.withAlpha(80)),
            const SizedBox(height: 12),
            Text('Run not found: $runId',
                style: TextStyle(color: onSurface.withAlpha(150))),
            if (onBack != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onBack, child: const Text('Back')),
            ],
          ],
        ),
      );
    }

    final executor = ref.read(runExecutorProvider);

    return Scaffold(
      backgroundColor: surface,
      appBar: AppBar(
        backgroundColor: surface,
        elevation: 0,
        leading: onBack != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back, size: 18),
                onPressed: onBack,
                tooltip: 'Back to runs',
              )
            : null,
        titleSpacing: onBack != null ? 0 : 20,
        title: Row(
          children: [
            _StatusBadgeLarge(status: run.status),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                run.title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          // Operational Controls: Pause / Resume / Cancel / Resume Interrupted
          if (run.isActive) ...[
            IconButton(
              icon: const Icon(Icons.pause_circle_outline, size: 20, color: Color(0xfff6d365)),
              tooltip: 'Pause Run',
              onPressed: () => executor.pauseRun(run.id),
            ),
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined, size: 20, color: Color(0xffff6b6b)),
              tooltip: 'Cancel Run',
              onPressed: () => executor.cancelRun(run.id),
            ),
          ] else if (run.status == RunStatus.blocked) ...[
            IconButton(
              icon: const Icon(Icons.play_circle_outline, size: 20, color: Color(0xffa5e887)),
              tooltip: 'Resume Run',
              onPressed: () => executor.resumeRun(run.id),
            ),
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined, size: 20, color: Color(0xffff6b6b)),
              tooltip: 'Cancel Run',
              onPressed: () => executor.cancelRun(run.id),
            ),
          ] else if (run.isInterrupted) ...[
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('Resume from Checkpoint'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xff3584e4),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              onPressed: () => executor.resumeInterruptedRun(run.id),
            ),
          ] else if (run.needsApproval) ...[
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined, size: 20, color: Color(0xffff6b6b)),
              tooltip: 'Cancel Run',
              onPressed: () => executor.cancelRun(run.id),
            ),
          ],
          const SizedBox(width: 12),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Left column: Goal, Approval Banner, Plan, Artifacts, Outcome ───
          Expanded(
            flex: 5,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. Prominent Interactive Approval Banner (if approval requested)
                  if (run.needsApproval && run.pendingApproval != null) ...[
                    _InteractiveApprovalBanner(
                      run: run,
                      approval: run.pendingApproval!,
                      onApprove: () => executor.resolveApproval(
                        run.id,
                        run.pendingApproval!.id,
                        true,
                      ),
                      onReject: () => executor.resolveApproval(
                        run.id,
                        run.pendingApproval!.id,
                        false,
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],

                  // 2. Interruption notice (if interrupted)
                  if (run.isInterrupted) ...[
                    _InterruptedBanner(
                      onResume: () => executor.resumeInterruptedRun(run.id),
                    ),
                    const SizedBox(height: 24),
                  ],

                  // 3. Goal section
                  _SectionHeader(title: 'GOAL'),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: onSurface.withAlpha(8),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: onSurface.withAlpha(20)),
                    ),
                    child: Text(
                      run.goal,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: onSurface,
                        height: 1.4,
                      ),
                    ),
                  ),

                  if (run.providerId != null || run.modelId != null) ...[
                    const SizedBox(height: 10),
                    _RunModelRow(run: run),
                  ],

                  const SizedBox(height: 24),

                  // 4. Current Activity (if active)
                  if (run.isActive) ...[
                    _SectionHeader(title: 'CURRENT ACTIVITY'),
                    const SizedBox(height: 8),
                    _CurrentActivityBanner(run: run, primary: primary),
                    const SizedBox(height: 24),
                  ],

                  // 5. Execution Plan
                  _SectionHeader(title: 'EXECUTION PLAN'),
                  const SizedBox(height: 8),
                  if (run.plan.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: onSurface.withAlpha(6),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        run.status == RunStatus.planning
                            ? 'Analyzing goal and formulating plan...'
                            : 'No execution plan recorded.',
                        style: TextStyle(
                            fontSize: 13, color: onSurface.withAlpha(120)),
                      ),
                    )
                  else
                    Column(
                      children: [
                        for (int i = 0; i < run.plan.length; i++)
                          _PlanStepRow(
                            index: i + 1,
                            task: run.plan[i],
                            isLast: i == run.plan.length - 1,
                          ),
                      ],
                    ),

                  const SizedBox(height: 24),

                  // 6. Artifacts Section
                  _SectionHeader(title: 'ARTIFACTS & OUTPUTS (${run.artifacts.length})'),
                  const SizedBox(height: 8),
                  if (run.artifacts.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: onSurface.withAlpha(6),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'No durable artifacts produced yet.',
                        style: TextStyle(
                            fontSize: 13, color: onSurface.withAlpha(120)),
                      ),
                    )
                  else
                    Column(
                      children: [
                        for (final art in run.artifacts)
                          _ArtifactCard(artifact: art),
                      ],
                    ),

                  const SizedBox(height: 24),

                  // 7. Outcome / Result section
                  if (run.outcome.isNotEmpty || run.errorMessage.isNotEmpty) ...[
                    _SectionHeader(
                      title: run.status == RunStatus.completed
                          ? 'VERIFIED OUTCOME'
                          : 'FAILURE REPORT',
                    ),
                    const SizedBox(height: 8),
                    _OutcomeBlock(
                      outcome: run.outcome,
                      errorMessage: run.errorMessage,
                      isSuccess: run.status == RunStatus.completed,
                    ),
                    const SizedBox(height: 24),
                  ],

                  // 8. Metadata section
                  _SectionHeader(title: 'RUN METADATA'),
                  const SizedBox(height: 8),
                  _RunMetadataGrid(run: run),
                ],
              ),
            ),
          ),

          // Divider
          VerticalDivider(width: 1, color: onSurface.withAlpha(20)),

          // ── Right column: the Run's operational surfaces ──────────────────
          Expanded(
            flex: 5,
            child: RunWorkspacePanel(run: run),
          ),
        ],
      ),
    );
  }
}

// ── Interactive Approval Banner ───────────────────────────────────────────────

class _InteractiveApprovalBanner extends StatelessWidget {
  final Run run;
  final ApprovalRequest approval;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _InteractiveApprovalBanner({
    required this.run,
    required this.approval,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    final riskColor = switch (approval.risk) {
      CapabilityRisk.privileged => const Color(0xffff6b6b),
      CapabilityRisk.high => const Color(0xffff9f43),
      CapabilityRisk.medium => const Color(0xfff6d365),
      _ => const Color(0xff65d5e8),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: riskColor.withAlpha(18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: riskColor.withAlpha(120), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.gavel, size: 20, color: riskColor),
              const SizedBox(width: 8),
              Text(
                'APPROVAL REQUIRED',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: riskColor,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: riskColor.withAlpha(40),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: riskColor.withAlpha(90)),
                ),
                child: Text(
                  approval.risk.displayLabel.toUpperCase(),
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    color: riskColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            approval.title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            approval.explanation,
            style: TextStyle(
              fontSize: 13,
              color: onSurface.withAlpha(180),
              height: 1.3,
            ),
          ),
          if (approval.payload.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: onSurface.withAlpha(12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: onSurface.withAlpha(20)),
              ),
              child: Text(
                approval.payload.entries
                    .map((e) => '${e.key}: ${e.value}')
                    .join('\n'),
                style: TextStyle(
                  fontFamily: 'JetBrains Mono',
                  fontSize: 11,
                  color: onSurface.withAlpha(200),
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.close, size: 16),
                label: const Text('Reject'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xffff6b6b),
                  side: const BorderSide(color: Color(0xffff6b6b)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
                onPressed: onReject,
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Approve once'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xff4cd137),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onPressed: onApprove,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Interrupted Banner ────────────────────────────────────────────────────────

class _InterruptedBanner extends StatelessWidget {
  final VoidCallback onResume;

  const _InterruptedBanner({required this.onResume});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    const warningColor = Color(0xfff6d365);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: warningColor.withAlpha(18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: warningColor.withAlpha(90)),
      ),
      child: Row(
        children: [
          const Icon(Icons.pause_circle_filled, size: 22, color: warningColor),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'RUN WAS INTERRUPTED',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                    color: warningColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Execution halted during an unexpected application exit or restart. You can resume safely from the latest checkpoint.',
                  style: TextStyle(
                    fontSize: 12,
                    color: onSurface.withAlpha(190),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: onResume,
            style: FilledButton.styleFrom(
              backgroundColor: warningColor,
              foregroundColor: Colors.black,
            ),
            child: const Text('Resume'),
          ),
        ],
      ),
    );
  }
}

// ── Artifact Card ─────────────────────────────────────────────────────────────

class _ArtifactCard extends StatelessWidget {
  final Artifact artifact;

  const _ArtifactCard({required this.artifact});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    final (icon, color) = switch (artifact.type) {
      ArtifactType.file => (Icons.insert_drive_file_outlined, const Color(0xff65d5e8)),
      ArtifactType.diff => (Icons.difference_outlined, const Color(0xffa5e887)),
      ArtifactType.report => (Icons.assessment_outlined, const Color(0xfff6d365)),
      ArtifactType.commandOutput => (Icons.terminal_outlined, const Color(0xffe056fd)),
      ArtifactType.diagnostic => (Icons.health_and_safety_outlined, const Color(0xffff9f43)),
      ArtifactType.terminalLog => (Icons.terminal_outlined, const Color(0xffe056fd)),
      ArtifactType.browserCapture => (Icons.public_outlined, const Color(0xff6ac9e8)),
      ArtifactType.downloadedFile => (Icons.download_outlined, const Color(0xff8fd67a)),
      ArtifactType.screenshot => (Icons.photo_camera_outlined, const Color(0xffb595f5)),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: onSurface.withAlpha(8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: onSurface.withAlpha(20)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      artifact.title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: onSurface,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: color.withAlpha(30),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        artifact.type.displayLabel.toUpperCase(),
                        style: TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.w700,
                          color: color,
                        ),
                      ),
                    ),
                  ],
                ),
                if (artifact.path != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    artifact.path!,
                    style: TextStyle(
                      fontFamily: 'JetBrains Mono',
                      fontSize: 11,
                      color: onSurface.withAlpha(120),
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.visibility_outlined, size: 18),
            tooltip: 'View artifact',
            onPressed: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Row(
                    children: [
                      Icon(icon, size: 20, color: color),
                      const SizedBox(width: 10),
                      Text(artifact.title),
                    ],
                  ),
                  content: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (artifact.path != null)
                          Text('Path: ${artifact.path}',
                              style: TextStyle(
                                  fontFamily: 'JetBrains Mono',
                                  fontSize: 11,
                                  color: onSurface.withAlpha(140))),
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: onSurface.withAlpha(12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: SelectableText(
                            artifact.contentPreview ?? 'No preview content available.',
                            style: const TextStyle(
                                fontFamily: 'JetBrains Mono', fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

// ── Section Header ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Text(title, style: AppText.label.copyWith(color: onSurface.withAlpha(120)));
  }
}

// ── Current Activity Banner ───────────────────────────────────────────────────

/// The single fastest thing to find after the Run title — deliberately
/// larger and more saturated than any other panel on this page while a Run
/// is active.
class _CurrentActivityBanner extends StatelessWidget {
  final Run run;
  final Color primary;

  const _CurrentActivityBanner({required this.run, required this.primary});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return Container(
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: primary.withAlpha(16),
        borderRadius: Radii.mdR,
        border: Border.all(color: primary.withAlpha(70), width: 1.2),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: primary),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(run.displayStatus.toUpperCase(), style: AppText.badge.copyWith(color: primary)),
                const SizedBox(height: 2),
                Text(
                  run.latestEventMessage.isNotEmpty ? run.latestEventMessage : 'Working on task…',
                  style: AppText.bodyStrong.copyWith(fontSize: 14, color: onSurface),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Plan Step Row ─────────────────────────────────────────────────────────────

class _PlanStepRow extends StatelessWidget {
  final int index;
  final RunTask task;
  final bool isLast;

  const _PlanStepRow({
    required this.index,
    required this.task,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final scheme = Theme.of(context).colorScheme;

    final (icon, color) = switch (task.status) {
      'completed' => (
          Icon(Icons.check_circle, size: 18, color: StatusTone.success.foreground(scheme)),
          StatusTone.success.foreground(scheme),
        ),
      'running' => (
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: StatusTone.progress.foreground(scheme)),
          ),
          StatusTone.progress.foreground(scheme),
        ),
      'failed' => (
          Icon(Icons.cancel, size: 18, color: StatusTone.danger.foreground(scheme)),
          StatusTone.danger.foreground(scheme),
        ),
      _ => (
          Icon(Icons.radio_button_unchecked,
              size: 18, color: onSurface.withAlpha(70)),
          onSurface.withAlpha(70),
        ),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            icon,
            if (!isLast)
              Container(
                width: 2,
                height: task.description.isNotEmpty ? 44 : 26,
                color: onSurface.withAlpha(20),
                margin: const EdgeInsets.symmetric(vertical: 2),
              ),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        task.title,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body.copyWith(
                          fontSize: 13,
                          fontWeight: task.status == 'running' ? FontWeight.w700 : FontWeight.w500,
                          color: task.status == 'completed' ? onSurface.withAlpha(150) : onSurface,
                          decoration: task.status == 'completed' ? TextDecoration.lineThrough : null,
                        ),
                      ),
                    ),
                    if (task.attempts > 1) ...[
                      const SizedBox(width: Space.sm),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: StatusTone.warning.foreground(scheme).withAlpha(30),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          'Attempt ${task.attempts}/${task.maxAttempts}',
                          style: AppText.badge.copyWith(fontSize: 8, color: StatusTone.warning.foreground(scheme)),
                        ),
                      ),
                    ],
                  ],
                ),
                if (task.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(task.description, style: AppText.metadata.copyWith(color: onSurface.withAlpha(110))),
                ],
                if (task.dependencies.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Depends on: ${task.dependencies.join(', ')}',
                    style: AppText.metadata.copyWith(
                      fontSize: 10,
                      fontStyle: FontStyle.italic,
                      color: onSurface.withAlpha(90),
                    ),
                  ),
                ],
                if (task.error != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Error: ${task.error}',
                    style: AppText.metadata.copyWith(fontSize: 11, color: StatusTone.danger.foreground(scheme)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Outcome Block ─────────────────────────────────────────────────────────────

class _OutcomeBlock extends StatelessWidget {
  final String outcome;
  final String errorMessage;
  final bool isSuccess;

  const _OutcomeBlock({
    required this.outcome,
    required this.errorMessage,
    required this.isSuccess,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final scheme = theme.colorScheme;

    // A verified success is calm (soft, low-alarm tint); a failure is
    // equally legible but never styled like a crash screen.
    final borderColor = isSuccess ? StatusTone.success.foreground(scheme) : StatusTone.danger.foreground(scheme);
    final text = isSuccess ? outcome : (errorMessage.isNotEmpty ? errorMessage : outcome);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: borderColor.withAlpha(isSuccess ? 8 : 10),
        borderRadius: Radii.mdR,
        border: Border.all(color: borderColor.withAlpha(isSuccess ? 50 : 60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isSuccess ? Icons.check_circle_outline : Icons.error_outline,
                size: IconSizes.md,
                color: borderColor,
              ),
              const SizedBox(width: Space.sm),
              Text(isSuccess ? 'VERIFIED OUTCOME' : 'FAILED', style: AppText.badge.copyWith(color: borderColor)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.copy, size: 14),
                tooltip: 'Copy output',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Output copied to clipboard')),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          SelectableText(text, style: AppText.body.copyWith(fontSize: 13, height: 1.5, color: onSurface)),
        ],
      ),
    );
  }
}

// ── Run Metadata Grid ─────────────────────────────────────────────────────────

class _RunMetadataGrid extends StatelessWidget {
  final Run run;

  const _RunMetadataGrid({required this.run});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: onSurface.withAlpha(6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: onSurface.withAlpha(15)),
      ),
      child: Column(
        children: [
          _MetaRow('Run ID', run.id, isCode: true),
          _MetaRow('Status', run.displayStatus),
          _MetaRow('Created', _formatDate(run.createdAt)),
          if (run.startedAt != null)
            _MetaRow('Started', _formatDate(run.startedAt!)),
          if (run.completedAt != null)
            _MetaRow('Completed', _formatDate(run.completedAt!)),
          if (run.startedAt != null && run.completedAt != null)
            _MetaRow(
              'Duration',
              _formatDuration(run.completedAt!.difference(run.startedAt!)),
            ),
          if (run.providerId != null) _MetaRow('Provider', run.providerId!),
          if (run.modelId != null) _MetaRow('Model', run.modelLabel, isCode: true),
          _MetaRow('Tasks', '${run.plan.length} total'),
          _MetaRow('Events', '${run.events.length} recorded'),
          _MetaRow('Artifacts', '${run.artifacts.length} durable outputs'),
        ],
      ),
    );
  }

  static String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  static String _formatDuration(Duration d) {
    if (d.inMinutes > 0) {
      return '${d.inMinutes}m ${d.inSeconds % 60}s';
    }
    return '${d.inSeconds}s';
  }
}

class _MetaRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isCode;

  const _MetaRow(this.label, this.value, {this.isCode = false});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(fontSize: 12, color: onSurface.withAlpha(120))),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFamily: isCode ? 'monospace' : null,
              color: onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Status Badge Large ────────────────────────────────────────────────────────

class _StatusBadgeLarge extends StatelessWidget {
  final RunStatus status;

  const _StatusBadgeLarge({required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StatusPill(style: statusStyleForRun(status, scheme));
  }
}

// ── Run Model Row ─────────────────────────────────────────────────────────────

/// Compact, read-only display of the model a Run actually used. Historical
/// Runs cannot have their model changed here — only System → Models changes
/// the default, and only the Home composer picks a per-Run override before
/// the Run starts.
class _RunModelRow extends ConsumerWidget {
  final Run run;

  const _RunModelRow({required this.run});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final providers = ref.watch(providersListProvider).valueOrNull ?? const <ProviderInfo>[];

    ProviderInfo? provider;
    for (final p in providers) {
      if (p.id == run.providerId) {
        provider = p;
        break;
      }
    }

    final defaultModel = ref.watch(defaultModelProvider).valueOrNull;
    final isOverride = run.hasModelOverride &&
        (defaultModel == null ||
            !defaultModel.isSet ||
            run.modelId != defaultModel.modelId ||
            run.providerId != defaultModel.providerId);

    return Row(
      children: [
        Icon(Icons.memory_rounded, size: 13, color: onSurface.withAlpha(120)),
        const SizedBox(width: 6),
        Text('MODEL', style: AppText.label.copyWith(color: onSurface.withAlpha(120))),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            run.modelLabel,
            overflow: TextOverflow.ellipsis,
            style: AppText.code.copyWith(color: onSurface),
          ),
        ),
        if (provider != null) ...[
          Text('  ·  ', style: AppText.metadata.copyWith(color: onSurface.withAlpha(90))),
          Text(provider.name, style: AppText.bodySecondary.copyWith(color: onSurface.withAlpha(160))),
          Text('  ·  ', style: AppText.metadata.copyWith(color: onSurface.withAlpha(90))),
          Text(provider.local ? 'Local' : 'Cloud',
              style: AppText.bodySecondary.copyWith(color: onSurface.withAlpha(160))),
        ],
        if (isOverride) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: onSurface.withAlpha(18),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text('OVERRIDE', style: AppText.badge.copyWith(color: onSurface.withAlpha(150))),
          ),
        ],
      ],
    );
  }
}


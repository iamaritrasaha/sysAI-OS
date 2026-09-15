/// SysAI OS Runs View — Persisted Runs browser
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/run.dart';
import '../providers/app_providers.dart';
import '../theme/status.dart';
import 'run_detail_view.dart';
import 'shell.dart';

enum _RunFilter {
  all,
  active,
  completed,
  failed;

  String get label => switch (this) {
    _RunFilter.all => 'All Runs',
    _RunFilter.active => 'Active',
    _RunFilter.completed => 'Completed',
    _RunFilter.failed => 'Failed',
  };
}

class RunsView extends ConsumerStatefulWidget {
  const RunsView({super.key});

  @override
  ConsumerState<RunsView> createState() => _RunsViewState();
}

class _RunsViewState extends ConsumerState<RunsView> {
  _RunFilter _filter = _RunFilter.all;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final surface = theme.colorScheme.surface;
    final primary = theme.colorScheme.primary;

    final selectedRunId = ref.watch(selectedRunIdProvider);
    final runsAsync = ref.watch(runListProvider);

    // If a run is selected, show detail view with back button
    if (selectedRunId != null) {
      return RunDetailView(
        runId: selectedRunId,
        onBack: () =>
            ref.read(selectedRunIdProvider.notifier).state = null,
      );
    }

    final allRuns = runsAsync.valueOrNull ?? [];
    final filteredRuns = switch (_filter) {
      _RunFilter.all => allRuns,
      _RunFilter.active => allRuns.where((r) => r.isActive).toList(),
      _RunFilter.completed =>
        allRuns.where((r) => r.status == RunStatus.completed).toList(),
      _RunFilter.failed =>
        allRuns.where((r) => r.status == RunStatus.failed).toList(),
    };

    return Scaffold(
      backgroundColor: surface,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
            child: Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Runs',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: onSurface,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Persisted execution records from SysAI OS runtime',
                      style: TextStyle(
                        fontSize: 13,
                        color: onSurface.withAlpha(140),
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: 'Reload from database',
                  onPressed: () =>
                      ref.read(runListProvider.notifier).refreshFromDb(),
                ),
              ],
            ),
          ),

          // ── Filter Chips ─────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Row(
              children: [
                for (final f in _RunFilter.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _FilterButton(
                      label: f.label,
                      count: _countForFilter(allRuns, f),
                      isSelected: _filter == f,
                      onTap: () => setState(() => _filter = f),
                      primary: primary,
                      onSurface: onSurface,
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          Divider(height: 1, color: onSurface.withAlpha(20)),

          // ── Runs List ────────────────────────────────────────────────────
          Expanded(
            child: runsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(
                child: Text('Error loading runs: $err',
                    style: const TextStyle(color: Color(0xffff6b6b))),
              ),
              data: (_) {
                if (filteredRuns.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.inbox_outlined,
                            size: 40, color: onSurface.withAlpha(70)),
                        const SizedBox(height: 12),
                        Text(
                          _emptyMessageForFilter(_filter),
                          style: TextStyle(
                            fontSize: 14,
                            color: onSurface.withAlpha(130),
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 28, vertical: 16),
                  itemCount: filteredRuns.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final run = filteredRuns[index];
                    return _RunListItem(
                      run: run,
                      onTap: () => ref
                          .read(selectedRunIdProvider.notifier)
                          .state = run.id,
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  int _countForFilter(List<Run> runs, _RunFilter filter) => switch (filter) {
    _RunFilter.all => runs.length,
    _RunFilter.active => runs.where((r) => r.isActive).length,
    _RunFilter.completed =>
      runs.where((r) => r.status == RunStatus.completed).length,
    _RunFilter.failed =>
      runs.where((r) => r.status == RunStatus.failed).length,
  };

  String _emptyMessageForFilter(_RunFilter filter) => switch (filter) {
    _RunFilter.all => 'No runs in database. Create one from the Home view.',
    _RunFilter.active => 'No active runs currently executing.',
    _RunFilter.completed => 'No completed runs yet.',
    _RunFilter.failed => 'No failed runs.',
  };
}

class _FilterButton extends StatelessWidget {
  final String label;
  final int count;
  final bool isSelected;
  final VoidCallback onTap;
  final Color primary;
  final Color onSurface;

  const _FilterButton({
    required this.label,
    required this.count,
    required this.isSelected,
    required this.onTap,
    required this.primary,
    required this.onSurface,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? primary.withAlpha(25) : onSurface.withAlpha(10),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? primary : onSurface.withAlpha(20),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? primary : onSurface.withAlpha(170),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                color: isSelected ? primary.withAlpha(40) : onSurface.withAlpha(15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: isSelected ? primary : onSurface.withAlpha(140),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RunListItem extends StatelessWidget {
  final Run run;
  final VoidCallback onTap;

  const _RunListItem({required this.run, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final primary = theme.colorScheme.primary;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: onSurface.withAlpha(6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: run.isActive
                ? primary.withAlpha(60)
                : onSurface.withAlpha(18),
          ),
        ),
        child: Row(
          children: [
            _RunStatusIcon(status: run.status),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        run.displayStatus.toUpperCase(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                          color: statusStyleForRun(run.status, Theme.of(context).colorScheme).foreground,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        run.id,
                        style: TextStyle(
                          fontSize: 10,
                          fontFamily: 'JetBrains Mono',
                          color: onSurface.withAlpha(100),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    run.goal,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (run.outcome.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      run.outcome.split('\n').first,
                      style: TextStyle(
                        fontSize: 12,
                        color: onSurface.withAlpha(130),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (run.plan.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      '${run.plan.where((t) => t.status == 'completed').length}/${run.plan.length} tasks completed',
                      style: TextStyle(
                        fontSize: 11,
                        color: onSurface.withAlpha(110),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _formatDateTime(run.createdAt),
                  style: TextStyle(
                    fontSize: 11,
                    color: onSurface.withAlpha(100),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${run.events.length} events',
                  style: TextStyle(
                    fontSize: 10,
                    color: onSurface.withAlpha(90),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 18, color: onSurface.withAlpha(80)),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _RunStatusIcon extends StatelessWidget {
  final RunStatus status;

  const _RunStatusIcon({required this.status});

  @override
  Widget build(BuildContext context) {
    final style = statusStyleForRun(status, Theme.of(context).colorScheme);

    if (status == RunStatus.running || status == RunStatus.planning || status == RunStatus.verifying) {
      return SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2, color: style.foreground),
      );
    }
    return Icon(style.icon, size: 22, color: style.foreground);
  }
}

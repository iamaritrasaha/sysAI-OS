/// SysAI OS Activity View — global structured-event timeline across all Runs.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/run.dart';
import '../providers/app_providers.dart';
import '../theme/event_style.dart';
import '../theme/status.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/state_panels.dart';

enum _ActivityFilter { all, attention }

class ActivityView extends ConsumerStatefulWidget {
  final void Function(String runId) onOpenRun;

  const ActivityView({super.key, required this.onOpenRun});

  @override
  ConsumerState<ActivityView> createState() => _ActivityViewState();
}

class _ActivityViewState extends ConsumerState<ActivityView> {
  _ActivityFilter _filter = _ActivityFilter.all;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final surface = theme.colorScheme.surface;
    final primary = theme.colorScheme.primary;

    final runs = ref.watch(runListProvider).valueOrNull ?? const <Run>[];

    final items = <(Run, RunEvent)>[];
    for (final run in runs) {
      for (final event in run.events) {
        items.add((run, event));
      }
    }
    items.sort((a, b) => b.$2.timestamp.compareTo(a.$2.timestamp));

    final visibleItems = _filter == _ActivityFilter.all
        ? items
        : items.where((i) {
            final tone = eventVisualFor(i.$2.type).tone;
            return tone == StatusTone.warning || tone == StatusTone.danger;
          }).toList();

    // Cap render volume — this is a scanning surface, not a full audit log.
    final capped = visibleItems.take(300).toList();

    return Scaffold(
      backgroundColor: surface,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 24, 32, Space.lg),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Activity', style: AppText.pageTitle.copyWith(color: onSurface)),
                      const SizedBox(height: 3),
                      Text(
                        'Structured events across every Run, newest first',
                        style: AppText.bodySecondary.copyWith(color: onSurface.withAlpha(140)),
                      ),
                    ],
                  ),
                ),
                _FilterChip(
                  label: 'All',
                  selected: _filter == _ActivityFilter.all,
                  onTap: () => setState(() => _filter = _ActivityFilter.all),
                  primary: primary,
                  onSurface: onSurface,
                ),
                const SizedBox(width: Space.sm),
                _FilterChip(
                  label: 'Needs attention',
                  selected: _filter == _ActivityFilter.attention,
                  onTap: () => setState(() => _filter = _ActivityFilter.attention),
                  primary: primary,
                  onSurface: onSurface,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: onSurface.withAlpha(20)),
          Expanded(
            child: capped.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(Space.xxl),
                    child: EmptyStatePanel(
                      icon: Icons.timeline_outlined,
                      message: _filter == _ActivityFilter.all
                          ? 'No activity yet. Events from Runs will appear here as they execute.'
                          : 'Nothing needs attention right now.',
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: Space.md),
                    itemCount: capped.length,
                    separatorBuilder: (context, index) => const SizedBox(height: Space.xs),
                    itemBuilder: (context, index) {
                      final (run, event) = capped[index];
                      return _ActivityRow(
                        run: run,
                        event: event,
                        onTap: () => widget.onOpenRun(run.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color primary;
  final Color onSurface;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.primary,
    required this.onSurface,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: Radii.smR,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.xs),
        decoration: BoxDecoration(
          color: selected ? primary.withAlpha(25) : onSurface.withAlpha(10),
          borderRadius: Radii.smR,
          border: Border.all(color: selected ? primary : onSurface.withAlpha(20)),
        ),
        child: Text(
          label,
          style: AppText.bodySecondary.copyWith(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? primary : onSurface.withAlpha(160),
          ),
        ),
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final Run run;
  final RunEvent event;
  final VoidCallback onTap;

  const _ActivityRow({required this.run, required this.event, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onSurface = scheme.onSurface;
    final visual = eventVisualFor(event.type);
    final color = visual.tone.foreground(scheme);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.mdR,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
          decoration: BoxDecoration(
            color: onSurface.withAlpha(6),
            borderRadius: Radii.mdR,
            border: Border.all(color: onSurface.withAlpha(14)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(visual.icon, size: IconSizes.md, color: color),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(visual.category, style: AppText.bodyStrong.copyWith(fontSize: 12, color: color)),
                        const SizedBox(width: 6),
                        Text(event.type, style: AppText.code.copyWith(fontSize: 10.5, color: onSurface.withAlpha(110))),
                        const Spacer(),
                        Text(_relativeTime(event.timestamp),
                            style: AppText.metadata.copyWith(color: onSurface.withAlpha(100))),
                      ],
                    ),
                    if (event.message.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(event.message,
                          style: AppText.bodySecondary.copyWith(color: onSurface.withAlpha(200)),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                    ],
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(Icons.subdirectory_arrow_right_rounded, size: 12, color: onSurface.withAlpha(90)),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(run.title,
                              style: AppText.metadata.copyWith(color: onSurface.withAlpha(140)),
                              overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

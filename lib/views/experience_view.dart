/// SysAI OS Experience View — Read-only interface to SysAI Experience Engine
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/state_panels.dart';

class ExperienceView extends ConsumerStatefulWidget {
  const ExperienceView({super.key});

  @override
  ConsumerState<ExperienceView> createState() => _ExperienceViewState();
}

class _ExperienceViewState extends ConsumerState<ExperienceView> {
  final TextEditingController _searchController = TextEditingController();
  String _selectedType = 'all';
  List<dynamic>? _searchResults;
  bool _searching = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    final text = query.trim();
    if (text.isEmpty) {
      setState(() => _searchResults = null);
      return;
    }

    setState(() => _searching = true);
    final bridge = ref.read(bridgeServiceProvider);
    try {
      final res =
          await bridge.call('search_memory', params: {'query': text, 'limit': 30});
      setState(() {
        _searchResults = res['memories'] as List<dynamic>? ?? [];
      });
    } catch (_) {
      setState(() => _searchResults = []);
    } finally {
      setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final surface = theme.colorScheme.surface;
    final primary = theme.colorScheme.primary;

    final expData = ref.watch(experienceProvider);

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
                      Text('Experience', style: AppText.pageTitle.copyWith(color: onSurface)),
                      const SizedBox(height: 3),
                      Text(
                        'What SysAI has learned from past Runs',
                        style: AppText.bodySecondary.copyWith(color: onSurface.withAlpha(140)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                OutlinedButton.icon(
                  onPressed: () =>
                      ref.read(experienceProvider.notifier).refresh(),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Refresh'),
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

            const SizedBox(height: 24),

            // ── Experience Metrics Grid ──────────────────────────────────
            expData.when(
              loading: () => const LoadingStatePanel(message: 'Loading experience…'),
              error: (err, _) => ErrorStatePanel(
                message: 'Failed to load experience data: $err',
                onRetry: () => ref.read(experienceProvider.notifier).refresh(),
              ),
              data: (data) {
                final stats =
                    (data['stats'] as Map?)?.cast<String, dynamic>() ?? {};
                final total = stats['total'] ?? 0;
                final patterns = stats['patterns'] ?? 0;
                final assessments = stats['assessments'] ?? 0;
                final byType = (stats['by_type'] as Map?)?.cast<String, dynamic>() ?? {};
                final recurring = byType['incident'] ?? 0;

                final rawMemories =
                    data['memories'] as List<dynamic>? ?? [];
                final memoriesToDisplay = _searchResults ?? rawMemories;
                final highConfidence =
                    memoriesToDisplay.where((m) => m['confidence'] == 'high').length;

                final filteredMemories = _selectedType == 'all'
                    ? memoriesToDisplay
                    : memoriesToDisplay
                        .where((m) => m['type'] == _selectedType)
                        .toList();

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // What SysAI has actually learned, in plain terms — not
                    // a schema/record-count dump.
                    Row(
                      children: [
                        Expanded(
                          child: _StatBox(
                            label: 'LEARNED PATTERNS',
                            value: '$patterns',
                            icon: Icons.auto_awesome_outlined,
                            color: const Color(0xff8fd67a),
                          ),
                        ),
                        const SizedBox(width: Space.md),
                        Expanded(
                          child: _StatBox(
                            label: 'RECURRING PROBLEMS',
                            value: '$recurring',
                            icon: Icons.repeat_rounded,
                            color: const Color(0xfff0b84c),
                          ),
                        ),
                        const SizedBox(width: Space.md),
                        Expanded(
                          child: _StatBox(
                            label: 'HIGH CONFIDENCE',
                            value: '$highConfidence',
                            icon: Icons.verified_outlined,
                            color: const Color(0xff6ac9e8),
                          ),
                        ),
                        const SizedBox(width: Space.md),
                        Expanded(
                          child: _StatBox(
                            label: 'DIAGNOSTIC RUNS',
                            value: '$assessments',
                            icon: Icons.analytics_outlined,
                            color: onSurface.withAlpha(150),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.xs),
                    Text(
                      '$total learned records total',
                      style: AppText.metadata.copyWith(color: onSurface.withAlpha(110)),
                    ),

                    const SizedBox(height: 28),

                    // ── Search & Filter Bar ──────────────────────────────
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            onSubmitted: _performSearch,
                            decoration: InputDecoration(
                              hintText:
                                  'Search experiences by keyword, finding ID, or domain...',
                              hintStyle: TextStyle(
                                  color: onSurface.withAlpha(90),
                                  fontSize: 13),
                              prefixIcon: Icon(Icons.search,
                                  size: 18, color: onSurface.withAlpha(120)),
                              suffixIcon: _searchController.text.isNotEmpty
                                  ? IconButton(
                                      icon: const Icon(Icons.clear, size: 16),
                                      onPressed: () {
                                        _searchController.clear();
                                        _performSearch('');
                                      },
                                    )
                                  : null,
                              filled: true,
                              fillColor: onSurface.withAlpha(8),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide:
                                    BorderSide(color: onSurface.withAlpha(20)),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                            ),
                            style: TextStyle(color: onSurface, fontSize: 13),
                          ),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton(
                          onPressed: () =>
                              _performSearch(_searchController.text),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: primary,
                            foregroundColor: const Color(0xff0a1a0a),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: _searching
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Text('Search'),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // Filter tabs
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final t in [
                            ('all', 'All Memories'),
                            ('pattern', 'Patterns'),
                            ('incident', 'Incidents'),
                            ('outcome', 'Outcomes'),
                            ('machine_fact', 'Machine Facts'),
                            ('user_correction', 'Corrections'),
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: _TypeChip(
                                label: t.$2,
                                isSelected: _selectedType == t.$1,
                                onTap: () =>
                                    setState(() => _selectedType = t.$1),
                                primary: primary,
                                onSurface: onSurface,
                              ),
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // ── Records List or Empty State ──────────────────────
                    if (filteredMemories.isEmpty)
                      EmptyStatePanel(
                        icon: Icons.psychology_outlined,
                        message: _searchResults != null
                            ? 'No matching memories found. Try a different keyword.'
                            : 'Nothing learned yet. SysAI records patterns, recurring problems, and verified outcomes as Runs execute.',
                      )
                    else
                      ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: filteredMemories.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final mem =
                              (filteredMemories[index] as Map).cast<String, dynamic>();
                          return _MemoryCard(mem: mem);
                        },
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

class _StatBox extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _StatBox({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final surface = Theme.of(context).colorScheme.surface;

    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: Radii.mdR,
        border: Border.all(color: onSurface.withAlpha(20)),
      ),
      child: Row(
        children: [
          Icon(icon, size: IconSizes.lg, color: color),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppText.label.copyWith(color: onSurface.withAlpha(120)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(value, style: AppText.pageTitle.copyWith(fontSize: 18, color: onSurface)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final Color primary;
  final Color onSurface;

  const _TypeChip({
    required this.label,
    required this.isSelected,
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
          color: isSelected ? primary.withAlpha(25) : onSurface.withAlpha(10),
          borderRadius: Radii.smR,
          border: Border.all(
            color: isSelected ? primary : onSurface.withAlpha(20),
          ),
        ),
        child: Text(
          label,
          style: AppText.bodySecondary.copyWith(
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            color: isSelected ? primary : onSurface.withAlpha(160),
          ),
        ),
      ),
    );
  }
}

/// Human-friendly label for a raw memory `type` value (e.g. `machine_fact`
/// → `Machine Fact`) — the interface should never show a snake_case schema
/// value verbatim.
String _humanizeType(String type) =>
    type.split('_').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');

class _MemoryCard extends StatelessWidget {
  final Map<String, dynamic> mem;

  const _MemoryCard({required this.mem});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final type = mem['type'] as String? ?? 'incident';
    final subject = mem['subject'] as String? ?? '';
    final statement = mem['statement'] as String? ?? '';
    final confidence = mem['confidence'] as String? ?? 'medium';
    final observations = mem['times_observed'] ?? 1;
    final status = mem['status'] as String? ?? 'active';

    final color = switch (type) {
      'pattern' => const Color(0xff8fd67a),
      'incident' => const Color(0xfff0b84c),
      'outcome' => const Color(0xff6ac9e8),
      _ => onSurface.withAlpha(150),
    };

    return Container(
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: onSurface.withAlpha(6),
        borderRadius: Radii.mdR,
        border: Border.all(color: onSurface.withAlpha(18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withAlpha(25),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: color.withAlpha(70)),
                ),
                child: Text(_humanizeType(type).toUpperCase(), style: AppText.badge.copyWith(color: color)),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(subject, style: AppText.bodyStrong.copyWith(color: onSurface), overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: Space.sm),
              Text(
                'Seen $observations× · ${confidence[0].toUpperCase()}${confidence.substring(1)} confidence${status != 'active' ? ' · ${_humanizeType(status)}' : ''}',
                style: AppText.metadata.copyWith(color: onSurface.withAlpha(110)),
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          Text(statement, style: AppText.body.copyWith(fontSize: 12.5, color: onSurface.withAlpha(190))),
        ],
      ),
    );
  }
}

/// SysAI OS Computer View — Controlled Computer Use.
///
/// Renders the one real Computer target implemented this phase
/// (`sysai-test-surface`) and its action history. Snapshots only, no
/// video — and no fabricated cursor animation: any overlay drawn here
/// comes from a real, persisted `ComputerAction`'s own coordinates.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/run.dart';
import '../providers/app_providers.dart';
import '../services/test_surface_controller.dart';
import '../services/view_capture_service.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';

class ComputerView extends ConsumerStatefulWidget {
  const ComputerView({super.key});

  @override
  ConsumerState<ComputerView> createState() => _ComputerViewState();
}

class _ComputerViewState extends ConsumerState<ComputerView> {
  Uint8List? _lastCapture;
  String? _selectedRunId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final runs = ref.watch(runListProvider).valueOrNull ?? const <Run>[];
    // Runs that have at least one recorded Computer action, newest first —
    // the "session" list. Kept simple (a filtered view of live Run state)
    // rather than a second live-streaming aggregate.
    final runsWithComputerActivity =
        runs
            .where(
              (r) => r.events.any((e) => e.type.startsWith('computer.action')),
            )
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Row(
        children: [
          Expanded(
            flex: 3,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Computer',
                    style: AppText.pageTitle.copyWith(color: onSurface),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Controlled Computer Use — real actions against a SysAI-owned test surface only',
                    style: AppText.bodySecondary.copyWith(
                      color: onSurface.withAlpha(140),
                    ),
                  ),
                  const SizedBox(height: Space.xl),
                  _TestSurfacePanel(
                    onCaptured: (bytes) => setState(() => _lastCapture = bytes),
                  ),
                  const SizedBox(height: Space.xl),
                  if (_lastCapture != null) ...[
                    Text(
                      'LATEST CAPTURE',
                      style: AppText.label.copyWith(
                        color: onSurface.withAlpha(120),
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: onSurface.withAlpha(20)),
                        borderRadius: Radii.mdR,
                      ),
                      padding: const EdgeInsets.all(4),
                      child: Image.memory(_lastCapture!, width: 320),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Container(width: 1, color: onSurface.withAlpha(20)),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
                  child: Text(
                    'ACTIVITY',
                    style: AppText.label.copyWith(
                      color: onSurface.withAlpha(120),
                    ),
                  ),
                ),
                Expanded(
                  child: runsWithComputerActivity.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'No Computer actions yet. Run a goal that interacts with the test surface, '
                              'or use the controls on the left directly.',
                              textAlign: TextAlign.center,
                              style: AppText.bodySecondary.copyWith(
                                color: onSurface.withAlpha(130),
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: runsWithComputerActivity.length,
                          itemBuilder: (context, index) {
                            final run = runsWithComputerActivity[index];
                            final isSelected = run.id == _selectedRunId;
                            return _ComputerRunRow(
                              run: run,
                              expanded: isSelected,
                              onTap: () => setState(
                                () =>
                                    _selectedRunId = isSelected ? null : run.id,
                              ),
                            );
                          },
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

// ── Test surface panel ───────────────────────────────────────────────────

class _TestSurfacePanel extends ConsumerWidget {
  final ValueChanged<Uint8List> onCaptured;

  const _TestSurfacePanel({required this.onCaptured});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final state = ref.watch(testSurfaceControllerProvider);
    final controller = ref.read(testSurfaceControllerProvider.notifier);

    return Container(
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        border: Border.all(color: onSurface.withAlpha(20)),
        borderRadius: Radii.lgR,
      ),
      child: RepaintBoundary(
        key: testSurfaceRepaintKey,
        child: Container(
          color: theme.colorScheme.surface,
          padding: const EdgeInsets.all(Space.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SysAI OS Test Surface',
                style: AppText.sectionHeading.copyWith(color: onSurface),
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: ValueKey(state.fieldValue),
                controller: TextEditingController(text: state.fieldValue)
                  ..selection = TextSelection.collapsed(
                    offset: state.fieldValue.length,
                  ),
                decoration: const InputDecoration(
                  labelText: 'main_field',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: controller.setFieldValue,
              ),
              const SizedBox(height: Space.md),
              Row(
                children: [
                  Checkbox(
                    value: state.checked,
                    onChanged: (_) => controller.toggleCheckbox(),
                  ),
                  Text('agree_checkbox', style: TextStyle(color: onSurface)),
                  const SizedBox(width: Space.lg),
                  DropdownButton<String>(
                    value: state.selectedOption,
                    items: [
                      for (final o in kTestSurfaceOptions)
                        DropdownMenuItem(value: o, child: Text(o)),
                    ],
                    onChanged: (v) {
                      if (v != null) controller.selectOption(v);
                    },
                  ),
                ],
              ),
              const SizedBox(height: Space.md),
              SizedBox(
                height: 60,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: onSurface.withAlpha(20)),
                    borderRadius: Radii.smR,
                  ),
                  child: ListView.builder(
                    itemCount: 30,
                    itemBuilder: (context, i) => Container(
                      height: 20,
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        'scroll_region item $i',
                        style: TextStyle(
                          fontSize: 11,
                          color: onSurface.withAlpha(140),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: Space.md),
              Wrap(
                spacing: Space.md,
                runSpacing: Space.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: controller.submit,
                    child: Text(
                      state.submitted
                          ? 'submit_button (submitted)'
                          : 'submit_button',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: controller.reset,
                    child: const Text('Reset'),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.camera_alt_outlined, size: 16),
                    label: const Text('Capture'),
                    onPressed: () async {
                      final bytes = await captureBoundaryPng(
                        testSurfaceRepaintKey,
                      );
                      if (bytes != null) onCaptured(bytes);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Activity rows ─────────────────────────────────────────────────────────

class _ComputerRunRow extends StatelessWidget {
  final Run run;
  final bool expanded;
  final VoidCallback onTap;

  const _ComputerRunRow({
    required this.run,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final actionEvents = run.events
        .where((e) => e.type.startsWith('computer.action'))
        .toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: onSurface.withAlpha(6),
        borderRadius: Radii.smR,
        border: Border.all(color: onSurface.withAlpha(16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onTap,
            borderRadius: Radii.smR,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      run.title,
                      style: TextStyle(fontSize: 12.5, color: onSurface),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '${actionEvents.length} actions',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: onSurface.withAlpha(120),
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: onSurface.withAlpha(120),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final e in actionEvents) _ActionEventLine(event: e),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ActionEventLine extends StatelessWidget {
  final RunEvent event;

  const _ActionEventLine({required this.event});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final data = event.data ?? const {};
    final action = data['action'] as String? ?? '';
    final target = data['target_id'] as String? ?? '';
    final selector = data['selector'] as String?;

    final (icon, color) = switch (event.type) {
      'computer.action.requested' => (
        Icons.pending_outlined,
        const Color(0xff6ac9e8),
      ),
      'computer.action.completed' => (
        Icons.check_circle_outline,
        const Color(0xff8fd67a),
      ),
      'computer.action.denied' => (Icons.block, const Color(0xffef6a6a)),
      _ => (Icons.circle_outlined, onSurface.withAlpha(140)),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${event.type.replaceFirst('computer.action.', '')} $action${selector != null ? ' → $selector' : ''} on $target',
              style: TextStyle(
                fontSize: 10.5,
                fontFamily: 'JetBrains Mono',
                color: onSurface.withAlpha(160),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// SysAI OS Automations View — persistent, scheduled Runs.
///
/// A ScheduledAutomation is never a unit of execution on its own; firing
/// one only ever creates a normal Run through the same pipeline a manual
/// Run goes through. This view is deliberately not another metrics
/// dashboard — it communicates exactly what the brief asked for: enabled,
/// next run, goal, workspace, model, last result.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../config/sysai_config.dart';
import '../models/scheduled_automation.dart';
import '../providers/app_providers.dart';
import '../services/local_timezone.dart';
import '../services/schedule_calculator.dart';
import '../services/scheduler_service.dart';
import '../theme/status.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/model_selector.dart';

class AutomationsView extends ConsumerStatefulWidget {
  final void Function(String runId) onOpenRun;

  const AutomationsView({super.key, required this.onOpenRun});

  @override
  ConsumerState<AutomationsView> createState() => _AutomationsViewState();
}

class _AutomationsViewState extends ConsumerState<AutomationsView> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.colorScheme.surface;
    final onSurface = theme.colorScheme.onSurface;

    if (_selectedId != null) {
      return _AutomationDetailPanel(
        automationId: _selectedId!,
        onBack: () => setState(() => _selectedId = null),
        onOpenRun: widget.onOpenRun,
      );
    }

    final automationsAsync = ref.watch(automationsListProvider);

    return Scaffold(
      backgroundColor: surface,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
            child: Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Automations',
                      style: AppText.pageTitle.copyWith(color: onSurface),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Scheduled goals that create a normal Run when due',
                      style: AppText.bodySecondary.copyWith(
                        color: onSurface.withAlpha(140),
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: 'Reload',
                  onPressed: () => ref.invalidate(automationsListProvider),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => _openEditor(context, null),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New Automation'),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: onSurface.withAlpha(20)),
          Expanded(
            child: automationsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(
                child: Text(
                  'Error loading automations: $err',
                  style: const TextStyle(color: Color(0xffff6b6b)),
                ),
              ),
              data: (automations) {
                if (automations.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.schedule_outlined,
                          size: 40,
                          color: onSurface.withAlpha(70),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No automations yet. Create one to run a goal on a schedule.',
                          style: AppText.bodySecondary.copyWith(
                            color: onSurface.withAlpha(130),
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 16,
                  ),
                  itemCount: automations.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final automation = automations[index];
                    return _AutomationRow(
                      automation: automation,
                      onTap: () => setState(() => _selectedId = automation.id),
                      onEdit: () => _openEditor(context, automation),
                      onToggle: (enabled) async {
                        await ref
                            .read(schedulerServiceProvider)
                            .setEnabled(automation.id, enabled);
                        ref.invalidate(automationsListProvider);
                      },
                      onRunNow: () async {
                        await ref
                            .read(schedulerServiceProvider)
                            .triggerNow(automation.id);
                        ref.invalidate(automationsListProvider);
                      },
                      onDelete: () async {
                        await ref
                            .read(schedulerServiceProvider)
                            .delete(automation.id);
                        ref.invalidate(automationsListProvider);
                      },
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

  Future<void> _openEditor(
    BuildContext context,
    ScheduledAutomation? existing,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _AutomationEditorDialog(existing: existing),
    );
    if (saved == true) {
      ref.invalidate(automationsListProvider);
    }
  }
}

// ── List row ──────────────────────────────────────────────────────────────

class _AutomationRow extends ConsumerWidget {
  final ScheduledAutomation automation;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRunNow;
  final VoidCallback onDelete;

  const _AutomationRow({
    required this.automation,
    required this.onTap,
    required this.onEdit,
    required this.onToggle,
    required this.onRunNow,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final resultStyle = statusStyleForAutomationResult(
      automation.lastResult,
      theme.colorScheme,
    );

    return InkWell(
      onTap: onTap,
      borderRadius: Radii.mdR,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: onSurface.withAlpha(6),
          borderRadius: Radii.mdR,
          border: Border.all(color: onSurface.withAlpha(18)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Switch(value: automation.enabled, onChanged: onToggle),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    automation.title,
                    style: AppText.bodyStrong.copyWith(
                      color: onSurface,
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.schedule,
                        size: 12,
                        color: onSurface.withAlpha(120),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _scheduleSummary(automation),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: onSurface.withAlpha(150),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Icon(
                        Icons.smart_toy_outlined,
                        size: 12,
                        color: onSurface.withAlpha(120),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        automation.modelLabel,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: onSurface.withAlpha(150),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _nextRunLabel(automation),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: onSurface.withAlpha(160),
                  ),
                ),
                const SizedBox(height: 4),
                StatusPill(style: resultStyle, dense: true),
              ],
            ),
            const SizedBox(width: 12),
            IconButton(
              icon: const Icon(Icons.play_arrow, size: 18),
              tooltip: 'Run now',
              onPressed: onRunNow,
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 16),
              tooltip: 'Edit',
              onPressed: onEdit,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 16),
              tooltip: 'Delete',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

String _scheduleSummary(ScheduledAutomation a) => switch (a.scheduleType) {
  AutomationScheduleType.once => 'Once',
  AutomationScheduleType.interval =>
    'Every ${(((a.scheduleExpression['minutes'] as num?) ?? 60) / 60).toStringAsFixed(0)}h',
  AutomationScheduleType.daily => 'Daily ${_hm(a.scheduleExpression)}',
  AutomationScheduleType.weekly =>
    'Weekly ${_weekdayName(a.scheduleExpression['weekday'] as int? ?? 1)} ${_hm(a.scheduleExpression)}',
};

String _hm(Map<String, dynamic> expr) {
  final h = (expr['hour'] as num?)?.toInt() ?? 0;
  final m = (expr['minute'] as num?)?.toInt() ?? 0;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

const _weekdayNames = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
String _weekdayName(int weekday) => _weekdayNames[weekday.clamp(1, 7)];

/// Renders `nextTriggerAt` (persisted UTC) in the automation's own
/// configured timezone — never the system-local zone, since those can
/// differ.
String _nextRunLabel(ScheduledAutomation a) {
  if (!a.enabled) return 'Disabled';
  final next = a.nextTriggerAt;
  if (next == null) return 'Not scheduled';
  final loc = resolveLocation(a.timezone);
  final local = tz.TZDateTime.from(next, loc);
  final datePart =
      '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  final timePart =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  return 'Next: $datePart $timePart';
}

// ── Editor ────────────────────────────────────────────────────────────────

class _AutomationEditorDialog extends ConsumerStatefulWidget {
  final ScheduledAutomation? existing;

  const _AutomationEditorDialog({this.existing});

  @override
  ConsumerState<_AutomationEditorDialog> createState() =>
      _AutomationEditorDialogState();
}

class _AutomationEditorDialogState
    extends ConsumerState<_AutomationEditorDialog> {
  late final TextEditingController _goalController;
  late final TextEditingController _workspaceController;
  late AutomationScheduleType _scheduleType;
  late TimeOfDay _timeOfDay;
  late int _weekday;
  late int _intervalHours;
  DateTime? _onceDate;
  late String _timezone;
  String? _providerId;
  String? _modelId;
  String? _modelDisplayName;
  late bool _enabled;
  bool _saving = false;
  bool _loadingTimezone = true;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _goalController = TextEditingController(text: existing?.goal ?? '');
    _workspaceController = TextEditingController(
      text: existing?.workspacePath ?? SysAIConfig.defaultWorkspacePath,
    );
    _scheduleType = existing?.scheduleType ?? AutomationScheduleType.daily;
    final expr = existing?.scheduleExpression ?? const {};
    _timeOfDay = TimeOfDay(
      hour: (expr['hour'] as num?)?.toInt() ?? 9,
      minute: (expr['minute'] as num?)?.toInt() ?? 0,
    );
    _weekday = (expr['weekday'] as num?)?.toInt() ?? DateTime.monday;
    _intervalHours = (((expr['minutes'] as num?)?.toInt() ?? 360) / 60)
        .round()
        .clamp(1, 24 * 7);
    _onceDate = existing?.nextTriggerAt;
    _timezone = existing?.timezone ?? 'UTC';
    _providerId = existing?.providerId;
    _modelId = existing?.modelId;
    _modelDisplayName = existing?.modelDisplayName;
    _enabled = existing?.enabled ?? true;

    if (existing == null) {
      detectLocalTimezone().then((tzName) {
        if (mounted) {
          setState(() {
            _timezone = tzName;
            _loadingTimezone = false;
          });
        }
      });
    } else {
      _loadingTimezone = false;
    }
  }

  @override
  void dispose() {
    _goalController.dispose();
    _workspaceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final isEditing = widget.existing != null;

    return Dialog(
      backgroundColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: Radii.lgR,
        side: BorderSide(color: onSurface.withAlpha(26)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          // The Cancel/Create action row is pinned outside the scrollable
          // region on purpose — a tall form (schedule fields + timezone +
          // model picker) must never be able to push it out of reach,
          // whether for a real user or for `tester.tap()` in a widget test.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isEditing ? 'Edit Automation' : 'New Automation',
                style: AppText.pageTitle.copyWith(color: onSurface),
              ),
              const SizedBox(height: Space.lg),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'GOAL',
                        style: AppText.label.copyWith(
                          color: onSurface.withAlpha(120),
                        ),
                      ),
                      const SizedBox(height: Space.xs),
                      TextField(
                        controller: _goalController,
                        minLines: 2,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          hintText: 'e.g. Run the test suite and report whether the project is healthy.',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: Space.lg),

                      Text(
                        'WORKSPACE',
                        style: AppText.label.copyWith(
                          color: onSurface.withAlpha(120),
                        ),
                      ),
                      const SizedBox(height: Space.xs),
                      TextField(
                        controller: _workspaceController,
                        style: const TextStyle(
                          fontFamily: 'JetBrains Mono',
                          fontSize: 12.5,
                        ),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: Space.lg),

                      Text(
                        'SCHEDULE',
                        style: AppText.label.copyWith(
                          color: onSurface.withAlpha(120),
                        ),
                      ),
                      const SizedBox(height: Space.xs),
                      SegmentedButton<AutomationScheduleType>(
                        segments: const [
                          ButtonSegment(
                            value: AutomationScheduleType.once,
                            label: Text('Once'),
                          ),
                          ButtonSegment(
                            value: AutomationScheduleType.daily,
                            label: Text('Daily'),
                          ),
                          ButtonSegment(
                            value: AutomationScheduleType.weekly,
                            label: Text('Weekly'),
                          ),
                          ButtonSegment(
                            value: AutomationScheduleType.interval,
                            label: Text('Every N hours'),
                          ),
                        ],
                        selected: {_scheduleType},
                        onSelectionChanged: (s) =>
                            setState(() => _scheduleType = s.first),
                      ),
                      const SizedBox(height: Space.md),
                      _buildScheduleFields(onSurface),

                      const SizedBox(height: Space.lg),
                      Text(
                        'TIMEZONE',
                        style: AppText.label.copyWith(
                          color: onSurface.withAlpha(120),
                        ),
                      ),
                      const SizedBox(height: Space.xs),
                      DropdownButtonFormField<String>(
                        initialValue: kCommonTimezones.contains(_timezone)
                            ? _timezone
                            : null,
                        hint: _loadingTimezone
                            ? const Text('Detecting…')
                            : Text(_timezone),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          if (!kCommonTimezones.contains(_timezone))
                            DropdownMenuItem(
                              value: _timezone,
                              child: Text(_timezone),
                            ),
                          for (final tzName in kCommonTimezones)
                            DropdownMenuItem(
                              value: tzName,
                              child: Text(tzName),
                            ),
                        ],
                        onChanged: (v) =>
                            setState(() => _timezone = v ?? _timezone),
                      ),
                      const SizedBox(height: Space.lg),

                      Text(
                        'MODEL',
                        style: AppText.label.copyWith(
                          color: onSurface.withAlpha(120),
                        ),
                      ),
                      const SizedBox(height: Space.xs),
                      ModelSelectorButton(
                        placeholder:
                            _modelDisplayName ??
                            _modelId ??
                            'Use SysAI OS default at run time',
                        selectedModelId: _modelId,
                        fillWidth: true,
                        onSelected: (m) => setState(() {
                          _providerId = m.provider;
                          _modelId = m.id;
                          _modelDisplayName = m.displayName;
                        }),
                      ),
                      const SizedBox(height: Space.lg),

                      Row(
                        children: [
                          Switch(
                            value: _enabled,
                            onChanged: (v) => setState(() => _enabled = v),
                          ),
                          const SizedBox(width: 8),
                          Text('Enabled', style: TextStyle(color: onSurface)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Space.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(isEditing ? 'Save' : 'Create'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScheduleFields(Color onSurface) {
    switch (_scheduleType) {
      case AutomationScheduleType.once:
        return Row(
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.calendar_today, size: 14),
              label: Text(
                _onceDate == null ? 'Pick date & time' : _onceDate.toString(),
              ),
              onPressed: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate:
                      _onceDate ?? DateTime.now().add(const Duration(days: 1)),
                  firstDate: DateTime.now(),
                  lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
                );
                if (date == null || !mounted) return;
                final time = await showTimePicker(
                  context: context,
                  initialTime: _onceDate != null
                      ? TimeOfDay.fromDateTime(_onceDate!)
                      : const TimeOfDay(hour: 9, minute: 0),
                );
                if (time == null) return;
                setState(
                  () => _onceDate = DateTime(
                    date.year,
                    date.month,
                    date.day,
                    time.hour,
                    time.minute,
                  ),
                );
              },
            ),
          ],
        );
      case AutomationScheduleType.daily:
        return _timePickerRow(onSurface);
      case AutomationScheduleType.weekly:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButton<int>(
              value: _weekday,
              items: [
                for (var w = 1; w <= 7; w++)
                  DropdownMenuItem(value: w, child: Text(_weekdayName(w))),
              ],
              onChanged: (v) => setState(() => _weekday = v ?? _weekday),
            ),
            const SizedBox(height: Space.sm),
            _timePickerRow(onSurface),
          ],
        );
      case AutomationScheduleType.interval:
        return Row(
          children: [
            const Text('Every '),
            SizedBox(
              width: 60,
              child: TextFormField(
                initialValue: '$_intervalHours',
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  final parsed = int.tryParse(v);
                  if (parsed != null && parsed > 0) {
                    setState(() => _intervalHours = parsed);
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            const Text('hour(s)'),
          ],
        );
    }
  }

  Widget _timePickerRow(Color onSurface) {
    return OutlinedButton.icon(
      icon: const Icon(Icons.access_time, size: 14),
      label: Text(_timeOfDay.format(context)),
      onPressed: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: _timeOfDay,
        );
        if (picked != null) setState(() => _timeOfDay = picked);
      },
    );
  }

  Map<String, dynamic> _buildExpression() => switch (_scheduleType) {
    AutomationScheduleType.once => const {},
    AutomationScheduleType.interval => {'minutes': _intervalHours * 60},
    AutomationScheduleType.daily => {
      'hour': _timeOfDay.hour,
      'minute': _timeOfDay.minute,
    },
    AutomationScheduleType.weekly => {
      'hour': _timeOfDay.hour,
      'minute': _timeOfDay.minute,
      'weekday': _weekday,
    },
  };

  Future<void> _save() async {
    final goal = _goalController.text.trim();
    if (goal.isEmpty) return;
    if (_scheduleType == AutomationScheduleType.once && _onceDate == null) {
      return;
    }

    setState(() => _saving = true);
    final scheduler = ref.read(schedulerServiceProvider);

    DateTime? onceAtUtc;
    if (_scheduleType == AutomationScheduleType.once) {
      final loc = resolveLocation(_timezone);
      onceAtUtc = tz.TZDateTime(
        loc,
        _onceDate!.year,
        _onceDate!.month,
        _onceDate!.day,
        _onceDate!.hour,
        _onceDate!.minute,
      ).toUtc();
    }

    try {
      final existing = widget.existing;
      if (existing == null) {
        await scheduler.create(
          goal: goal,
          workspacePath: _workspaceController.text.trim(),
          scheduleType: _scheduleType,
          scheduleExpression: _buildExpression(),
          timezone: _timezone,
          providerId: _providerId,
          modelId: _modelId,
          modelDisplayName: _modelDisplayName,
          onceAtUtc: onceAtUtc,
        );
      } else {
        var updated = existing.copyWith(
          goal: goal,
          workspacePath: _workspaceController.text.trim(),
          scheduleType: _scheduleType,
          scheduleExpression: _buildExpression(),
          timezone: _timezone,
          providerId: _providerId,
          modelId: _modelId,
          modelDisplayName: _modelDisplayName,
          enabled: _enabled,
        );
        final next = _scheduleType == AutomationScheduleType.once
            ? onceAtUtc
            : computeNextTrigger(updated, DateTime.now().toUtc());
        updated = updated.copyWith(
          nextTriggerAt: next,
          clearNextTriggerAt: next == null,
        );
        await scheduler.update(updated);
      }
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

// ── Detail ────────────────────────────────────────────────────────────────

class _AutomationDetailPanel extends ConsumerWidget {
  final String automationId;
  final VoidCallback onBack;
  final void Function(String runId) onOpenRun;

  const _AutomationDetailPanel({
    required this.automationId,
    required this.onBack,
    required this.onOpenRun,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return FutureBuilder(
      future: ref.read(runRepositoryProvider.future).then((repo) async {
        final automation = await repo.getAutomation(automationId);
        final runs = automation == null
            ? const []
            : await repo.getRunsCreatedByAutomation(automationId);
        return (automation, runs);
      }),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final (automation, runs) = snapshot.data!;
        if (automation == null) {
          return Center(
            child: Text(
              'Automation not found.',
              style: TextStyle(color: onSurface),
            ),
          );
        }

        final resultStyle = statusStyleForAutomationResult(
          automation.lastResult,
          theme.colorScheme,
        );

        return Scaffold(
          backgroundColor: theme.colorScheme.surface,
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, size: 18),
                      onPressed: onBack,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        automation.title,
                        style: AppText.pageTitle.copyWith(color: onSurface),
                      ),
                    ),
                    StatusPill(style: resultStyle),
                  ],
                ),
                const SizedBox(height: Space.lg),
                Text(
                  automation.goal,
                  style: AppText.body.copyWith(color: onSurface),
                ),
                const SizedBox(height: Space.lg),
                _detailRow('Schedule', _scheduleSummary(automation), onSurface),
                _detailRow('Next run', _nextRunLabel(automation), onSurface),
                _detailRow('Timezone', automation.timezone, onSurface),
                _detailRow(
                  'Workspace',
                  automation.workspacePath,
                  onSurface,
                  mono: true,
                ),
                _detailRow('Model', automation.modelLabel, onSurface),
                _detailRow(
                  'Enabled',
                  automation.enabled ? 'Yes' : 'No',
                  onSurface,
                ),
                const SizedBox(height: Space.xl),
                Text(
                  'PAST RUNS',
                  style: AppText.label.copyWith(
                    color: onSurface.withAlpha(120),
                  ),
                ),
                const SizedBox(height: Space.sm),
                if (runs.isEmpty)
                  Text(
                    'No executions yet.',
                    style: AppText.bodySecondary.copyWith(
                      color: onSurface.withAlpha(130),
                    ),
                  )
                else
                  for (final run in runs)
                    InkWell(
                      onTap: () => onOpenRun(run.id),
                      borderRadius: Radii.smR,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: onSurface.withAlpha(6),
                          borderRadius: Radii.smR,
                          border: Border.all(color: onSurface.withAlpha(16)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                run.displayStatus,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: onSurface,
                                ),
                              ),
                            ),
                            Text(
                              '${run.createdAt.toLocal()}'.split('.').first,
                              style: TextStyle(
                                fontSize: 11,
                                color: onSurface.withAlpha(120),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.chevron_right,
                              size: 16,
                              color: onSurface.withAlpha(100),
                            ),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _detailRow(
    String label,
    String value,
    Color onSurface, {
    bool mono = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: onSurface.withAlpha(130)),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 13,
              color: onSurface,
              fontFamily: mono ? 'JetBrains Mono' : null,
            ),
          ),
        ),
      ],
    ),
  );
}

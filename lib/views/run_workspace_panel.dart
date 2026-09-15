/// The Run Detail right column: a small set of tabs over the Run's
/// operational surfaces — Activity (what happened), Terminal (commands run),
/// and Browser (pages visited). Reuses existing event styling/typography;
/// this is not a new design system, just new content within the current one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/browser_session.dart';
import '../models/run.dart';
import '../models/terminal_session.dart';
import '../providers/app_providers.dart';
import '../theme/event_style.dart';
import '../theme/status.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/state_panels.dart';

enum _WorkspaceTab { activity, terminal, browser }

class RunWorkspacePanel extends ConsumerStatefulWidget {
  final Run run;

  const RunWorkspacePanel({super.key, required this.run});

  @override
  ConsumerState<RunWorkspacePanel> createState() => _RunWorkspacePanelState();
}

class _RunWorkspacePanelState extends ConsumerState<RunWorkspacePanel> {
  _WorkspaceTab _tab = _WorkspaceTab.activity;
  String? _selectedSessionId;
  bool _loadedFromDb = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedFromDb) return;
    _loadedFromDb = true;
    // Covers reopening a historical Run after an app restart, where the
    // live in-memory session maps are empty but the database has history.
    Future(() async {
      final repo = await ref.read(runRepositoryProvider.future);
      await ref.read(terminalSessionsProvider.notifier).ensureLoaded(widget.run.id, repo);
      await ref.read(browserSessionsProvider.notifier).ensureLoaded(widget.run.id, repo);
    });
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final run = widget.run;

    final terminalSessions = ref.watch(terminalSessionsForRunProvider(run.id));
    final browserSession = ref.watch(browserSessionForRunProvider(run.id));
    final terminalRunning = terminalSessions.any((s) => s.status == TerminalSessionStatus.running);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, Space.lg, 16, Space.sm),
          child: Row(
            children: [
              _TabButton(
                icon: Icons.stream,
                label: 'Activity',
                hint: run.events.isEmpty ? null : '${run.events.length}',
                selected: _tab == _WorkspaceTab.activity,
                onTap: () => setState(() => _tab = _WorkspaceTab.activity),
              ),
              const SizedBox(width: Space.xs),
              _TabButton(
                icon: Icons.terminal_outlined,
                label: 'Terminal',
                hint: terminalSessions.isEmpty ? null : (terminalRunning ? 'Running' : '${terminalSessions.length}'),
                hintTone: terminalRunning ? StatusTone.progress : StatusTone.neutral,
                selected: _tab == _WorkspaceTab.terminal,
                onTap: () => setState(() => _tab = _WorkspaceTab.terminal),
              ),
              const SizedBox(width: Space.xs),
              _TabButton(
                icon: Icons.public_outlined,
                label: 'Browser',
                hint: browserSession == null ? null : 'Active',
                hintTone: StatusTone.info,
                selected: _tab == _WorkspaceTab.browser,
                onTap: () => setState(() => _tab = _WorkspaceTab.browser),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: onSurface.withAlpha(15)),
        Expanded(
          child: switch (_tab) {
            _WorkspaceTab.activity => _ActivityTab(run: run),
            _WorkspaceTab.terminal => _TerminalTab(
                sessions: terminalSessions,
                selectedId: _selectedSessionId,
                onSelect: (id) => setState(() => _selectedSessionId = id),
              ),
            _WorkspaceTab.browser => _BrowserTab(session: browserSession),
          },
        ),
      ],
    );
  }
}

class _TabButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? hint;
  final StatusTone hintTone;
  final bool selected;
  final VoidCallback onTap;

  const _TabButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.hint,
    this.hintTone = StatusTone.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onSurface = scheme.onSurface;
    final primary = scheme.primary;
    final tint = hintTone.foreground(scheme);

    return InkWell(
      onTap: onTap,
      borderRadius: Radii.smR,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
        decoration: BoxDecoration(
          color: selected ? primary.withAlpha(22) : Colors.transparent,
          borderRadius: Radii.smR,
          border: Border.all(color: selected ? primary.withAlpha(70) : Colors.transparent),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: IconSizes.sm, color: selected ? primary : onSurface.withAlpha(150)),
            const SizedBox(width: 6),
            Text(label, style: AppText.navigation.copyWith(
                  fontSize: 12.5,
                  color: selected ? primary : onSurface.withAlpha(190),
                )),
            if (hint != null) ...[
              const SizedBox(width: 5),
              Text('· $hint', style: AppText.metadata.copyWith(color: tint)),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Activity Tab (existing timeline, unchanged visual language) ──────────────

class _ActivityTab extends StatelessWidget {
  final Run run;

  const _ActivityTab({required this.run});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    if (run.events.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(Space.lg),
        child: EmptyStatePanel(icon: Icons.stream, message: 'No events recorded yet.'),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: Space.sm),
      itemCount: run.events.length,
      itemBuilder: (context, index) {
        final event = run.events[index];
        final isLatest = index == run.events.length - 1;
        final visual = eventVisualFor(event.type);
        final color = visual.tone.foreground(Theme.of(context).colorScheme);
        final timeStr = '${event.timestamp.hour.toString().padLeft(2, '0')}:'
            '${event.timestamp.minute.toString().padLeft(2, '0')}:'
            '${event.timestamp.second.toString().padLeft(2, '0')}';

        return Container(
          margin: const EdgeInsets.only(bottom: Space.sm),
          padding: const EdgeInsets.all(Space.sm),
          decoration: BoxDecoration(
            color: isLatest ? color.withAlpha(12) : onSurface.withAlpha(6),
            borderRadius: Radii.smR,
            border: Border.all(color: isLatest ? color.withAlpha(60) : onSurface.withAlpha(15)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 2), child: Icon(visual.icon, size: 14, color: color)),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(event.type, style: AppText.code.copyWith(fontSize: 10, color: color)),
                        const Spacer(),
                        Text(timeStr, style: AppText.metadata.copyWith(color: onSurface.withAlpha(90))),
                      ],
                    ),
                    if (event.message.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(event.message, style: AppText.body.copyWith(fontSize: 12, color: onSurface, height: 1.3)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Terminal Tab ───────────────────────────────────────────────────────────

class _TerminalTab extends ConsumerWidget {
  final List<TerminalSession> sessions; // newest first
  final String? selectedId;
  final ValueChanged<String> onSelect;

  const _TerminalTab({required this.sessions, required this.selectedId, required this.onSelect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (sessions.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(Space.lg),
        child: EmptyStatePanel(
          icon: Icons.terminal_outlined,
          message: 'No terminal activity yet. Commands the Run executes will appear here as they run.',
        ),
      );
    }

    final selected = sessions.firstWhere(
      (s) => s.id == (selectedId ?? sessions.first.id),
      orElse: () => sessions.first,
    );
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return Column(
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: sessions.length > 1 ? 160 : 64),
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
            itemCount: sessions.length,
            separatorBuilder: (context, i) => const SizedBox(height: 4),
            itemBuilder: (context, i) => _SessionRow(
              session: sessions[i],
              selected: sessions[i].id == selected.id,
              onTap: () => onSelect(sessions[i].id),
            ),
          ),
        ),
        Divider(height: 1, color: onSurface.withAlpha(15)),
        Expanded(child: _TerminalOutputView(session: selected)),
      ],
    );
  }
}

class _SessionRow extends StatelessWidget {
  final TerminalSession session;
  final bool selected;
  final VoidCallback onTap;

  const _SessionRow({required this.session, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onSurface = scheme.onSurface;
    final tone = switch (session.status) {
      TerminalSessionStatus.running => StatusTone.progress,
      TerminalSessionStatus.completed => StatusTone.success,
      TerminalSessionStatus.failed => StatusTone.danger,
      TerminalSessionStatus.timedOut => StatusTone.warning,
    };

    return InkWell(
      onTap: onTap,
      borderRadius: Radii.smR,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withAlpha(18) : Colors.transparent,
          borderRadius: Radii.smR,
        ),
        child: Row(
          children: [
            if (session.status == TerminalSessionStatus.running)
              SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(strokeWidth: 1.8, color: tone.foreground(scheme)),
              )
            else
              Icon(
                session.status == TerminalSessionStatus.completed ? Icons.check_circle : Icons.error,
                size: 13,
                color: tone.foreground(scheme),
              ),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Text(
                session.command,
                overflow: TextOverflow.ellipsis,
                style: AppText.code.copyWith(fontSize: 12, color: onSurface),
              ),
            ),
            if (session.exitCode != null) ...[
              const SizedBox(width: Space.sm),
              Text('exit ${session.exitCode}', style: AppText.metadata.copyWith(color: onSurface.withAlpha(110))),
            ],
            if (session.elapsed != null) ...[
              const SizedBox(width: Space.sm),
              Text('${session.elapsed!.inMilliseconds}ms', style: AppText.metadata.copyWith(color: onSurface.withAlpha(90))),
            ],
          ],
        ),
      ),
    );
  }
}

class _TerminalOutputView extends ConsumerWidget {
  final TerminalSession session;

  const _TerminalOutputView({required this.session});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final liveLines = ref.watch(terminalLiveOutputProvider)[session.id];

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(Space.md),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: onSurface.withAlpha(6),
        borderRadius: Radii.mdR,
        border: Border.all(color: onSurface.withAlpha(15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.folder_outlined, size: 12, color: onSurface.withAlpha(110)),
              const SizedBox(width: 4),
              Text(session.cwd, style: AppText.path.copyWith(fontSize: 11, color: onSurface.withAlpha(140))),
              const Spacer(),
              if (session.truncated)
                Text('output truncated', style: AppText.metadata.copyWith(color: const Color(0xfff0b84c))),
            ],
          ),
          const SizedBox(height: Space.sm),
          Expanded(
            child: SingleChildScrollView(
              child: liveLines != null && liveLines.isNotEmpty
                  ? SelectableText.rich(
                      TextSpan(
                        children: [
                          for (final line in liveLines)
                            TextSpan(
                              text: '${line.text}\n',
                              style: AppText.terminal.copyWith(
                                color: line.stream == 'stderr' ? const Color(0xffef6a6a) : onSurface.withAlpha(210),
                              ),
                            ),
                        ],
                      ),
                    )
                  : SelectableText(
                      session.outputPreview.isNotEmpty
                          ? session.outputPreview
                          : (session.status == TerminalSessionStatus.running
                              ? 'Waiting for output…'
                              : 'No output captured.'),
                      style: AppText.terminal.copyWith(color: onSurface.withAlpha(210)),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Browser Tab ───────────────────────────────────────────────────────────

class _BrowserTab extends StatelessWidget {
  final BrowserSession? session;

  const _BrowserTab({required this.session});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final s = session;
    if (s == null || s.history.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(Space.lg),
        child: EmptyStatePanel(
          icon: Icons.public_outlined,
          message: 'No browsing activity yet. Pages the Run reads will appear here.',
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(Space.md),
      children: [
        Container(
          padding: const EdgeInsets.all(Space.md),
          decoration: BoxDecoration(
            color: onSurface.withAlpha(6),
            borderRadius: Radii.mdR,
            border: Border.all(color: onSurface.withAlpha(15)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.public, size: IconSizes.md, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(
                      s.currentTitle ?? s.currentUrl ?? 'Untitled page',
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodyStrong.copyWith(color: onSurface),
                    ),
                  ),
                ],
              ),
              if (s.currentUrl != null) ...[
                const SizedBox(height: 3),
                Text(s.currentUrl!, style: AppText.path.copyWith(fontSize: 11, color: onSurface.withAlpha(140))),
              ],
              const SizedBox(height: Space.sm),
              Row(
                children: [
                  if (s.downloadCount > 0) ...[
                    Icon(Icons.download_outlined, size: 12, color: onSurface.withAlpha(120)),
                    const SizedBox(width: 3),
                    Text('${s.downloadCount} download${s.downloadCount == 1 ? '' : 's'}',
                        style: AppText.metadata.copyWith(color: onSurface.withAlpha(120))),
                    const SizedBox(width: Space.md),
                  ],
                  if (s.captureCount > 0) ...[
                    Icon(Icons.camera_alt_outlined, size: 12, color: onSurface.withAlpha(120)),
                    const SizedBox(width: 3),
                    Text('${s.captureCount} capture${s.captureCount == 1 ? '' : 's'}',
                        style: AppText.metadata.copyWith(color: onSurface.withAlpha(120))),
                  ],
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.lg),
        Text('NAVIGATION HISTORY', style: AppText.label.copyWith(color: onSurface.withAlpha(120))),
        const SizedBox(height: Space.sm),
        for (final entry in s.history.reversed)
          Container(
            margin: const EdgeInsets.only(bottom: Space.xs),
            padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 6),
            decoration: BoxDecoration(color: onSurface.withAlpha(6), borderRadius: Radii.smR),
            child: Row(
              children: [
                Icon(
                  entry.statusCode != null && entry.statusCode! < 400 ? Icons.check_circle_outline : Icons.error_outline,
                  size: 12,
                  color: entry.statusCode != null && entry.statusCode! < 400
                      ? const Color(0xff8fd67a)
                      : const Color(0xffef6a6a),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.title ?? entry.url,
                          overflow: TextOverflow.ellipsis, style: AppText.bodySecondary.copyWith(color: onSurface)),
                      Text(entry.url,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.path.copyWith(fontSize: 10.5, color: onSurface.withAlpha(120))),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

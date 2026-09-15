/// SysAI OS desktop shell — the main navigation frame.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../adwaita_surface.dart';
import '../models/notification.dart';
import '../providers/app_providers.dart';
import '../services/bridge_service.dart';
import '../services/scheduler_service.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/model_selector.dart';
import 'activity_view.dart';
import 'automations_view.dart';
import 'computer_view.dart';
import 'home_view.dart';
import 'runs_view.dart';
import 'experience_view.dart';
import 'system_view.dart';
import 'workspace_view.dart';

// ── Navigation destinations ───────────────────────────────────────────────────

enum _NavDest {
  home,
  runs,
  workspace,
  automations,
  computer,
  activity,
  experience,
  system;

  String get label => switch (this) {
    _NavDest.home => 'Home',
    _NavDest.runs => 'Runs',
    _NavDest.workspace => 'Workspace',
    _NavDest.automations => 'Automations',
    _NavDest.computer => 'Computer',
    _NavDest.activity => 'Activity',
    _NavDest.experience => 'Experience',
    _NavDest.system => 'System',
  };

  IconData get icon => switch (this) {
    _NavDest.home => Icons.home_outlined,
    _NavDest.runs => Icons.play_circle_outline,
    _NavDest.workspace => Icons.folder_outlined,
    _NavDest.automations => Icons.schedule_outlined,
    _NavDest.computer => Icons.desktop_windows_outlined,
    _NavDest.activity => Icons.timeline_outlined,
    _NavDest.experience => Icons.psychology_outlined,
    _NavDest.system => Icons.settings_outlined,
  };

  IconData get activeIcon => switch (this) {
    _NavDest.home => Icons.home,
    _NavDest.runs => Icons.play_circle,
    _NavDest.workspace => Icons.folder,
    _NavDest.automations => Icons.schedule,
    _NavDest.computer => Icons.desktop_windows,
    _NavDest.activity => Icons.timeline,
    _NavDest.experience => Icons.psychology,
    _NavDest.system => Icons.settings,
  };
}

// ── Selected run provider ─────────────────────────────────────────────────────

/// Currently selected Run ID for the Run Detail view.
final selectedRunIdProvider = StateProvider<String?>((ref) => null);

// ── Shell ─────────────────────────────────────────────────────────────────────

class SysAIOSShell extends ConsumerStatefulWidget {
  const SysAIOSShell({super.key});

  @override
  ConsumerState<SysAIOSShell> createState() => _SysAIOSShellState();
}

class _SysAIOSShellState extends ConsumerState<SysAIOSShell> {
  _NavDest _current = _NavDest.home;

  @override
  void initState() {
    super.initState();
    // Eagerly starts the scheduler's central timer at app launch,
    // independent of which page the user happens to land on — the same
    // "don't tie correctness to whether a particular screen is open"
    // requirement the bridge/Run pipeline already follows. Read (not
    // watch): this is a one-time kick-off, not something the shell should
    // rebuild for.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(schedulerServiceProvider).start();
    });
  }

  void _navigate(_NavDest dest) {
    setState(() => _current = dest);
  }

  void navigateToRun(String runId) {
    ref.read(selectedRunIdProvider.notifier).state = runId;
    _navigate(_NavDest.runs);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.colorScheme.surface;
    final onSurface = theme.colorScheme.onSurface;
    final primary = theme.colorScheme.primary;

    final Widget body = switch (_current) {
      _NavDest.home => HomeView(onRunCreated: navigateToRun),
      _NavDest.runs => const RunsView(),
      _NavDest.workspace => WorkspaceView(onOpenRun: navigateToRun),
      _NavDest.automations => AutomationsView(onOpenRun: navigateToRun),
      _NavDest.computer => const ComputerView(),
      _NavDest.activity => ActivityView(onOpenRun: navigateToRun),
      _NavDest.experience => const ExperienceView(),
      _NavDest.system => const SystemView(),
    };

    return Scaffold(
      backgroundColor: surface,
      body: Row(
        children: [
          // ── Sidebar navigation ──────────────────────────────────────────
          _Sidebar(
            current: _current,
            onNavigate: _navigate,
            onOpenRun: navigateToRun,
            surface: surface,
            onSurface: onSurface,
            primary: primary,
          ),

          // ── Main content ────────────────────────────────────────────────
          Expanded(child: body),
        ],
      ),
    );
  }
}

// ── Sidebar ───────────────────────────────────────────────────────────────────

class _Sidebar extends ConsumerWidget {
  final _NavDest current;
  final void Function(_NavDest) onNavigate;
  final void Function(String runId) onOpenRun;
  final Color surface;
  final Color onSurface;
  final Color primary;

  const _Sidebar({
    required this.current,
    required this.onNavigate,
    required this.onOpenRun,
    required this.surface,
    required this.onSurface,
    required this.primary,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bridgeStatus = ref.watch(bridgeStatusProvider);
    final bridge = ref.watch(bridgeServiceProvider);

    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: surface,
        border: Border(
          right: BorderSide(color: onSurface.withAlpha(20), width: 1),
        ),
      ),
      child: Column(
        children: [
          // Logo / brand
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 12, 18),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: primary,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: const Icon(Icons.bolt, color: Color(0xff0a1a0a), size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('SysAI',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 17,
                            color: onSurface,
                          )),
                      Text('AGENTIC OS',
                          style: TextStyle(
                            fontSize: 8,
                            letterSpacing: 1.4,
                            color: onSurface.withAlpha(100),
                          )),
                    ],
                  ),
                ),
                _NotificationBell(onOpenRun: onOpenRun),
              ],
            ),
          ),

          // Bridge status indicator
          _BridgeStatusBadge(
              bridgeStatus: bridgeStatus, sysaiAvailable: bridge.sysaiAvailable),

          const SizedBox(height: Space.md),

          // Default model quick switcher — future Runs only, never touches
          // a Run already in flight.
          const _QuickModelSwitcher(),

          const SizedBox(height: 16),

          // Navigation items
          Expanded(
            child: Builder(
              builder: (context) {
                final runs = ref.watch(runListProvider).valueOrNull ?? [];
                final attentionCount = runs.where((r) => r.needsAttention).length;

                return ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    for (final dest in _NavDest.values)
                      _NavItem(
                        dest: dest,
                        isSelected: current == dest,
                        onTap: () => onNavigate(dest),
                        primary: primary,
                        onSurface: onSurface,
                        surface: surface,
                        badgeCount: (dest == _NavDest.runs || dest == _NavDest.home)
                            ? attentionCount
                            : 0,
                      ),
                  ],
                );
              },
            ),
          ),

          // Bottom: active runs count
          _ActiveRunsFooter(onSurface: onSurface, primary: primary),
        ],
      ),
    );
  }
}

// ── Notification Bell ────────────────────────────────────────────────────────

/// The in-app attention center. Distinct from Activity: Activity is "what
/// happened," this is "what needs (or needed) the user's attention" —
/// approvals, failures, completions, interruptions. Intentionally small;
/// it opens a short list, not another dashboard.
class _NotificationBell extends ConsumerWidget {
  final void Function(String runId) onOpenRun;

  const _NotificationBell({required this.onOpenRun});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final notifications = ref.watch(notificationsProvider).valueOrNull ?? const [];
    final unread = ref.watch(unreadNotificationCountProvider);

    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Theme.of(context).colorScheme.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: Radii.mdR,
            side: BorderSide(color: onSurface.withAlpha(26)),
          ),
        ),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
      ),
      menuChildren: [
        SizedBox(
          width: 320,
          child: _NotificationList(notifications: notifications, onOpenRun: onOpenRun),
        ),
      ],
      builder: (context, controller, child) {
        return IconButton(
          tooltip: 'Notifications',
          onPressed: () => controller.isOpen ? controller.close() : controller.open(),
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(Icons.notifications_outlined, size: IconSizes.lg, color: onSurface.withAlpha(180)),
              if (unread > 0)
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: const BoxDecoration(color: Color(0xffef6a6a), shape: BoxShape.circle),
                    constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
                    child: Text(
                      unread > 9 ? '9+' : '$unread',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _NotificationList extends ConsumerWidget {
  final List<AppNotification> notifications;
  final void Function(String runId) onOpenRun;

  const _NotificationList({required this.notifications, required this.onOpenRun});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onSurface = Theme.of(context).colorScheme.onSurface;

    if (notifications.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Text(
          'No notifications yet.',
          style: AppText.bodySecondary.copyWith(color: onSurface.withAlpha(140)),
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 400),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final n in notifications.take(20))
              _NotificationRow(
                notification: n,
                onTap: () {
                  if (!n.read) ref.read(notificationsProvider.notifier).markRead(n.id);
                  if (n.runId != null) onOpenRun(n.runId!);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _NotificationRow extends StatelessWidget {
  final AppNotification notification;
  final VoidCallback onTap;

  const _NotificationRow({required this.notification, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final (icon, color) = switch (notification.type) {
      NotificationType.runCompleted => (Icons.check_circle_outline, const Color(0xff8fd67a)),
      NotificationType.runFailed => (Icons.error_outline, const Color(0xffef6a6a)),
      NotificationType.runInterrupted => (Icons.pause_circle_outline, const Color(0xfff0b84c)),
      NotificationType.approvalRequired => (Icons.gavel, const Color(0xfff0b84c)),
      NotificationType.runBlocked => (Icons.block, const Color(0xfff0b84c)),
      NotificationType.automationFailed => (Icons.event_busy, const Color(0xffef6a6a)),
      NotificationType.automationMissed => (Icons.schedule_outlined, const Color(0xfff0b84c)),
    };

    return InkWell(
      onTap: onTap,
      borderRadius: Radii.smR,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.sm),
        decoration: BoxDecoration(
          color: notification.read ? Colors.transparent : onSurface.withAlpha(8),
          borderRadius: Radii.smR,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: IconSizes.md, color: color),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(notification.title, style: AppText.bodyStrong.copyWith(fontSize: 12.5, color: onSurface)),
                  const SizedBox(height: 2),
                  Text(
                    notification.message,
                    style: AppText.bodySecondary.copyWith(fontSize: 11.5, color: onSurface.withAlpha(160)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (!notification.read)
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(top: 4, left: 4),
                decoration: const BoxDecoration(color: Color(0xff6ac9e8), shape: BoxShape.circle),
              ),
          ],
        ),
      ),
    );
  }
}

class _BridgeStatusBadge extends StatelessWidget {
  final AsyncValue<BridgeStatus> bridgeStatus;
  final bool sysaiAvailable;

  const _BridgeStatusBadge({
    required this.bridgeStatus,
    required this.sysaiAvailable,
  });

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;

    final (color, label) = bridgeStatus.when(
      data: (s) => switch (s) {
        BridgeStatus.connected => (const Color(0xffa5e887), 'Connected'),
        BridgeStatus.sysaiUnavailable => (const Color(0xffffc46b), 'SysAI not found'),
        BridgeStatus.starting => (const Color(0xff65d5e8), 'Starting...'),
        BridgeStatus.failed => (const Color(0xffff6b6b), 'Bridge failed'),
        _ => (const Color(0xff91a2ab), 'Offline'),
      },
      loading: () => (const Color(0xff65d5e8), 'Connecting...'),
      error: (e, s) => (const Color(0xffff6b6b), 'Error'),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withAlpha(25),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withAlpha(60)),
        ),
        child: Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: onSurface.withAlpha(170),
                  letterSpacing: 0.2,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickModelSwitcher extends ConsumerWidget {
  const _QuickModelSwitcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final defaultModel = ref.watch(defaultModelProvider).valueOrNull;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('DEFAULT MODEL', style: AppText.label.copyWith(color: onSurface.withAlpha(110))),
          const SizedBox(height: Space.xs),
          SizedBox(
            width: double.infinity,
            child: ModelSelectorButton(
              placeholder: defaultModel?.modelDisplayName ?? defaultModel?.modelId ?? 'Not set',
              selectedModelId: defaultModel?.modelId,
              compact: true,
              fillWidth: true,
              onSelected: (m) => ref.read(defaultModelProvider.notifier).setDefault(
                    providerId: m.provider,
                    modelId: m.id,
                    modelDisplayName: m.displayName,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final _NavDest dest;
  final bool isSelected;
  final VoidCallback onTap;
  final Color primary;
  final Color onSurface;
  final Color surface;
  final int badgeCount;

  const _NavItem({
    required this.dest,
    required this.isSelected,
    required this.onTap,
    required this.primary,
    required this.onSurface,
    required this.surface,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: isSelected ? primary.withAlpha(25) : Colors.transparent,
            borderRadius: BorderRadius.circular(adwaitaRadius()),
            border: Border.all(
              color: isSelected ? primary.withAlpha(80) : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Icon(
                isSelected ? dest.activeIcon : dest.icon,
                size: 18,
                color: isSelected ? primary : onSurface.withAlpha(160),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  dest.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    color: isSelected ? primary : onSurface.withAlpha(200),
                  ),
                ),
              ),
              if (badgeCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xffff9f43),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$badgeCount',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: Color(0xff121417),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActiveRunsFooter extends ConsumerWidget {
  final Color onSurface;
  final Color primary;

  const _ActiveRunsFooter({required this.onSurface, required this.primary});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Runs execute independently of which page is open — this footer is
    // the one place that stays true regardless of navigation, so a Run
    // never silently "disappears" just because the user looked away.
    final activeRuns = ref.watch(activeRunsProvider);
    final pendingApprovals = ref.watch(pendingApprovalsProvider);

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: onSurface.withAlpha(10),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.pending_outlined, size: 15,
                    color: activeRuns.isEmpty ? onSurface.withAlpha(80) : primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    activeRuns.isEmpty
                        ? 'No active runs'
                        : '${activeRuns.length} active run${activeRuns.length == 1 ? '' : 's'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: activeRuns.isEmpty
                          ? onSurface.withAlpha(100)
                          : onSurface.withAlpha(200),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (pendingApprovals.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.gavel, size: 13, color: Color(0xfff0b84c)),
                  const SizedBox(width: 8),
                  Text(
                    '${pendingApprovals.length} need${pendingApprovals.length == 1 ? 's' : ''} approval',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xfff0b84c),
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

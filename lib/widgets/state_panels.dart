/// Shared empty/error/loading treatments.
///
/// Every screen was independently hand-rolling its own "nothing here yet"
/// box with slightly different padding, icon size, and copy tone. These
/// three cover the common cases so a screen only needs to supply the
/// specific icon/message.
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../theme/typography.dart';

class EmptyStatePanel extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const EmptyStatePanel({
    super.key,
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: Space.xxl, horizontal: Space.xl),
      decoration: BoxDecoration(
        color: onSurface.withAlpha(6),
        borderRadius: Radii.mdR,
        border: Border.all(color: onSurface.withAlpha(15)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 32, color: onSurface.withAlpha(70)),
          const SizedBox(height: Space.md),
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppText.bodySecondary.copyWith(color: onSurface.withAlpha(140)),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: Space.md),
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

class ErrorStatePanel extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const ErrorStatePanel({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    const danger = Color(0xffef6a6a);
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: danger.withAlpha(14),
        borderRadius: Radii.mdR,
        border: Border.all(color: danger.withAlpha(60)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, size: IconSizes.lg, color: danger),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(message, style: AppText.bodySecondary.copyWith(color: onSurface.withAlpha(210))),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class LoadingStatePanel extends StatelessWidget {
  final String? message;

  const LoadingStatePanel({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xxl),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            if (message != null) ...[
              const SizedBox(height: Space.md),
              Text(message!, style: AppText.bodySecondary.copyWith(color: onSurface.withAlpha(140))),
            ],
          ],
        ),
      ),
    );
  }
}

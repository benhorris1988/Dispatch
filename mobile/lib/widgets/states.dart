import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'buttons.dart';

/// Shimmer-free loading placeholder block. Compose several into a layout that
/// mirrors the loaded content.
class Skeleton extends StatelessWidget {
  const Skeleton({super.key, this.width, this.height = 14, this.radius = 6});
  const Skeleton.circle({super.key, double size = 32})
      : width = size,
        height = size,
        radius = 999;
  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: context.isDark ? const Color(0xFF243352) : DispatchColors.surfaceAlt, borderRadius: BorderRadius.circular(radius)),
    );
  }
}

/// A panel-shaped skeleton with a heading line and [rows] body lines.
class SkeletonPanel extends StatelessWidget {
  const SkeletonPanel({super.key, this.rows = 4, this.height});
  final int rows;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.all(Sp.lg),
      decoration: BoxDecoration(color: context.panelColor, borderRadius: DispatchRadius.panelR, border: Border.all(color: context.borderColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        const Skeleton(width: 160, height: 18),
        const SizedBox(height: Sp.lg),
        for (var i = 0; i < rows; i++) ...[
          Row(children: [
            const Skeleton.circle(size: 24),
            const SizedBox(width: Sp.md),
            Expanded(flex: 3, child: Skeleton(width: double.infinity)),
            const SizedBox(width: Sp.md),
            Expanded(flex: 1, child: Skeleton(width: double.infinity)),
          ]),
          if (i < rows - 1) const SizedBox(height: Sp.md),
        ],
      ]),
    );
  }
}

/// Centred spinner for whole-page loads.
class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.message});
  final String? message;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
        if (message != null) ...[const SizedBox(height: Sp.md), Text(message!, style: context.text.bodyMedium?.copyWith(color: context.mutedColor))],
      ]),
    );
  }
}

/// Something went wrong. Plain copy, optional retry.
class ErrorState extends StatelessWidget {
  const ErrorState({super.key, this.title = 'Something went wrong', this.message, this.onRetry, this.compact = false});
  final String title;
  final String? message;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) => _StateBody(
        icon: Icons.error_outline_rounded,
        iconColor: DispatchColors.red,
        title: title,
        message: message ?? 'We could not load this just now. Check your connection and try again.',
        action: onRetry == null ? null : SecondaryButton('Try again', icon: Icons.refresh_rounded, onPressed: onRetry),
        compact: compact,
      );
}

/// Nothing to show yet.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, this.icon = Icons.inbox_outlined, required this.title, this.message, this.action, this.compact = false});
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final bool compact;

  @override
  Widget build(BuildContext context) => _StateBody(icon: icon, iconColor: context.mutedColor, title: title, message: message, action: action, compact: compact);
}

class _StateBody extends StatelessWidget {
  const _StateBody({required this.icon, required this.iconColor, required this.title, this.message, this.action, this.compact = false});
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? message;
  final Widget? action;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(compact ? Sp.lg : Sp.xxl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: compact ? 40 : 56,
              height: compact ? 40 : 56,
              decoration: BoxDecoration(color: DispatchColors.tint(iconColor, opacity: 0.1), shape: BoxShape.circle),
              child: Icon(icon, size: compact ? 22 : 28, color: iconColor),
            ),
            const SizedBox(height: Sp.lg),
            Text(title, style: compact ? context.text.titleMedium : context.text.headlineSmall, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: Sp.sm),
              Text(message!, style: context.text.bodyMedium?.copyWith(color: context.mutedColor), textAlign: TextAlign.center),
            ],
            if (action != null) ...[const SizedBox(height: Sp.lg), action!],
          ]),
        ),
      ),
    );
  }
}

/// Placeholder body for screens that other agents will fill in.
class ComingSoon extends StatelessWidget {
  const ComingSoon(this.title, {super.key, this.detail});
  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.construction_rounded,
      title: title,
      message: detail ?? 'This screen is on its way. Check back shortly.',
    );
  }
}

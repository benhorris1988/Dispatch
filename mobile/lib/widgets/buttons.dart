import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Orange filled primary action.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton(this.label, {super.key, this.onPressed, this.icon, this.busy = false, this.expand = false, this.navy = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final bool expand;
  /// Ink-navy variant (e.g. Accept on a change card).
  final bool navy;

  @override
  Widget build(BuildContext context) {
    final child = busy
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
        : Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
            // Loose flex inside a min-size Row: the label keeps its natural
            // width wherever there is room and gives way in a narrow column
            // instead of overflowing the button.
            Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ]);
    final btn = FilledButton(
      onPressed: busy ? null : onPressed,
      style: navy ? FilledButton.styleFrom(backgroundColor: DispatchColors.ink, disabledBackgroundColor: DispatchColors.ink.withValues(alpha: 0.4)) : null,
      child: child,
    );
    return expand ? SizedBox(width: double.infinity, child: btn) : btn;
  }
}

/// Outlined secondary action.
class SecondaryButton extends StatelessWidget {
  const SecondaryButton(this.label, {super.key, this.onPressed, this.icon, this.busy = false, this.expand = false, this.danger = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final bool expand;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final fg = danger ? DispatchColors.red : null;
    final child = busy
        ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: fg ?? context.inkColor))
        : Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 18, color: fg), const SizedBox(width: 8)],
            Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: fg == null ? null : TextStyle(color: fg))),
          ]);
    final btn = OutlinedButton(onPressed: busy ? null : onPressed, child: child);
    return expand ? SizedBox(width: double.infinity, child: btn) : btn;
  }
}

/// Small pill with an icon + text, used for informational tags in headers
/// ('Freeze horizon: 10 working days', 'Next replan proposal 02:00 Wed').
class InfoPill extends StatelessWidget {
  const InfoPill(this.label, {super.key, this.icon, this.onTap, this.dot});
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  /// A coloured status dot instead of an icon.
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: context.panelColor, borderRadius: BorderRadius.circular(999), border: Border.all(color: context.borderColor)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (dot != null) ...[Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)), const SizedBox(width: 8)],
        if (icon != null) ...[Icon(icon, size: 16, color: context.mutedColor), const SizedBox(width: 6)],
        // Pill labels are sentences ('Next replan proposal Wed 9 Sep 06:00')
        // and the pill is often the widest thing in a header's action row.
        Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.labelLarge?.copyWith(fontWeight: FontWeight.w500))),
      ]),
    );
    if (onTap == null) return body;
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(999), child: body);
  }
}

/// Segmented control ('Due date | Owner | Type', 'Weeks | Days | Months').
/// Selected segment is ink navy with white text.
class SegmentedTabs extends StatelessWidget {
  const SegmentedTabs({super.key, required this.labels, required this.selected, required this.onChanged, this.compact = false});
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: context.panelColor, borderRadius: DispatchRadius.buttonR, border: Border.all(color: context.borderColor)),
      clipBehavior: Clip.antiAlias,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0) Container(width: 1, height: compact ? 28 : 36, color: context.borderColor),
          // The control sits in panel headers and filter bars that can be much
          // narrower than the sum of its segments. Loose flex keeps every
          // segment at its natural width while there is room and gives each an
          // equal share of what is left when there is not, rather than running
          // off the edge. (Weighting the flex by label length is worse: it
          // starves a short label like 'All' of the width it does need.)
          Flexible(
            child: InkWell(
              onTap: () => onChanged(i),
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 16, vertical: compact ? 6 : 9),
                color: i == selected ? DispatchColors.ink : Colors.transparent,
                child: Text(
                  labels[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.labelLarge?.copyWith(color: i == selected ? Colors.white : context.mutedColor, fontSize: compact ? 13 : 14),
                ),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

/// Icon button in a bordered square (bell, export…).
class IconBox extends StatelessWidget {
  const IconBox(this.icon, {super.key, this.onPressed, this.tooltip, this.badge = false, this.size = 44});
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool badge;
  final double size;

  @override
  Widget build(BuildContext context) {
    Widget w = InkWell(
      onTap: onPressed,
      borderRadius: DispatchRadius.buttonR,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: context.panelColor, borderRadius: DispatchRadius.buttonR, border: Border.all(color: context.borderColor)),
        child: Stack(alignment: Alignment.center, children: [
          Icon(icon, size: 20, color: context.inkColor),
          if (badge)
            Positioned(
              right: 11,
              top: 11,
              child: Container(width: 8, height: 8, decoration: BoxDecoration(color: DispatchColors.orange, shape: BoxShape.circle, border: Border.all(color: context.panelColor, width: 1.5))),
            ),
        ]),
      ),
    );
    if (tooltip != null) w = Tooltip(message: tooltip!, child: w);
    return w;
  }
}

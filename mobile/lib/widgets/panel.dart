import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// White card with a 14px radius, 1px border and an optional header row
/// (title, subtitle, trailing). Set [padding] to EdgeInsets.zero for tables
/// that want to run edge to edge under the header.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.all(Sp.lg),
    this.headerPadding,
    this.dividerAfterHeader = false,
    this.accent,
  });

  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets? headerPadding;
  final bool dividerAfterHeader;
  /// Optional 3px left accent bar (e.g. work-type colour).
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final hasHeader = title != null || trailing != null;
    Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasHeader)
          Padding(
            padding: headerPadding ?? EdgeInsets.fromLTRB(Sp.lg, Sp.lg, Sp.lg, dividerAfterHeader ? Sp.md : Sp.sm),
            child: PanelHeader(title: title ?? '', subtitle: subtitle, trailing: trailing),
          ),
        if (hasHeader && dividerAfterHeader) const Divider(),
        Padding(padding: hasHeader && padding.top == Sp.lg ? padding.copyWith(top: Sp.sm) : padding, child: child),
      ],
    );
    return Container(
      decoration: BoxDecoration(
        color: context.panelColor,
        borderRadius: DispatchRadius.panelR,
        border: Border.all(color: context.borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: accent == null
          ? body
          : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(width: 3, color: accent),
              Expanded(child: body),
            ]),
    );
  }
}

/// Header row used by [Panel]; reusable for sections without a card.
class PanelHeader extends StatelessWidget {
  const PanelHeader({super.key, required this.title, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: Sp.md,
            runSpacing: 2,
            children: [
              Text(title, style: context.text.titleLarge),
              if (subtitle != null) Text(subtitle!, style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: Sp.md), trailing!],
      ],
    );
  }
}

/// Smaller card (10px radius) for list rows and tiles inside a panel.
class DispatchCard extends StatelessWidget {
  const DispatchCard({super.key, required this.child, this.padding = const EdgeInsets.all(Sp.md), this.onTap, this.accent, this.dashed = false, this.tint});
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color? accent;
  final bool dashed;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final inner = Padding(padding: padding, child: child);
    Widget body = Container(
      decoration: BoxDecoration(
        color: tint ?? context.panelColor,
        borderRadius: DispatchRadius.cardR,
        border: dashed ? null : Border.all(color: context.borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: accent == null
          ? inner
          : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(width: 3, color: accent),
              Expanded(child: inner),
            ]),
    );
    if (dashed) body = DashedBox(radius: DispatchRadius.card, color: context.borderColor, child: body);
    if (onTap == null) return body;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, borderRadius: DispatchRadius.cardR, child: body),
    );
  }
}

/// Dashed rounded border around a child (indicative blocks, empty slots).
class DashedBox extends StatelessWidget {
  const DashedBox({super.key, required this.child, this.radius = DispatchRadius.card, this.color = DispatchColors.border, this.width = 1.2});
  final Widget child;
  final double radius, width;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _DashPainter(color: color, radius: radius, width: width), child: child);
}

class _DashPainter extends CustomPainter {
  _DashPainter({required this.color, required this.radius, required this.width});
  final Color color;
  final double radius, width;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(width / 2, width / 2, size.width - width, size.height - width), Radius.circular(radius)));
    for (final m in path.computeMetrics()) {
      double d = 0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, (d + 4).clamp(0, m.length)), paint);
        d += 7;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashPainter o) => o.color != color || o.radius != radius || o.width != width;
}

/// Section label used above groups ('Today · Tue 8 Sep', 'Coming up').
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing, this.padding = const EdgeInsets.only(top: Sp.lg, bottom: Sp.sm)});
  final String text;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(children: [
        Expanded(child: Text(text, style: context.text.titleSmall?.copyWith(color: context.mutedColor))),
        ?trailing,
      ]),
    );
  }
}

/// Page header: title, optional subtitle line, optional action row.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.subtitle, this.actions = const []});
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final titleBlock = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(title, style: context.text.headlineLarge),
      if (subtitle != null) ...[const SizedBox(height: 4), Text(subtitle!, style: context.text.bodyLarge?.copyWith(color: context.mutedColor))],
    ]);
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < 640 || actions.isEmpty) {
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          titleBlock,
          if (actions.isNotEmpty) ...[const SizedBox(height: Sp.md), Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: actions)],
        ]);
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(child: titleBlock),
        Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: actions),
      ]);
    });
  }
}

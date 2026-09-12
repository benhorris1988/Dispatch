/// Visual parts shared by the Schedule and Changes screens: hatching, the
/// assignment block, lane headers, the legend and the before → after pair.
/// New file (prefix `Sch`) so the shared widget library stays untouched.
library;

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../screens/parts/sch_models.dart';
import '../services/format.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'widgets.dart';

/// 45° hatching, used for leave, rota and the indicative region.
class SchHatchPainter extends CustomPainter {
  SchHatchPainter({required this.colour, this.spacing = 7, this.strokeWidth = 1});
  final Color colour;
  final double spacing;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = colour
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    for (double x = -size.height; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
    }
  }

  @override
  bool shouldRepaint(SchHatchPainter old) => old.colour != colour || old.spacing != spacing;
}

/// Hatched fill behind [child] (or on its own).
class SchHatch extends StatelessWidget {
  const SchHatch({super.key, required this.colour, this.child, this.spacing = 7, this.radius = 0});
  final Color colour;
  final Widget? child;
  final double spacing;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final paint = CustomPaint(painter: SchHatchPainter(colour: colour, spacing: spacing), child: child ?? const SizedBox.expand());
    return radius > 0 ? ClipRRect(borderRadius: BorderRadius.circular(radius), child: paint) : paint;
  }
}

/// Dashed rounded outline (the indicative block and the drag ghost).
class SchDashedBorderPainter extends CustomPainter {
  SchDashedBorderPainter({required this.colour, this.radius = DispatchRadius.card, this.strokeWidth = 1.2, this.dash = 4, this.gap = 3});
  final Color colour;
  final double radius;
  final double strokeWidth;
  final double dash;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    final path = Path()..addRRect(rect);
    final paint = Paint()
      ..color = colour
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    for (final metric in path.computeMetrics()) {
      double d = 0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, (d + dash).clamp(0, metric.length)), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(SchDashedBorderPainter old) => old.colour != colour;
}

/// Load percentage against the target band: red over 100, amber over 90,
/// green inside the band, grey below it. The number and its tooltip carry the
/// meaning as well as the colour.
Color schLoadColour(double pct, {int targetMin = 80, int targetMax = 90}) {
  if (pct > 100) return DispatchColors.red;
  if (pct > targetMax) return DispatchColors.amber;
  if (pct >= targetMin) return DispatchColors.green;
  return DispatchColors.faint;
}

String schLoadLabel(double pct, {int targetMin = 80, int targetMax = 90}) {
  if (pct > 100) return 'over capacity';
  if (pct > targetMax) return 'above the target band';
  if (pct >= targetMin) return 'inside the target band';
  return 'below the target band';
}

/// One assignment block. [away] renders the grey hatched leave/training form.
class SchBlockCard extends StatelessWidget {
  const SchBlockCard({
    super.key,
    required this.title,
    this.subtitle,
    this.railColour,
    this.indicative = false,
    this.away = false,
    this.moved = false,
    this.ghost = false,
    this.locked = false,
    this.fixed = false,
    this.dense = false,
  });

  final String title;
  final String? subtitle;
  final Color? railColour;
  final bool indicative;
  final bool away;
  final bool moved;
  final bool ghost;
  final bool locked;
  final bool fixed;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final muted = context.mutedColor;

    if (ghost) {
      return CustomPaint(
        painter: SchDashedBorderPainter(colour: muted.withValues(alpha: 0.7)),
        child: const SizedBox.expand(),
      );
    }

    if (away) {
      final base = context.isDark ? DispatchColors.darkBorder : DispatchColors.surfaceAlt;
      return Container(
        decoration: BoxDecoration(
          color: base,
          borderRadius: DispatchRadius.cardR,
          border: Border.all(color: context.borderColor),
        ),
        child: SchHatch(
          colour: muted.withValues(alpha: 0.35),
          radius: DispatchRadius.card,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.sm, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.text.labelMedium?.copyWith(color: muted)),
            ),
          ),
        ),
      );
    }

    final rail = railColour ?? DispatchColors.typeBlue;
    // Narrow blocks (a day column in the months view) have no room for the
    // lock or pin glyph; the block's tooltip and semantics still carry it.
    final body = LayoutBuilder(
      builder: (context, constraints) => _body(context, rail, muted, showBadge: constraints.maxWidth >= 78),
    );

    final decoration = BoxDecoration(
      color: moved ? DispatchColors.tint(DispatchColors.orange, opacity: context.isDark ? 0.22 : 0.13) : scheme.surface,
      borderRadius: DispatchRadius.cardR,
      border: Border.all(color: moved ? DispatchColors.orange : context.borderColor, width: moved ? 1.4 : 1),
    );

    Widget card = ClipRRect(borderRadius: DispatchRadius.cardR, child: body);
    if (indicative) {
      card = Stack(
        fit: StackFit.expand,
        children: [
          card,
          IgnorePointer(child: SchHatch(colour: muted.withValues(alpha: 0.18), spacing: 8, radius: DispatchRadius.card)),
          IgnorePointer(child: CustomPaint(painter: SchDashedBorderPainter(colour: moved ? DispatchColors.orange : context.borderColor))),
        ],
      );
      return Container(
        decoration: BoxDecoration(color: decoration.color, borderRadius: DispatchRadius.cardR),
        child: card,
      );
    }
    return Container(decoration: decoration, child: card);
  }

  Widget _body(BuildContext context, Color rail, Color muted, {required bool showBadge}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(width: 3, color: rail),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.sm, vertical: 3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.labelMedium?.copyWith(fontSize: 12.5, height: 1.15, fontWeight: FontWeight.w700, color: context.inkColor),
                      ),
                    ),
                    if (showBadge && (locked || fixed)) ...[
                      const SizedBox(width: 4),
                      Icon(fixed ? Icons.push_pin_outlined : Icons.lock_outline, size: 11, color: muted),
                    ],
                  ],
                ),
                if (subtitle != null && subtitle!.isNotEmpty && !dense)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.labelSmall?.copyWith(fontSize: 10.5, height: 1.15, color: muted),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The frozen lane header: avatar, name, role and load.
class SchLaneHeader extends StatelessWidget {
  const SchLaneHeader({super.key, required this.person, required this.height, this.targetMin = 80, this.targetMax = 90, this.onTap, this.onRota = false});
  final SchPerson person;
  final double height;
  final int targetMin;
  final int targetMax;
  final VoidCallback? onTap;
  final bool onRota;

  @override
  Widget build(BuildContext context) {
    final colour = schLoadColour(person.loadPct, targetMin: targetMin, targetMax: targetMax);
    return InkWell(
      onTap: onTap,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: Sp.md, vertical: Sp.sm),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.borderColor))),
        child: Row(
          children: [
            PersonAvatar(person.initialsOrDerived, colourHex: person.colourHex, seed: person.id, size: 30),
            const SizedBox(width: Sp.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(person.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.titleSmall),
                  Text(
                    dotJoin([person.roleTitle, if (onRota) 'on rota']),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.labelSmall?.copyWith(color: context.mutedColor),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Sp.sm),
            Tooltip(
              message: '${person.loadPct.round()}% load — ${schLoadLabel(person.loadPct, targetMin: targetMin, targetMax: targetMax)}',
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${person.loadPct.round()}%', style: DispatchTheme.numeric(size: 14, color: colour)),
                  Text('load', style: context.text.labelSmall?.copyWith(color: context.mutedColor)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Legend row: work-type dots, indicative and leave keys.
class SchLegend extends StatelessWidget {
  const SchLegend({super.key, required this.workTypes, this.trailing = const []});
  final List<WorkType> workTypes;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final muted = context.mutedColor;
    return Wrap(
      spacing: Sp.lg,
      runSpacing: Sp.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final t in workTypes) LegendDot(t.name, colour: t.colour),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CustomPaint(painter: SchDashedBorderPainter(colour: muted, radius: 3, dash: 3, gap: 2)),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Indicative (beyond planning horizon)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.labelMedium?.copyWith(color: muted),
              ),
            ),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 12, height: 12, child: SchHatch(colour: muted.withValues(alpha: 0.5), spacing: 4, radius: 3)),
            const SizedBox(width: 6),
            Flexible(child: Text('Leave', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.labelMedium?.copyWith(color: muted))),
          ],
        ),
        ...trailing,
      ],
    );
  }
}

/// before → after: struck-through grey box, arrow, orange-tinted box.
/// Falls back to a stacked layout when [vertical] (phone).
class SchBeforeAfter extends StatelessWidget {
  const SchBeforeAfter({super.key, required this.before, required this.after, this.vertical = false});
  final String before;
  final String after;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final beforeBox = _Box(
      text: before.isEmpty ? 'Not planned' : before,
      background: context.isDark ? DispatchColors.darkBorder.withValues(alpha: 0.4) : DispatchColors.surfaceAlt,
      border: context.borderColor,
      textStyle: context.text.bodyMedium?.copyWith(color: context.mutedColor, decoration: TextDecoration.lineThrough),
      semantics: 'Before: $before',
    );
    final afterBox = _Box(
      text: after.isEmpty ? 'Removed from the plan' : after,
      background: DispatchColors.tint(DispatchColors.orange, opacity: context.isDark ? 0.18 : 0.1),
      border: DispatchColors.orange.withValues(alpha: 0.6),
      textStyle: context.text.bodyMedium?.copyWith(color: context.inkColor, fontWeight: FontWeight.w600),
      semantics: 'After: $after',
    );
    if (vertical) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          beforeBox,
          const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Icon(Icons.arrow_downward, size: 18, color: DispatchColors.orange)),
          afterBox,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: beforeBox),
        const Padding(padding: EdgeInsets.symmetric(horizontal: Sp.md), child: Icon(Icons.arrow_forward, size: 18, color: DispatchColors.orange)),
        Expanded(child: afterBox),
      ],
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.text, required this.background, required this.border, this.textStyle, required this.semantics});
  final String text;
  final Color background;
  final Color border;
  final TextStyle? textStyle;
  final String semantics;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semantics,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Sp.md, vertical: Sp.sm + 2),
        decoration: BoxDecoration(color: background, borderRadius: DispatchRadius.cardR, border: Border.all(color: border)),
        child: Text(text, style: textStyle),
      ),
    );
  }
}

/// "3 of 5 used" change-budget meter (STAB-03).
class SchBudgetMeter extends StatelessWidget {
  const SchBudgetMeter({super.key, required this.used, required this.limit, this.label = 'Change budget this week', this.width = 190});
  final double used;
  final double limit;
  final String label;
  final double width;

  @override
  Widget build(BuildContext context) {
    final fraction = limit <= 0 ? 0.0 : (used / limit).clamp(0.0, 1.0);
    final over = limit > 0 && used > limit;
    return Semantics(
      label: '$label: ${fmtDays(used)} of ${fmtDays(limit)} used',
      excludeSemantics: true,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: context.text.labelMedium?.copyWith(color: context.mutedColor)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: fraction,
                      minHeight: 7,
                      backgroundColor: context.borderColor,
                      valueColor: AlwaysStoppedAnimation(over ? DispatchColors.red : DispatchColors.orange),
                    ),
                  ),
                ),
                const SizedBox(width: Sp.sm),
                Text('${_n(used)} of ${_n(limit)} used', style: DispatchTheme.numeric(size: 13, color: context.inkColor)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _n(double v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
}

/// A tone chip whose label wraps instead of overflowing. Impact-chip labels
/// come from the engine ("Inside freeze horizon · needs your approval") and can
/// be longer than a narrow column, so the text has to be flexible.
class SchChip extends StatelessWidget {
  const SchChip(this.label, {super.key, this.tone, this.icon, this.maxLines = 2});
  final String label;
  final String? tone; // ok | warn | bad | info | accent
  final IconData? icon;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final fg = switch (tone) {
      'ok' => DispatchColors.green,
      'warn' => DispatchColors.amber,
      'bad' => DispatchColors.red,
      'accent' => DispatchColors.orange,
      _ => context.inkColor,
    };
    final bg = tone == null || tone == 'info'
        ? (context.isDark ? const Color(0xFF243352) : DispatchColors.surfaceAlt)
        : DispatchColors.tint(fg, opacity: context.isDark ? 0.22 : 0.12);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: DispatchRadius.chipR),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: fg), const SizedBox(width: 4)],
          Flexible(
            child: Text(
              label,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: context.text.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w600, height: 1.2),
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Priority bar + number. Orange ≥ 70, navy ≥ 50, blue below.
class PriorityBar extends StatelessWidget {
  const PriorityBar(this.score, {super.key, this.width = 72, this.showNumber = true, this.height = 6});
  final double? score; // 0..100
  final double width;
  final bool showNumber;
  final double height;

  static Color colourFor(double s) => s >= 70 ? DispatchColors.orange : (s >= 50 ? DispatchColors.ink : DispatchColors.typeBlue);

  @override
  Widget build(BuildContext context) {
    final s = (score ?? 0).clamp(0, 100).toDouble();
    final c = score == null ? context.borderColor : colourFor(s);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: width,
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(height / 2),
          child: Stack(children: [
            Container(color: context.isDark ? DispatchColors.darkBorder : DispatchColors.surfaceAlt),
            FractionallySizedBox(widthFactor: s / 100, child: Container(color: c)),
          ]),
        ),
      ),
      if (showNumber) ...[
        const SizedBox(width: Sp.sm),
        SizedBox(
          width: 28,
          child: Text(score == null ? '—' : s.round().toString(),
              style: DispatchTheme.numeric(size: 13, weight: FontWeight.w800, color: score == null ? context.mutedColor : context.inkColor)),
        ),
      ],
    ]);
  }
}

/// Proficiency square for a skills matrix. 4 = filled navy, 3 = blue,
/// 2/1 = light blue (1 lighter), 0 = dashed empty.
class ProficiencySquare extends StatelessWidget {
  const ProficiencySquare(this.level, {super.key, this.size = 18, this.tooltip});
  final int level; // 0..4
  final double size;
  final String? tooltip;

  static Color? fillFor(int level) => switch (level.clamp(0, 4)) {
        4 => DispatchColors.ink,
        3 => DispatchColors.typeBlue,
        2 => const Color(0xFF9DB6EE),
        1 => const Color(0xFFD3DFF6),
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final fill = fillFor(level);
    final w = fill == null
        ? CustomPaint(painter: _DashSquare(color: context.borderColor), child: SizedBox(width: size, height: size))
        : Container(width: size, height: size, decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(4)));
    return tooltip == null ? w : Tooltip(message: tooltip!, child: w);
  }
}

class _DashSquare extends CustomPainter {
  _DashSquare({required this.color});
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0.6, 0.6, size.width - 1.2, size.height - 1.2), const Radius.circular(4)));
    for (final m in path.computeMetrics()) {
      double d = 0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, (d + 2.5).clamp(0, m.length)), paint);
        d += 5;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashSquare o) => o.color != color;
}

/// Three dots for benefit/estimate confidence: low = 1, medium = 2, high = 3.
class ConfidenceDots extends StatelessWidget {
  const ConfidenceDots(this.confidence, {super.key, this.size = 7, this.showLabel = false});
  final String? confidence; // low | medium | high
  final double size;
  final bool showLabel;

  int get _n => switch ((confidence ?? '').toLowerCase()) { 'high' => 3, 'medium' => 2, 'low' => 1, _ => 0 };

  @override
  Widget build(BuildContext context) {
    final n = _n;
    final c = switch (n) { 3 => DispatchColors.green, 2 => DispatchColors.amber, 1 => DispatchColors.red, _ => context.borderColor };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < 3; i++)
        Container(
          width: size,
          height: size,
          margin: EdgeInsets.only(right: i < 2 ? 3 : 0),
          decoration: BoxDecoration(shape: BoxShape.circle, color: i < n ? c : context.borderColor),
        ),
      if (showLabel) ...[
        const SizedBox(width: 6),
        Text(n == 0 ? 'Unknown' : '${confidence![0].toUpperCase()}${confidence!.substring(1)}', style: context.text.labelMedium?.copyWith(color: context.mutedColor)),
      ],
    ]);
  }
}

/// Thin progress bar (e.g. 'Day 14 of 20', change budget). Colour defaults to blue.
class ProgressBar extends StatelessWidget {
  const ProgressBar(this.fraction, {super.key, this.colour = DispatchColors.typeBlue, this.height = 6, this.trailing});
  final double fraction;
  final Color colour;
  final double height;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final bar = ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Stack(children: [
          Container(color: context.isDark ? DispatchColors.darkBorder : DispatchColors.surfaceAlt),
          FractionallySizedBox(widthFactor: fraction.clamp(0, 1), child: Container(color: colour)),
        ]),
      ),
    );
    if (trailing == null) return bar;
    return Row(children: [Expanded(child: bar), const SizedBox(width: Sp.md), trailing!]);
  }
}

/// Load percentage text, red when over 100.
class LoadPct extends StatelessWidget {
  const LoadPct(this.pct, {super.key, this.size = 15});
  final double? pct;
  final double size;
  @override
  Widget build(BuildContext context) {
    final over = (pct ?? 0) > 100;
    return Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
      Text(pct == null ? '—' : '${pct!.round()}%', style: DispatchTheme.numeric(size: size, weight: FontWeight.w800, color: over ? DispatchColors.red : context.inkColor)),
      Text('load', style: context.text.labelSmall),
    ]);
  }
}

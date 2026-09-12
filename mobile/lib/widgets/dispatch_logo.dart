import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Orange rounded mark with a route-arrow glyph.
class DispatchMark extends StatelessWidget {
  const DispatchMark({super.key, this.size = 44});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: DispatchColors.orange, borderRadius: BorderRadius.circular(size * 0.28)),
      child: CustomPaint(painter: _RoutePainter()),
    );
  }
}

class _RoutePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final stroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.075
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = Colors.white;
    // A route: dot bottom-left, curve up to an arrowhead top-right.
    final p = Path()
      ..moveTo(s * 0.28, s * 0.70)
      ..cubicTo(s * 0.28, s * 0.50, s * 0.42, s * 0.50, s * 0.52, s * 0.46)
      ..cubicTo(s * 0.62, s * 0.42, s * 0.70, s * 0.38, s * 0.70, s * 0.30);
    canvas.drawPath(p, stroke);
    canvas.drawCircle(Offset(s * 0.28, s * 0.70), s * 0.075, fill);
    final arrow = Path()
      ..moveTo(s * 0.58, s * 0.30)
      ..lineTo(s * 0.70, s * 0.30)
      ..lineTo(s * 0.70, s * 0.42);
    canvas.drawPath(arrow, stroke);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Mark + 'Dispatch / Delivery planning' wordmark. [onDark] for the sidebar.
class DispatchLogo extends StatelessWidget {
  const DispatchLogo({super.key, this.size = 44, this.onDark = true, this.showTagline = true});
  final double size;
  final bool onDark;
  final bool showTagline;

  @override
  Widget build(BuildContext context) {
    final fg = onDark ? Colors.white : DispatchColors.ink;
    final sub = onDark ? DispatchColors.sidebarMuted : DispatchColors.muted;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      DispatchMark(size: size),
      const SizedBox(width: 12),
      Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text('Dispatch', style: DispatchTheme.manrope(fontSize: size * 0.5, fontWeight: FontWeight.w800, color: fg, height: 1.1, letterSpacing: -0.4)),
        if (showTagline) Text('Delivery planning', style: DispatchTheme.inter(fontSize: size * 0.3, fontWeight: FontWeight.w500, color: sub, height: 1.2)),
      ]),
    ]);
  }
}

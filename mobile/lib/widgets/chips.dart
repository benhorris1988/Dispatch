import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Parcel-style square size stamp: S / M / L / C. Filled navy for L, outlined
/// otherwise; dashed border for C (custom) or when [dashed] is set.
class SizeStamp extends StatelessWidget {
  const SizeStamp(this.stamp, {super.key, this.size = 28, this.dashed, this.filled});

  final String? stamp;
  final double size;
  /// Defaults to true for 'C'.
  final bool? dashed;
  /// Defaults to true for 'L'.
  final bool? filled;

  @override
  Widget build(BuildContext context) {
    final s = (stamp ?? '?').toUpperCase();
    final isDashed = dashed ?? (s == 'C');
    final isFilled = filled ?? (s == 'L');
    final ink = context.isDark ? DispatchColors.darkText : DispatchColors.ink;
    final label = Text(
      s,
      style: DispatchTheme.manrope(fontSize: size * 0.5, fontWeight: FontWeight.w800, color: isFilled ? Colors.white : ink, height: 1),
    );
    if (isDashed) {
      return CustomPaint(
        painter: _DashedBorderPainter(color: ink.withValues(alpha: 0.55), radius: DispatchRadius.stamp),
        child: SizedBox(width: size, height: size, child: Center(child: label)),
      );
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isFilled ? DispatchColors.ink : Colors.transparent,
        borderRadius: BorderRadius.circular(DispatchRadius.stamp),
        border: Border.all(color: isFilled ? DispatchColors.ink : ink, width: 1.5),
      ),
      child: label,
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius, this.dash = 3, this.gap = 2.5, this.width = 1.5});
  final Color color;
  final double radius, dash, gap, width;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    final rrect = RRect.fromRectAndRadius(Rect.fromLTWH(width / 2, width / 2, size.width - width, size.height - width), Radius.circular(radius));
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      double d = 0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, (d + dash).clamp(0, metric.length)), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) => old.color != color || old.radius != radius;
}

/// Tinted work-type chip: coloured label on a 12% tint of the same colour.
class TypeChip extends StatelessWidget {
  const TypeChip(this.name, {super.key, this.colour, this.colourHex, this.compact = false});

  final String name;
  final Color? colour;
  /// '#RRGGBB' from the API; used when [colour] is null.
  final String? colourHex;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = colour ?? DispatchColors.parseHex(colourHex);
    return _Chip(label: name, fg: c, bg: DispatchColors.tint(c, opacity: context.isDark ? 0.22 : 0.12), compact: compact);
  }
}

/// Status → (label, foreground colour). Accepts work-item statuses, health
/// values, assignment states and benefit statuses.
({String label, Color fg}) statusStyle(String? status) {
  switch ((status ?? '').toLowerCase()) {
    case 'on_track':
    case 'on track':
      return (label: 'On track', fg: DispatchColors.green);
    case 'delivered':
    case 'realised':
    case 'accepted':
    case 'ok':
      return (label: _cap(status!), fg: DispatchColors.green);
    case 'at_risk':
    case 'at risk':
      return (label: 'At risk', fg: DispatchColors.amber);
    case 'needs_estimate':
      return (label: 'Needs estimate', fg: DispatchColors.amber);
    case 'needs_benefit':
      return (label: 'Needs benefit', fg: DispatchColors.amber);
    case 'needs_approval':
      return (label: 'Needs approval', fg: DispatchColors.amber);
    case 'blocked':
      return (label: 'Blocked', fg: DispatchColors.red);
    case 'late':
      return (label: 'Late', fg: DispatchColors.red);
    case 'rejected':
    case 'cancelled':
      return (label: _cap(status!), fg: DispatchColors.red);
    case 'in_progress':
    case 'in progress':
    case 'in_flight':
    case 'realising':
    case 'pending':
      return (label: _cap(status!), fg: DispatchColors.orange);
    case 'scheduled':
    case 'committed':
    case 'planned':
    case 'indicative':
    case 'ready':
    case 'draft':
    case 'superseded':
    case 'edited':
      return (label: _cap(status!), fg: DispatchColors.muted);
    default:
      return (label: status == null || status.isEmpty ? '—' : _cap(status), fg: DispatchColors.muted);
  }
}

String _cap(String s) {
  final t = s.replaceAll('_', ' ');
  return t[0].toUpperCase() + t.substring(1);
}

/// Status chip with the standard colour mapping. Pass [label] to override the
/// text (e.g. 'Due Fri 11 Sep' in a grey chip via status 'scheduled').
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.label, this.icon, this.compact = false});

  final String? status;
  final String? label;
  final IconData? icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final s = statusStyle(status);
    final fg = s.fg == DispatchColors.muted && context.isDark ? DispatchColors.darkText : s.fg;
    final bg = s.fg == DispatchColors.muted
        ? (context.isDark ? const Color(0xFF243352) : DispatchColors.surfaceAlt)
        : DispatchColors.tint(s.fg, opacity: context.isDark ? 0.22 : 0.12);
    return _Chip(label: label ?? s.label, fg: fg, bg: bg, icon: icon, compact: compact);
  }
}

/// Neutral chip with an optional tone: 'ok' | 'warn' | 'bad' | 'info' | null.
/// Used for impact chips on change cards.
class ToneChip extends StatelessWidget {
  const ToneChip(this.label, {super.key, this.tone, this.icon, this.compact = false});
  final String label;
  final String? tone;
  final IconData? icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final fg = switch (tone) {
      'ok' => DispatchColors.green,
      'warn' => DispatchColors.amber,
      'bad' => DispatchColors.red,
      'accent' => DispatchColors.orange,
      _ => context.isDark ? DispatchColors.darkText : DispatchColors.ink,
    };
    final bg = tone == null || tone == 'info'
        ? (context.isDark ? const Color(0xFF243352) : DispatchColors.surfaceAlt)
        : DispatchColors.tint(fg, opacity: context.isDark ? 0.22 : 0.12);
    return _Chip(label: label, fg: fg, bg: bg, icon: icon, compact: compact);
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.fg, required this.bg, this.icon, this.compact = false});
  final String label;
  final Color fg, bg;
  final IconData? icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8, vertical: compact ? 2 : 4),
      decoration: BoxDecoration(color: bg, borderRadius: DispatchRadius.chipR),
      // Chips carry API-supplied labels of unpredictable length and sit in table cells and
      // narrow columns, so the text has to be able to give way. Flexible + ellipsis keeps
      // the chip inside its cell instead of overflowing the row it is in.
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: compact ? 12 : 14, color: fg), const SizedBox(width: 4)],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: DispatchTheme.inter(fontSize: compact ? 11.5 : 12.5, fontWeight: FontWeight.w600, color: fg, height: 1.2),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small dot + text legend swatch (e.g. schedule legend).
class LegendDot extends StatelessWidget {
  const LegendDot(this.label, {super.key, required this.colour, this.dashed = false});
  final String label;
  final Color colour;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      dashed
          ? CustomPaint(painter: _DashedBorderPainter(color: colour, radius: 3, width: 1.2, dash: 2, gap: 2), child: const SizedBox(width: 11, height: 11))
          : Container(width: 11, height: 11, decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(3))),
      const SizedBox(width: 6),
      // Legends are built from work-type names and sit in a Wrap inside panel
      // headers, so the label has to be able to give way like a chip's does.
      Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodySmall)),
    ]);
  }
}

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'widgets.dart';

/// Shared pieces for the Team & skills, Person, Benefits, Settings, Reports and
/// Notifications screens. Nothing here edits a shell file — every widget is new
/// and prefixed `Tm` so it cannot collide with another screen author's work.
///
/// Charts are hand-drawn with [CustomPainter] or plain layout widgets so they
/// inherit the theme (no hard-coded light-mode colours) and stay legible in
/// both themes.

// ─── Text repair ──────────────────────────────────────────────────────────

/// Repair double-encoded UTF-8 coming back from the API ('Monâ€“Thu' →
/// 'Mon–Thu'). A no-op once the server stores the text correctly, so it is safe
/// to leave in place.
// A "repair double-encoded UTF-8" helper used to live here. It was removed: the API
// returns correct UTF-8 on every endpoint checked at byte level (en dash e2 80 93, minus
// e2 88 92), and the mojibake that prompted it was the Windows console rendering, not the
// payload. Worse, the repair would have mangled legitimate Latin-1-range text — a person
// named "Angela" spelled with an circumflex A trips exactly the characters it looked for.

// ─── Headings ─────────────────────────────────────────────────────────────

/// Panel title with an info icon that opens the metric definition (REP-04).
class TmMetricTitle extends StatelessWidget {
  const TmMetricTitle({super.key, required this.title, this.subtitle, this.definition});
  final String title;
  final String? subtitle;
  final String? definition;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: Text(title, style: context.text.titleLarge, overflow: TextOverflow.ellipsis)),
      if (definition != null && definition!.isNotEmpty) ...[
        const SizedBox(width: 4),
        IconButton(
          onPressed: () => showTmInfoDialog(context, title, definition ?? ''),
          icon: const Icon(Icons.info_outline_rounded, size: 17),
          color: context.mutedColor,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          tooltip: 'How $title is measured',
        ),
      ],
      if (subtitle != null) ...[
        const SizedBox(width: Sp.sm),
        Flexible(child: Text(subtitle!, style: context.text.bodyMedium?.copyWith(color: context.mutedColor), overflow: TextOverflow.ellipsis)),
      ],
    ]);
  }
}

Future<void> showTmInfoDialog(BuildContext context, String title, String body) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(child: Text(body, style: context.text.bodyMedium)),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
    ),
  );
}

/// Tinted note box with an info icon — used for the benefits priority note and
/// the size-class footnote.
class TmInfoBox extends StatelessWidget {
  const TmInfoBox(this.text, {super.key, this.icon = Icons.info_outline_rounded, this.tone});
  final String text;
  final IconData icon;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final c = tone ?? DispatchColors.typeBlue;
    return Container(
      padding: const EdgeInsets.all(Sp.md),
      decoration: BoxDecoration(
        color: DispatchColors.tint(c, opacity: context.isDark ? 0.18 : 0.08),
        borderRadius: DispatchRadius.cardR,
        border: Border.all(color: DispatchColors.tint(c, opacity: 0.3)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 17, color: c),
        const SizedBox(width: Sp.sm),
        Expanded(child: Text(text, style: context.text.bodyMedium)),
      ]),
    );
  }
}

/// Inline error message, e.g. a 409 band-overlap explanation under a form.
class TmInlineError extends StatelessWidget {
  const TmInlineError(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Sp.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.error_outline_rounded, size: 16, color: DispatchColors.red),
        const SizedBox(width: 6),
        Expanded(child: Text(message, style: context.text.bodyMedium?.copyWith(color: DispatchColors.red))),
      ]),
    );
  }
}

// ─── Tables ───────────────────────────────────────────────────────────────

/// A column in a [TmTable].
class TmCol {
  const TmCol(this.label, {this.width, this.flex = 1, this.align = TextAlign.left, this.numeric = false});
  final String label;

  /// Fixed pixel width; when null the column takes [flex] of the remainder.
  final double? width;
  final int flex;
  final TextAlign align;
  final bool numeric;
}

/// Header row + divided body rows, edge to edge inside a [Panel] with zero
/// padding. Below [cardBelow] the caller should render cards instead — use
/// [TmTable.isNarrow].
class TmTable extends StatelessWidget {
  const TmTable({super.key, required this.columns, required this.rows, this.rowPadding, this.headerPadding});
  final List<TmCol> columns;

  /// Each row is a list of cells, one per column.
  final List<List<Widget>> rows;
  final EdgeInsets? rowPadding;
  final EdgeInsets? headerPadding;

  static const double cardBelow = 800;
  static bool isNarrow(double width) => width < cardBelow;

  Widget _cell(Widget child, TmCol c) {
    final aligned = Align(
      alignment: switch (c.align) {
        TextAlign.right => Alignment.centerRight,
        TextAlign.center => Alignment.center,
        _ => Alignment.centerLeft,
      },
      child: child,
    );
    return c.width != null ? SizedBox(width: c.width, child: aligned) : Expanded(flex: c.flex, child: aligned);
  }

  @override
  Widget build(BuildContext context) {
    final rp = rowPadding ?? const EdgeInsets.symmetric(horizontal: Sp.lg, vertical: Sp.md);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        color: context.isDark ? const Color(0xFF1B2842) : DispatchColors.surfaceAlt,
        padding: headerPadding ?? rp.copyWith(top: Sp.sm, bottom: Sp.sm),
        child: Row(children: [
          for (var i = 0; i < columns.length; i++) ...[
            if (i > 0) const SizedBox(width: Sp.md),
            _cell(
              Text(columns[i].label,
                  style: context.text.labelMedium?.copyWith(color: context.mutedColor, fontWeight: FontWeight.w600), textAlign: columns[i].align),
              columns[i],
            ),
          ],
        ]),
      ),
      for (var r = 0; r < rows.length; r++) ...[
        if (r > 0) Divider(height: 1, thickness: 1, color: context.borderColor),
        Padding(
          padding: rp,
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            for (var i = 0; i < columns.length; i++) ...[
              if (i > 0) const SizedBox(width: Sp.md),
              _cell(rows[r].length > i ? rows[r][i] : const SizedBox(), columns[i]),
            ],
          ]),
        ),
      ],
    ]);
  }
}

/// Label / value pair used inside the narrow-screen card fallbacks and the
/// person's working-pattern panel.
class TmKeyValue extends StatelessWidget {
  const TmKeyValue(this.label, this.value, {super.key, this.valueWidget, this.labelWidth = 140});
  final String label;
  final String? value;
  final Widget? valueWidget;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: labelWidth, child: Text(label, style: context.text.bodyMedium?.copyWith(color: context.mutedColor))),
        const SizedBox(width: Sp.md),
        Expanded(child: valueWidget ?? Text(value ?? '—', style: context.text.bodyMedium)),
      ]),
    );
  }
}

// ─── Small indicators ─────────────────────────────────────────────────────

/// Load bar with a percentage: green in band, amber above the ceiling, red over
/// 100. The percentage text carries the same meaning as the colour.
class TmLoadBar extends StatelessWidget {
  const TmLoadBar(this.pct, {super.key, this.width = 56, this.targetMax = 90});
  final double? pct;
  final double width;
  final double targetMax;

  static Color colourFor(double? pct, double targetMax) {
    if (pct == null) return DispatchColors.muted;
    if (pct > 100) return DispatchColors.red;
    if (pct > targetMax) return DispatchColors.amber;
    return DispatchColors.green;
  }

  @override
  Widget build(BuildContext context) {
    final c = colourFor(pct, targetMax);
    final v = (pct ?? 0).clamp(0, 130).toDouble();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: width,
        height: 5,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Stack(children: [
            Container(color: context.isDark ? DispatchColors.darkBorder : DispatchColors.surfaceAlt),
            FractionallySizedBox(widthFactor: (v / 130).clamp(0.0, 1.0), child: Container(color: c)),
          ]),
        ),
      ),
      const SizedBox(width: Sp.sm),
      SizedBox(
        width: 40,
        child: Text(pct == null ? '—' : '${pct!.round()}%',
            textAlign: TextAlign.right, style: DispatchTheme.numeric(size: 13, weight: FontWeight.w700, color: context.inkColor)),
      ),
    ]);
  }
}

/// Tiny bar used in the matrix footer ('Items needing skill, next 6 weeks').
class TmMiniBar extends StatelessWidget {
  const TmMiniBar({super.key, required this.fraction, required this.colour, this.width = 44, this.trailing});
  final double fraction;
  final Color colour;
  final double width;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: width,
        height: 5,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Stack(children: [
            Container(color: context.isDark ? DispatchColors.darkBorder : DispatchColors.surfaceAlt),
            FractionallySizedBox(widthFactor: fraction.clamp(0.0, 1.0), child: Container(color: colour)),
          ]),
        ),
      ),
      if (trailing != null) ...[
        const SizedBox(width: 6),
        Text(trailing!, style: DispatchTheme.numeric(size: 12.5, weight: FontWeight.w700, color: context.inkColor)),
      ],
    ]);
  }
}

/// A labelled progress bar row (value by benefit type).
class TmProgressRow extends StatelessWidget {
  const TmProgressRow({super.key, required this.label, required this.value, required this.fraction, required this.colour});
  final String label;
  final String value;
  final double fraction;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: Sp.sm),
          Expanded(child: Text(label, style: context.text.bodyMedium)),
          Text(value, style: DispatchTheme.numeric(size: 14, weight: FontWeight.w800, color: context.inkColor)),
        ]),
        const SizedBox(height: 6),
        ProgressBar(fraction, colour: colour, height: 5),
      ]),
    );
  }
}

// ─── Charts ───────────────────────────────────────────────────────────────

/// One bar in a [TmGroupedBarChart] or [TmStackedBarChart].
class TmBar {
  const TmBar(this.value, this.colour, {this.tooltip});
  final double value;
  final Color colour;
  final String? tooltip;
}

/// A cluster of bars sharing one axis label.
class TmBarGroup {
  const TmBarGroup(this.label, this.bars, {this.flag});
  final String label;
  final List<TmBar> bars;

  /// Marker shown above the group when something is exceptional (e.g. '!' when
  /// demand exceeds supply) so colour is not the only carrier of meaning.
  final String? flag;
}

/// Grouped vertical bars. Heights are fractions of the largest value across all
/// groups (or [maxValue] when given).
class TmGroupedBarChart extends StatelessWidget {
  const TmGroupedBarChart({super.key, required this.groups, this.height = 150, this.maxValue, this.barWidth = 12, this.labelStyle});
  final List<TmBarGroup> groups;
  final double height;
  final double? maxValue;
  final double barWidth;
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) return const SizedBox.shrink();
    final max = maxValue ?? groups.expand((g) => g.bars).fold<double>(1, (a, b) => math.max(a, b.value));
    return SizedBox(
      height: height + 26,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (final g in groups)
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                height: height,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  for (final b in g.bars) ...[
                    Tooltip(
                      message: b.tooltip ?? '',
                      child: Container(
                        width: barWidth,
                        height: math.max(3, height * (b.value / max).clamp(0.0, 1.0)),
                        margin: const EdgeInsets.symmetric(horizontal: 1.5),
                        decoration: BoxDecoration(color: b.colour, borderRadius: const BorderRadius.vertical(top: Radius.circular(3))),
                      ),
                    ),
                  ],
                ]),
              ),
              const SizedBox(height: 6),
              // The parent reserves 26px below the bars, which one line fits and two do
              // not; letting the label wrap overflowed the chart by ~6px.
              Flexible(
                child: Text(
                  g.flag == null ? g.label : '${g.label} ${g.flag}',
                  style: labelStyle ?? context.text.labelSmall?.copyWith(color: context.mutedColor),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
              ),
            ]),
          ),
      ]),
    );
  }
}

/// One stacked column.
class TmStack {
  const TmStack(this.label, this.segments);
  final String label;
  final List<TmBar> segments;
  double get total => segments.fold(0.0, (a, b) => a + b.value);
}

/// Stacked vertical bars (delivered items by work type).
class TmStackedBarChart extends StatelessWidget {
  const TmStackedBarChart({super.key, required this.stacks, this.height = 170, this.barWidth = 46});
  final List<TmStack> stacks;
  final double height;
  final double barWidth;

  @override
  Widget build(BuildContext context) {
    if (stacks.isEmpty) return const SizedBox.shrink();
    final max = stacks.fold<double>(1, (a, s) => math.max(a, s.total));
    return SizedBox(
      height: height + 26,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (final s in stacks)
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                height: height,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    width: barWidth,
                    child: Column(mainAxisAlignment: MainAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                      for (final seg in s.segments.where((x) => x.value > 0).toList().reversed)
                        Tooltip(
                          message: seg.tooltip ?? '',
                          child: Container(height: math.max(4, height * (seg.value / max)), color: seg.colour),
                        ),
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(s.label, style: context.text.labelSmall?.copyWith(color: context.mutedColor), maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
      ]),
    );
  }
}

/// A point on the [TmLineChart].
class TmLinePoint {
  const TmLinePoint(this.label, this.value, {this.note});
  final String label;
  final double value;
  final String? note;
}

/// Simple line chart with dots, x labels every [labelEvery] points and an
/// optional dashed annotation on the first point carrying a note.
class TmLineChart extends StatelessWidget {
  const TmLineChart({super.key, required this.points, this.height = 210, this.colour = DispatchColors.green, this.labelEvery = 3, this.minValue, this.maxValue});
  final List<TmLinePoint> points;
  final double height;
  final Color colour;
  final int labelEvery;
  final double? minValue;
  final double? maxValue;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: height,
      child: CustomPaint(
        size: Size.infinite,
        painter: _LinePainter(
          points: points,
          colour: colour,
          gridColour: context.borderColor,
          textColour: context.mutedColor,
          labelEvery: labelEvery,
          minValue: minValue,
          maxValue: maxValue,
        ),
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.points,
    required this.colour,
    required this.gridColour,
    required this.textColour,
    required this.labelEvery,
    this.minValue,
    this.maxValue,
  });
  final List<TmLinePoint> points;
  final Color colour, gridColour, textColour;
  final int labelEvery;
  final double? minValue, maxValue;

  @override
  void paint(Canvas canvas, Size size) {
    const bottom = 26.0;
    final h = size.height - bottom;
    final values = points.map((p) => p.value).toList();
    final lo = minValue ?? (values.reduce(math.min) - 8).clamp(0, 100).toDouble();
    final hi = maxValue ?? math.min(100, values.reduce(math.max) + 6);
    final span = (hi - lo).abs() < 1 ? 1.0 : hi - lo;

    double x(int i) => points.length == 1 ? size.width / 2 : 8 + (size.width - 16) * i / (points.length - 1);
    double y(double v) => h - (v - lo) / span * (h - 10) - 6;

    // Baseline.
    final grid = Paint()
      ..color = gridColour
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, h), Offset(size.width, h), grid);

    // Annotation for the first noted point (e.g. the freeze-horizon week).
    final noted = points.indexWhere((p) => p.note != null && p.note!.isNotEmpty);
    if (noted >= 0) {
      final dash = Paint()
        ..color = textColour.withValues(alpha: 0.5)
        ..strokeWidth = 1;
      final ax = x(noted);
      for (double dy = 0; dy < h; dy += 7) {
        canvas.drawLine(Offset(ax, dy), Offset(ax, math.min(dy + 4, h)), dash);
      }
    }

    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final p = Offset(x(i), y(points[i].value));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeJoin = StrokeJoin.round,
    );

    for (var i = 0; i < points.length; i++) {
      final p = Offset(x(i), y(points[i].value));
      canvas.drawCircle(p, 3.6, Paint()..color = colour);
      canvas.drawCircle(
        p,
        3.6,
        Paint()
          ..color = colour
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
    }

    for (var i = 0; i < points.length; i++) {
      if (i % labelEvery != 0 && i != points.length - 1) continue;
      final tp = TextPainter(
        text: TextSpan(text: points[i].label, style: TextStyle(fontSize: 11, color: textColour)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset((x(i) - tp.width / 2).clamp(0, size.width - tp.width), h + 7));
    }
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => old.points != points || old.colour != colour;
}

/// A point on the [TmScatterChart].
class TmScatterPoint {
  const TmScatterPoint({required this.x, required this.y, required this.colour, this.tooltip});
  final double x;
  final double y;
  final Color colour;
  final String? tooltip;
}

/// Estimated vs actual scatter with a dashed parity line.
class TmScatterChart extends StatelessWidget {
  const TmScatterChart({super.key, required this.points, this.height = 230});
  final List<TmScatterPoint> points;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: height,
      child: CustomPaint(
        size: Size.infinite,
        painter: _ScatterPainter(points: points, axisColour: context.borderColor, parityColour: context.mutedColor.withValues(alpha: 0.5)),
      ),
    );
  }
}

class _ScatterPainter extends CustomPainter {
  _ScatterPainter({required this.points, required this.axisColour, required this.parityColour});
  final List<TmScatterPoint> points;
  final Color axisColour, parityColour;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 10.0;
    final maxV = points.fold<double>(1, (a, p) => math.max(a, math.max(p.x, p.y))) * 1.08;
    final w = size.width - pad * 2;
    final h = size.height - pad * 2;
    double px(double v) => pad + w * (v / maxV);
    double py(double v) => size.height - pad - h * (v / maxV);

    final axis = Paint()
      ..color = axisColour
      ..strokeWidth = 1;
    canvas.drawLine(Offset(pad, pad), Offset(pad, size.height - pad), axis);
    canvas.drawLine(Offset(pad, size.height - pad), Offset(size.width - pad, size.height - pad), axis);

    // Parity line (dashed): estimated == actual.
    final parity = Paint()
      ..color = parityColour
      ..strokeWidth = 1.2;
    var t = 0.0;
    while (t < 1) {
      final a = Offset(px(maxV * t), py(maxV * t));
      final b = Offset(px(maxV * math.min(1, t + 0.02)), py(maxV * math.min(1, t + 0.02)));
      canvas.drawLine(a, b, parity);
      t += 0.04;
    }

    for (final p in points) {
      canvas.drawCircle(Offset(px(p.x), py(p.y)), 4.2, Paint()..color = p.colour);
    }
  }

  @override
  bool shouldRepaint(covariant _ScatterPainter old) => old.points != points;
}

/// Legend row for the charts above.
class TmLegend extends StatelessWidget {
  const TmLegend(this.entries, {super.key});
  final List<({String label, Color colour})> entries;

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: Sp.lg, runSpacing: Sp.sm, children: [
      for (final e in entries) LegendDot(e.label, colour: e.colour),
    ]);
  }
}

// ─── Forms ────────────────────────────────────────────────────────────────

/// Label above a field, matching the settings forms.
class TmField extends StatelessWidget {
  const TmField({super.key, required this.label, required this.child, this.hint});
  final String label;
  final Widget child;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: context.text.labelLarge?.copyWith(color: context.mutedColor)),
      const SizedBox(height: 6),
      child,
      if (hint != null) ...[const SizedBox(height: 4), Text(hint!, style: context.text.bodySmall?.copyWith(color: context.mutedColor))],
    ]);
  }
}

/// Switch with a label to its right (settings toggles, pairing switches).
class TmSwitchRow extends StatelessWidget {
  const TmSwitchRow({super.key, required this.label, required this.value, this.onChanged, this.subtitle, this.disabledNote});
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? subtitle;
  final String? disabledNote;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Switch(value: value, onChanged: onChanged),
        const SizedBox(width: Sp.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Padding(padding: const EdgeInsets.only(top: 6), child: Text(label, style: context.text.bodyMedium)),
            if (subtitle != null) Text(subtitle!, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
            if (onChanged == null && disabledNote != null)
              Text(disabledNote!, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
          ]),
        ),
      ]),
    );
  }
}

/// Left-hand section nav used by Settings.
class TmSideNav extends StatelessWidget {
  const TmSideNav({super.key, required this.items, required this.selected, required this.onChanged});
  final List<String> items;
  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < items.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          // Material asserts that shape and borderRadius are never both given;
          // the selected row needs a border, so carry the radius in the shape
          // for both states and vary only the side.
          child: Material(
            color: i == selected ? context.panelColor : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: DispatchRadius.buttonR,
              side: i == selected ? BorderSide(color: context.borderColor) : BorderSide.none,
            ),
            child: InkWell(
              onTap: () => onChanged(i),
              borderRadius: DispatchRadius.buttonR,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Sp.md, vertical: 11),
                child: Text(
                  items[i],
                  style: context.text.bodyLarge?.copyWith(
                    color: i == selected ? context.inkColor : context.mutedColor,
                    fontWeight: i == selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ),
    ]);
  }
}

// ─── Dialog helpers ───────────────────────────────────────────────────────

/// Show a CSV export in a copyable box. Browser downloads are not available
/// from the sandboxed web build, so the export is offered as text to copy.
Future<void> showTmCsvDialog(BuildContext context, {required String title, required String csv, String? filename}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 620,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (filename != null) Text(filename, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
          const SizedBox(height: Sp.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Sp.md),
              decoration: BoxDecoration(
                color: context.isDark ? const Color(0xFF111B2E) : DispatchColors.surfaceAlt,
                borderRadius: DispatchRadius.cardR,
                border: Border.all(color: context.borderColor),
              ),
              child: SingleChildScrollView(child: SelectableText(csv, style: DispatchTheme.numeric(size: 12, weight: FontWeight.w500, color: context.inkColor))),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        FilledButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: csv));
            if (context.mounted) Navigator.of(context).pop();
          },
          child: const Text('Copy to clipboard'),
        ),
      ],
    ),
  );
}

/// Standard confirmation dialog. Returns true when confirmed.
Future<bool> showTmConfirm(BuildContext context, {required String title, required String message, String confirmLabel = 'Confirm', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Text(message)),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: danger ? FilledButton.styleFrom(backgroundColor: DispatchColors.red) : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Snackbar with the house style.
void tmToast(BuildContext context, String message, {bool bad = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: bad ? DispatchColors.red : DispatchColors.ink,
      behavior: SnackBarBehavior.floating,
      width: 420,
    ),
  );
}

/// CSV field quoting for client-side exports (the skills matrix).
String csvCell(Object? v) {
  final s = (v ?? '').toString();
  return s.contains(RegExp('[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
}

String csvLine(List<Object?> cells) => cells.map(csvCell).join(',');

// ─── Add leave (ADM-05) ───────────────────────────────────────────────────

/// One entry in the person picker of [showTmAddLeave].
typedef TmPersonOption = ({int id, String name});

/// Add leave, training, sickness or other absence. Only the type is stored —
/// never a reason (ADM-05). Returns true when a record was created.
Future<bool> showTmAddLeave(BuildContext context, {required List<TmPersonOption> people, int? personId}) async {
  final r = await showDialog<bool>(context: context, builder: (context) => _TmAddLeaveDialog(people: people, personId: personId));
  return r ?? false;
}

class _TmAddLeaveDialog extends StatefulWidget {
  const _TmAddLeaveDialog({required this.people, this.personId});
  final List<TmPersonOption> people;
  final int? personId;

  @override
  State<_TmAddLeaveDialog> createState() => _TmAddLeaveDialogState();
}

class _TmAddLeaveDialogState extends State<_TmAddLeaveDialog> {
  int? _personId;
  String _type = 'leave';
  DateTime? _from;
  DateTime? _to;
  bool _halfDays = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _personId = widget.personId ?? (widget.people.isNotEmpty ? widget.people.first.id : null);
  }

  Future<void> _pick(bool isFrom) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: (isFrom ? _from : _to) ?? _from ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
    );
    if (d == null) return;
    setState(() {
      if (isFrom) {
        _from = d;
        if (_to == null || _to!.isBefore(d)) _to = d;
      } else {
        _to = d;
      }
    });
  }

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String _label(DateTime? d) {
    if (d == null) return 'Choose a date';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  Future<void> _save() async {
    if (_personId == null || _from == null || _to == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.post('people.php', 'add_availability', {
        'person_id': _personId,
        'from_date': _iso(_from!),
        'to_date': _iso(_to!),
        'type': _type,
        'fraction': _halfDays ? 0.5 : 1.0,
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add leave'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.people.length > 1) ...[
              TmField(
                label: 'Person',
                child: DropdownButtonFormField<int>(
                  initialValue: _personId,
                  items: [for (final p in widget.people) DropdownMenuItem(value: p.id, child: Text(p.name))],
                  onChanged: (v) => setState(() => _personId = v),
                ),
              ),
              const SizedBox(height: Sp.md),
            ],
            TmField(
              label: 'Type',
              child: DropdownButtonFormField<String>(
                initialValue: _type,
                items: const [
                  DropdownMenuItem(value: 'leave', child: Text('Leave')),
                  DropdownMenuItem(value: 'training', child: Text('Training')),
                  DropdownMenuItem(value: 'sickness', child: Text('Sickness')),
                  DropdownMenuItem(value: 'other', child: Text('Other')),
                ],
                onChanged: (v) => setState(() => _type = v ?? 'leave'),
              ),
            ),
            const SizedBox(height: Sp.md),
            Row(children: [
              Expanded(
                child: TmField(
                  label: 'From',
                  child: SecondaryButton(_label(_from), icon: Icons.calendar_today_outlined, expand: true, onPressed: () => _pick(true)),
                ),
              ),
              const SizedBox(width: Sp.md),
              Expanded(
                child: TmField(
                  label: 'To',
                  child: SecondaryButton(_label(_to), icon: Icons.calendar_today_outlined, expand: true, onPressed: () => _pick(false)),
                ),
              ),
            ]),
            const SizedBox(height: Sp.sm),
            TmSwitchRow(label: 'Half days', value: _halfDays, onChanged: (v) => setState(() => _halfDays = v)),
            const SizedBox(height: Sp.md),
            const TmInfoBox(
              'Only the type of absence is stored — never a reason, a medical detail or a note. People who can see the schedule see the dates and the type.',
            ),
            if (_error != null) TmInlineError(_error!),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        PrimaryButton('Add leave', busy: _busy, onPressed: (_personId == null || _from == null || _to == null) ? null : _save),
      ],
    );
  }
}

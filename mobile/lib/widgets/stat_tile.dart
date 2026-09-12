import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Tone of a footnote/delta: colours the footnote text and icon.
enum StatTone { neutral, good, warn, bad, accent }

Color statToneColor(BuildContext context, StatTone t) => switch (t) {
      StatTone.good => DispatchColors.green,
      StatTone.warn => DispatchColors.amber,
      StatTone.bad => DispatchColors.red,
      StatTone.accent => DispatchColors.orange,
      StatTone.neutral => context.mutedColor,
    };

/// KPI tile: label, big Manrope value, optional unit text beside it, and a
/// footnote with a tone (e.g. '↗ 2 more than last fortnight').
///
/// Tiles are borderless inside a [StatRow] (which draws the dividers); set
/// [bordered] when using one standalone.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.footnote,
    this.tone = StatTone.neutral,
    this.footnoteIcon,
    this.bordered = false,
    this.onTap,
  });

  final String label;
  final String value;
  /// Text shown after the value at body size, e.g. '3 due this week', 'target 80–90%'.
  final String? unit;
  final String? footnote;
  final StatTone tone;
  /// Defaults by tone: good → trending up, bad → trending down, warn → warning, neutral → dash.
  final IconData? footnoteIcon;
  final bool bordered;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final toneColor = statToneColor(context, tone);
    final icon = footnoteIcon ??
        switch (tone) {
          StatTone.good => Icons.north_east_rounded,
          StatTone.bad => Icons.south_east_rounded,
          StatTone.warn => Icons.warning_amber_rounded,
          StatTone.accent => Icons.bolt_rounded,
          StatTone.neutral => Icons.remove_rounded,
        };
    Widget body = Padding(
      padding: const EdgeInsets.all(Sp.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
        const SizedBox(height: Sp.sm),
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          // Most values are a number or two, but some are a phrase ('w/c 28
          // Sep', 'Not on rota') that can be wider than a tile in a four-up
          // row. Keep the value at its designed size and let it give way.
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DispatchTheme.numeric(size: 34, weight: FontWeight.w800, color: context.inkColor, height: 1),
            ),
          ),
          if (unit != null) ...[
            const SizedBox(width: Sp.sm),
            Flexible(child: Text(unit!, style: context.text.bodyLarge?.copyWith(color: context.mutedColor), overflow: TextOverflow.ellipsis)),
          ],
        ]),
        if (footnote != null) ...[
          const SizedBox(height: Sp.sm),
          Row(children: [
            Icon(icon, size: 15, color: toneColor),
            const SizedBox(width: 4),
            Flexible(child: Text(footnote!, style: context.text.labelMedium?.copyWith(color: toneColor), overflow: TextOverflow.ellipsis)),
          ]),
        ],
      ]),
    );
    if (bordered) {
      body = Container(
        decoration: BoxDecoration(color: context.panelColor, borderRadius: DispatchRadius.panelR, border: Border.all(color: context.borderColor)),
        child: body,
      );
    }
    if (onTap == null) return body;
    return InkWell(onTap: onTap, borderRadius: bordered ? DispatchRadius.panelR : BorderRadius.zero, child: body);
  }
}

/// A bordered panel holding tiles side by side with 1px vertical dividers;
/// wraps to a 2-column grid when narrow.
class StatRow extends StatelessWidget {
  const StatRow({super.key, required this.tiles, this.minTileWidth = 240});
  final List<StatTile> tiles;
  final double minTileWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final perRow = (c.maxWidth / minTileWidth).floor().clamp(1, tiles.length);
      final rows = <List<StatTile>>[];
      for (var i = 0; i < tiles.length; i += perRow) {
        rows.add(tiles.sublist(i, (i + perRow).clamp(0, tiles.length)));
      }
      return Container(
        decoration: BoxDecoration(color: context.panelColor, borderRadius: DispatchRadius.panelR, border: Border.all(color: context.borderColor)),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          for (var r = 0; r < rows.length; r++) ...[
            if (r > 0) const Divider(),
            IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var i = 0; i < rows[r].length; i++) ...[
                  if (i > 0) VerticalDivider(width: 1, thickness: 1, color: context.borderColor),
                  Expanded(child: rows[r][i]),
                ],
                // Fill the last row so tiles keep equal width.
                for (var i = rows[r].length; i < perRow; i++) const Expanded(child: SizedBox()),
              ]),
            ),
          ],
        ]),
      );
    });
  }
}

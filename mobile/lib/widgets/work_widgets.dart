import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'widgets.dart';

/// Shared pieces for the Overview, Pipeline, Work item, Estimate and Add work
/// screens. Everything here is new (no shell file is edited): row parsing that
/// mirrors the API's WorkItemRow, a responsive table, small charts and the
/// tinted note card used by the watch list.

// ─── Parsing ──────────────────────────────────────────────────────────────

/// A person as the API returns them inside another record: `{person_id|id,
/// name, initials, colour}`.
class PersonLite {
  const PersonLite({required this.id, required this.name, this.initials, this.colourHex});
  final int id;
  final String name;
  final String? initials;
  final String? colourHex;

  factory PersonLite.fromJson(Map<String, dynamic> j) => PersonLite(
        id: asIntOr(j['person_id'] ?? j['id'], 0),
        name: asStrOr(j['name'], ''),
        initials: asStr(j['initials']),
        colourHex: asStr(j['colour']),
      );

  String get firstName => name.trim().split(RegExp(r'\s+')).first;

  Person toPerson() => Person(id: id, name: name, initials: initials, colourHex: colourHex);
}

/// One required skill on a work item (`{skill_id, name, min_proficiency}` plus
/// the coverage fields the item detail adds).
class SkillNeed {
  const SkillNeed({
    required this.skillId,
    required this.name,
    this.minProficiency = 2,
    this.effortDays,
    this.coverageCount,
    this.coverageLabel,
    this.singlePoint = false,
    this.gap = false,
    this.qualified = const [],
  });

  final int skillId;
  final String name;
  final int minProficiency;
  final double? effortDays;
  final int? coverageCount;
  final String? coverageLabel;
  final bool singlePoint;
  final bool gap;
  final List<PersonLite> qualified;

  factory SkillNeed.fromJson(Map<String, dynamic> j) => SkillNeed(
        skillId: asIntOr(j['skill_id'] ?? j['id'], 0),
        name: asStrOr(j['name'] ?? j['skill_name'], ''),
        minProficiency: asIntOr(j['min_proficiency'], 2),
        effortDays: asDouble(j['effort_days']),
        coverageCount: asInt(j['coverage_count']),
        coverageLabel: asStr(j['coverage_label']),
        singlePoint: asBool(j['single_point']),
        gap: asBool(j['gap']),
        qualified: (j['qualified'] as List?)?.whereType<Map>().map((e) => PersonLite.fromJson(Map<String, dynamic>.from(e))).toList() ?? const [],
      );
}

/// The API's WorkItemRow, read straight from the raw map so that every field
/// the endpoints send is available without touching the shared models.
class WorkRow {
  WorkRow(this.raw);
  final Map<String, dynamic> raw;

  int get id => asIntOr(raw['id'], 0);
  String get ref => asStrOr(raw['ref'], '');
  String get title => asStrOr(raw['title'], '');
  String? get summary => asStr(raw['summary']);
  int? get workTypeId => asInt(raw['work_type_id']);
  String get typeName => asStrOr(raw['type_name'], '');
  String? get typeColour => asStr(raw['type_colour']);
  String get typePolicy => asStrOr(raw['type_policy'], 'planned');
  String? get sizeStamp => asStr(raw['size_stamp']);
  String? get sizeName => asStr(raw['size_name']);
  bool get isCustom => asBool(raw['is_custom']);
  double? get customEffortDays => asDouble(raw['custom_effort_days']);
  String get status => asStrOr(raw['status'], 'draft');
  String? get health => asStr(raw['health']);
  double? get priorityScore => asDouble(raw['priority_score']);
  int get benefitValue => asIntOr(raw['benefit_value'], 0);
  double? get romLow => asDouble(raw['rom_low']);
  double? get romHigh => asDouble(raw['rom_high']);
  String get romUnit => asStrOr(raw['rom_unit'], 'days');
  bool get hasEstimate => asBool(raw['has_estimate']);
  double? get estimateLikely => asDouble(raw['estimate_likely']);
  int? get estimateClass => asInt(raw['estimate_class']);
  DateTime? get neededBy => asDate(raw['needed_by']);
  DateTime? get earliestStart => asDate(raw['earliest_start']);
  DateTime? get plannedFrom => asDate(raw['planned_from']);
  DateTime? get plannedTo => asDate(raw['planned_to']);
  DateTime? get due => asDate(raw['due'] ?? raw['needed_by'] ?? raw['planned_to']);
  String? get dueLabel => asStr(raw['due_label']);
  String? get statusLabel => asStr(raw['status_label']);
  String? get requestedBy => asStr(raw['requested_by']);
  String? get sponsor => asStr(raw['sponsor']);
  int get progressPct => asIntOr(raw['progress_pct'], 0);
  List<String> get tags => asStrList(raw['tags']);
  DateTime? get createdAt => asDate(raw['created_at']);
  DateTime? get updatedAt => asDate(raw['updated_at']);

  List<SkillNeed> get skills =>
      (raw['skills'] as List?)?.whereType<Map>().map((e) => SkillNeed.fromJson(Map<String, dynamic>.from(e))).toList() ?? const [];

  List<PersonLite> get assignees =>
      (raw['assignees'] as List?)?.whereType<Map>().map((e) => PersonLite.fromJson(Map<String, dynamic>.from(e))).toList() ?? const [];

  /// Health wins over status while the item is live, so a scheduled item that
  /// is at risk reads 'At risk'.
  String get displayStatus {
    final h = health;
    if ((status == 'scheduled' || status == 'in_progress') && h != null && h.isNotEmpty && h != 'on_track') return h;
    return status;
  }

  /// '28–52' / '36' / '—'
  String get romLabel => fmtRange(romLow, romHigh);
}

/// '28–52', '28+', '36', '—' — an effort range without its unit.
String fmtRange(double? low, double? high) {
  String n(double d) => d == d.roundToDouble() ? d.toInt().toString() : d.toStringAsFixed(1);
  if (low == null && high == null) return '—';
  if (low == null) return n(high!);
  if (high == null) return n(low);
  if (low == high) return n(low);
  return '${n(low)}–${n(high)}';
}

/// '36 days' / '0.5 days' with no rounding surprises.
String fmtDaysShort(double? d, {String unit = 'days'}) {
  if (d == null) return '—';
  final s = d == d.roundToDouble() ? d.toInt().toString() : d.toStringAsFixed(1);
  return '$s $unit';
}

// ─── Small building blocks ────────────────────────────────────────────────

/// Overlapping avatars for a list of assignees; empty shows a dash.
class AssigneeAvatars extends StatelessWidget {
  const AssigneeAvatars(this.people, {super.key, this.size = 26, this.max = 3});
  final List<PersonLite> people;
  final double size;
  final int max;

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) return Text('—', style: context.text.bodyMedium?.copyWith(color: context.mutedColor));
    return AvatarStack(people.map((p) => p.toPerson()).toList(), size: size, max: max);
  }
}

/// Required-skill chips, truncated with a '+N' chip.
class SkillChips extends StatelessWidget {
  const SkillChips(this.skills, {super.key, this.max = 2, this.compact = true});
  final List<SkillNeed> skills;
  final int max;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (skills.isEmpty) return Text('—', style: context.text.bodyMedium?.copyWith(color: context.mutedColor));
    final shown = skills.take(max).toList();
    final rest = skills.length - shown.length;
    return Wrap(spacing: Sp.xs, runSpacing: Sp.xs, children: [
      for (final s in shown) ToneChip(s.name, compact: compact),
      if (rest > 0)
        Tooltip(
          message: skills.skip(max).map((s) => s.name).join(', '),
          child: ToneChip('+$rest', tone: 'info', compact: compact),
        ),
    ]);
  }
}

/// Label / value line used in the Plan and benefit panels.
class MetaRow extends StatelessWidget {
  const MetaRow(this.label, {super.key, this.value, this.child, this.labelWidth = 132});
  final String label;
  final String? value;
  final Widget? child;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: labelWidth,
          child: Text(label, style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
        ),
        const SizedBox(width: Sp.sm),
        Expanded(child: child ?? Text(value ?? '—', style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
      ]),
    );
  }
}

/// A tinted, bordered note — amber for a warning, red for something breaking.
/// Colour is never the only carrier: each card leads with an icon and a bold
/// title, and the tone is named in the semantics label.
class NoteCard extends StatelessWidget {
  const NoteCard({super.key, required this.title, this.body, this.suggestion, this.tone = 'warn', this.icon, this.onTap});
  final String title;
  final String? body;
  final String? suggestion;
  final String tone; // warn | bad | info
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colour = switch (tone) {
      'bad' => DispatchColors.red,
      'info' => DispatchColors.typeBlue,
      _ => DispatchColors.amber,
    };
    final toneWord = switch (tone) { 'bad' => 'Problem', 'info' => 'Note', _ => 'Warning' };
    final icn = icon ?? switch (tone) { 'bad' => Icons.error_outline_rounded, 'info' => Icons.info_outline_rounded, _ => Icons.warning_amber_rounded };
    return Semantics(
      button: onTap != null,
      label: '$toneWord: $title',
      child: DispatchCard(
        onTap: onTap,
        tint: DispatchColors.tint(colour, opacity: context.isDark ? 0.16 : 0.10),
        accent: colour,
        padding: const EdgeInsets.all(Sp.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icn, size: 18, color: colour),
          const SizedBox(width: Sp.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: context.text.titleSmall),
              if (body != null && body!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(body!, style: context.text.bodySmall?.copyWith(color: context.inkColor)),
              ],
              if (suggestion != null && suggestion!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(suggestion!, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

// ─── Responsive table ─────────────────────────────────────────────────────

/// A column in a [DispatchTable].
class TableCol {
  const TableCol(this.label, {this.width, this.flex = 1, this.alignRight = false});
  final String label;

  /// Fixed width in logical pixels; when null the column flexes.
  final double? width;
  final int flex;
  final bool alignRight;
}

/// Dense header + rows table with a tinted header, hairline dividers and an
/// optional row tap. Screens swap it for cards below ~800px.
class DispatchTable extends StatelessWidget {
  const DispatchTable({
    super.key,
    required this.columns,
    required this.rows,
    this.onRowTap,
    this.rowSemantics,
    this.minWidth = 720,
  });

  final List<TableCol> columns;
  final List<List<Widget>> rows;
  final void Function(int index)? onRowTap;
  final String Function(int index)? rowSemantics;
  final double minWidth;

  Widget _cell(BuildContext context, TableCol c, Widget child) {
    final aligned = Align(alignment: c.alignRight ? Alignment.centerRight : Alignment.centerLeft, child: child);
    return c.width != null ? SizedBox(width: c.width, child: aligned) : Expanded(flex: c.flex, child: aligned);
  }

  @override
  Widget build(BuildContext context) {
    final header = Container(
      color: context.scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: Sp.md, vertical: Sp.sm),
      child: Row(children: [
        for (final c in columns)
          _cell(context, c, Text(c.label, style: context.text.labelMedium?.copyWith(color: context.mutedColor))),
      ]),
    );

    final body = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      final cells = rows[i];
      Widget row = Padding(
        padding: const EdgeInsets.symmetric(horizontal: Sp.md, vertical: Sp.md),
        child: Row(children: [
          for (var c = 0; c < columns.length; c++) _cell(context, columns[c], c < cells.length ? cells[c] : const SizedBox.shrink()),
        ]),
      );
      if (onRowTap != null) {
        final idx = i;
        row = InkWell(onTap: () => onRowTap!(idx), child: row);
        row = Semantics(button: true, label: rowSemantics?.call(idx), child: row);
      }
      body.add(row);
      if (i < rows.length - 1) body.add(Divider(height: 1, color: context.borderColor));
    }

    final table = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, ...body]);

    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth >= minWidth) return table;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(width: minWidth, child: table),
      );
    });
  }
}

// ─── Charts ───────────────────────────────────────────────────────────────

/// One segment of a stacked bar.
class BarSegment {
  const BarSegment({required this.label, required this.value, required this.colour, this.hatched = false});
  final String label;
  final double value;
  final Color colour;
  final bool hatched;
}

/// Vertical stacked bars with a caption under each — 'Planned effort by work
/// type'. Bars share one scale so weeks are comparable.
class StackedWeekBars extends StatelessWidget {
  const StackedWeekBars({super.key, required this.weeks, this.height = 120});

  /// One entry per week: its caption and the segments bottom-to-top.
  final List<({String label, List<BarSegment> segments})> weeks;
  final double height;

  @override
  Widget build(BuildContext context) {
    var max = 0.0;
    for (final w in weeks) {
      final total = w.segments.fold<double>(0, (a, s) => a + s.value);
      if (total > max) max = total;
    }
    if (max <= 0) max = 1;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final w in weeks)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Tooltip(
                  message: [
                    w.label,
                    ...w.segments.where((s) => s.value > 0).map((s) => '${s.label} ${fmtDaysShort(s.value)}'),
                  ].join('\n'),
                  child: SizedBox(
                    height: height,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        for (final s in w.segments.reversed)
                          if (s.value > 0)
                            Container(
                              height: (s.value / max) * height,
                              decoration: BoxDecoration(color: s.colour),
                            ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Sp.sm),
                Text(w.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.labelSmall),
              ]),
            ),
          ),
      ],
    );
  }
}

/// Horizontal stacked bar — effort by skill, benefit by type.
class StackedBar extends StatelessWidget {
  const StackedBar({super.key, required this.segments, this.height = 26, this.radius = 6});
  final List<BarSegment> segments;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final total = segments.fold<double>(0, (a, s) => a + s.value);
    if (total <= 0) {
      return Container(
        height: height,
        decoration: BoxDecoration(color: context.scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(radius)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        height: height,
        child: Row(children: [
          for (final s in segments)
            if (s.value > 0)
              Expanded(
                flex: (s.value / total * 1000).round().clamp(1, 1000),
                child: Tooltip(message: '${s.label} ${fmtDaysShort(s.value)}', child: Container(color: s.colour)),
              ),
        ]),
      ),
    );
  }
}

/// The optimistic → pessimistic gradient bar on the ROM panel, with the
/// most-likely point marked.
class RangeGradientBar extends StatelessWidget {
  const RangeGradientBar({super.key, required this.low, required this.likely, required this.high, this.height = 10});
  final double? low, likely, high;
  final double height;

  @override
  Widget build(BuildContext context) {
    final fraction = (low != null && high != null && likely != null && high! > low!)
        ? ((likely! - low!) / (high! - low!)).clamp(0.0, 1.0)
        : 0.5;
    return LayoutBuilder(builder: (context, box) {
      return SizedBox(
        height: height + 6,
        child: Stack(children: [
          Container(
            height: height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(height / 2),
              gradient: LinearGradient(colors: [
                DispatchColors.tint(DispatchColors.typeBlue, opacity: 0.35),
                DispatchColors.ink,
                DispatchColors.orange,
              ]),
            ),
          ),
          Positioned(
            left: (box.maxWidth - 3) * fraction,
            child: Container(width: 3, height: height + 6, color: context.panelColor),
          ),
        ]),
      );
    });
  }
}

/// Level square + minimum-level caption used by the required-skills panel.
class SkillLevelBadge extends StatelessWidget {
  const SkillLevelBadge(this.level, {super.key});
  final int level;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: DispatchColors.tint(DispatchColors.typeBlue, opacity: context.isDark ? 0.3 : 0.14),
        borderRadius: DispatchRadius.chipR,
      ),
      child: Text('$level', style: DispatchTheme.numeric(size: 13, color: DispatchColors.typeBlue)),
    );
  }
}

/// Estimate-class tolerance (EST-03). The API sends a `class_label` too, but
/// it arrives double-encoded from PHP, so the label is built here instead.
int toleranceForClass(int? c) => switch (c) { 5 => 50, 4 => 40, 3 => 30, 2 => 15, 1 => 5, _ => 30 };

/// '±30%'
String classToleranceLabel(int? c) => '±${toleranceForClass(c)}%';

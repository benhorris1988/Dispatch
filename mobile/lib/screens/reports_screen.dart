import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/api.dart';
import '../services/format.dart';
import '../shell/app_shell.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/team_widgets.dart';
import '../widgets/widgets.dart';

/// Reports (REP-*, spec 9.4.11). Four panels, each with an in-app definition:
/// plan stability, load and utilisation against the target band, estimate
/// accuracy by size, and delivered items by work type.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  static const _tabs = ['4 weeks', '12 weeks', '12 months'];
  static const _ranges = ['4w', '12w', '12m'];

  int _tab = 1;
  bool _loading = true;
  String? _error;
  _Reports? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await Api.post('reports.php', 'get', {'range': _ranges[_tab]});
      if (!mounted) return;
      setState(() {
        _data = _Reports.fromJson(r);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _export() async {
    final report = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Export a report'),
        children: [
          for (final r in const [
            (key: 'stability', label: 'Plan stability'),
            (key: 'load', label: 'Load and utilisation'),
            (key: 'accuracy', label: 'Estimate accuracy'),
            (key: 'delivered', label: 'Delivered by work type'),
          ])
            SimpleDialogOption(onPressed: () => Navigator.of(context).pop(r.key), child: Text(r.label, style: context.text.bodyLarge)),
        ],
      ),
    );
    if (report == null) return;
    try {
      final r = await Api.post('reports.php', 'export_csv', {'report': report, 'range': _ranges[_tab]});
      if (!mounted) return;
      await showTmCsvDialog(context, title: 'Export report', csv: asStrOr(r['csv'], ''), filename: asStr(r['filename']));
    } on ApiException catch (e) {
      if (mounted) tmToast(context, e.message, bad: true);
    }
  }

  Future<void> _scheduleEmail() async {
    await showDialog<void>(context: context, builder: (context) => const _ScheduleEmailDialog());
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return PageBody(
      onRefresh: _load,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(
          title: 'Reports',
          subtitle: d == null ? 'Updated nightly' : dotJoin(['${d.workspaceName} team', d.rangeLabel, 'updated nightly']),
          actions: [
            SegmentedTabs(
              labels: _tabs,
              selected: _tab,
              onChanged: (i) {
                setState(() => _tab = i);
                _load();
              },
            ),
            SecondaryButton('Schedule email', icon: Icons.mail_outline_rounded, onPressed: _scheduleEmail),
            SecondaryButton('Export', icon: Icons.file_download_outlined, onPressed: d == null ? null : _export),
          ],
        ),
        const SizedBox(height: Sp.xl),
        if (_loading)
          const _ReportsSkeleton()
        else if (_error != null)
          ErrorState(title: 'We could not load the reports', message: _error, onRetry: _load)
        else if (d == null)
          const EmptyState(icon: Icons.insights_outlined, title: 'No reports yet', message: 'Reports appear once a plan has been committed.')
        else
          LayoutBuilder(builder: (context, c) {
            final panels = [
              _StabilityPanel(data: d),
              _LoadPanel(data: d),
              _AccuracyPanel(data: d),
              _DeliveredPanel(data: d),
            ];
            if (c.maxWidth < 1000) {
              return Column(children: [
                for (final p in panels) Padding(padding: const EdgeInsets.only(bottom: Sp.lg), child: p),
              ]);
            }
            return Column(children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: panels[0]),
                const SizedBox(width: Sp.lg),
                Expanded(child: panels[1]),
              ]),
              const SizedBox(height: Sp.lg),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: panels[2]),
                const SizedBox(width: Sp.lg),
                Expanded(child: panels[3]),
              ]),
            ]);
          }),
      ]),
    );
  }
}

// ─── Panels ───────────────────────────────────────────────────────────────

/// Panel with an info-icon title and a chip on the right.
class _ReportPanel extends StatelessWidget {
  const _ReportPanel({required this.title, this.subtitle, this.definition, this.chip, required this.child});
  final String title;
  final String? subtitle;
  final String? definition;
  final Widget? chip;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: context.panelColor, borderRadius: DispatchRadius.panelR, border: Border.all(color: context.borderColor)),
      padding: const EdgeInsets.all(Sp.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: TmMetricTitle(title: title, subtitle: subtitle, definition: definition)),
          if (chip != null) ...[const SizedBox(width: Sp.sm), chip!],
        ]),
        const SizedBox(height: Sp.lg),
        child,
      ]),
    );
  }
}

class _StabilityPanel extends StatelessWidget {
  const _StabilityPanel({required this.data});
  final _Reports data;

  @override
  Widget build(BuildContext context) {
    final weeks = data.stability;
    // Annotate the week the freeze horizon was introduced, when the API says so.
    final points = [
      for (final w in weeks)
        TmLinePoint(w.label, w.indexPct, note: (w.note?.toLowerCase().contains('freeze horizon') ?? false) ? w.note : null),
    ];
    final notes = weeks.where((w) => w.note != null && w.note!.isNotEmpty).toList();

    return _ReportPanel(
      title: 'Plan stability',
      subtitle: '% of committed assignment-days unchanged week on week',
      definition: data.definitions['stability'],
      chip: ToneChip('${data.thisWeekIndex.round()}% this week', tone: data.thisWeekIndex >= 85 ? 'ok' : 'warn'),
      child: weeks.isEmpty
          ? const EmptyState(icon: Icons.show_chart_rounded, title: 'No stability history', message: 'Commit a plan to start the trend.', compact: true)
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TmLineChart(points: points, height: 210, colour: DispatchColors.green, labelEvery: weeks.length > 8 ? 3 : 1),
              const SizedBox(height: Sp.md),
              for (final n in notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('${n.label}: ${n.note}', style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
                ),
            ]),
    );
  }
}

class _LoadPanel extends StatelessWidget {
  const _LoadPanel({required this.data});
  final _Reports data;

  static const _planned = Color(0xFFAFC5EC);

  @override
  Widget build(BuildContext context) {
    final weeks = data.load;
    return _ReportPanel(
      title: 'Load and utilisation',
      subtitle: 'Team average, planned vs actual',
      definition: data.definitions['load'],
      chip: ToneChip('Target band ${data.targetMin}–${data.targetMax}%', tone: 'warn'),
      child: weeks.isEmpty
          ? const EmptyState(icon: Icons.bar_chart_rounded, title: 'No load history', message: 'Load appears once capacity has been derived.', compact: true)
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TmGroupedBarChart(
                height: 210,
                barWidth: 9,
                maxValue: 110,
                groups: [
                  for (final w in weeks)
                    TmBarGroup(
                      w.label,
                      [
                        TmBar(w.plannedPct, _planned, tooltip: '${w.label} planned ${w.plannedPct.round()}%'),
                        TmBar(w.actualPct, w.above90 ? DispatchColors.red : DispatchColors.ink,
                            tooltip: '${w.label} actual ${w.actualPct.round()}%${w.above90 ? ' — above 90%' : ''}'),
                      ],
                      flag: w.above90 ? '!' : null,
                    ),
                ],
              ),
              const SizedBox(height: Sp.md),
              const TmLegend([
                (label: 'Planned', colour: _planned),
                (label: 'Actual (timesheets)', colour: DispatchColors.ink),
                (label: 'Above 90% (!)', colour: DispatchColors.red),
              ]),
            ]),
    );
  }
}

class _AccuracyPanel extends StatelessWidget {
  const _AccuracyPanel({required this.data});
  final _Reports data;

  @override
  Widget build(BuildContext context) {
    final a = data.accuracy;
    return _ReportPanel(
      title: 'Estimate accuracy',
      subtitle: 'Estimated vs actual days, delivered items',
      definition: data.definitions['accuracy'],
      chip: ToneChip('${a.n} items'),
      child: a.points.isEmpty
          ? const EmptyState(icon: Icons.scatter_plot_outlined, title: 'Nothing delivered yet', message: 'Accuracy appears once items are delivered with actual effort.', compact: true)
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TmScatterChart(
                height: 230,
                points: [
                  for (final p in a.points)
                    TmScatterPoint(
                      x: p.estimated,
                      y: p.actual,
                      colour: p.group == 'lc' ? DispatchColors.orange : DispatchColors.ink,
                      tooltip: '${p.ref}: estimated ${fmtDays(p.estimated)}, actual ${fmtDays(p.actual)}',
                    ),
                ],
              ),
              const SizedBox(height: Sp.sm),
              Row(children: [
                Expanded(child: Text('Estimated days →', style: context.text.bodySmall?.copyWith(color: context.mutedColor))),
                Text('Above the line = ran over', style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
              ]),
              const SizedBox(height: Sp.md),
              TmLegend([
                (label: 'Small / Medium · median ×${a.medianSm.toStringAsFixed(2)} (${a.nSm})', colour: DispatchColors.ink),
                (label: 'Large / Custom · median ×${a.medianLc.toStringAsFixed(2)} (${a.nLc})', colour: DispatchColors.orange),
              ]),
            ]),
    );
  }
}

class _DeliveredPanel extends StatelessWidget {
  const _DeliveredPanel({required this.data});
  final _Reports data;

  @override
  Widget build(BuildContext context) {
    final months = data.delivered;
    final types = <String, Color>{};
    for (final m in months) {
      for (final t in m.byType) {
        types.putIfAbsent(t.type, () => DispatchColors.parseHex(t.colour));
      }
    }
    final delta = data.cycleTimeDeltaPct;
    return _ReportPanel(
      title: 'Delivered by work type',
      subtitle: 'Items per month',
      definition: data.definitions['delivered'],
      chip: delta == null
          ? null
          : ToneChip('Cycle time ${delta <= 0 ? '↓' : '↑'} ${delta.abs().round()}%', tone: delta <= 0 ? 'ok' : 'bad'),
      child: months.isEmpty
          ? const EmptyState(icon: Icons.inventory_2_outlined, title: 'Nothing delivered yet', message: 'Delivered items appear here month by month.', compact: true)
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TmStackedBarChart(
                height: 200,
                barWidth: 42,
                stacks: [
                  for (final m in months)
                    TmStack(m.label, [
                      for (final t in m.byType)
                        TmBar(t.count.toDouble(), DispatchColors.parseHex(t.colour), tooltip: '${m.label}: ${t.count} ${t.type.toLowerCase()}'),
                    ]),
                ],
              ),
              const SizedBox(height: Sp.md),
              TmLegend([for (final e in types.entries) (label: e.key, colour: e.value)]),
            ]),
    );
  }
}

// ─── Schedule email ───────────────────────────────────────────────────────

class _ScheduleEmailDialog extends StatefulWidget {
  const _ScheduleEmailDialog();

  @override
  State<_ScheduleEmailDialog> createState() => _ScheduleEmailDialogState();
}

class _ScheduleEmailDialogState extends State<_ScheduleEmailDialog> {
  String _cadence = 'weekly';
  final Set<String> _reports = {'stability', 'load'};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Schedule email'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TmField(
            label: 'How often',
            child: DropdownButtonFormField<String>(
              initialValue: _cadence,
              items: const [
                DropdownMenuItem(value: 'weekly', child: Text('Every Monday morning')),
                DropdownMenuItem(value: 'fortnightly', child: Text('Every other Monday')),
                DropdownMenuItem(value: 'monthly', child: Text('First working day of the month')),
              ],
              onChanged: (v) => setState(() => _cadence = v ?? _cadence),
            ),
          ),
          const SizedBox(height: Sp.md),
          Text('Reports to include', style: context.text.labelLarge?.copyWith(color: context.mutedColor)),
          for (final r in const [
            (key: 'stability', label: 'Plan stability'),
            (key: 'load', label: 'Load and utilisation'),
            (key: 'accuracy', label: 'Estimate accuracy'),
            (key: 'delivered', label: 'Delivered by work type'),
          ])
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _reports.contains(r.key),
              onChanged: (v) => setState(() => v == true ? _reports.add(r.key) : _reports.remove(r.key)),
              title: Text(r.label, style: context.text.bodyMedium),
            ),
          const SizedBox(height: Sp.sm),
          const TmInfoBox('Scheduled email is not wired up in this build. The settings you choose here are not saved yet.'),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        PrimaryButton('Schedule', onPressed: () {
          Navigator.of(context).pop();
          tmToast(context, 'Scheduled email is not available in this build');
        }),
      ],
    );
  }
}

// ─── Skeleton ─────────────────────────────────────────────────────────────

class _ReportsSkeleton extends StatelessWidget {
  const _ReportsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(children: const [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: SkeletonPanel(rows: 6)),
        SizedBox(width: Sp.lg),
        Expanded(child: SkeletonPanel(rows: 6)),
      ]),
      SizedBox(height: Sp.lg),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: SkeletonPanel(rows: 6)),
        SizedBox(width: Sp.lg),
        Expanded(child: SkeletonPanel(rows: 6)),
      ]),
    ]);
  }
}

// ─── Parsing (reports.php get) ────────────────────────────────────────────

class _StabilityWeek {
  const _StabilityWeek({required this.label, required this.indexPct, this.note, this.changesInsideFreeze = 0});
  final String label;
  final double indexPct;
  final String? note;
  final int changesInsideFreeze;

  factory _StabilityWeek.fromJson(Map<String, dynamic> j) => _StabilityWeek(
        label: asStrOr(j['label'], ''),
        indexPct: asDoubleOr(j['index_pct'], 0),
        note: asStr(j['note']),
        changesInsideFreeze: asIntOr(j['changes_inside_freeze'], 0),
      );
}

class _LoadWeek {
  const _LoadWeek({required this.label, this.plannedPct = 0, this.actualPct = 0, this.above90 = false});
  final String label;
  final double plannedPct;
  final double actualPct;
  final bool above90;

  factory _LoadWeek.fromJson(Map<String, dynamic> j) => _LoadWeek(
        label: asStrOr(j['label'], ''),
        plannedPct: asDoubleOr(j['planned_pct'], 0),
        actualPct: asDoubleOr(j['actual_pct'], 0),
        above90: asBool(j['above_90']),
      );
}

class _AccuracyPoint {
  const _AccuracyPoint({required this.ref, required this.estimated, required this.actual, required this.group, this.stamp});
  final String ref;
  final double estimated;
  final double actual;
  final String group; // sm | lc
  final String? stamp;

  factory _AccuracyPoint.fromJson(Map<String, dynamic> j) => _AccuracyPoint(
        ref: asStrOr(j['ref'], ''),
        estimated: asDoubleOr(j['estimated'], 0),
        actual: asDoubleOr(j['actual'], 0),
        group: asStrOr(j['group'], 'sm'),
        stamp: asStr(j['stamp']),
      );
}

class _Accuracy {
  const _Accuracy({required this.points, this.medianSm = 1, this.medianLc = 1, this.n = 0, this.nSm = 0, this.nLc = 0});
  final List<_AccuracyPoint> points;
  final double medianSm;
  final double medianLc;
  final int n;
  final int nSm;
  final int nLc;

  factory _Accuracy.fromJson(Map<String, dynamic> j) => _Accuracy(
        points: asList(j['points'], _AccuracyPoint.fromJson),
        medianSm: asDoubleOr(j['median_sm'], 1),
        medianLc: asDoubleOr(j['median_lc'], 1),
        n: asIntOr(j['n'], 0),
        nSm: asIntOr(j['n_sm'], 0),
        nLc: asIntOr(j['n_lc'], 0),
      );
}

class _DeliveredType {
  const _DeliveredType({required this.type, required this.colour, this.count = 0});
  final String type;
  final String colour;
  final int count;

  factory _DeliveredType.fromJson(Map<String, dynamic> j) =>
      _DeliveredType(type: asStrOr(j['type'], ''), colour: asStrOr(j['colour'], '#3B6BD6'), count: asIntOr(j['count'], 0));
}

class _DeliveredMonth {
  const _DeliveredMonth({required this.label, required this.byType, this.total = 0});
  final String label;
  final List<_DeliveredType> byType;
  final int total;

  factory _DeliveredMonth.fromJson(Map<String, dynamic> j) => _DeliveredMonth(
        label: asStrOr(j['label'], ''),
        byType: asList(j['by_type'], _DeliveredType.fromJson),
        total: asIntOr(j['total'], 0),
      );
}

class _Reports {
  const _Reports({
    required this.stability,
    required this.load,
    required this.accuracy,
    required this.delivered,
    required this.definitions,
    required this.thisWeekIndex,
    required this.workspaceName,
    required this.rangeLabel,
    required this.targetMin,
    required this.targetMax,
    this.cycleTimeDeltaPct,
  });

  final List<_StabilityWeek> stability;
  final List<_LoadWeek> load;
  final _Accuracy accuracy;
  final List<_DeliveredMonth> delivered;
  final Map<String, String> definitions;
  final double thisWeekIndex;
  final String workspaceName;
  final String rangeLabel;
  final int targetMin;
  final int targetMax;
  final double? cycleTimeDeltaPct;

  factory _Reports.fromJson(Map<String, dynamic> j) {
    final defs = asMap(j['definitions']);
    return _Reports(
      stability: asList(j['stability'], _StabilityWeek.fromJson),
      load: asList(j['load'], _LoadWeek.fromJson),
      accuracy: _Accuracy.fromJson(asMap(j['accuracy'])),
      delivered: asList(j['delivered'], _DeliveredMonth.fromJson),
      definitions: {for (final e in defs.entries) e.key: e.value?.toString() ?? ''},
      thisWeekIndex: asDoubleOr(j['this_week_index'], 0),
      workspaceName: asStrOr(j['workspace_name'], 'Workspace'),
      rangeLabel: asStrOr(j['range_label'], ''),
      targetMin: asIntOr(j['target_min'], 80),
      targetMax: asIntOr(j['target_max'], 90),
      cycleTimeDeltaPct: asDouble(j['cycle_time_delta_pct']),
    );
  }
}

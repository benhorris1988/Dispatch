import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/models.dart';
import '../services/api.dart';
import '../services/format.dart';
import '../shell/app_shell.dart';
import '../shell/nav.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/team_widgets.dart';
import '../widgets/wc_filters.dart';
import '../widgets/widgets.dart';

/// Benefits (BEN-*, spec 9.4.9). The register totals value in plan, realised to
/// date and at risk; realisation by quarter compares planned with
/// owner-confirmed realised value; a note explains how benefit value feeds the
/// priority score.
class BenefitsScreen extends StatefulWidget {
  const BenefitsScreen({super.key});

  @override
  State<BenefitsScreen> createState() => _BenefitsScreenState();
}

class _BenefitsScreenState extends State<BenefitsScreen> {
  static const _tabs = ['Register', 'Realisation', 'By owner'];

  int _tab = 0;
  bool _loading = true;
  String? _error;
  _Register? _data;

  // Register filters (BEN-05). `benefits.php list` takes all four; they narrow
  // the register itself, never the workspace totals beside it.
  String? _fType;
  String? _fStatus;
  String? _fOwner;
  String? _fQuarter;

  /// Every quarter the register has ever shown, so narrowing to one does not
  /// empty the quarter picker behind you.
  final Set<String> _quartersSeen = {};

  static const _statusOptions = <String, String>{
    'planned': 'Planned',
    'in_flight': 'In flight',
    'realising': 'Realising',
    'realised': 'Realised',
    'at_risk': 'At risk',
  };

  int get _filterCount => [_fType, _fStatus, _fOwner, _fQuarter].where((f) => f != null).length;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      // Only the first load blanks the page: changing a filter keeps the
      // register on screen, and the filter row with it.
      _loading = _data == null;
      _error = null;
    });
    try {
      // Only the register lists benefits, so the other two tabs always ask for
      // everything and cannot show a filtered aggregate by accident.
      final onRegister = _tab == 0;
      final r = await Api.post('benefits.php', 'list', {
        if (onRegister && _fType != null) 'type': _fType,
        if (onRegister && _fStatus != null) 'status': _fStatus,
        if (onRegister && _fOwner != null) 'owner': _fOwner,
        if (onRegister && _fQuarter != null) 'quarter': _fQuarter,
      });
      if (!mounted) return;
      setState(() {
        _data = _Register.fromJson(r);
        _quartersSeen
          ..addAll(_data!.byQuarter.map((q) => q.quarter).where((q) => q.isNotEmpty))
          ..addAll(_data!.benefits.map((b) => b.realisationQuarter).whereType<String>());
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

  void _setFilter(void Function() change) {
    setState(change);
    _load();
  }

  void _clearFilters() => _setFilter(() {
        _fType = null;
        _fStatus = null;
        _fOwner = null;
        _fQuarter = null;
      });

  void _setTab(int i) {
    final wasFiltered = _filterCount > 0 && (_tab == 0) != (i == 0);
    setState(() => _tab = i);
    if (wasFiltered) _load();
  }

  /// Q1 2026 before Q2 2026 before Q1 2027.
  static int _quarterKey(String q) {
    final m = RegExp(r'Q(\d)\s*(\d{4})').firstMatch(q);
    if (m == null) return 0;
    return int.parse(m.group(2)!) * 10 + int.parse(m.group(1)!);
  }

  Widget _filterBar(_Register d) {
    final owners = d.byOwner.map((o) => o.ownerName).where((n) => n.isNotEmpty && n != 'Unassigned').toList()..sort();
    final quarters = _quartersSeen.toList()..sort((a, b) => _quarterKey(a).compareTo(_quarterKey(b)));

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: Sp.md, runSpacing: Sp.md, crossAxisAlignment: WrapCrossAlignment.center, children: [
        WcFilterDropdown<String?>(
          value: _fType,
          hint: 'All types',
          icon: Icons.category_outlined,
          maxWidth: 210,
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('All types')),
            for (final t in d.types) DropdownMenuItem<String?>(value: t.type, child: Text(t.label)),
          ],
          onChanged: (v) => _setFilter(() => _fType = v),
        ),
        WcFilterDropdown<String?>(
          value: _fStatus,
          hint: 'Any status',
          icon: Icons.flag_outlined,
          maxWidth: 190,
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('Any status')),
            for (final e in _statusOptions.entries) DropdownMenuItem<String?>(value: e.key, child: Text(e.value)),
          ],
          onChanged: (v) => _setFilter(() => _fStatus = v),
        ),
        WcFilterDropdown<String?>(
          value: owners.contains(_fOwner) ? _fOwner : null,
          hint: 'All owners',
          icon: Icons.person_outline_rounded,
          maxWidth: 210,
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('All owners')),
            for (final o in owners) DropdownMenuItem<String?>(value: o, child: Text(o)),
          ],
          onChanged: (v) => _setFilter(() => _fOwner = v),
        ),
        WcFilterDropdown<String?>(
          value: quarters.contains(_fQuarter) ? _fQuarter : null,
          hint: 'Any quarter',
          icon: Icons.event_outlined,
          maxWidth: 170,
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('Any quarter')),
            for (final q in quarters) DropdownMenuItem<String?>(value: q, child: Text(q)),
          ],
          onChanged: (v) => _setFilter(() => _fQuarter = v),
        ),
        WcActiveFilters(count: _filterCount, onClear: _clearFilters),
      ]),
      if (_filterCount > 0) ...[
        const SizedBox(height: Sp.sm),
        Text(
          'Showing ${d.benefits.length} of ${d.totals.benefitCount} benefits. The totals above cover the whole register.',
          style: context.text.bodySmall,
        ),
      ],
    ]);
  }

  Future<void> _export() async {
    try {
      final r = await Api.post('benefits.php', 'export_csv');
      if (!mounted) return;
      await showTmCsvDialog(context, title: 'Export benefits register', csv: asStrOr(r['csv'], ''), filename: asStr(r['filename']));
    } on ApiException catch (e) {
      if (mounted) tmToast(context, e.message, bad: true);
    }
  }

  Future<void> _addBenefit() async {
    final saved = await showDialog<bool>(context: context, builder: (context) => _BenefitDialog(types: _data?.types ?? const []));
    if (saved == true) await _load();
  }

  Future<void> _editBenefit(_BenefitRow b) async {
    final saved = await showDialog<bool>(context: context, builder: (context) => _BenefitDialog(types: _data?.types ?? const [], benefit: b));
    if (saved == true) await _load();
  }

  Future<void> _recordRealisation(_BenefitRow b) async {
    final saved = await showDialog<bool>(context: context, builder: (context) => _RealisationDialog(benefit: b));
    if (saved == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final config = context.watch<WorkspaceConfig>();
    final d = _data;

    return PageBody(
      onRefresh: _load,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(
          title: 'Benefits',
          subtitle: d == null
              ? 'Benefits register'
              : dotJoin([
                  'Benefits register',
                  '${d.totals.benefitCount} benefits across ${d.totals.itemsWithBenefits} items',
                  'values are annual, owner-confirmed',
                ]),
          actions: [
            SegmentedTabs(labels: _tabs, selected: _tab, onChanged: _setTab),
            SecondaryButton('Export', icon: Icons.file_download_outlined, onPressed: d == null ? null : _export),
            if (session.can('benefit_owner')) PrimaryButton('Add benefit', icon: Icons.add_rounded, onPressed: _addBenefit),
          ],
        ),
        const SizedBox(height: Sp.xl),
        if (_loading)
          const _BenefitsSkeleton()
        else if (_error != null)
          ErrorState(title: 'We could not load the benefits register', message: _error, onRetry: _load)
        else if (d == null || (d.benefits.isEmpty && _filterCount == 0))
          EmptyState(
            icon: Icons.savings_outlined,
            title: 'No benefits recorded yet',
            message: 'Add a benefit case to a work item so its value can feed the priority score.',
            action: session.can('benefit_owner') ? PrimaryButton('Add benefit', icon: Icons.add_rounded, onPressed: _addBenefit) : null,
          )
        else ...[
          _Totals(totals: d.totals),
          const SizedBox(height: Sp.lg),
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth >= 1100;
            final left = switch (_tab) {
              1 => _RealisationTab(
                  data: d,
                  canRecord: session.can('benefit_owner'),
                  onRecord: _recordRealisation,
                ),
              2 => _ByOwnerTab(data: d),
              _ => _RegisterTab(
                  data: d,
                  canEdit: session.can('benefit_owner'),
                  onEdit: _editBenefit,
                  filters: _filterBar(d),
                  onClearFilters: _filterCount == 0 ? null : _clearFilters,
                ),
            };
            final right = _SidePanels(data: d, policy: config.policy);
            if (!wide) {
              return Column(children: [left, const SizedBox(height: Sp.lg), right]);
            }
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 3, child: left),
              const SizedBox(width: Sp.lg),
              SizedBox(width: 380, child: right),
            ]);
          }),
        ],
      ]),
    );
  }
}

// ─── Totals ───────────────────────────────────────────────────────────────

class _Totals extends StatelessWidget {
  const _Totals({required this.totals});
  final _Totals2 totals;

  @override
  Widget build(BuildContext context) {
    final t = totals;
    return StatRow(tiles: [
      StatTile(
        label: 'Value in the plan',
        value: fmtMoneyK(t.inPlan),
        unit: 'per year',
        footnote: '${fmtMoneyK(t.addedThisQuarter)} added this quarter',
        tone: StatTone.good,
      ),
      StatTile(
        label: 'Realised, year to date',
        value: fmtMoneyK(t.realisedYtd),
        footnote: '${t.targetPct}% of the annual target',
        tone: StatTone.neutral,
        footnoteIcon: Icons.adjust_rounded,
      ),
      StatTile(
        label: 'At risk',
        value: fmtMoneyK(t.atRisk),
        footnote: '${t.atRiskCount} ${t.atRiskCount == 1 ? 'benefit' : 'benefits'} at risk',
        tone: t.atRiskCount > 0 ? StatTone.bad : StatTone.good,
        footnoteIcon: t.atRiskCount > 0 ? Icons.warning_amber_rounded : Icons.check_rounded,
      ),
      StatTile(
        label: 'Items without a benefit case',
        value: '${t.itemsWithoutCase}',
        unit: 'of ${t.itemsTotal}',
        footnote: t.itemsWithoutCaseNote,
        tone: StatTone.neutral,
      ),
    ]);
  }
}

// ─── Register tab ─────────────────────────────────────────────────────────

class _RegisterTab extends StatelessWidget {
  const _RegisterTab({
    required this.data,
    required this.canEdit,
    required this.onEdit,
    required this.filters,
    this.onClearFilters,
  });
  final _Register data;
  final bool canEdit;
  final void Function(_BenefitRow) onEdit;

  /// The type, status, owner and quarter row (BEN-05).
  final Widget filters;
  final VoidCallback? onClearFilters;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      filters,
      const SizedBox(height: Sp.lg),
      _panel(context),
    ]);
  }

  Widget _panel(BuildContext context) {
    if (data.benefits.isEmpty) {
      return Panel(
        child: EmptyState(
          icon: Icons.filter_alt_outlined,
          title: 'No benefit matches these filters',
          message: 'Widen one of them to see more of the register.',
          compact: true,
          action: onClearFilters == null ? null : SecondaryButton('Clear the filters', onPressed: onClearFilters),
        ),
      );
    }
    return Panel(
      padding: EdgeInsets.zero,
      child: LayoutBuilder(builder: (context, c) {
        if (TmTable.isNarrow(c.maxWidth)) {
          return Padding(
            padding: const EdgeInsets.all(Sp.lg),
            child: Column(children: [
              for (final b in data.benefits)
                Padding(
                  padding: const EdgeInsets.only(bottom: Sp.md),
                  child: DispatchCard(
                    onTap: b.ref == null ? null : () => context.go(Routes.item(b.ref!)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(dotJoin([b.ref, b.title]), style: context.text.titleSmall),
                      const SizedBox(height: Sp.sm),
                      Wrap(spacing: Sp.sm, runSpacing: Sp.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        TypeChip(b.typeLabel, colourHex: b.typeColour, compact: true),
                        Text('${(b.annualValue / 1000).round()}k/yr', style: DispatchTheme.numeric(size: 13.5, weight: FontWeight.w800, color: context.inkColor)),
                        ConfidenceDots(b.confidence, showLabel: true),
                        StatusChip(b.status, compact: true),
                      ]),
                      const SizedBox(height: 4),
                      Text('Realised from ${b.realisationQuarter ?? '—'}', style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
                    ]),
                  ),
                ),
            ]),
          );
        }
        return TmTable(
          columns: const [
            TmCol('Work', flex: 4),
            TmCol('Type', width: 140),
            TmCol('£k / yr', width: 80, align: TextAlign.right),
            TmCol('Confidence', width: 130),
            TmCol('Realised from', width: 120),
            TmCol('Status', width: 108),
            TmCol('', width: 44),
          ],
          rows: [
            for (final b in data.benefits)
              [
                InkWell(
                  onTap: b.ref == null ? null : () => context.go(Routes.item(b.ref!)),
                  child: RichText(
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(style: context.text.bodyMedium, children: [
                      TextSpan(text: '${b.ref ?? ''} ', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
                      TextSpan(text: b.title, style: context.text.titleSmall),
                    ]),
                  ),
                ),
                TypeChip(b.typeLabel, colourHex: b.typeColour, compact: true),
                Text('${(b.annualValue / 1000).round()}',
                    style: DispatchTheme.numeric(size: 14, weight: FontWeight.w800, color: context.inkColor)),
                ConfidenceDots(b.confidence, showLabel: true),
                Text(b.realisationQuarter ?? '—', style: context.text.bodyMedium),
                StatusChip(b.status, compact: true),
                canEdit
                    ? IconButton(
                        onPressed: () => onEdit(b),
                        icon: const Icon(Icons.edit_outlined, size: 17),
                        tooltip: 'Edit this benefit',
                        visualDensity: VisualDensity.compact,
                      )
                    : const SizedBox(),
              ],
          ],
        );
      }),
    );
  }
}

// ─── Realisation tab ──────────────────────────────────────────────────────

class _RealisationTab extends StatelessWidget {
  const _RealisationTab({required this.data, required this.canRecord, required this.onRecord});
  final _Register data;
  final bool canRecord;
  final void Function(_BenefitRow) onRecord;

  @override
  Widget build(BuildContext context) {
    final rows = data.benefits.where((b) => b.realisationFrom != null).toList()
      ..sort((a, b) => a.realisationFrom!.compareTo(b.realisationFrom!));
    return Panel(
      title: 'Realisation',
      subtitle: canRecord ? 'Record what has actually landed, quarter by quarter' : 'Owner-confirmed values by benefit',
      padding: EdgeInsets.zero,
      dividerAfterHeader: true,
      child: rows.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(Sp.lg),
              child: EmptyState(icon: Icons.event_outlined, title: 'Nothing to realise yet', message: 'No benefit has a realisation date.', compact: true),
            )
          : LayoutBuilder(builder: (context, c) {
              if (TmTable.isNarrow(c.maxWidth)) {
                return Padding(
                  padding: const EdgeInsets.all(Sp.lg),
                  child: Column(children: [
                    for (final b in rows)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Sp.md),
                        child: DispatchCard(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                            Text(dotJoin([b.ref, b.title]), style: context.text.titleSmall),
                            const SizedBox(height: 4),
                            Text(
                              'From ${b.realisationQuarter ?? '—'} · ${fmtMoneyK(b.annualValue)} a year · realised ${fmtMoneyK(b.realisedValue ?? 0)}',
                              style: context.text.bodySmall?.copyWith(color: context.mutedColor),
                            ),
                            if (canRecord) ...[
                              const SizedBox(height: Sp.sm),
                              SecondaryButton('Record realisation', onPressed: () => onRecord(b)),
                            ],
                          ]),
                        ),
                      ),
                  ]),
                );
              }
              return TmTable(
                columns: const [
                  TmCol('Work', flex: 4),
                  TmCol('From', width: 110),
                  TmCol('Planned £k/yr', width: 120, align: TextAlign.right),
                  TmCol('Realised £k', width: 110, align: TextAlign.right),
                  TmCol('Status', width: 108),
                  TmCol('', width: 170, align: TextAlign.right),
                ],
                rows: [
                  for (final b in rows)
                    [
                      RichText(
                        overflow: TextOverflow.ellipsis,
                        text: TextSpan(style: context.text.bodyMedium, children: [
                          TextSpan(text: '${b.ref ?? ''} ', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
                          TextSpan(text: b.title, style: context.text.titleSmall),
                        ]),
                      ),
                      Text(b.realisationQuarter ?? '—', style: context.text.bodyMedium),
                      Text('${(b.annualValue / 1000).round()}', style: DispatchTheme.numeric(size: 14, weight: FontWeight.w700, color: context.inkColor)),
                      Text(b.realisedValue == null ? '—' : '${(b.realisedValue! / 1000).round()}',
                          style: DispatchTheme.numeric(size: 14, weight: FontWeight.w700, color: (b.realisedValue ?? 0) > 0 ? DispatchColors.green : context.mutedColor)),
                      StatusChip(b.status, compact: true),
                      canRecord ? SecondaryButton('Record', icon: Icons.check_rounded, onPressed: () => onRecord(b)) : const SizedBox(),
                    ],
                ],
              );
            }),
    );
  }
}

// ─── By owner tab ─────────────────────────────────────────────────────────

class _ByOwnerTab extends StatelessWidget {
  const _ByOwnerTab({required this.data});
  final _Register data;

  @override
  Widget build(BuildContext context) {
    final max = data.byOwner.fold<double>(1, (a, o) => a > o.value ? a : o.value);
    return Panel(
      title: 'Value by owner',
      subtitle: 'Annual value of the benefits each owner has confirmed',
      child: data.byOwner.isEmpty
          ? const EmptyState(icon: Icons.person_outline_rounded, title: 'No owners yet', message: 'Assign an owner to each benefit case.', compact: true)
          : Column(children: [
              for (final o in data.byOwner)
                TmProgressRow(
                  label: '${o.ownerName} · ${o.count} ${o.count == 1 ? 'benefit' : 'benefits'}',
                  value: '${fmtMoneyK(o.value)}${o.realised > 0 ? ' · ${fmtMoneyK(o.realised)} realised' : ''}',
                  fraction: o.value / max,
                  colour: DispatchColors.typeBlue,
                ),
            ]),
    );
  }
}

// ─── Right column ─────────────────────────────────────────────────────────

class _SidePanels extends StatelessWidget {
  const _SidePanels({required this.data, required this.policy});
  final _Register data;
  final Policy policy;

  @override
  Widget build(BuildContext context) {
    final maxType = data.byType.fold<double>(1, (a, t) => a > t.value ? a : t.value);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        title: 'Realisation by quarter',
        subtitle: '£k, cumulative',
        child: data.byQuarter.isEmpty
            ? const EmptyState(icon: Icons.bar_chart_rounded, title: 'No quarters yet', message: 'Add realisation dates to compare.', compact: true)
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TmGroupedBarChart(
                  height: 140,
                  barWidth: 11,
                  groups: [
                    for (final q in data.byQuarter)
                      TmBarGroup(
                        q.label,
                        [
                          TmBar(q.planned.toDouble(), const Color(0xFFAFC5EC), tooltip: '${q.quarter} planned ${fmtMoneyK(q.planned)}'),
                          TmBar(q.realised.toDouble(), DispatchColors.green, tooltip: '${q.quarter} realised ${fmtMoneyK(q.realised)}'),
                        ],
                        flag: q.confirmed ? null : '·',
                      ),
                  ],
                ),
                const SizedBox(height: Sp.md),
                const TmLegend([
                  (label: 'Planned', colour: Color(0xFFAFC5EC)),
                  (label: 'Realised (owner-confirmed)', colour: DispatchColors.green),
                ]),
              ]),
      ),
      const SizedBox(height: Sp.lg),
      Panel(
        title: 'Value by benefit type',
        child: Column(children: [
          for (final t in data.byType)
            TmProgressRow(
              label: t.label,
              value: fmtMoneyK(t.value),
              fraction: t.value / maxType,
              colour: DispatchColors.parseHex(t.colour),
            ),
        ]),
      ),
      const SizedBox(height: Sp.lg),
      TmInfoBox(data.priorityNote.isNotEmpty ? data.priorityNote : _fallbackNote(policy)),
    ]);
  }

  /// Only used if the endpoint stops sending its own note — still read from the
  /// policy rather than hard-coded.
  String _fallbackNote(Policy p) {
    final w = p.priorityWeights;
    final scale = w['confidenceScale'] is Map ? Map<String, dynamic>.from(w['confidenceScale'] as Map) : const {};
    final value = w['value'] ?? 40;
    return 'Benefit value contributes $value% of the priority score. Confidence scales it: '
        'High ×${scale['high'] ?? 1}, Medium ×${scale['medium'] ?? 0.7}, Low ×${scale['low'] ?? 0.4}.';
  }
}

// ─── Dialogs ──────────────────────────────────────────────────────────────

/// Add or edit a benefit. New benefits are attached with a work-item search.
class _BenefitDialog extends StatefulWidget {
  const _BenefitDialog({required this.types, this.benefit});
  final List<_TypeOption> types;
  final _BenefitRow? benefit;

  @override
  State<_BenefitDialog> createState() => _BenefitDialogState();
}

class _BenefitDialogState extends State<_BenefitDialog> {
  final TextEditingController _search = TextEditingController();
  late final TextEditingController _value = TextEditingController(text: widget.benefit == null ? '' : widget.benefit!.annualValue.round().toString());
  late final TextEditingController _owner = TextEditingController(text: widget.benefit?.ownerName ?? '');
  late final TextEditingController _narrative = TextEditingController(text: widget.benefit?.narrative);

  Timer? _debounce;
  bool _searching = false;
  List<({int id, String ref, String title})> _results = const [];
  int? _workItemId;
  String? _workItemLabel;

  late String _type = widget.benefit?.type ?? 'cost_avoidance';
  late String _confidence = widget.benefit?.confidence ?? 'medium';
  late DateTime? _from = widget.benefit?.realisationFrom;
  late String _status = widget.benefit?.status ?? 'planned';
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.benefit != null) {
      _workItemId = widget.benefit!.workItemId;
      _workItemLabel = dotJoin([widget.benefit!.ref, widget.benefit!.title]);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _value.dispose();
    _owner.dispose();
    _narrative.dispose();
    super.dispose();
  }

  void _onSearchChanged(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() => _results = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _runSearch(q.trim()));
  }

  Future<void> _runSearch(String q) async {
    setState(() => _searching = true);
    try {
      final r = await Api.post('work_items.php', 'list', {'q': q, 'limit': 8});
      final items = <({int id, String ref, String title})>[];
      for (final raw in (r['items'] as List? ?? const [])) {
        if (raw is Map) {
          items.add((id: asIntOr(raw['id'], 0), ref: asStrOr(raw['ref'], ''), title: asStrOr(raw['title'], '')));
        }
      }
      if (mounted) {
        setState(() {
          _results = items;
          _searching = false;
        });
      }
    } on ApiException {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _from ?? now,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 5),
    );
    if (d != null) setState(() => _from = d);
  }

  String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.post('benefits.php', 'save', {
        if (widget.benefit != null) 'id': widget.benefit!.id,
        if (_workItemId != null) 'work_item_id': _workItemId,
        'type': _type,
        'annual_value': double.tryParse(_value.text.trim().replaceAll(',', '')) ?? 0,
        'confidence': _confidence,
        if (_from != null) 'realisation_from': _iso(_from!),
        'owner_name': _owner.text.trim(),
        'narrative': _narrative.text.trim(),
        'status': _status,
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
    final isNew = widget.benefit == null;
    return AlertDialog(
      title: Text(isNew ? 'Add benefit' : 'Edit benefit'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (isNew) ...[
              TmField(
                label: 'Work item',
                hint: 'Search by reference or title, for example “WI-1042” or “telemetry”.',
                child: TextField(
                  controller: _search,
                  onChanged: _onSearchChanged,
                  decoration: InputDecoration(
                    hintText: 'Search work items',
                    prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    suffixIcon: _searching ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))) : null,
                  ),
                ),
              ),
              if (_workItemLabel != null)
                Padding(
                  padding: const EdgeInsets.only(top: Sp.sm),
                  child: Row(children: [
                    const Icon(Icons.check_circle_rounded, size: 16, color: DispatchColors.green),
                    const SizedBox(width: 6),
                    Expanded(child: Text(_workItemLabel!, style: context.text.bodyMedium)),
                  ]),
                ),
              if (_results.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: Sp.sm),
                  constraints: const BoxConstraints(maxHeight: 170),
                  decoration: BoxDecoration(borderRadius: DispatchRadius.cardR, border: Border.all(color: context.borderColor)),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final it in _results)
                        ListTile(
                          dense: true,
                          title: Text(dotJoin([it.ref, it.title]), style: context.text.bodyMedium),
                          onTap: () => setState(() {
                            _workItemId = it.id;
                            _workItemLabel = dotJoin([it.ref, it.title]);
                            _results = const [];
                            _search.text = '';
                          }),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: Sp.md),
            ],
            Row(children: [
              Expanded(
                child: TmField(
                  label: 'Type',
                  child: DropdownButtonFormField<String>(
                    initialValue: _type,
                    items: [for (final t in widget.types) DropdownMenuItem(value: t.type, child: Text(t.label))],
                    onChanged: (v) => setState(() => _type = v ?? _type),
                  ),
                ),
              ),
              const SizedBox(width: Sp.md),
              Expanded(
                child: TmField(
                  label: 'Annual value (£)',
                  child: TextField(controller: _value, keyboardType: TextInputType.number),
                ),
              ),
            ]),
            const SizedBox(height: Sp.md),
            Row(children: [
              Expanded(
                child: TmField(
                  label: 'Confidence',
                  child: DropdownButtonFormField<String>(
                    initialValue: _confidence,
                    items: const [
                      DropdownMenuItem(value: 'high', child: Text('High')),
                      DropdownMenuItem(value: 'medium', child: Text('Medium')),
                      DropdownMenuItem(value: 'low', child: Text('Low')),
                    ],
                    onChanged: (v) => setState(() => _confidence = v ?? _confidence),
                  ),
                ),
              ),
              const SizedBox(width: Sp.md),
              Expanded(
                child: TmField(
                  label: 'Realisation from',
                  child: SecondaryButton(_from == null ? 'Choose a date' : fmtShortDate(_from), icon: Icons.calendar_today_outlined, expand: true, onPressed: _pickDate),
                ),
              ),
            ]),
            const SizedBox(height: Sp.md),
            Row(children: [
              Expanded(child: TmField(label: 'Owner', child: TextField(controller: _owner))),
              const SizedBox(width: Sp.md),
              Expanded(
                child: TmField(
                  label: 'Status',
                  child: DropdownButtonFormField<String>(
                    initialValue: _status,
                    items: const [
                      DropdownMenuItem(value: 'planned', child: Text('Planned')),
                      DropdownMenuItem(value: 'in_flight', child: Text('In flight')),
                      DropdownMenuItem(value: 'realising', child: Text('Realising')),
                      DropdownMenuItem(value: 'realised', child: Text('Realised')),
                      DropdownMenuItem(value: 'at_risk', child: Text('At risk')),
                    ],
                    onChanged: (v) => setState(() => _status = v ?? _status),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: Sp.md),
            TmField(label: 'Narrative', child: TextField(controller: _narrative, maxLines: 3)),
            if (_error != null) TmInlineError(_error!),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        PrimaryButton('Save', busy: _busy, onPressed: _workItemId == null ? null : _save),
      ],
    );
  }
}

/// Record realised value for one quarter (benefit_owner and above).
class _RealisationDialog extends StatefulWidget {
  const _RealisationDialog({required this.benefit});
  final _BenefitRow benefit;

  @override
  State<_RealisationDialog> createState() => _RealisationDialogState();
}

class _RealisationDialogState extends State<_RealisationDialog> {
  final TextEditingController _value = TextEditingController();
  late String _quarter = widget.benefit.realisationQuarter ?? _currentQuarter();
  bool _busy = false;
  String? _error;

  static String _currentQuarter() {
    final n = DateTime.now();
    return 'Q${((n.month - 1) ~/ 3) + 1} ${n.year}';
  }

  List<String> get _quarters {
    final start = widget.benefit.realisationFrom ?? DateTime.now();
    final out = <String>[];
    var d = DateTime(start.year, start.month);
    for (var i = 0; i < 8; i++) {
      out.add('Q${((d.month - 1) ~/ 3) + 1} ${d.year}');
      d = DateTime(d.year, d.month + 3);
    }
    return out.toSet().toList();
  }

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.post('benefits.php', 'record_realisation', {
        'benefit_id': widget.benefit.id,
        'quarter': _quarter,
        'realised_value': double.tryParse(_value.text.trim().replaceAll(',', '')) ?? 0,
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
    final quarters = _quarters;
    if (!quarters.contains(_quarter)) _quarter = quarters.first;
    return AlertDialog(
      title: const Text('Record realisation'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(dotJoin([widget.benefit.ref, widget.benefit.title]), style: context.text.titleSmall),
          const SizedBox(height: Sp.md),
          TmField(
            label: 'Quarter',
            child: DropdownButtonFormField<String>(
              initialValue: _quarter,
              items: [for (final q in quarters) DropdownMenuItem(value: q, child: Text(q))],
              onChanged: (v) => setState(() => _quarter = v ?? _quarter),
            ),
          ),
          const SizedBox(height: Sp.md),
          TmField(
            label: 'Realised value (£)',
            hint: 'The value the owner has confirmed landed in that quarter.',
            child: TextField(controller: _value, keyboardType: TextInputType.number, autofocus: true),
          ),
          if (_error != null) TmInlineError(_error!),
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        PrimaryButton('Record', busy: _busy, onPressed: _save),
      ],
    );
  }
}

// ─── Skeleton ─────────────────────────────────────────────────────────────

class _BenefitsSkeleton extends StatelessWidget {
  const _BenefitsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: const [
      SkeletonPanel(rows: 2),
      SizedBox(height: Sp.lg),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(flex: 3, child: SkeletonPanel(rows: 8)),
        SizedBox(width: Sp.lg),
        Expanded(flex: 2, child: SkeletonPanel(rows: 6)),
      ]),
    ]);
  }
}

// ─── Parsing (benefits.php list) ──────────────────────────────────────────

class _BenefitRow {
  const _BenefitRow({
    required this.id,
    required this.workItemId,
    this.ref,
    this.title,
    required this.type,
    required this.typeLabel,
    this.typeColour,
    this.annualValue = 0,
    this.confidence = 'medium',
    this.realisationFrom,
    this.realisationQuarter,
    this.ownerName,
    this.narrative,
    this.status = 'planned',
    this.realisedValue,
  });

  final int id;
  final int workItemId;
  final String? ref;
  final String? title;
  final String type;
  final String typeLabel;
  final String? typeColour;
  final double annualValue;
  final String confidence;
  final DateTime? realisationFrom;
  final String? realisationQuarter;
  final String? ownerName;
  final String? narrative;
  final String status;
  final double? realisedValue;

  factory _BenefitRow.fromJson(Map<String, dynamic> j) => _BenefitRow(
        id: asIntOr(j['id'], 0),
        workItemId: asIntOr(j['work_item_id'], 0),
        ref: asStr(j['ref']),
        title: asStr(j['title']),
        type: asStrOr(j['type'], 'other'),
        typeLabel: asStrOr(j['type_label'], humanise(asStr(j['type']))),
        typeColour: asStr(j['type_colour']),
        annualValue: asDoubleOr(j['annual_value'], 0),
        confidence: asStrOr(j['confidence'], 'medium'),
        realisationFrom: asDate(j['realisation_from']),
        realisationQuarter: asStr(j['realisation_quarter']),
        ownerName: asStr(j['owner_name']),
        narrative: asStr(j['narrative']),
        status: asStrOr(j['status'], 'planned'),
        realisedValue: asDouble(j['realised_value']),
      );
}

class _Totals2 {
  const _Totals2({
    this.inPlan = 0,
    this.realisedYtd = 0,
    this.atRisk = 0,
    this.atRiskCount = 0,
    this.itemsWithoutCase = 0,
    this.itemsWithoutCaseNote,
    this.itemsTotal = 0,
    this.itemsWithBenefits = 0,
    this.benefitCount = 0,
    this.addedThisQuarter = 0,
    this.targetPct = 0,
  });

  final double inPlan;
  final double realisedYtd;
  final double atRisk;
  final int atRiskCount;
  final int itemsWithoutCase;
  final String? itemsWithoutCaseNote;
  final int itemsTotal;
  final int itemsWithBenefits;
  final int benefitCount;
  final double addedThisQuarter;
  final int targetPct;

  factory _Totals2.fromJson(Map<String, dynamic> j) => _Totals2(
        inPlan: asDoubleOr(j['in_plan'], 0),
        realisedYtd: asDoubleOr(j['realised_ytd'], 0),
        atRisk: asDoubleOr(j['at_risk'], 0),
        atRiskCount: asIntOr(j['at_risk_count'], 0),
        itemsWithoutCase: asIntOr(j['items_without_case'], 0),
        itemsWithoutCaseNote: asStr(j['items_without_case_note']),
        itemsTotal: asIntOr(j['items_total'], 0),
        itemsWithBenefits: asIntOr(j['items_with_benefits'], 0),
        benefitCount: asIntOr(j['benefit_count'], 0),
        addedThisQuarter: asDoubleOr(j['added_this_quarter'], 0),
        targetPct: asIntOr(j['target_pct'], 0),
      );
}

class _TypeTotal {
  const _TypeTotal({required this.type, required this.label, required this.colour, required this.value, this.count = 0});
  final String type;
  final String label;
  final String colour;
  final double value;
  final int count;

  factory _TypeTotal.fromJson(Map<String, dynamic> j) => _TypeTotal(
        type: asStrOr(j['type'], ''),
        label: asStrOr(j['label'], ''),
        colour: asStrOr(j['colour'], '#3B6BD6'),
        value: asDoubleOr(j['value'], 0),
        count: asIntOr(j['count'], 0),
      );
}

class _QuarterTotal {
  const _QuarterTotal({required this.quarter, required this.label, this.planned = 0, this.realised = 0, this.confirmed = false});
  final String quarter;
  final String label;
  final double planned;
  final double realised;
  final bool confirmed;

  factory _QuarterTotal.fromJson(Map<String, dynamic> j) => _QuarterTotal(
        quarter: asStrOr(j['quarter'], ''),
        label: asStrOr(j['label'], ''),
        planned: asDoubleOr(j['planned'], 0),
        realised: asDoubleOr(j['realised'], 0),
        confirmed: asBool(j['confirmed']),
      );
}

class _OwnerTotal {
  const _OwnerTotal({required this.ownerName, this.count = 0, this.value = 0, this.realised = 0});
  final String ownerName;
  final int count;
  final double value;
  final double realised;

  factory _OwnerTotal.fromJson(Map<String, dynamic> j) => _OwnerTotal(
        ownerName: asStrOr(j['owner_name'], 'Unassigned'),
        count: asIntOr(j['count'], 0),
        value: asDoubleOr(j['value'], 0),
        realised: asDoubleOr(j['realised'], 0),
      );
}

class _TypeOption {
  const _TypeOption({required this.type, required this.label, required this.colour});
  final String type;
  final String label;
  final String colour;

  factory _TypeOption.fromJson(Map<String, dynamic> j) =>
      _TypeOption(type: asStrOr(j['type'], ''), label: asStrOr(j['label'], ''), colour: asStrOr(j['colour'], '#3B6BD6'));
}

class _Register {
  const _Register({
    required this.benefits,
    required this.totals,
    required this.byType,
    required this.byQuarter,
    required this.byOwner,
    required this.types,
    required this.priorityNote,
  });

  final List<_BenefitRow> benefits;
  final _Totals2 totals;
  final List<_TypeTotal> byType;
  final List<_QuarterTotal> byQuarter;
  final List<_OwnerTotal> byOwner;
  final List<_TypeOption> types;
  final String priorityNote;

  factory _Register.fromJson(Map<String, dynamic> j) => _Register(
        benefits: asList(j['benefits'], _BenefitRow.fromJson),
        totals: _Totals2.fromJson(asMap(j['totals'])),
        byType: asList(j['by_type'], _TypeTotal.fromJson),
        byQuarter: asList(j['by_quarter'], _QuarterTotal.fromJson),
        byOwner: asList(j['by_owner'], _OwnerTotal.fromJson),
        types: asList(j['types'], _TypeOption.fromJson),
        priorityNote: asStrOr(j['priority_note'], ''),
      );
}

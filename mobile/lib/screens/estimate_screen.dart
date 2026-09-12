import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/models.dart';
import '../services/api.dart';
import '../services/format.dart';
import '../shell/app_shell.dart';
import '../shell/breaks.dart';
import '../shell/nav.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/widgets.dart';
import '../widgets/work_widgets.dart';

/// Estimate (EST-*, web-08): size-class, three-point and task roll-up methods
/// with PERT, P80, effort by skill, class and cost, calibration, similar work
/// and version history.
class EstimateScreen extends StatefulWidget {
  const EstimateScreen({super.key, required this.ref});

  /// Work item reference, e.g. WI-1042.
  final String ref;

  @override
  State<EstimateScreen> createState() => _EstimateScreenState();
}

const _methods = ['size', 'three_point', 'rollup'];
const _methodLabels = ['Size class only', 'Three-point', 'Task roll-up'];

class _SplitRow {
  _SplitRow({this.skillId, required this.label, required this.days});
  final int? skillId;
  final String label;
  double days;
}

class _EstimateScreenState extends State<EstimateScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  final _optimistic = TextEditingController();
  final _likely = TextEditingController();
  final _pessimistic = TextEditingController();
  final _dayRate = TextEditingController();
  final _assumptions = TextEditingController();

  int _method = 1;
  int _class = 3;
  String? _sizeStamp;
  List<_SplitRow> _split = [];

  static const _palette = [
    DispatchColors.typeBlue,
    DispatchColors.ink,
    DispatchColors.orange,
    DispatchColors.typeTeal,
    DispatchColors.typeViolet,
    DispatchColors.amber,
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _optimistic.dispose();
    _likely.dispose();
    _pessimistic.dispose();
    _dayRate.dispose();
    _assumptions.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = _data == null;
      _error = null;
    });
    try {
      final r = await Api.post('estimates.php', 'get', {'ref': widget.ref});
      if (!mounted) return;
      final latest = asMap(r['latest']);
      final item = asMap(r['item']);
      setState(() {
        _data = r;
        _loading = false;
        _optimistic.text = _num(asDouble(latest['optimistic']));
        _likely.text = _num(asDouble(latest['likely']));
        _pessimistic.text = _num(asDouble(latest['pessimistic']));
        _dayRate.text = _num(asDouble(latest['day_rate']) ?? asDouble(r['day_rate']));
        _assumptions.text = asStrOr(latest['assumptions'], '');
        _class = asIntOr(latest['estimate_class'], 3);
        _sizeStamp = asStr(item['size_stamp']);
        _method = latest.isEmpty ? 1 : _methods.indexOf(asStrOr(latest['method'], 'three_point')).clamp(0, 2);
        _split = _initialSplit(r, latest);
      });
      context.read<ShellState>().setPageTitle('Estimate · ${asStrOr(item['ref'], widget.ref)}', breadcrumb: ['Pipeline', asStrOr(item['ref'], widget.ref), 'Estimate']);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  List<_SplitRow> _initialSplit(Map<String, dynamic> r, Map<String, dynamic> latest) {
    final fromEstimate = (latest['skill_split'] as List?)?.whereType<Map>().toList() ?? const [];
    if (fromEstimate.isNotEmpty) {
      return [
        for (final s in fromEstimate)
          _SplitRow(skillId: asInt(s['skill_id']), label: asStrOr(s['label'] ?? s['name'], 'Unnamed'), days: asDoubleOr(s['days'], 0)),
      ];
    }
    final skills = (r['skills'] as List?)?.whereType<Map>().toList() ?? const [];
    return [
      for (final s in skills)
        _SplitRow(skillId: asInt(s['skill_id']), label: asStrOr(s['name'], 'Unnamed'), days: asDoubleOr(s['effort_days'], 0)),
    ];
  }

  static String _num(double? d) {
    if (d == null) return '';
    return d == d.roundToDouble() ? d.toInt().toString() : d.toStringAsFixed(1);
  }

  double? get _o => double.tryParse(_optimistic.text.trim());
  double? get _m => double.tryParse(_likely.text.trim());
  double? get _p => double.tryParse(_pessimistic.text.trim());
  double? get _rate => double.tryParse(_dayRate.text.trim());

  double? get _expected => (_o != null && _m != null && _p != null) ? (_o! + 4 * _m! + _p!) / 6 : _m;
  double? get _sd => (_o != null && _p != null) ? (_p! - _o!) / 6 : null;
  double? get _p80 => (_expected != null && _sd != null) ? _expected! + 0.8416 * _sd! : null;

  int get _tolerance => toleranceForClass(_class);

  /// Implied stamp from the size bands the endpoint returned.
  ({String stamp, String name, String range})? get _impliedSize {
    final days = _expected;
    if (days == null || _data == null) return null;
    final bands = (_data!['size_bands'] as List?)?.whereType<Map>().toList() ?? const [];
    for (final b in bands) {
      if (asBool(b['is_custom'])) continue;
      final min = asDouble(b['min_days']) ?? 0;
      final max = asDouble(b['max_days']);
      if (days >= min && (max == null || days <= max)) {
        return (
          stamp: asStrOr(b['stamp'], '?'),
          name: asStrOr(b['name'], ''),
          range: max == null ? '${_num(min)}+ days' : '${_num(min)}–${_num(max)} days',
        );
      }
    }
    return (stamp: 'C', name: 'Custom', range: 'beyond the largest band');
  }

  double get _splitTotal => _split.fold<double>(0, (a, s) => a + s.days);

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _save() async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Save this estimate'),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Every estimate is a new version with an author, a date and a reason.', style: dialogContext.text.bodySmall),
            const SizedBox(height: Sp.md),
            TextField(
              controller: reason,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Reason', hintText: 'for example after design review widened Terraform scope'),
            ),
          ]),
        ),
        actions: [
          SecondaryButton('Cancel', onPressed: () => Navigator.of(dialogContext).pop(false)),
          PrimaryButton('Save estimate', onPressed: () => Navigator.of(dialogContext).pop(true)),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _saving = true);
    try {
      final method = _methods[_method];
      final r = await Api.post('estimates.php', 'save', {
        'work_item_id': asIntOr(asMap(_data?['item'])['id'], 0),
        'method': method,
        if (method == 'three_point') ...{
          'optimistic': _o,
          'likely': _m,
          'pessimistic': _p,
        },
        if (method == 'size') 'size_stamp': _sizeStamp,
        'estimate_class': _class,
        if (_rate != null) 'day_rate': _rate,
        'assumptions': _assumptions.text.trim(),
        if (reason.text.trim().isNotEmpty) 'reason': reason.text.trim(),
        if (_split.isNotEmpty)
          'skill_split': [for (final s in _split) {'skill_id': s.skillId, 'label': s.label, 'days': s.days}],
      });
      _snack('Version ${asIntOr(r['version'], 0)} saved.');
      await _load();
    } on ApiException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _showVersions() async {
    final versions = _listOf('versions');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (sheetContext, controller) => Padding(
          padding: const EdgeInsets.fromLTRB(Sp.xl, 0, Sp.xl, Sp.xl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(padding: const EdgeInsets.only(bottom: Sp.md), child: Text('Estimate versions', style: sheetContext.text.headlineSmall)),
            Expanded(
              child: versions.isEmpty
                  ? const EmptyState(icon: Icons.history_rounded, title: 'No versions yet', message: 'The first save creates version 1.')
                  : ListView(controller: controller, children: [for (final v in versions) _versionTile(v)]),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _copyFromSimilar() async {
    final similar = _listOf('similar');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (sheetContext, controller) => Padding(
          padding: const EdgeInsets.fromLTRB(Sp.xl, 0, Sp.xl, Sp.xl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(padding: const EdgeInsets.only(bottom: Sp.md), child: Text('Copy from similar work', style: sheetContext.text.headlineSmall)),
            Expanded(
              child: similar.isEmpty
                  ? const EmptyState(
                      icon: Icons.content_copy_outlined,
                      title: 'No similar delivered work',
                      message: 'Once work of the same size and skills has been delivered, its estimate can be copied here.')
                  : ListView(controller: controller, children: [for (final s in similar) _similarTile(s, inSheet: true)]),
            ),
          ]),
        ),
      ),
    );
  }

  void _applySimilar(Map<String, dynamic> s) {
    setState(() {
      _method = 1;
      _likely.text = _num(asDouble(s['estimated_days']));
      _optimistic.text = _num(asDouble(s['optimistic']) ?? (asDouble(s['estimated_days']) != null ? asDouble(s['estimated_days'])! * 0.8 : null));
      _pessimistic.text = _num(asDouble(s['pessimistic']) ?? (asDouble(s['estimated_days']) != null ? asDouble(s['estimated_days'])! * 1.3 : null));
    });
    _snack('Copied the estimate from ${asStrOr(s['ref'], '')}. Save it to create a new version.');
  }

  List<Map<String, dynamic>> _listOf(String key, [Map<String, dynamic>? from]) =>
      ((from ?? _data)?[key] as List?)?.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() ?? const [];

  // ─── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const PageBody(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SkeletonPanel(rows: 2),
          SizedBox(height: Sp.lg),
          SkeletonPanel(rows: 8),
        ]),
      );
    }
    if (_error != null) {
      return PageBody(child: ErrorState(title: 'The estimate could not be loaded', message: _error, onRetry: _load));
    }

    final item = WorkRow(asMap(_data!['item']));
    final latest = asMap(_data!['latest']);
    final versions = _listOf('versions');
    final session = context.watch<Session>();

    final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _methodPanel(item),
      const SizedBox(height: Sp.lg),
      _costPanel(),
    ]);
    final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _calibrationPanel(),
      const SizedBox(height: Sp.lg),
      _similarPanel(),
      const SizedBox(height: Sp.lg),
      _historyPanel(versions),
    ]);

    return PageBody(
      onRefresh: _load,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          TextButton(onPressed: () => context.go(Routes.pipeline), child: const Text('Pipeline')),
          Icon(Icons.chevron_right_rounded, size: 16, color: context.mutedColor),
          TextButton(onPressed: () => context.go(Routes.item(item.ref)), child: Text(item.ref)),
          Icon(Icons.chevron_right_rounded, size: 16, color: context.mutedColor),
          const SizedBox(width: Sp.sm),
          Text('Estimate', style: context.text.bodyMedium),
        ]),
        const SizedBox(height: Sp.sm),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: Sp.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text(item.ref, style: DispatchTheme.numeric(size: 15, color: context.mutedColor)),
                TypeChip(item.typeName, colourHex: item.typeColour, compact: true),
                SizeStamp(item.sizeStamp, size: 24, dashed: item.isCustom),
              ]),
              const SizedBox(height: Sp.sm),
              Text('Estimate · ${item.title}', style: Breaks.isPhone(context) ? context.text.headlineMedium : context.text.displaySmall),
              const SizedBox(height: Sp.xs),
              Text(
                latest.isEmpty
                    ? 'Rough order of magnitude · not estimated yet'
                    : dotJoin([
                        'Rough order of magnitude',
                        'version ${asIntOr(latest['version'], 1)}',
                        'last updated by ${asStrOr(latest['author_name'], 'unknown')}, ${fmtDayMonth(asDate(latest['created_at']))}',
                      ]),
                style: context.text.bodyMedium?.copyWith(color: context.mutedColor),
              ),
            ]),
          ),
          const SizedBox(width: Sp.lg),
          Wrap(spacing: Sp.sm, runSpacing: Sp.sm, alignment: WrapAlignment.end, children: [
            SecondaryButton('Versions (${versions.length})', icon: Icons.history_rounded, onPressed: _showVersions),
            SecondaryButton('Copy from similar', icon: Icons.content_copy_outlined, onPressed: _copyFromSimilar),
            if (session.can('team_member'))
              PrimaryButton('Save estimate', icon: Icons.save_outlined, busy: _saving, onPressed: _save),
          ]),
        ]),
        const SizedBox(height: Sp.lg),
        if (Breaks.isDesktop(context))
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 7, child: left),
            const SizedBox(width: Sp.lg),
            SizedBox(width: 400, child: right),
          ])
        else ...[
          left,
          const SizedBox(height: Sp.lg),
          right,
        ],
      ]),
    );
  }

  Widget _methodPanel(WorkRow item) {
    final implied = _impliedSize;
    return Panel(
      title: 'Method',
      trailing: SegmentedTabs(
        labels: _methodLabels,
        selected: _method,
        compact: true,
        onChanged: (i) => setState(() => _method = i),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_method == 0) _sizeMethod(item),
        if (_method == 1) _threePointMethod(),
        if (_method == 2) _rollupMethod(),
        const SizedBox(height: Sp.lg),
        Container(
          padding: const EdgeInsets.all(Sp.md),
          decoration: BoxDecoration(color: context.scheme.surfaceContainerHighest, borderRadius: DispatchRadius.cardR),
          child: Wrap(spacing: Sp.xl, runSpacing: Sp.md, children: [
            _tile('Expected (PERT)', _num(_expected), unit: 'days'),
            _tile('Standard deviation', _sd == null ? '—' : _sd!.toStringAsFixed(1)),
            _tile('P80 (plan at this)', _p80 == null ? '—' : _p80!.toStringAsFixed(1), colour: DispatchColors.orange),
            if (implied != null)
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Size class implied', style: context.text.bodySmall),
                const SizedBox(height: 4),
                Row(children: [
                  SizeStamp(implied.stamp, size: 24, dashed: implied.stamp == 'C'),
                  const SizedBox(width: Sp.sm),
                  Text(implied.name, style: context.text.titleSmall),
                  const SizedBox(width: Sp.sm),
                  Text(implied.range, style: context.text.bodySmall),
                ]),
              ]),
          ]),
        ),
        const SizedBox(height: Sp.lg),
        _effortBySkill(),
      ]),
    );
  }

  Widget _tile(String label, String value, {String? unit, Color? colour}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: context.text.bodySmall),
      const SizedBox(height: 2),
      Text.rich(TextSpan(children: [
        TextSpan(text: value.isEmpty ? '—' : value, style: DispatchTheme.numeric(size: 24, weight: FontWeight.w800, color: colour ?? context.inkColor)),
        if (unit != null) TextSpan(text: ' $unit', style: context.text.bodySmall),
      ])),
    ]);
  }

  Widget _numberField(String label, TextEditingController c) {
    return TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      decoration: InputDecoration(labelText: label),
      onChanged: (_) => setState(() {}),
    );
  }

  Widget _threePointMethod() {
    return Row(children: [
      Expanded(child: _numberField('Optimistic (days)', _optimistic)),
      const SizedBox(width: Sp.md),
      Expanded(child: _numberField('Most likely (days)', _likely)),
      const SizedBox(width: Sp.md),
      Expanded(child: _numberField('Pessimistic (days)', _pessimistic)),
    ]);
  }

  Widget _sizeMethod(WorkRow item) {
    final bands = _listOf('size_bands');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('The size class supplies the planning value; no numbers are typed.', style: context.text.bodySmall),
      const SizedBox(height: Sp.md),
      Wrap(spacing: Sp.md, runSpacing: Sp.md, children: [
        for (final b in bands)
          InkWell(
            onTap: () => setState(() {
              _sizeStamp = asStr(b['stamp']);
              final planning = asDouble(b['planning_days']);
              if (planning != null) _likely.text = _num(planning);
              final min = asDouble(b['min_days']);
              final max = asDouble(b['max_days']);
              if (min != null) _optimistic.text = _num(min);
              if (max != null) _pessimistic.text = _num(max);
            }),
            borderRadius: DispatchRadius.cardR,
            child: Container(
              width: 150,
              padding: const EdgeInsets.all(Sp.md),
              decoration: BoxDecoration(
                borderRadius: DispatchRadius.cardR,
                border: Border.all(
                  color: _sizeStamp == asStr(b['stamp']) ? DispatchColors.ink : context.borderColor,
                  width: _sizeStamp == asStr(b['stamp']) ? 2 : 1,
                ),
              ),
              child: Column(children: [
                SizeStamp(asStr(b['stamp']), size: 28, dashed: asBool(b['is_custom'])),
                const SizedBox(height: Sp.sm),
                Text(asStrOr(b['name'], ''), style: context.text.titleSmall),
                Text(
                  asBool(b['is_custom'])
                      ? 'enter days'
                      : '${_num(asDouble(b['min_days']))}–${asDouble(b['max_days']) == null ? '' : _num(asDouble(b['max_days']))} days',
                  style: context.text.bodySmall,
                ),
              ]),
            ),
          ),
      ]),
      if (bands.isEmpty) Text('No size bands are configured for ${item.typeName}.', style: context.text.bodySmall),
    ]);
  }

  Widget _rollupMethod() {
    final tasks = _listOf('tasks');
    final total = asDouble(_data?['tasks_rollup_days']) ?? 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (tasks.isEmpty)
        const EmptyState(
          icon: Icons.checklist_rounded,
          title: 'No tasks to roll up',
          message: 'Split the item into tasks on its Tasks tab, then roll the effort up here.',
          compact: true,
        )
      else ...[
        for (final t in tasks)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Expanded(child: Text(asStrOr(t['title'], ''), style: context.text.bodyMedium)),
              Text(dotJoin([asStr(t['skill_name']), fmtDaysShort(asDouble(t['effort_days']))]), style: context.text.bodySmall),
            ]),
          ),
        const Divider(height: Sp.xl),
        Row(children: [
          Text('Roll-up total', style: context.text.titleSmall),
          const Spacer(),
          Text(fmtDaysShort(total), style: DispatchTheme.numeric(size: 15)),
        ]),
        const SizedBox(height: Sp.sm),
        Text('Saving with this method records the roll-up as the most-likely value.', style: context.text.bodySmall),
      ],
    ]);
  }

  Widget _effortBySkill() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Text('Effort by skill', style: context.text.titleMedium),
        const Spacer(),
        Text('Drives the skills the scheduler must match · total ${fmtDaysShort(_splitTotal)}', style: context.text.bodySmall),
      ]),
      const SizedBox(height: Sp.md),
      if (_split.isEmpty)
        Text('No skills are declared on this item yet, so there is nothing to split.', style: context.text.bodySmall)
      else ...[
        StackedBar(
          segments: [
            for (var i = 0; i < _split.length; i++)
              BarSegment(label: _split[i].label, value: _split[i].days, colour: _palette[i % _palette.length]),
          ],
        ),
        const SizedBox(height: Sp.md),
        Wrap(spacing: Sp.lg, runSpacing: Sp.sm, children: [
          for (var i = 0; i < _split.length; i++)
            SizedBox(
              width: 220,
              child: Row(children: [
                Container(width: 11, height: 11, decoration: BoxDecoration(color: _palette[i % _palette.length], borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: Sp.sm),
                Expanded(child: Text(_split[i].label, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: context.inkColor))),
                SizedBox(
                  width: 64,
                  child: TextFormField(
                    initialValue: _num(_split[i].days),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    textAlign: TextAlign.right,
                    decoration: const InputDecoration(suffixText: 'd', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
                    onChanged: (v) => setState(() => _split[i].days = double.tryParse(v) ?? 0),
                  ),
                ),
              ]),
            ),
        ]),
      ],
    ]);
  }

  Widget _costPanel() {
    final classes = _listOf('classes');
    final description = classes.where((c) => asIntOr(c['class'], 0) == _class).map((c) => asStrOr(c['description'], '')).firstOrNull ?? '';
    final costLikely = (_m != null && _rate != null) ? _m! * _rate! : null;

    return Panel(
      title: 'Confidence and cost',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (Breaks.isPhone(context))
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_classSelector(classes, description), const SizedBox(height: Sp.lg), _rateBlock(costLikely)])
        else
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _classSelector(classes, description)),
            const SizedBox(width: Sp.xl),
            Expanded(child: _rateBlock(costLikely)),
          ]),
        const SizedBox(height: Sp.lg),
        Text('Assumptions and exclusions', style: context.text.titleSmall),
        const SizedBox(height: Sp.sm),
        TextField(
          controller: _assumptions,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(hintText: 'What the estimate assumes, and what it leaves out.'),
        ),
      ]),
    );
  }

  Widget _classSelector(List<Map<String, dynamic>> classes, String description) {
    final order = [5, 4, 3, 2, 1];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Estimate class', style: context.text.titleSmall),
      const SizedBox(height: Sp.sm),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedTabs(
          labels: [for (final c in order) '$c ${classToleranceLabel(c)}'],
          selected: order.indexOf(_class).clamp(0, 4),
          compact: true,
          onChanged: (i) => setState(() => _class = order[i]),
        ),
      ),
      const SizedBox(height: Sp.sm),
      Text(description.isEmpty ? 'Class $_class · ±$_tolerance%' : 'Class $_class: $description', style: context.text.bodySmall),
    ]);
  }

  Widget _rateBlock(double? costLikely) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Blended day rate', style: context.text.titleSmall),
      const SizedBox(height: Sp.sm),
      TextField(
        controller: _dayRate,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        decoration: const InputDecoration(prefixText: '£'),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: Sp.md),
      Row(children: [
        Expanded(child: Text('Cost at most likely', style: context.text.bodyMedium?.copyWith(color: context.mutedColor))),
        Text(fmtMoneyK(costLikely), style: DispatchTheme.numeric(size: 14)),
      ]),
      const SizedBox(height: 4),
      Row(children: [
        Expanded(child: Text('Cost range (±$_tolerance%)', style: context.text.bodyMedium?.copyWith(color: context.mutedColor))),
        Text(
          costLikely == null ? '—' : '${fmtMoneyK(costLikely * (1 - _tolerance / 100))} – ${fmtMoneyK(costLikely * (1 + _tolerance / 100))}',
          style: DispatchTheme.numeric(size: 14),
        ),
      ]),
    ]);
  }

  Widget _calibrationPanel() {
    final cal = asMap(_data?['calibration']);
    final byStamp = _listOf('by_stamp', cal);
    return Panel(
      title: 'Calibration',
      subtitle: "How this team's estimates have landed",
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        NoteCard(
          tone: 'warn',
          icon: Icons.trending_up_rounded,
          title: asStrOr(cal['recommendation'], 'Not enough delivered work to calibrate yet.'),
        ),
        if (byStamp.isNotEmpty) ...[
          const SizedBox(height: Sp.lg),
          SizedBox(
            height: 130,
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              for (final b in byStamp)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                      Text('×${(asDouble(b['median_ratio']) ?? 1).toStringAsFixed(2)}',
                          style: DispatchTheme.numeric(size: 12, color: (asDouble(b['median_ratio']) ?? 1) > 1.1 ? DispatchColors.orange : context.inkColor)),
                      const SizedBox(height: 4),
                      Container(
                        height: (((asDouble(b['median_ratio']) ?? 1) / 1.6) * 80).clamp(8, 92),
                        decoration: BoxDecoration(
                          color: (asDouble(b['median_ratio']) ?? 1) > 1.1 ? DispatchColors.orange : DispatchColors.ink,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text('${asStrOr(b['name'], asStrOr(b['stamp'], ''))} · ${asIntOr(b['n'], 0)}',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.labelSmall),
                    ]),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: Sp.sm),
          Text('Actual ÷ most-likely, median by size class · items delivered in the last 12 months', style: context.text.bodySmall),
        ],
      ]),
    );
  }

  Widget _similarPanel() {
    final similar = _listOf('similar');
    return Panel(
      title: 'Similar work',
      subtitle: 'Same skills, same size',
      padding: EdgeInsets.zero,
      child: similar.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(Sp.xl),
              child: EmptyState(
                icon: Icons.content_copy_outlined,
                title: 'Nothing comparable yet',
                message: 'Delivered work of the same size with overlapping skills will appear here.',
                compact: true,
              ),
            )
          : Column(children: [for (final s in similar.take(4)) _similarTile(s)]),
    );
  }

  Widget _similarTile(Map<String, dynamic> s, {bool inSheet = false}) {
    return Container(
      padding: const EdgeInsets.all(Sp.md),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.borderColor))),
      child: Row(children: [
        SizeStamp(asStr(s['size_stamp']), size: 24),
        const SizedBox(width: Sp.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${asStrOr(s['ref'], '')} ${asStrOr(s['title'], '')}', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.titleSmall),
            Text(
              dotJoin([
                'Estimated ${_num(asDouble(s['estimated_days']))}',
                'actual ${fmtDaysShort(asDouble(s['actual_days']))}',
                asDate(s['delivered_at']) == null ? null : '${fmtDayMonth(asDate(s['delivered_at']))} ${asDate(s['delivered_at'])!.year}',
              ]),
              style: context.text.bodySmall,
            ),
          ]),
        ),
        TextButton(
          onPressed: () {
            if (inSheet) Navigator.of(context).pop();
            _applySimilar(s);
          },
          child: const Text('Use'),
        ),
      ]),
    );
  }

  Widget _historyPanel(List<Map<String, dynamic>> versions) {
    return Panel(
      title: 'Estimate history',
      child: versions.isEmpty
          ? const EmptyState(icon: Icons.history_rounded, title: 'No versions yet', message: 'The first save creates version 1.', compact: true)
          : Column(children: [for (final v in versions) _versionTile(v)]),
    );
  }

  Widget _versionTile(Map<String, dynamic> v) {
    final latestVersion = asIntOr(asMap(_data?['latest'])['version'], -1);
    final isLatest = asIntOr(v['version'], -2) == latestVersion;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Icon(
            isLatest ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
            size: 16,
            color: isLatest ? DispatchColors.orange : context.mutedColor,
          ),
        ),
        const SizedBox(width: Sp.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'v${asIntOr(v['version'], 0)} · ${asStrOr(v['method'], '') == 'size' ? 'size class' : '${_num(asDouble(v['optimistic']))} / ${_num(asDouble(v['likely']))} / ${_num(asDouble(v['pessimistic']))} days'}',
              style: context.text.titleSmall,
            ),
            const SizedBox(height: 2),
            Text(
              dotJoin([asStr(v['author_name']), fmtDayMonth(asDate(v['created_at'])), asStr(v['reason'])]),
              style: context.text.bodySmall,
            ),
          ]),
        ),
      ]),
    );
  }
}

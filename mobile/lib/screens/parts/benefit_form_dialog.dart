import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/api.dart';
import '../../services/format.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/team_widgets.dart';
import '../../widgets/widgets.dart';

/// One benefit type as `benefits.php list.types` publishes it.
class BenefitTypeOption {
  const BenefitTypeOption({required this.type, required this.label});
  final String type;
  final String label;
  factory BenefitTypeOption.fromJson(Map<String, dynamic> j) => BenefitTypeOption(type: asStrOr(j['type'], ''), label: asStrOr(j['label'], ''));
}

/// Add or edit a benefit (BEN-01/BEN-02), shared by the register and the work
/// item screen. Resolves `true` after a successful save.
///
/// The *Financial / Non-financial* switch drives the form: financial needs an
/// annual value; non-financial hides it, needs a point on the qualitative scale
/// and may carry a proxy value. Scale labels and types come from
/// `benefits.php list` — passed in when the caller already has them, fetched
/// otherwise — and any validation message from `save` is shown verbatim.
Future<bool> showBenefitFormDialog(
  BuildContext context, {
  int? workItemId,
  String? workItemLabel,
  Benefit? benefit,
  List<BenefitTypeOption> types = const [],
  List<QualitativeScale> scales = const [],
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => BenefitFormDialog(workItemId: workItemId, workItemLabel: workItemLabel, benefit: benefit, types: types, scales: scales),
  );
  return saved == true;
}

class BenefitFormDialog extends StatefulWidget {
  const BenefitFormDialog({super.key, this.workItemId, this.workItemLabel, this.benefit, this.types = const [], this.scales = const []});

  /// Fixed when opened from a work item; otherwise the form offers a search.
  final int? workItemId;
  final String? workItemLabel;
  final Benefit? benefit;
  final List<BenefitTypeOption> types;
  final List<QualitativeScale> scales;

  @override
  State<BenefitFormDialog> createState() => _BenefitFormDialogState();
}

class _BenefitFormDialogState extends State<BenefitFormDialog> {
  /// Only if `list` is unreachable: the six types the schema has always had.
  static const _fallbackTypes = [
    BenefitTypeOption(type: 'cost_avoidance', label: 'Cost avoidance'),
    BenefitTypeOption(type: 'productivity', label: 'Productivity'),
    BenefitTypeOption(type: 'revenue', label: 'Revenue'),
    BenefitTypeOption(type: 'risk_reduction', label: 'Risk reduction'),
    BenefitTypeOption(type: 'compliance', label: 'Compliance'),
    BenefitTypeOption(type: 'other', label: 'Other'),
  ];

  final TextEditingController _search = TextEditingController();
  late final TextEditingController _value = TextEditingController(
      text: widget.benefit == null || !widget.benefit!.isFinancial ? '' : widget.benefit!.annualValue.round().toString());
  late final TextEditingController _proxy = TextEditingController(text: widget.benefit?.proxyValue == null ? '' : widget.benefit!.proxyValue!.round().toString());
  late final TextEditingController _owner = TextEditingController(text: widget.benefit?.ownerName ?? '');
  late final TextEditingController _narrative = TextEditingController(text: widget.benefit?.narrative);

  late List<BenefitTypeOption> _types = widget.types;
  late List<QualitativeScale> _scales = widget.scales;
  bool _loadingOptions = false;

  Timer? _debounce;
  bool _searching = false;
  List<({int id, String ref, String title})> _results = const [];
  int? _workItemId;
  String? _workItemLabel;

  late bool _financial = widget.benefit?.isFinancial ?? true;
  late String _type = widget.benefit?.type ?? 'cost_avoidance';
  late int? _scale = widget.benefit?.qualitativeScale;
  late String _confidence = widget.benefit?.confidence ?? 'medium';
  late DateTime? _from = widget.benefit?.realisationFrom;
  late String _status = widget.benefit?.status ?? 'planned';
  bool _busy = false;
  String? _error;

  bool get _isNew => widget.benefit == null;

  @override
  void initState() {
    super.initState();
    _workItemId = widget.workItemId ?? widget.benefit?.workItemId;
    _workItemLabel = widget.workItemLabel ?? (widget.benefit == null ? null : dotJoin([widget.benefit!.workItemRef, widget.benefit!.workItemTitle]));
    if (_types.isEmpty || _scales.isEmpty) _loadOptions();
  }

  /// Types and scale labels are the server's. One small list call fetches both,
  /// scoped to the item when we have one so it stays light.
  Future<void> _loadOptions() async {
    setState(() => _loadingOptions = true);
    try {
      final r = await Api.post('benefits.php', 'list', {if (_workItemId != null) 'work_item_id': _workItemId});
      if (!mounted) return;
      setState(() {
        if (_types.isEmpty) _types = asList(r['types'], BenefitTypeOption.fromJson);
        if (_scales.isEmpty) _scales = asList(r['qualitative_scales'], QualitativeScale.fromJson);
        _loadingOptions = false;
      });
    } on ApiException {
      if (mounted) setState(() => _loadingOptions = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _value.dispose();
    _proxy.dispose();
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
        if (raw is Map) items.add((id: asIntOr(raw['id'], 0), ref: asStrOr(raw['ref'], ''), title: asStrOr(raw['title'], '')));
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
    final d = await showDatePicker(context: context, initialDate: _from ?? now, firstDate: DateTime(now.year - 2), lastDate: DateTime(now.year + 5));
    if (d != null) setState(() => _from = d);
  }

  static String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  double? _num(TextEditingController c) {
    final t = c.text.trim().replaceAll(',', '').replaceAll('£', '');
    return t.isEmpty ? null : double.tryParse(t);
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final proxy = _num(_proxy);
      await Api.post('benefits.php', 'save', {
        if (!_isNew) 'id': widget.benefit!.id,
        if (_workItemId != null) 'work_item_id': _workItemId,
        'type': _type,
        'is_financial': _financial,
        // A non-financial benefit has no annual value; the server keeps it at 0.
        'annual_value': _financial ? (_num(_value) ?? 0) : 0,
        'confidence': _confidence,
        if (!_financial) 'qualitative_scale': _scale,
        if (!_financial && proxy != null) 'proxy_value': proxy,
        if (_from != null) 'realisation_from': _iso(_from!),
        'owner_name': _owner.text.trim(),
        'narrative': _narrative.text.trim(),
        'status': _status,
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      // The server's validation message, word for word (it names the valid scale).
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
    final types = _types.isEmpty ? _fallbackTypes : _types;
    if (!types.any((t) => t.type == _type)) _type = types.first.type;
    final canSave = _workItemId != null && !_busy && (_financial || _scale != null);

    return AlertDialog(
      title: Text(_isNew ? 'Add benefit' : 'Edit benefit'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_isNew && widget.workItemId == null) ...[
              TmField(
                label: 'Work item',
                hint: 'Search by reference or title, for example “WI-1042” or “telemetry”.',
                child: TextField(
                  controller: _search,
                  onChanged: _onSearchChanged,
                  decoration: InputDecoration(
                    hintText: 'Search work items',
                    prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    suffixIcon: _searching
                        ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                        : null,
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
                  child: ListView(shrinkWrap: true, children: [
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
                  ]),
                ),
              const SizedBox(height: Sp.md),
            ] else if (_workItemLabel != null) ...[
              Text(_workItemLabel!, style: context.text.titleSmall),
              const SizedBox(height: Sp.md),
            ],
            TmField(
              label: 'Kind of benefit',
              hint: _financial
                  ? 'A financial benefit counts in the register totals and is realised in money.'
                  : 'A non-financial benefit is rated on a scale. It feeds the priority score but never the money totals.',
              child: SegmentedTabs(
                labels: const ['Financial', 'Non-financial'],
                selected: _financial ? 0 : 1,
                compact: true,
                onChanged: (i) => setState(() {
                  _financial = i == 0;
                  _error = null;
                }),
              ),
            ),
            const SizedBox(height: Sp.md),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: TmField(
                  label: 'Type',
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('type-${types.length}'),
                    initialValue: _type,
                    isExpanded: true,
                    items: [for (final t in types) DropdownMenuItem(value: t.type, child: Text(t.label, overflow: TextOverflow.ellipsis))],
                    onChanged: (v) => setState(() => _type = v ?? _type),
                  ),
                ),
              ),
              const SizedBox(width: Sp.md),
              Expanded(
                child: _financial
                    ? TmField(
                        label: 'Annual value (£)',
                        child: TextField(controller: _value, keyboardType: TextInputType.number),
                      )
                    : TmField(
                        label: 'Scale',
                        child: DropdownButtonFormField<int>(
                          key: ValueKey('scale-${_scales.length}'),
                          initialValue: _scales.any((s) => s.scale == _scale) ? _scale : null,
                          isExpanded: true,
                          hint: Text(_loadingOptions ? 'Loading…' : 'Choose', overflow: TextOverflow.ellipsis),
                          items: [
                            for (final s in _scales) DropdownMenuItem(value: s.scale, child: Text('${s.scale} · ${s.label}', overflow: TextOverflow.ellipsis)),
                          ],
                          onChanged: (v) => setState(() => _scale = v),
                        ),
                      ),
              ),
            ]),
            if (!_financial) ...[
              const SizedBox(height: Sp.md),
              TmField(
                label: 'Proxy value (£, optional)',
                hint: 'A currency-equivalent stand-in used only for the priority score. Left blank, the per-point value from the policy applies.',
                child: TextField(controller: _proxy, keyboardType: TextInputType.number),
              ),
            ],
            const SizedBox(height: Sp.md),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: TmField(
                  label: 'Confidence',
                  child: DropdownButtonFormField<String>(
                    initialValue: _confidence,
                    isExpanded: true,
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
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: TmField(label: 'Owner', child: TextField(controller: _owner))),
              const SizedBox(width: Sp.md),
              Expanded(
                child: TmField(
                  label: 'Status',
                  child: DropdownButtonFormField<String>(
                    initialValue: _status,
                    isExpanded: true,
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
        PrimaryButton('Save', busy: _busy, onPressed: canSave ? _save : null),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/api.dart';
import '../../services/format.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/adm_metrics.dart';
import '../../widgets/team_widgets.dart';
import '../../widgets/widgets.dart';

// ─── Day rates (EST-05, and the first half of ADM-06) ─────────────────────

/// Day rates for the workspace, with add and edit for administrators.
///
/// `workspace_config.php save_day_rate` has always existed; nothing in the
/// client called it, so a rate could only be changed by seed data even though
/// the estimate screen derives every cost range from it. Rates are versioned by
/// effective date rather than overwritten, which is why the table leads with
/// that column and marks the one in force.
class AdmDayRatesPanel extends StatelessWidget {
  const AdmDayRatesPanel({
    super.key,
    required this.rates,
    required this.isAdmin,
    required this.onChanged,
    this.workspaceCurrency = 'GBP',
    this.today,
  });

  /// Rows exactly as `workspace_config.php get` returns them.
  final List<Map<String, dynamic>> rates;
  final bool isAdmin;
  final Future<void> Function() onChanged;
  final String workspaceCurrency;
  final DateTime? today;

  static String symbolFor(String? currency) => switch ((currency ?? 'GBP').toUpperCase()) {
        'GBP' => '£',
        'USD' => r'$',
        'EUR' => '€',
        _ => '',
      };

  static String money(dynamic rate, String? currency) {
    final symbol = symbolFor(currency);
    final text = fmtMoney(asDouble(rate), symbol: symbol);
    return symbol.isEmpty ? '$text ${(currency ?? '').toUpperCase()}'.trim() : text;
  }

  /// Mirrors `items_lib.php blended_day_rate()`: the most recent rate whose
  /// effective-from date has passed, blended rates first.
  int? get _inForceId {
    final now = today ?? DateTime.now();
    final live = rates.where((r) {
      final from = asDate(r['effective_from']);
      return from == null || !from.isAfter(now);
    }).toList();
    if (live.isEmpty) return null;
    live.sort((a, b) {
      final blended = (asBool(b['is_blended']) ? 1 : 0) - (asBool(a['is_blended']) ? 1 : 0);
      if (blended != 0) return blended;
      final da = asDate(a['effective_from']) ?? DateTime(1900);
      final db = asDate(b['effective_from']) ?? DateTime(1900);
      return db.compareTo(da);
    });
    return asInt(live.first['id']);
  }

  Future<void> _edit(BuildContext context, Map<String, dynamic>? rate) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _AdmDayRateDialog(rate: rate, workspaceCurrency: workspaceCurrency),
    );
    if (saved == true) await onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final inForce = _inForceId;
    final sorted = [...rates]..sort((a, b) {
        final da = asDate(a['effective_from']) ?? DateTime(1900);
        final db = asDate(b['effective_from']) ?? DateTime(1900);
        return db.compareTo(da);
      });

    return TmMetricPanel(
      title: 'Day rates',
      subtitle: 'Turn effort days into an indicative cost',
      definition: AdmMetrics.dayRate,
      trailing: isAdmin ? SecondaryButton('Add rate', icon: Icons.add_rounded, onPressed: () => _edit(context, null)) : null,
      padding: EdgeInsets.zero,
      dividerAfterHeader: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (sorted.isEmpty)
          Padding(
            padding: const EdgeInsets.all(Sp.lg),
            child: EmptyState(
              icon: Icons.payments_outlined,
              title: 'No day rate set',
              message: 'Estimates fall back to a default rate until a blended rate is added.',
              compact: true,
              action: isAdmin ? PrimaryButton('Add rate', icon: Icons.add_rounded, onPressed: () => _edit(context, null)) : null,
            ),
          )
        else
          LayoutBuilder(builder: (context, c) {
            if (TmTable.isNarrow(c.maxWidth)) {
              return Padding(
                padding: const EdgeInsets.all(Sp.lg),
                child: Column(children: [
                  for (final r in sorted)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Sp.md),
                      child: DispatchCard(
                        onTap: isAdmin ? () => _edit(context, r) : null,
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Row(children: [
                            Expanded(child: Text(asStrOr(r['name'], 'Rate'), style: context.text.titleSmall)),
                            if (asInt(r['id']) == inForce) const ToneChip('In force today', tone: 'ok', compact: true),
                          ]),
                          const SizedBox(height: 4),
                          Text(
                            dotJoin([
                              '${money(r['rate'], asStr(r['currency']))} per day',
                              'from ${fmtShortDate(asDate(r['effective_from']))}',
                              asBool(r['is_blended']) ? 'blended' : 'per role',
                            ]),
                            style: context.text.bodySmall?.copyWith(color: context.mutedColor),
                          ),
                        ]),
                      ),
                    ),
                ]),
              );
            }
            return TmTable(
              columns: const [
                TmCol('Rate', flex: 3),
                TmCol('Per day', width: 120, align: TextAlign.right),
                TmCol('Effective from', width: 150),
                TmCol('Basis', width: 110),
                TmCol('', width: 150),
                TmCol('', width: 44),
              ],
              rows: [
                for (final r in sorted)
                  [
                    Text(asStrOr(r['name'], 'Rate'), style: context.text.titleSmall, overflow: TextOverflow.ellipsis),
                    Text(money(r['rate'], asStr(r['currency'])),
                        style: DispatchTheme.numeric(size: 13.5, weight: FontWeight.w700, color: context.inkColor)),
                    Text(fmtShortDate(asDate(r['effective_from'])), style: context.text.bodyMedium),
                    ToneChip(asBool(r['is_blended']) ? 'Blended' : 'Per role', compact: true),
                    asInt(r['id']) == inForce
                        ? const ToneChip('In force today', tone: 'ok', compact: true)
                        : Text(
                            (asDate(r['effective_from'])?.isAfter(today ?? DateTime.now()) ?? false) ? 'Starts later' : 'Superseded',
                            style: context.text.bodySmall?.copyWith(color: context.mutedColor),
                          ),
                    isAdmin
                        ? IconButton(
                            onPressed: () => _edit(context, r),
                            icon: const Icon(Icons.edit_outlined, size: 17),
                            tooltip: 'Edit ${asStrOr(r['name'], 'rate')}',
                            visualDensity: VisualDensity.compact,
                          )
                        : const SizedBox(),
                  ],
              ],
            );
          }),
        const Padding(
          padding: EdgeInsets.all(Sp.lg),
          child: TmInfoBox(
            'Rates are versioned by effective date, not overwritten: adding one with a later date leaves the old rate in place for anything already costed. '
            'The estimate screen uses the blended rate in force today, multiplied by the planning effort, to show its cost range.',
          ),
        ),
      ]),
    );
  }
}

class _AdmDayRateDialog extends StatefulWidget {
  const _AdmDayRateDialog({this.rate, required this.workspaceCurrency});
  final Map<String, dynamic>? rate;
  final String workspaceCurrency;

  @override
  State<_AdmDayRateDialog> createState() => _AdmDayRateDialogState();
}

class _AdmDayRateDialogState extends State<_AdmDayRateDialog> {
  late final TextEditingController _name = TextEditingController(text: asStrOr(widget.rate?['name'], ''));
  late final TextEditingController _rate = TextEditingController(text: _initialRate());
  late final TextEditingController _currency =
      TextEditingController(text: asStrOr(widget.rate?['currency'], widget.workspaceCurrency).toUpperCase());
  late DateTime _from = asDate(widget.rate?['effective_from']) ?? DateTime.now();
  late bool _blended = asBool(widget.rate?['is_blended'], fallback: widget.rate == null);
  bool _busy = false;
  String? _error;

  String _initialRate() {
    final v = asDouble(widget.rate?['rate']);
    if (v == null) return '';
    return v == v.roundToDouble() ? v.round().toString() : v.toString();
  }

  @override
  void dispose() {
    _name.dispose();
    _rate.dispose();
    _currency.dispose();
    super.dispose();
  }

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _from,
      firstDate: DateTime(_from.year - 5),
      lastDate: DateTime(_from.year + 5),
      helpText: 'Effective from',
    );
    if (d != null) setState(() => _from = d);
  }

  Future<void> _save() async {
    final rate = double.tryParse(_rate.text.trim());
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Give the rate a name, for example “Blended engineer”.');
      return;
    }
    if (rate == null || rate <= 0) {
      setState(() => _error = 'Enter the rate as a number of whole currency units per day, for example 700.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.post('workspace_config.php', 'save_day_rate', {
        if (widget.rate != null) 'id': asInt(widget.rate!['id']),
        'name': _name.text.trim(),
        'rate': rate,
        'currency': _currency.text.trim().isEmpty ? widget.workspaceCurrency : _currency.text.trim().toUpperCase(),
        'effective_from': _iso(_from),
        'is_blended': _blended,
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
      title: Text(widget.rate == null ? 'Add day rate' : 'Edit ${asStrOr(widget.rate!['name'], 'day rate')}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TmField(
              label: 'Name',
              hint: 'For example “Blended engineer” or “Senior data engineer”.',
              child: TextField(controller: _name, autofocus: widget.rate == null),
            ),
            const SizedBox(height: Sp.md),
            Row(children: [
              Expanded(
                flex: 2,
                child: TmField(
                  label: 'Rate per day',
                  child: TextField(controller: _rate, keyboardType: TextInputType.number),
                ),
              ),
              const SizedBox(width: Sp.md),
              Expanded(child: TmField(label: 'Currency', child: TextField(controller: _currency))),
            ]),
            const SizedBox(height: Sp.md),
            TmField(
              label: 'Effective from',
              hint: 'Rates are versioned by this date; the one in force today is used for cost.',
              child: SecondaryButton(fmtShortDate(_from), icon: Icons.calendar_today_outlined, expand: true, onPressed: _pickDate),
            ),
            const SizedBox(height: Sp.sm),
            TmSwitchRow(
              label: 'Blended rate',
              subtitle: 'A blended rate applies to every role and is the one the estimate screen uses.',
              value: _blended,
              onChanged: (v) => setState(() => _blended = v),
            ),
            if (_error != null) TmInlineError(_error!),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        PrimaryButton('Save rate', busy: _busy, onPressed: _save),
      ],
    );
  }
}

// ─── Objective weights (SCH-02) ───────────────────────────────────────────

/// The seven objective terms of section 8.6, editable.
///
/// The engine already reads `scheduling_policies.objective_weights`; Settings
/// only ever printed them. Each term carries the meaning the requirement gives
/// it, because a bare number called "contextSwitching" tells an administrator
/// nothing about what raising it would do.
class AdmObjectiveWeights extends StatelessWidget {
  const AdmObjectiveWeights({
    super.key,
    required this.weights,
    required this.isAdmin,
    required this.onChanged,
    required this.policyVersion,
    this.targetLoadMin = 80,
    this.targetLoadMax = 90,
  });

  /// The live weights with any unsaved edits already merged in.
  final Map<String, dynamic> weights;
  final bool isAdmin;
  final void Function(String key, num value) onChanged;
  final int policyVersion;
  final int targetLoadMin;
  final int targetLoadMax;

  static const terms = <({String key, String label, String defaultWeight, String meaning})>[
    (
      key: 'valueCompletion',
      label: 'Value-weighted completion',
      defaultWeight: '1.0',
      meaning: 'Sum over items of priority score × completion week; earlier completion of high-score items is better.',
    ),
    (
      key: 'lateness',
      label: 'Lateness',
      defaultWeight: '3.0',
      meaning: 'Sum over items of working days finished after the needed-by date, weighted by priority score.',
    ),
    (
      key: 'unscheduledValue',
      label: 'Unscheduled value',
      defaultWeight: '5.0',
      meaning: 'Priority score of items left unscheduled inside the planning horizon.',
    ),
    (
      key: 'loadImbalance',
      label: 'Load imbalance',
      defaultWeight: '0.5',
      meaning: 'Deviation of each person’s weekly load from the target band.',
    ),
    (
      key: 'contextSwitching',
      label: 'Context switching',
      defaultWeight: '0.5',
      meaning: 'Number of item switches per person per week beyond one.',
    ),
    (
      key: 'stabilityPlanned',
      label: 'Stability',
      defaultWeight: '2.0',
      meaning: 'Assignment-days moved relative to the committed plan, inside the planned window. '
          'Committed-window moves are hard-locked unless someone unlocks them, and indicative moves cost nothing.',
    ),
    (
      key: 'preferences',
      label: 'Preferences',
      defaultWeight: '0.2',
      meaning: 'Assignments against a person’s stated avoid list; a bonus for development pairing.',
    ),
  ];

  String _meaning(({String key, String label, String defaultWeight, String meaning}) t) =>
      t.key == 'loadImbalance' ? 'Deviation of each person’s weekly load from the target band ($targetLoadMin to $targetLoadMax%).' : t.meaning;

  @override
  Widget build(BuildContext context) {
    final known = terms.map((t) => t.key).toSet();
    final extra = weights.keys.where((k) => !known.contains(k)).toList()..sort();

    return Panel(
      title: 'Objective weights',
      subtitle: 'What the engine minimises when it proposes a plan',
      child: LayoutBuilder(builder: (context, c) {
        final narrow = c.maxWidth < 520;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < terms.length; i++) ...[
            if (i > 0) Divider(height: Sp.lg, thickness: 1, color: context.borderColor),
            _row(context, terms[i].key, terms[i].label, '${_meaning(terms[i])} Default ${terms[i].defaultWeight}.', narrow),
          ],
          for (final k in extra) ...[
            Divider(height: Sp.lg, thickness: 1, color: context.borderColor),
            _row(context, k, humanise(k), 'Set outside this form — the engine reads it from the policy.', narrow),
          ],
          const SizedBox(height: Sp.md),
          TmInfoBox(
            'A higher weight makes the engine work harder to avoid that cost. '
            'Saving writes a new scheduling policy version (the current one is v$policyVersion) and keeps the old one for the audit trail; '
            'the engine picks the new weights up on its next proposal, and plans already made keep the weights they were made with.',
          ),
        ]);
      }),
    );
  }

  Widget _row(BuildContext context, String key, String label, String meaning, bool narrow) {
    final field = SizedBox(
      width: 104,
      child: TextFormField(
        key: ValueKey('objective-$key'),
        initialValue: _text(weights[key]),
        enabled: isAdmin,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.right,
        decoration: const InputDecoration(isDense: true),
        onChanged: (s) {
          final v = num.tryParse(s.trim());
          if (v != null) onChanged(key, v);
        },
      ),
    );
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: context.text.titleSmall),
      const SizedBox(height: 2),
      Text(meaning, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
    ]);

    if (narrow) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(child: Text(label, style: context.text.titleSmall)),
            const SizedBox(width: Sp.md),
            field,
          ]),
          const SizedBox(height: 4),
          Text(meaning, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(child: text),
        const SizedBox(width: Sp.lg),
        field,
      ]),
    );
  }

  static String _text(dynamic v) {
    final d = asDouble(v);
    if (d == null) return '';
    return d == d.roundToDouble() ? d.round().toString() : d.toString();
  }
}

// ─── Work type size rules (CFG-02) ────────────────────────────────────────

/// One size class a work type can use.
typedef AdmSizeOption = ({String stamp, String name});

/// Default size and allowed sizes for a work type (CFG-02).
///
/// `save_work_type` has always accepted `default_size_stamp` and
/// `allowed_sizes`, and the Add work form already uses the default — the
/// Settings form simply never offered either.
class AdmSizeRules extends StatelessWidget {
  const AdmSizeRules({
    super.key,
    required this.stamps,
    required this.defaultStamp,
    required this.allowed,
    required this.onDefaultChanged,
    required this.onAllowedChanged,
    this.enabled = true,
    this.typePlural = 'items',
  });

  final List<AdmSizeOption> stamps;
  final String? defaultStamp;

  /// Empty means every size is allowed, which is how the API stores it (null).
  final Set<String> allowed;
  final ValueChanged<String?> onDefaultChanged;
  final ValueChanged<Set<String>> onAllowedChanged;
  final bool enabled;
  final String typePlural;

  /// Null when the pair is coherent, otherwise the message to show.
  static String? validate(String? defaultStamp, Set<String> allowed) {
    if (defaultStamp == null || defaultStamp.isEmpty) return null;
    if (allowed.isEmpty || allowed.contains(defaultStamp)) return null;
    return 'The default size must be one of the allowed sizes.';
  }

  @override
  Widget build(BuildContext context) {
    final names = {for (final s in stamps) s.stamp: s.name};
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      TmField(
        label: 'Default size',
        hint: 'Pre-selected on the Add work form when someone adds ${typePlural.toLowerCase()}.',
        child: DropdownButtonFormField<String?>(
          initialValue: stamps.any((s) => s.stamp == defaultStamp) ? defaultStamp : null,
          isDense: true,
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('No default')),
            for (final s in stamps)
              DropdownMenuItem<String?>(
                value: s.stamp,
                child: Text('${s.stamp} · ${s.name}', overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: enabled ? onDefaultChanged : null,
        ),
      ),
      const SizedBox(height: Sp.md),
      TmField(
        label: 'Allowed sizes',
        hint: allowed.isEmpty
            ? 'Every size is allowed. Select sizes to restrict the choice.'
            : 'Only ${allowed.toList().join(', ')} can be chosen for ${typePlural.toLowerCase()}.',
        child: Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
          for (final s in stamps)
            FilterChip(
              label: Text('${s.stamp} · ${s.name}'),
              selected: allowed.contains(s.stamp),
              onSelected: enabled
                  ? (on) {
                      final next = {...allowed};
                      if (on) {
                        next.add(s.stamp);
                      } else {
                        next.remove(s.stamp);
                      }
                      onAllowedChanged(next);
                    }
                  : null,
              tooltip: names[s.stamp],
              visualDensity: VisualDensity.compact,
            ),
          if (allowed.isNotEmpty && enabled)
            ActionChip(
              label: const Text('Allow all'),
              avatar: const Icon(Icons.clear_rounded, size: 15),
              onPressed: () => onAllowedChanged(<String>{}),
              visualDensity: VisualDensity.compact,
            ),
        ]),
      ),
    ]);
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/models.dart';
import '../../services/api.dart';
import '../../services/format.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/widgets.dart';

/// The Add work form (mobile-add-work). Used by the phone screen and by the
/// desktop dialog opened from the Pipeline toolbar.
///
/// Type and size pickers use the configured names, colours and stamps; the
/// readiness note is derived from the selected type's policy.
class AddWorkForm extends StatefulWidget {
  const AddWorkForm({super.key, required this.onCreated, this.onCancel, this.submitLabel = 'Add to pipeline'});

  /// Called with the new item's ref once `work_items.php create` succeeds.
  final void Function(String ref) onCreated;
  final VoidCallback? onCancel;
  final String submitLabel;

  @override
  State<AddWorkForm> createState() => _AddWorkFormState();
}

class _SkillPick {
  _SkillPick(this.skill, this.minLevel);
  final Skill skill;
  int minLevel;
}

class _AddWorkFormState extends State<AddWorkForm> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _summary = TextEditingController();
  final _requestedBy = TextEditingController();
  final _sponsor = TextEditingController();
  final _effortDays = TextEditingController();
  final _benefitValue = TextEditingController();
  final _tags = TextEditingController();

  WorkType? _type;
  SizeClass? _size;
  DateTime? _neededBy;
  DateTime? _earliestStart;
  String _benefitType = 'cost_avoidance';
  String _confidence = 'medium';
  String _severity = 'P3';
  final List<_SkillPick> _skills = [];
  List<Skill> _catalogue = const [];
  bool _submitting = false;
  String? _error;

  static const _benefitTypes = <String, String>{
    'cost_avoidance': 'Cost avoidance',
    'productivity': 'Productivity',
    'revenue': 'Revenue',
    'risk_reduction': 'Risk reduction',
    'compliance': 'Compliance',
    'other': 'Other',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prime());
  }

  @override
  void dispose() {
    _title.dispose();
    _summary.dispose();
    _requestedBy.dispose();
    _sponsor.dispose();
    _effortDays.dispose();
    _benefitValue.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _prime() async {
    final cfg = context.read<WorkspaceConfig>();
    if (!cfg.loaded && !cfg.loading) await cfg.load();
    if (!mounted) return;
    setState(() {
      _type ??= cfg.activeWorkTypes.isEmpty ? null : cfg.activeWorkTypes.first;
      _size ??= _sizesFor(_type).where((s) => !s.isCustom).firstOrNull;
    });
    try {
      final r = await Api.post('skills.php', 'list');
      if (!mounted) return;
      setState(() => _catalogue = asList(r['skills'], Skill.fromJson).where((s) => !s.retired).toList());
    } on ApiException {
      // The skills picker simply stays empty; everything else still works.
    }
  }

  List<SizeClass> _sizesFor(WorkType? type) {
    final cfg = context.read<WorkspaceConfig>();
    if (type == null) return cfg.defaultSizeClasses;
    var list = cfg.sizeClasses.where((s) => s.workTypeId == type.id).toList();
    if (list.isEmpty) list = cfg.defaultSizeClasses;
    if (type.allowedSizes.isNotEmpty) {
      final allowed = type.allowedSizes.map((s) => s.toUpperCase()).toSet();
      list = list.where((s) => allowed.contains(s.stamp.toUpperCase())).toList();
    }
    list.sort((a, b) => a.isCustom == b.isCustom ? a.sortOrder.compareTo(b.sortOrder) : (a.isCustom ? 1 : -1));
    return list;
  }

  String get _readinessNote {
    final t = _type;
    if (t == null) return 'Choose a work type to see what happens next.';
    if (t.isInterrupt) {
      return 'This item will enter the pipeline as Ready, prioritised by its severity, and can displace planned work through the incident reserve.';
    }
    if (t.requiresEstimate) {
      return 'This item will enter the pipeline as Needs estimate. It cannot be scheduled until it has a rough order of magnitude.';
    }
    if (t.requiresBenefit) {
      return 'This item will enter the pipeline as Needs benefit case. It cannot be scheduled until the benefit is recorded.';
    }
    return 'This item will enter the pipeline as Ready, so the scheduler can place it at the next replan.';
  }

  Future<void> _pickNeededBy() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _neededBy ?? now.add(const Duration(days: 30)),
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
      helpText: 'Needed by',
    );
    if (picked != null && mounted) setState(() => _neededBy = picked);
  }

  Future<void> _pickEarliestStart() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _earliestStart ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
      helpText: 'Earliest start',
    );
    if (picked != null && mounted) setState(() => _earliestStart = picked);
  }

  List<String> get _tagList => _tags.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();

  Future<void> _addSkill() async {
    if (_catalogue.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The skills catalogue could not be loaded.')));
      return;
    }
    final taken = _skills.map((s) => s.skill.id).toSet();
    final available = _catalogue.where((s) => !taken.contains(s.id)).toList();
    if (available.isEmpty) return;
    Skill chosen = available.first;
    int level = 3;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          title: const Text('Add a required skill'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              DropdownButtonFormField<int>(
                initialValue: chosen.id,
                decoration: const InputDecoration(labelText: 'Skill'),
                items: [for (final s in available) DropdownMenuItem(value: s.id, child: Text(s.name))],
                onChanged: (v) => setLocal(() => chosen = available.firstWhere((s) => s.id == v)),
              ),
              const SizedBox(height: Sp.md),
              Text('Minimum level', style: dialogContext.text.labelMedium),
              const SizedBox(height: Sp.sm),
              SegmentedTabs(
                labels: const ['1 Aware', '2 Practitioner', '3 Independent', '4 Expert'],
                selected: level - 1,
                compact: true,
                onChanged: (i) => setLocal(() => level = i + 1),
              ),
            ]),
          ),
          actions: [
            SecondaryButton('Cancel', onPressed: () => Navigator.of(dialogContext).pop(false)),
            PrimaryButton('Add skill', onPressed: () => Navigator.of(dialogContext).pop(true)),
          ],
        ),
      ),
    );
    if (result == true && mounted) setState(() => _skills.add(_SkillPick(chosen, level)));
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final type = _type;
    if (type == null) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final body = <String, dynamic>{
      'title': _title.text.trim(),
      'work_type_id': type.id,
      if (_size != null) 'size_stamp': _size!.stamp,
      if (_size != null && _size!.isCustom) 'custom_effort_days': double.tryParse(_effortDays.text.trim()),
      if (_summary.text.trim().isNotEmpty) 'summary': _summary.text.trim(),
      if (_requestedBy.text.trim().isNotEmpty) 'requested_by': _requestedBy.text.trim(),
      if (_sponsor.text.trim().isNotEmpty) 'sponsor': _sponsor.text.trim(),
      if (_neededBy != null) 'needed_by': _iso(_neededBy!),
      if (_earliestStart != null) 'earliest_start': _iso(_earliestStart!),
      if (_tagList.isNotEmpty) 'tags': _tagList,
      if (type.isInterrupt) 'severity': _severity,
      if (_skills.isNotEmpty)
        'skills': [for (final s in _skills) {'skill_id': s.skill.id, 'min_proficiency': s.minLevel}],
      if (!type.isInterrupt && (double.tryParse(_benefitValue.text.trim().replaceAll(',', '')) ?? 0) > 0)
        'benefit': {
          'type': _benefitType,
          'annual_value': double.parse(_benefitValue.text.trim().replaceAll(',', '')),
          'confidence': _confidence,
        },
    };
    try {
      final r = await Api.post('work_items.php', 'create', body);
      final ref = asStrOr(asMap(r['item'])['ref'], '');
      if (!mounted) return;
      widget.onCreated(ref);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  static String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final cfg = context.watch<WorkspaceConfig>();
    final types = cfg.activeWorkTypes;
    if (!cfg.loaded && types.isEmpty) return const SkeletonPanel(rows: 6);

    final sizes = _sizesFor(_type);

    return Form(
      key: _formKey,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _label('What needs doing?'),
        TextFormField(
          controller: _title,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(hintText: 'A short title, for example Vendor risk scoring dashboard'),
          validator: (v) => (v == null || v.trim().length < 3) ? 'Give the work a title of at least three characters.' : null,
        ),
        _label('Type'),
        _pickerGrid(
          children: [
            for (final t in types)
              _PickerTile(
                selected: _type?.id == t.id,
                onTap: () => setState(() {
                  _type = t;
                  _size = _sizesFor(t).where((s) => !s.isCustom).firstOrNull;
                }),
                child: Row(children: [
                  Container(width: 14, height: 14, decoration: BoxDecoration(color: t.colour, borderRadius: BorderRadius.circular(4))),
                  const SizedBox(width: Sp.sm),
                  Expanded(child: Text(t.name, style: context.text.titleSmall, overflow: TextOverflow.ellipsis)),
                  if (_type?.id == t.id) const Icon(Icons.check_rounded, size: 18),
                ]),
              ),
          ],
        ),
        if (_type?.isInterrupt ?? false) ...[
          _label('Severity'),
          SegmentedTabs(
            labels: const ['P1', 'P2', 'P3', 'P4'],
            selected: ['P1', 'P2', 'P3', 'P4'].indexOf(_severity),
            compact: true,
            onChanged: (i) => setState(() => _severity = ['P1', 'P2', 'P3', 'P4'][i]),
          ),
        ],
        _label('Size'),
        _pickerGrid(
          minTileWidth: 150,
          children: [
            for (final s in sizes)
              _PickerTile(
                selected: _size?.id == s.id,
                onTap: () => setState(() => _size = s),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  SizeStamp(s.stamp, size: 30, dashed: s.isCustom),
                  const SizedBox(height: Sp.sm),
                  Text(s.name, style: context.text.titleSmall),
                  Text(s.isCustom ? 'enter days' : s.rangeLabel, style: context.text.bodySmall),
                ]),
              ),
          ],
        ),
        if (_size?.isCustom ?? false) ...[
          const SizedBox(height: Sp.md),
          TextFormField(
            controller: _effortDays,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: const InputDecoration(labelText: 'Effort in days', hintText: 'for example 24'),
            validator: (v) {
              if (!(_size?.isCustom ?? false)) return null;
              final d = double.tryParse((v ?? '').trim());
              return (d == null || d <= 0) ? 'A Custom size needs an effort in days.' : null;
            },
          ),
        ],
        _label('Dates'),
        LayoutBuilder(builder: (context, box) {
          final side = box.maxWidth < 420;
          final neededBy = _DatePick(
            label: 'Needed by',
            value: _neededBy,
            onPick: _pickNeededBy,
            onClear: () => setState(() => _neededBy = null),
          );
          final earliest = _DatePick(
            label: 'Earliest start',
            value: _earliestStart,
            onPick: _pickEarliestStart,
            onClear: () => setState(() => _earliestStart = null),
          );
          if (side) {
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              neededBy,
              const SizedBox(height: Sp.md),
              earliest,
            ]);
          }
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: neededBy),
            const SizedBox(width: Sp.md),
            Expanded(child: earliest),
          ]);
        }),
        const SizedBox(height: Sp.xs),
        Text(
          'The scheduler will not place this work before its earliest start. Leave it empty when the team could begin at any time.',
          style: context.text.bodySmall,
        ),
        _label('Why it matters'),
        TextFormField(
          controller: _summary,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(hintText: 'What the work is, and what it unblocks or replaces.'),
        ),
        _label('Who is asking'),
        Row(children: [
          Expanded(child: TextFormField(controller: _requestedBy, decoration: const InputDecoration(labelText: 'Requested by'))),
          const SizedBox(width: Sp.md),
          Expanded(child: TextFormField(controller: _sponsor, decoration: const InputDecoration(labelText: 'Sponsor'))),
        ]),
        _label('Tags'),
        TextFormField(
          controller: _tags,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            hintText: 'Comma separated, for example finance, regulatory',
            helperText: 'Tags are searchable from the pipeline.',
          ),
        ),
        if (_tagList.isNotEmpty) ...[
          const SizedBox(height: Sp.sm),
          Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
            for (final t in _tagList) ToneChip(t, compact: true),
          ]),
        ],
        if (!(_type?.isInterrupt ?? false)) ...[
          _label('Benefit, £ per year'),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              flex: 2,
              child: TextFormField(
                controller: _benefitValue,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9,]'))],
                decoration: const InputDecoration(hintText: '95,000'),
              ),
            ),
            const SizedBox(width: Sp.md),
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _benefitType,
                decoration: const InputDecoration(labelText: 'Benefit type'),
                items: [for (final e in _benefitTypes.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: (v) => setState(() => _benefitType = v ?? 'other'),
              ),
            ),
            const SizedBox(width: Sp.md),
            Expanded(
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _confidence,
                decoration: const InputDecoration(labelText: 'Confidence'),
                items: const [
                  DropdownMenuItem(value: 'low', child: Text('Low')),
                  DropdownMenuItem(value: 'medium', child: Text('Medium')),
                  DropdownMenuItem(value: 'high', child: Text('High')),
                ],
                onChanged: (v) => setState(() => _confidence = v ?? 'medium'),
              ),
            ),
          ]),
        ],
        _label('Required skills'),
        Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
          for (final s in _skills)
            InputChip(
              label: Text('${s.skill.name}  L${s.minLevel}'),
              onDeleted: () => setState(() => _skills.remove(s)),
              deleteIcon: const Icon(Icons.close_rounded, size: 16),
            ),
          ActionChip(avatar: const Icon(Icons.add_rounded, size: 16), label: const Text('Add skill'), onPressed: _addSkill),
        ]),
        const SizedBox(height: Sp.lg),
        DispatchCard(
          tint: DispatchColors.tint(DispatchColors.typeBlue, opacity: context.isDark ? 0.16 : 0.08),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline_rounded, size: 18, color: context.mutedColor),
            const SizedBox(width: Sp.sm),
            Expanded(child: Text(_readinessNote, style: context.text.bodySmall?.copyWith(color: context.inkColor))),
          ]),
        ),
        if (_error != null) ...[
          const SizedBox(height: Sp.md),
          ErrorState(title: 'The item could not be added', message: _error, compact: true),
        ],
        const SizedBox(height: Sp.lg),
        // Wrap, so a long submit label and a cancel button stack on a narrow phone
        // instead of running off the edge.
        Wrap(alignment: WrapAlignment.end, spacing: Sp.md, runSpacing: Sp.sm, children: [
          if (widget.onCancel != null) SecondaryButton('Cancel', onPressed: widget.onCancel),
          PrimaryButton(widget.submitLabel, icon: Icons.add_rounded, busy: _submitting, onPressed: _submit),
        ]),
      ]),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(top: Sp.lg, bottom: Sp.sm),
        child: Text(text, style: context.text.titleSmall),
      );

  Widget _pickerGrid({required List<Widget> children, double minTileWidth = 200}) {
    return LayoutBuilder(builder: (context, box) {
      final cols = (box.maxWidth / minTileWidth).floor().clamp(1, 4);
      final width = (box.maxWidth - (cols - 1) * Sp.md) / cols;
      return Wrap(
        spacing: Sp.md,
        runSpacing: Sp.md,
        children: [for (final c in children) SizedBox(width: width, child: c)],
      );
    });
  }
}

/// Labelled date button used for needed-by and earliest start (PIP-01).
class _DatePick extends StatelessWidget {
  const _DatePick({required this.label, required this.value, required this.onPick, required this.onClear});

  final String label;
  final DateTime? value;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: context.text.labelMedium?.copyWith(color: context.mutedColor)),
      const SizedBox(height: Sp.xs),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onPick,
            icon: const Icon(Icons.calendar_today_rounded, size: 18),
            label: Align(
              alignment: Alignment.centerLeft,
              child: Text(value == null ? 'Choose a date' : fmtDate(value), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
        if (value != null)
          IconButton(
            tooltip: 'Clear the ${label.toLowerCase()} date',
            onPressed: onClear,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
      ]),
    ]);
  }
}

class _PickerTile extends StatelessWidget {
  const _PickerTile({required this.child, required this.selected, required this.onTap});
  final Widget child;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: DispatchRadius.cardR,
        child: Container(
          padding: const EdgeInsets.all(Sp.md),
          decoration: BoxDecoration(
            color: context.panelColor,
            borderRadius: DispatchRadius.cardR,
            border: Border.all(color: selected ? DispatchColors.ink : context.borderColor, width: selected ? 2 : 1),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Desktop dialog wrapper for [AddWorkForm] (Pipeline → Add work).
Future<String?> showAddWorkDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Add work'),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: AddWorkForm(
            onCreated: (ref) => Navigator.of(dialogContext).pop(ref),
            onCancel: () => Navigator.of(dialogContext).pop(),
          ),
        ),
      ),
    ),
  );
}

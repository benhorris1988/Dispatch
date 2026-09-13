import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/models.dart';
import '../services/api.dart';
import '../services/format.dart';
import '../shell/app_shell.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/team_widgets.dart';
import '../widgets/widgets.dart';
import 'parts/adm_settings_parts.dart';

/// Settings (CFG-*, ADM-*, spec 9.4.10). Work types, size classes and
/// scheduling policy for the workspace, plus the skills catalogue, roles,
/// integrations, notification defaults and the audit log.
///
/// Everything is read-only below the administrator role: the controls are
/// hidden rather than relying on a 403.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const sections = [
    'General',
    'Work types',
    'Size classes',
    'Day rates',
    'Scheduling & stability',
    'Priority & objective',
    'Skills catalogue',
    'Teams & roles',
    'Integrations',
    'Notifications',
    'Audit log',
  ];

  /// Sections whose edits accumulate in [_policyDraft] rather than saving as
  /// they are made.
  static const _policySections = {4, 5};

  int _section = 1;
  bool _loading = true;
  String? _error;
  _Config? _config;

  // Draft state for the two form sections and General.
  final Map<String, dynamic> _policyDraft = {};
  final Map<String, dynamic> _wsDraft = {};
  bool _saving = false;

  // Work type being renamed in the right-hand form.
  int? _editingTypeId;

  // Incident override toggle on the size classes section.
  bool _incidentOverride = false;

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
      final r = await Api.post('workspace_config.php', 'get');
      if (!mounted) return;
      setState(() {
        _config = _Config.fromJson(r);
        _policyDraft.clear();
        _wsDraft.clear();
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

  bool get _dirty => _section == 0 ? _wsDraft.isNotEmpty : (_policySections.contains(_section) && _policyDraft.isNotEmpty);

  void _discard() {
    setState(() {
      _policyDraft.clear();
      _wsDraft.clear();
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      if (_section == 0) {
        await Api.post('workspace_config.php', 'save_workspace', Map<String, dynamic>.from(_wsDraft));
        if (mounted) tmToast(context, 'Workspace saved');
      } else {
        final r = await Api.post('workspace_config.php', 'save_policy', Map<String, dynamic>.from(_policyDraft));
        final v = asIntOr(asMap(r['policy'])['version'], 0);
        if (mounted) tmToast(context, 'Policy v$v saved');
      }
      if (!mounted) return;
      await _load();
      if (mounted) await context.read<WorkspaceConfig>().load();
    } on ApiException catch (e) {
      if (mounted) tmToast(context, e.message, bad: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _setPolicy(String key, dynamic value) => setState(() => _policyDraft[key] = value);
  void _setWs(String key, dynamic value) => setState(() => _wsDraft[key] = value);

  dynamic _policyValue(String key, dynamic current) => _policyDraft.containsKey(key) ? _policyDraft[key] : current;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final isAdmin = session.isAdmin;
    final c = _config;

    return PageBody(
      onRefresh: _load,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(
          title: 'Settings',
          subtitle: 'Work types, size classes and scheduling policy for the ${c?.workspaceName ?? 'workspace'} workspace',
          actions: [
            if (!isAdmin) const ToneChip('Read only · administrators can change these', tone: 'info', icon: Icons.lock_outline_rounded),
            if (isAdmin && _dirty) SecondaryButton('Discard', onPressed: _saving ? null : _discard),
            if (isAdmin && _dirty) PrimaryButton('Save changes', icon: Icons.save_outlined, busy: _saving, onPressed: _save),
          ],
        ),
        const SizedBox(height: Sp.xl),
        if (_loading)
          const _SettingsSkeleton()
        else if (_error != null)
          ErrorState(title: 'We could not load the configuration', message: _error, onRetry: _load)
        else if (c == null)
          const EmptyState(icon: Icons.settings_outlined, title: 'No configuration', message: 'This workspace has not been set up yet.')
        else
          LayoutBuilder(builder: (context, box) {
            final wide = box.maxWidth >= 980;
            final nav = wide
                ? SizedBox(width: 210, child: TmSideNav(items: sections, selected: _section, onChanged: (i) => setState(() => _section = i)))
                : Padding(
                    padding: const EdgeInsets.only(bottom: Sp.lg),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SegmentedTabs(labels: sections, selected: _section, onChanged: (i) => setState(() => _section = i), compact: true),
                    ),
                  );
            final body = _body(c, isAdmin);
            if (!wide) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [nav, body]);
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              nav,
              const SizedBox(width: Sp.lg),
              Expanded(child: body),
            ]);
          }),
      ]),
    );
  }

  Widget _body(_Config c, bool isAdmin) => switch (_section) {
        0 => _GeneralSection(config: c, isAdmin: isAdmin, draft: _wsDraft, onChange: _setWs, onReload: _load),
        1 => _WorkTypesSection(
            config: c,
            isAdmin: isAdmin,
            editingId: _editingTypeId,
            onEdit: (id) => setState(() => _editingTypeId = id),
            onReload: _load,
          ),
        2 => _SizeClassesSection(
            config: c,
            isAdmin: isAdmin,
            incidentOverride: _incidentOverride,
            onToggleOverride: (v) => setState(() => _incidentOverride = v),
            onReload: _load,
          ),
        3 => AdmDayRatesPanel(
            rates: c.dayRates,
            isAdmin: isAdmin,
            workspaceCurrency: asStrOr(c.workspace['currency'], 'GBP'),
            onChanged: _load,
          ),
        4 => _SchedulingSection(config: c, isAdmin: isAdmin, value: _policyValue, onChange: _setPolicy),
        5 => _PrioritySection(config: c, isAdmin: isAdmin, draft: _policyDraft, onChange: _setPolicy),
        6 => const _SkillsCatalogueSection(),
        7 => const _TeamsRolesSection(),
        8 => _IntegrationsSection(rows: c.integrations),
        9 => const _NotificationDefaultsSection(),
        _ => const _AuditLogSection(),
      };
}

// ─── General ──────────────────────────────────────────────────────────────

class _GeneralSection extends StatelessWidget {
  const _GeneralSection({required this.config, required this.isAdmin, required this.draft, required this.onChange, required this.onReload});
  final _Config config;
  final bool isAdmin;
  final Map<String, dynamic> draft;
  final void Function(String, dynamic) onChange;
  final Future<void> Function() onReload;

  @override
  Widget build(BuildContext context) {
    final ws = config.workspace;
    String v(String key, String? current) => (draft[key] ?? current ?? '').toString();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        title: 'Workspace',
        subtitle: 'Names and working calendar used across every screen',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TmField(
            label: 'Name',
            child: TextFormField(initialValue: v('name', asStr(ws['name'])), enabled: isAdmin, onChanged: (s) => onChange('name', s)),
          ),
          const SizedBox(height: Sp.md),
          Row(children: [
            Expanded(
              child: TmField(
                label: 'Time zone',
                child: TextFormField(initialValue: v('time_zone', asStr(ws['time_zone'])), enabled: isAdmin, onChanged: (s) => onChange('time_zone', s)),
              ),
            ),
            const SizedBox(width: Sp.md),
            Expanded(
              child: TmField(
                label: 'Currency',
                child: TextFormField(initialValue: v('currency', asStr(ws['currency'])), enabled: isAdmin, onChanged: (s) => onChange('currency', s)),
              ),
            ),
          ]),
          const SizedBox(height: Sp.md),
          Row(children: [
            Expanded(
              child: TmField(
                label: 'Working days',
                hint: 'Comma separated, for example Mon,Tue,Wed,Thu,Fri.',
                child: TextFormField(initialValue: v('working_days', asStr(ws['working_days'])), enabled: isAdmin, onChanged: (s) => onChange('working_days', s)),
              ),
            ),
            const SizedBox(width: Sp.md),
            Expanded(
              child: TmField(
                label: 'Hours per day',
                child: TextFormField(
                  initialValue: v('hours_per_day', asStr(ws['hours_per_day'])),
                  enabled: isAdmin,
                  keyboardType: TextInputType.number,
                  onChanged: (s) => onChange('hours_per_day', double.tryParse(s) ?? s),
                ),
              ),
            ),
          ]),
        ]),
      ),
      const SizedBox(height: Sp.lg),
      Panel(
        title: 'Configuration export and import',
        subtitle: 'The whole workspace vocabulary and policy as JSON (CFG-10)',
        child: Row(children: [
          SecondaryButton('Export JSON', icon: Icons.file_download_outlined, onPressed: () => _export(context)),
          const SizedBox(width: Sp.sm),
          if (isAdmin) SecondaryButton('Import JSON', icon: Icons.file_upload_outlined, onPressed: () => _import(context)),
        ]),
      ),
    ]);
  }

  Future<void> _export(BuildContext context) async {
    try {
      final r = await Api.post('workspace_config.php', 'export');
      if (!context.mounted) return;
      const encoder = JsonEncoder.withIndent('  ');
      await showTmCsvDialog(context, title: 'Export configuration', csv: encoder.convert(r['config']), filename: 'workspace-config.json');
    } on ApiException catch (e) {
      if (context.mounted) tmToast(context, e.message, bad: true);
    }
  }

  Future<void> _import(BuildContext context) async {
    final controller = TextEditingController();
    final json = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import configuration'),
        content: SizedBox(
          width: 560,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const TmInfoBox('Importing replaces the work types, size classes and policy of this workspace. Existing references keep their prefix.'),
            const SizedBox(height: Sp.md),
            TextField(controller: controller, maxLines: 10, decoration: const InputDecoration(hintText: 'Paste the configuration JSON here')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Import')),
        ],
      ),
    );
    controller.dispose();
    if (json == null || json.trim().isEmpty || !context.mounted) return;
    try {
      final decoded = jsonDecode(json);
      await Api.post('workspace_config.php', 'import', {'config': decoded});
      if (context.mounted) tmToast(context, 'Configuration imported');
      await onReload();
    } on ApiException catch (e) {
      if (context.mounted) tmToast(context, e.message, bad: true);
    } on FormatException {
      if (context.mounted) tmToast(context, 'That is not valid JSON', bad: true);
    }
  }
}

// ─── Work types ───────────────────────────────────────────────────────────

class _WorkTypesSection extends StatelessWidget {
  const _WorkTypesSection({required this.config, required this.isAdmin, required this.editingId, required this.onEdit, required this.onReload});
  final _Config config;
  final bool isAdmin;
  final int? editingId;
  final ValueChanged<int?> onEdit;
  final Future<void> Function() onReload;

  @override
  Widget build(BuildContext context) {
    final types = config.workTypes.where((t) => !t.retired).toList();
    final editing = types.where((t) => t.id == editingId).firstOrNull;

    final list = Panel(
      title: 'Work types',
      subtitle: isAdmin ? 'Rename, recolour and reorder' : 'The vocabulary this workspace uses',
      trailing: isAdmin ? SecondaryButton('Add type', icon: Icons.add_rounded, onPressed: () => _openForm(context, null)) : null,
      padding: const EdgeInsets.symmetric(horizontal: Sp.lg, vertical: Sp.sm),
      child: isAdmin
          ? ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: types.length,
              onReorder: (oldIndex, newIndex) => _reorder(context, types, oldIndex, newIndex),
              itemBuilder: (context, i) => _WorkTypeTile(
                key: ValueKey(types[i].id),
                type: types[i],
                index: i,
                isAdmin: true,
                selected: types[i].id == editingId,
                onEdit: () => onEdit(types[i].id),
                onRetire: () => _retire(context, types[i]),
              ),
            )
          : Column(children: [
              for (var i = 0; i < types.length; i++)
                _WorkTypeTile(key: ValueKey(types[i].id), type: types[i], index: i, isAdmin: false, selected: false, onEdit: () {}, onRetire: () {}),
            ]),
    );

    final policy = _SchedulingSummaryPanel(config: config);

    // CFG-02: the sizes a type may use are its own override scope when it has
    // one (Incidents are planned in hours), otherwise the workspace defaults.
    final sizeRows = editing != null && editing.id == config.incidentWorkTypeId && config.incidentSizeClasses.isNotEmpty
        ? config.incidentSizeClasses
        : config.sizeClasses;
    final sizes = [for (final s in sizeRows) (stamp: s.stamp, name: s.name)];

    return LayoutBuilder(builder: (context, box) {
      final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (editing != null) ...[
          _WorkTypeForm(key: ValueKey(editing.id), type: editing, sizes: sizes, onSaved: onReload, onClose: () => onEdit(null)),
          const SizedBox(height: Sp.lg),
        ],
        policy,
      ]);
      if (box.maxWidth < 900) {
        return Column(children: [list, const SizedBox(height: Sp.lg), right]);
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(flex: 3, child: list),
        const SizedBox(width: Sp.lg),
        Expanded(flex: 2, child: right),
      ]);
    });
  }

  Future<void> _openForm(BuildContext context, _WorkTypeRow? type) async {
    final saved = await showDialog<bool>(context: context, builder: (context) => _AddWorkTypeDialog(existing: type));
    if (saved == true) await onReload();
  }

  Future<void> _reorder(BuildContext context, List<_WorkTypeRow> types, int oldIndex, int newIndex) async {
    final ordered = [...types];
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = ordered.removeAt(oldIndex);
    ordered.insert(newIndex, moved);
    try {
      await Api.post('workspace_config.php', 'reorder_work_types', {'ids': ordered.map((t) => t.id).toList()});
      await onReload();
    } on ApiException catch (e) {
      if (context.mounted) tmToast(context, e.message, bad: true);
    }
  }

  /// CFG-03: retiring a type with open items returns 409 and the open items;
  /// the user then chooses a type to re-type them to.
  Future<void> _retire(BuildContext context, _WorkTypeRow type) async {
    try {
      await Api.post('workspace_config.php', 'retire_work_type', {'id': type.id});
      if (context.mounted) tmToast(context, '${type.name} retired');
      await onReload();
    } on ApiException catch (e) {
      if (e.code != 409 || !context.mounted) {
        if (context.mounted) tmToast(context, e.message, bad: true);
        return;
      }
      final others = config.workTypes.where((t) => !t.retired && t.id != type.id).toList();
      final target = await showDialog<int>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text('Retire ${type.name}'),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.lg, 0, Sp.lg, Sp.md),
              child: Text('${e.message}\n\nChoose the type they should become.', style: context.text.bodyMedium),
            ),
            for (final t in others) SimpleDialogOption(onPressed: () => Navigator.of(context).pop(t.id), child: Text(t.plural, style: context.text.bodyLarge)),
          ],
        ),
      );
      if (target == null || !context.mounted) return;
      try {
        await Api.post('workspace_config.php', 'retire_work_type', {'id': type.id, 'retype_to_id': target});
        if (context.mounted) tmToast(context, 'Open items re-typed and ${type.name} retired');
        await onReload();
      } on ApiException catch (e2) {
        if (context.mounted) tmToast(context, e2.message, bad: true);
      }
    }
  }
}

class _WorkTypeTile extends StatelessWidget {
  const _WorkTypeTile({
    super.key,
    required this.type,
    required this.index,
    required this.isAdmin,
    required this.selected,
    required this.onEdit,
    required this.onRetire,
  });
  final _WorkTypeRow type;
  final int index;
  final bool isAdmin;
  final bool selected;
  final VoidCallback onEdit;
  final VoidCallback onRetire;

  @override
  Widget build(BuildContext context) {
    final t = type;
    final chips = <String>[
      t.requiresEstimate ? 'Estimate required' : 'Estimate optional',
      t.requiresBenefit ? 'Benefit case required' : 'No benefit case',
      if (t.isInterrupt) 'Interrupt-driven',
      if (t.defaultSizeStamp != null && t.defaultSizeStamp!.isNotEmpty) 'Defaults to ${t.defaultSizeStamp}',
      if (t.allowedSizes.isNotEmpty) 'Sizes ${t.allowedSizes.join(', ')}',
    ];
    return Container(
      padding: const EdgeInsets.symmetric(vertical: Sp.md),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.borderColor)),
        color: selected ? DispatchColors.tint(DispatchColors.typeBlue, opacity: context.isDark ? 0.14 : 0.05) : null,
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Container(width: 12, height: 12, decoration: BoxDecoration(color: DispatchColors.parseHex(t.colour), borderRadius: BorderRadius.circular(3))),
        ),
        const SizedBox(width: Sp.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Wrap(spacing: Sp.sm, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(t.name, style: context.text.titleSmall),
              ToneChip('prefix ${t.prefix}', compact: true),
              Text('${t.itemCount} items', style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
            ]),
            if (t.description != null && t.description!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(t.description ?? '', style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
            ],
            const SizedBox(height: Sp.sm),
            Wrap(spacing: Sp.sm, runSpacing: 4, children: [for (final c in chips) ToneChip(c, compact: true)]),
          ]),
        ),
        if (isAdmin) ...[
          const SizedBox(width: Sp.sm),
          ReorderableDragStartListener(
            index: index,
            child: Tooltip(
              message: 'Drag to reorder',
              child: Padding(padding: const EdgeInsets.all(6), child: Icon(Icons.drag_indicator_rounded, size: 18, color: context.mutedColor)),
            ),
          ),
          IconButton(onPressed: onEdit, icon: const Icon(Icons.edit_outlined, size: 17), tooltip: 'Rename ${t.name}', visualDensity: VisualDensity.compact),
          IconButton(onPressed: onRetire, icon: const Icon(Icons.archive_outlined, size: 17), tooltip: 'Retire ${t.name}', visualDensity: VisualDensity.compact),
        ],
      ]),
    );
  }
}

const List<({String label, String hex})> kTypeSwatches = [
  (label: 'Blue', hex: '#3B6BD6'),
  (label: 'Teal', hex: '#178F8A'),
  (label: 'Red', hex: '#C8102E'),
  (label: 'Violet', hex: '#6D5BD0'),
  (label: 'Orange', hex: '#F28C28'),
  (label: 'Green', hex: '#1F9D6B'),
  (label: 'Amber', hex: '#D99A00'),
  (label: 'Navy', hex: '#16284D'),
];

/// The inline “Rename …” form from the mockup.
class _WorkTypeForm extends StatefulWidget {
  const _WorkTypeForm({super.key, required this.type, required this.sizes, required this.onSaved, required this.onClose});
  final _WorkTypeRow type;

  /// The size classes in scope for this type (CFG-02).
  final List<AdmSizeOption> sizes;
  final Future<void> Function() onSaved;
  final VoidCallback onClose;

  @override
  State<_WorkTypeForm> createState() => _WorkTypeFormState();
}

class _WorkTypeFormState extends State<_WorkTypeForm> {
  late final TextEditingController _name = TextEditingController(text: widget.type.name);
  late final TextEditingController _plural = TextEditingController(text: widget.type.plural);
  late final TextEditingController _prefix = TextEditingController(text: widget.type.prefix);
  late String _colour = widget.type.colour;
  late bool _estimate = widget.type.requiresEstimate;
  late bool _benefit = widget.type.requiresBenefit;
  late bool _interrupt = widget.type.isInterrupt;
  late String? _defaultStamp = widget.type.defaultSizeStamp;
  late Set<String> _allowedSizes = {...widget.type.allowedSizes};
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _plural.dispose();
    _prefix.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final clash = AdmSizeRules.validate(_defaultStamp, _allowedSizes);
    if (clash != null) {
      setState(() => _error = clash);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.post('workspace_config.php', 'save_work_type', {
        'id': widget.type.id,
        'name': _name.text.trim(),
        'plural': _plural.text.trim(),
        'prefix': _prefix.text.trim().toUpperCase(),
        'colour': _colour,
        'policy': _interrupt ? 'interrupt' : 'planned',
        'requires_estimate': _estimate,
        'requires_benefit': _benefit,
        // An empty string clears the default; an empty list means every size is
        // allowed, which is how the API stores "no restriction".
        'default_size_stamp': _defaultStamp ?? '',
        'allowed_sizes': _allowedSizes.toList(),
      });
      if (!mounted) return;
      tmToast(context, '${_name.text.trim()} saved');
      await widget.onSaved();
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
    return Panel(
      title: 'Rename “${widget.type.name}”',
      trailing: IconButton(onPressed: widget.onClose, icon: const Icon(Icons.close_rounded, size: 18), tooltip: 'Close the form'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: TmField(label: 'Display name', child: TextField(controller: _name))),
          const SizedBox(width: Sp.md),
          Expanded(child: TmField(label: 'Plural', child: TextField(controller: _plural))),
        ]),
        const SizedBox(height: Sp.md),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: TmField(label: 'Reference prefix', child: TextField(controller: _prefix))),
          const SizedBox(width: Sp.md),
          Expanded(
            child: TmField(
              label: 'Colour',
              child: Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
                for (final s in kTypeSwatches)
                  Tooltip(
                    message: s.label,
                    child: InkWell(
                      onTap: () => setState(() => _colour = s.hex),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: DispatchColors.parseHex(s.hex),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: _colour.toUpperCase() == s.hex ? context.inkColor : Colors.transparent, width: 2),
                        ),
                        child: _colour.toUpperCase() == s.hex ? const Icon(Icons.check_rounded, size: 16, color: Colors.white) : null,
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: Sp.md),
        // CFG-02. save_work_type has always taken both and the Add work form
        // already uses the default; this form simply never offered them.
        AdmSizeRules(
          stamps: widget.sizes,
          defaultStamp: _defaultStamp,
          allowed: _allowedSizes,
          typePlural: widget.type.plural,
          onDefaultChanged: (v) => setState(() {
            _defaultStamp = v;
            _error = null;
          }),
          onAllowedChanged: (v) => setState(() {
            _allowedSizes = v;
            _error = null;
          }),
        ),
        const SizedBox(height: Sp.md),
        TmSwitchRow(label: 'Requires an estimate before scheduling', value: _estimate, onChanged: (v) => setState(() => _estimate = v)),
        TmSwitchRow(label: 'Requires a benefit case before scheduling', value: _benefit, onChanged: (v) => setState(() => _benefit = v)),
        TmSwitchRow(label: 'Interrupt-driven (may use the incident reserve)', value: _interrupt, onChanged: (v) => setState(() => _interrupt = v)),
        const SizedBox(height: Sp.sm),
        Text(
          'Renaming updates every screen, report and export. Existing references keep their prefix.',
          style: context.text.bodySmall?.copyWith(color: context.mutedColor),
        ),
        if (_error != null) TmInlineError(_error!),
        const SizedBox(height: Sp.md),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          SecondaryButton('Cancel', onPressed: widget.onClose),
          const SizedBox(width: Sp.sm),
          PrimaryButton('Save type', busy: _busy, onPressed: _save),
        ]),
      ]),
    );
  }
}

class _AddWorkTypeDialog extends StatefulWidget {
  const _AddWorkTypeDialog({this.existing});
  final _WorkTypeRow? existing;

  @override
  State<_AddWorkTypeDialog> createState() => _AddWorkTypeDialogState();
}

class _AddWorkTypeDialogState extends State<_AddWorkTypeDialog> {
  final _name = TextEditingController();
  final _plural = TextEditingController();
  final _prefix = TextEditingController();
  final _description = TextEditingController();
  String _colour = kTypeSwatches.first.hex;
  bool _estimate = true;
  bool _benefit = false;
  bool _interrupt = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _plural.dispose();
    _prefix.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.post('workspace_config.php', 'save_work_type', {
        'name': _name.text.trim(),
        'plural': _plural.text.trim().isEmpty ? '${_name.text.trim()}s' : _plural.text.trim(),
        'prefix': _prefix.text.trim().toUpperCase(),
        'colour': _colour,
        'policy': _interrupt ? 'interrupt' : 'planned',
        'requires_estimate': _estimate,
        'requires_benefit': _benefit,
        'description': _description.text.trim(),
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
      title: const Text('Add work type'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: TmField(label: 'Display name', child: TextField(controller: _name, autofocus: true))),
              const SizedBox(width: Sp.md),
              Expanded(child: TmField(label: 'Plural', child: TextField(controller: _plural))),
            ]),
            const SizedBox(height: Sp.md),
            TmField(label: 'Reference prefix', hint: 'Two or three letters, for example WI or INC.', child: TextField(controller: _prefix)),
            const SizedBox(height: Sp.md),
            TmField(
              label: 'Colour',
              child: Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
                for (final s in kTypeSwatches)
                  Tooltip(
                    message: s.label,
                    child: InkWell(
                      onTap: () => setState(() => _colour = s.hex),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: DispatchColors.parseHex(s.hex),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: _colour == s.hex ? context.inkColor : Colors.transparent, width: 2),
                        ),
                        child: _colour == s.hex ? const Icon(Icons.check_rounded, size: 16, color: Colors.white) : null,
                      ),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: Sp.md),
            TmField(label: 'Description', child: TextField(controller: _description, maxLines: 2)),
            const SizedBox(height: Sp.sm),
            TmSwitchRow(label: 'Requires an estimate before scheduling', value: _estimate, onChanged: (v) => setState(() => _estimate = v)),
            TmSwitchRow(label: 'Requires a benefit case before scheduling', value: _benefit, onChanged: (v) => setState(() => _benefit = v)),
            TmSwitchRow(label: 'Interrupt-driven (may use the incident reserve)', value: _interrupt, onChanged: (v) => setState(() => _interrupt = v)),
            if (_error != null) TmInlineError(_error!),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        PrimaryButton('Add type', busy: _busy, onPressed: _name.text.trim().isEmpty ? null : _save),
      ],
    );
  }
}

/// Read-only summary of the current scheduling policy (shown beside the work
/// types, as in the mockup).
class _SchedulingSummaryPanel extends StatelessWidget {
  const _SchedulingSummaryPanel({required this.config});
  final _Config config;

  @override
  Widget build(BuildContext context) {
    final p = config.policy;
    return Panel(
      title: 'Scheduling policy',
      subtitle: 'Version ${p.version}',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TmKeyValue('Freeze horizon', '${p.freezeHorizonDays} working days'),
        TmKeyValue('Change budget', '${p.changeBudgetDays} per person per week'),
        TmKeyValue('Minimum improvement', '${p.minImprovementPct.round()}% of objective'),
        TmKeyValue('Incident reserve', '${p.incidentReservePct.round()}% (${p.rotaReservePct.round()}% on rota)'),
        TmKeyValue('Replan cadence', 'Propose ${p.proposeCadence} · commit ${p.commitCadence}'),
        TmKeyValue('Max concurrent items', '${p.maxConcurrentItems} per person'),
      ]),
    );
  }
}

// ─── Size classes ─────────────────────────────────────────────────────────

class _SizeClassesSection extends StatelessWidget {
  const _SizeClassesSection({
    required this.config,
    required this.isAdmin,
    required this.incidentOverride,
    required this.onToggleOverride,
    required this.onReload,
  });
  final _Config config;
  final bool isAdmin;
  final bool incidentOverride;
  final ValueChanged<bool> onToggleOverride;
  final Future<void> Function() onReload;

  @override
  Widget build(BuildContext context) {
    final rows = incidentOverride ? config.incidentSizeClasses : config.sizeClasses;
    final unit = incidentOverride ? 'hours' : 'days';

    return Panel(
      title: 'Size classes',
      subtitle: 'Bands are in effort $unit; the engine uses the band midpoint until a three-point estimate exists',
      trailing: isAdmin
          ? SecondaryButton('Add size', icon: Icons.add_rounded, onPressed: () => _edit(context, null))
          : null,
      padding: EdgeInsets.zero,
      dividerAfterHeader: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.lg, Sp.md, Sp.lg, 0),
          child: TmSwitchRow(
            label: incidentOverride ? 'Showing the Incident override' : 'Applies to all types',
            subtitle: incidentOverride
                ? 'Incidents are planned in hours, so their bands override the workspace defaults.'
                : 'Turn on to see the hour-based bands that override these for Incidents.',
            value: incidentOverride,
            onChanged: config.incidentSizeClasses.isEmpty ? null : onToggleOverride,
            disabledNote: 'No incident override is configured.',
          ),
        ),
        const SizedBox(height: Sp.sm),
        LayoutBuilder(builder: (context, c) {
          if (rows.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(Sp.lg),
              child: EmptyState(icon: Icons.straighten_rounded, title: 'No size classes', message: 'Add a size band to start planning.', compact: true),
            );
          }
          if (TmTable.isNarrow(c.maxWidth)) {
            return Padding(
              padding: const EdgeInsets.all(Sp.lg),
              child: Column(children: [
                for (final s in rows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Sp.md),
                    child: DispatchCard(
                      onTap: isAdmin ? () => _edit(context, s) : null,
                      child: Row(children: [
                        SizeStamp(s.stamp, size: 30),
                        const SizedBox(width: Sp.md),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                            Text(s.name, style: context.text.titleSmall),
                            Text(
                              dotJoin([
                                _band(s, unit),
                                'plans at ${_planning(s, unit)}',
                                estimateClassLabel(s.defaultEstimateClass),
                                humanise(s.granularity),
                                s.countsForWip ? 'counts toward WIP' : 'does not count toward WIP',
                              ]),
                              style: context.text.bodySmall?.copyWith(color: context.mutedColor),
                            ),
                          ]),
                        ),
                      ]),
                    ),
                  ),
              ]),
            );
          }
          return TmTable(
            columns: const [
              TmCol('Stamp', width: 70),
              TmCol('Name', flex: 2),
              TmCol('Effort band', flex: 2),
              TmCol('Planning value', flex: 2),
              TmCol('Default estimate class', flex: 2),
              TmCol('Granularity', width: 110),
              TmCol('Counts toward WIP', width: 150),
              TmCol('', width: 44),
            ],
            rows: [
              for (final s in rows)
                [
                  SizeStamp(s.stamp, size: 28),
                  Text(s.name, style: context.text.titleSmall),
                  Text(_band(s, unit), style: context.text.bodyMedium),
                  Text(_planning(s, unit), style: context.text.bodyMedium),
                  Text(s.isCustom ? 'Chosen per item' : estimateClassLabel(s.defaultEstimateClass), style: context.text.bodyMedium),
                  Text(humanise(s.granularity), style: context.text.bodyMedium),
                  Row(children: [
                    Icon(s.countsForWip ? Icons.check_circle_rounded : Icons.remove_circle_outline_rounded,
                        size: 16, color: s.countsForWip ? DispatchColors.green : context.mutedColor),
                    const SizedBox(width: 6),
                    Text(s.countsForWip ? 'Yes' : 'No', style: context.text.bodyMedium),
                  ]),
                  isAdmin
                      ? IconButton(
                          onPressed: () => _edit(context, s),
                          icon: const Icon(Icons.edit_outlined, size: 17),
                          tooltip: 'Edit ${s.name}',
                          visualDensity: VisualDensity.compact,
                        )
                      : const SizedBox(),
                ],
            ],
          );
        }),
        const Padding(
          padding: EdgeInsets.all(Sp.lg),
          child: TmInfoBox('Items above the largest band must be split or entered as Custom with a task roll-up. Bands must not overlap.'),
        ),
      ]),
    );
  }

  static String _band(_SizeClassRow s, String unit) {
    if (s.isCustom) return 'Entered per item';
    String n(double d) => d == d.roundToDouble() ? d.toInt().toString() : d.toStringAsFixed(1);
    if (s.maxDays == null) return '${n(s.minDays ?? 0)}+ $unit';
    if ((s.minDays ?? 0) == 0) return 'Up to ${n(s.maxDays!)} $unit';
    return '${n(s.minDays!)}–${n(s.maxDays!)} $unit';
  }

  static String _planning(_SizeClassRow s, String unit) {
    if (s.isCustom) return 'As entered';
    if (s.planningDays == null) return '—';
    final d = s.planningDays!;
    return '${d == d.roundToDouble() ? d.toInt() : d} $unit';
  }

  Future<void> _edit(BuildContext context, _SizeClassRow? s) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _SizeClassDialog(sizeClass: s, workTypeId: incidentOverride ? config.incidentWorkTypeId : null),
    );
    if (saved == true) await onReload();
  }
}

class _SizeClassDialog extends StatefulWidget {
  const _SizeClassDialog({this.sizeClass, this.workTypeId});
  final _SizeClassRow? sizeClass;
  final int? workTypeId;

  @override
  State<_SizeClassDialog> createState() => _SizeClassDialogState();
}

class _SizeClassDialogState extends State<_SizeClassDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.sizeClass?.name ?? '');
  late final TextEditingController _stamp = TextEditingController(text: widget.sizeClass?.stamp ?? '');
  late final TextEditingController _min = TextEditingController(text: widget.sizeClass?.minDays?.toString() ?? '');
  late final TextEditingController _max = TextEditingController(text: widget.sizeClass?.maxDays?.toString() ?? '');
  late final TextEditingController _planning = TextEditingController(text: widget.sizeClass?.planningDays?.toString() ?? '');
  late int _estimateClass = widget.sizeClass?.defaultEstimateClass ?? 3;
  late String _granularity = widget.sizeClass?.granularity ?? 'day';
  late bool _wip = widget.sizeClass?.countsForWip ?? true;
  late bool _custom = widget.sizeClass?.isCustom ?? false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _stamp.dispose();
    _min.dispose();
    _max.dispose();
    _planning.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.post('workspace_config.php', 'save_size_class', {
        if (widget.sizeClass != null) 'id': widget.sizeClass!.id,
        if (widget.sizeClass == null && widget.workTypeId != null) 'work_type_id': widget.workTypeId,
        'name': _name.text.trim(),
        'stamp': _stamp.text.trim(),
        'min_days': _min.text.trim(),
        'max_days': _max.text.trim(),
        'planning_days': _planning.text.trim(),
        'default_estimate_class': _estimateClass,
        'granularity': _granularity,
        'counts_for_wip': _wip,
        'is_custom': _custom,
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          // CFG-05 overlap messages come back as a 409 and are shown in red here.
          _error = e.message;
          _busy = false;
        });
      }
    }
  }

  Future<void> _delete() async {
    final ok = await showTmConfirm(
      context,
      title: 'Delete ${widget.sizeClass!.name}?',
      message: 'Size classes in use cannot be deleted; the server will say so.',
      confirmLabel: 'Delete',
      danger: true,
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      await Api.post('workspace_config.php', 'delete_size_class', {'id': widget.sizeClass!.id});
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
      title: Text(widget.sizeClass == null ? 'Add size class' : 'Edit ${widget.sizeClass!.name}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(flex: 2, child: TmField(label: 'Name', child: TextField(controller: _name))),
              const SizedBox(width: Sp.md),
              Expanded(child: TmField(label: 'Stamp', child: TextField(controller: _stamp))),
            ]),
            const SizedBox(height: Sp.md),
            Row(children: [
              Expanded(child: TmField(label: 'Band starts at', child: TextField(controller: _min, keyboardType: TextInputType.number))),
              const SizedBox(width: Sp.md),
              Expanded(child: TmField(label: 'Band ends at', hint: 'Leave empty for no ceiling.', child: TextField(controller: _max, keyboardType: TextInputType.number))),
              const SizedBox(width: Sp.md),
              Expanded(child: TmField(label: 'Planning value', child: TextField(controller: _planning, keyboardType: TextInputType.number))),
            ]),
            const SizedBox(height: Sp.md),
            Row(children: [
              Expanded(
                child: TmField(
                  label: 'Default estimate class',
                  child: DropdownButtonFormField<int>(
                    initialValue: _estimateClass,
                    items: [for (var i = 1; i <= 5; i++) DropdownMenuItem(value: i, child: Text(estimateClassLabel(i)))],
                    onChanged: (v) => setState(() => _estimateClass = v ?? _estimateClass),
                  ),
                ),
              ),
              const SizedBox(width: Sp.md),
              Expanded(
                child: TmField(
                  label: 'Planning granularity',
                  child: DropdownButtonFormField<String>(
                    initialValue: _granularity,
                    items: const [
                      DropdownMenuItem(value: 'halfDay', child: Text('Half day')),
                      DropdownMenuItem(value: 'day', child: Text('Day')),
                      DropdownMenuItem(value: 'week', child: Text('Week')),
                    ],
                    onChanged: (v) => setState(() => _granularity = v ?? _granularity),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: Sp.sm),
            TmSwitchRow(label: 'Counts toward the WIP limit', value: _wip, onChanged: (v) => setState(() => _wip = v)),
            TmSwitchRow(label: 'Custom size (effort entered per item)', value: _custom, onChanged: (v) => setState(() => _custom = v)),
            if (_error != null) TmInlineError(_error!),
          ]),
        ),
      ),
      actions: [
        if (widget.sizeClass != null) TextButton(onPressed: _busy ? null : _delete, child: const Text('Delete', style: TextStyle(color: DispatchColors.red))),
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        PrimaryButton('Save', busy: _busy, onPressed: _save),
      ],
    );
  }
}

// ─── Scheduling & stability ───────────────────────────────────────────────

class _SchedulingSection extends StatelessWidget {
  const _SchedulingSection({required this.config, required this.isAdmin, required this.value, required this.onChange});
  final _Config config;
  final bool isAdmin;
  final dynamic Function(String, dynamic) value;
  final void Function(String, dynamic) onChange;

  @override
  Widget build(BuildContext context) {
    final p = config.policy;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        title: 'Scheduling and stability',
        subtitle: 'Saving creates a new policy version — the engine picks it up on the next run',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: Sp.lg, runSpacing: Sp.md, children: [
            _NumField(label: 'Freeze horizon (working days)', initial: p.freezeHorizonDays, enabled: isAdmin, onChanged: (v) => onChange('freeze_horizon_days', v)),
            _NumField(label: 'Planning horizon (weeks)', initial: p.planningHorizonWeeks, enabled: isAdmin, onChanged: (v) => onChange('planning_horizon_weeks', v)),
            _NumField(label: 'Model horizon (weeks)', initial: p.modelHorizonWeeks, enabled: isAdmin, onChanged: (v) => onChange('model_horizon_weeks', v)),
            _NumField(label: 'Change budget (days per person per week)', initial: p.changeBudgetDays, enabled: isAdmin, onChanged: (v) => onChange('change_budget_days', v)),
            _NumField(label: 'Minimum improvement (%)', initial: p.minImprovementPct, enabled: isAdmin, onChanged: (v) => onChange('min_improvement_pct', v)),
            _NumField(label: 'Incident reserve (%)', initial: p.incidentReservePct, enabled: isAdmin, onChanged: (v) => onChange('incident_reserve_pct', v)),
            _NumField(label: 'Rota reserve (%)', initial: p.rotaReservePct, enabled: isAdmin, onChanged: (v) => onChange('rota_reserve_pct', v)),
            _NumField(label: 'Max concurrent items', initial: p.maxConcurrentItems, enabled: isAdmin, onChanged: (v) => onChange('max_concurrent_items', v)),
            _NumField(label: 'Minimum focus days', initial: p.minFocusDays, enabled: isAdmin, onChanged: (v) => onChange('min_focus_days', v)),
            _NumField(label: 'Target load minimum (%)', initial: p.targetLoadMin, enabled: isAdmin, onChanged: (v) => onChange('target_load_min', v)),
            _NumField(label: 'Target load maximum (%)', initial: p.targetLoadMax, enabled: isAdmin, onChanged: (v) => onChange('target_load_max', v)),
            _NumField(label: 'Solver budget (seconds)', initial: p.solverBudgetSeconds, enabled: isAdmin, onChanged: (v) => onChange('solver_budget_seconds', v)),
            SizedBox(
              width: 260,
              child: TmField(
                label: 'Plan at',
                hint: 'P80 plans with contingency built in.',
                child: DropdownButtonFormField<String>(
                  initialValue: value('plan_at', p.planAt) as String,
                  items: const [
                    DropdownMenuItem(value: 'mostLikely', child: Text('Most likely')),
                    DropdownMenuItem(value: 'p80', child: Text('P80')),
                  ],
                  onChanged: isAdmin ? (v) => onChange('plan_at', v) : null,
                ),
              ),
            ),
            SizedBox(
              width: 260,
              child: TmField(
                label: 'Propose cadence',
                child: TextFormField(initialValue: p.proposeCadence, enabled: isAdmin, onChanged: (s) => onChange('propose_cadence', s)),
              ),
            ),
            SizedBox(
              width: 260,
              child: TmField(
                label: 'Commit cadence',
                child: TextFormField(initialValue: p.commitCadence, enabled: isAdmin, onChanged: (s) => onChange('commit_cadence', s)),
              ),
            ),
          ]),
          const SizedBox(height: Sp.md),
          TmSwitchRow(
            label: 'Apply changes outside the planning horizon automatically',
            subtitle: 'Work beyond the horizon is indicative, so moving it costs nothing.',
            value: value('auto_apply_outside_horizon', p.autoApplyOutsideHorizon) as bool,
            onChanged: isAdmin ? (v) => onChange('auto_apply_outside_horizon', v) : null,
            disabledNote: 'Configured by a workspace administrator',
          ),
          TmSwitchRow(
            label: 'Require acknowledgement for changes inside the freeze horizon',
            value: value('require_ack_inside_horizon', p.requireAckInsideHorizon) as bool,
            onChanged: isAdmin ? (v) => onChange('require_ack_inside_horizon', v) : null,
            disabledNote: 'Configured by a workspace administrator',
          ),
          const SizedBox(height: Sp.md),
          TmInfoBox('Current version: v${p.version}. Saving writes a new version and keeps the old one for the audit trail.'),
        ]),
      ),
    ]);
  }
}

class _NumField extends StatelessWidget {
  const _NumField({required this.label, required this.initial, required this.enabled, required this.onChanged, this.width = 260});
  final String label;
  final num initial;
  final bool enabled;
  final ValueChanged<num> onChanged;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: TmField(
        label: label,
        child: TextFormField(
          initialValue: initial == initial.roundToDouble() ? initial.round().toString() : initial.toString(),
          enabled: enabled,
          keyboardType: TextInputType.number,
          onChanged: (s) {
            final v = num.tryParse(s.trim());
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

// ─── Priority scoring ─────────────────────────────────────────────────────

class _PrioritySection extends StatelessWidget {
  const _PrioritySection({required this.config, required this.isAdmin, required this.draft, required this.onChange});
  final _Config config;
  final bool isAdmin;
  final Map<String, dynamic> draft;
  final void Function(String, dynamic) onChange;

  static const _terms = [
    (key: 'value', label: 'Benefit value'),
    (key: 'urgency', label: 'Urgency against needed-by'),
    (key: 'riskCompliance', label: 'Risk and compliance'),
    (key: 'dependencyLeverage', label: 'Dependency leverage'),
    (key: 'age', label: 'Age in the queue'),
  ];

  Map<String, dynamic> get _weights {
    final live = Map<String, dynamic>.from(config.policy.priorityWeights);
    final drafted = draft['priority_weights'];
    if (drafted is Map) live.addAll(Map<String, dynamic>.from(drafted));
    return live;
  }

  void _setWeight(String key, num v) {
    final current = draft['priority_weights'] is Map ? Map<String, dynamic>.from(draft['priority_weights'] as Map) : <String, dynamic>{};
    current[key] = v;
    onChange('priority_weights', current);
  }

  /// SCH-02. The engine already reads these; Settings only ever printed them.
  Map<String, dynamic> get _objectiveWeights {
    final live = Map<String, dynamic>.from(config.policy.objectiveWeights);
    final drafted = draft['objective_weights'];
    if (drafted is Map) live.addAll(Map<String, dynamic>.from(drafted));
    return live;
  }

  void _setObjective(String key, num v) {
    final current = draft['objective_weights'] is Map ? Map<String, dynamic>.from(draft['objective_weights'] as Map) : <String, dynamic>{};
    current[key] = v;
    onChange('objective_weights', current);
  }

  void _setConfidence(String key, num v) {
    final current = draft['priority_weights'] is Map ? Map<String, dynamic>.from(draft['priority_weights'] as Map) : <String, dynamic>{};
    final live = config.policy.priorityWeights['confidenceScale'];
    final scale = current['confidenceScale'] is Map
        ? Map<String, dynamic>.from(current['confidenceScale'] as Map)
        : (live is Map ? Map<String, dynamic>.from(live) : <String, dynamic>{});
    scale[key] = v;
    current['confidenceScale'] = scale;
    onChange('priority_weights', current);
  }

  @override
  Widget build(BuildContext context) {
    final w = _weights;
    final total = _terms.fold<num>(0, (a, t) => a + (asDouble(w[t.key]) ?? 0));
    final scaleRaw = w['confidenceScale'];
    final scale = scaleRaw is Map ? Map<String, dynamic>.from(scaleRaw) : const <String, dynamic>{};

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        title: 'Priority scoring',
        subtitle: 'How the queue is ordered — the weights must add up to 100',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: Sp.lg, runSpacing: Sp.md, children: [
            for (final t in _terms)
              _NumField(
                label: '${t.label} (%)',
                initial: asDoubleOr(w[t.key], 0),
                enabled: isAdmin,
                onChanged: (v) => _setWeight(t.key, v),
                width: 240,
              ),
          ]),
          const SizedBox(height: Sp.md),
          Row(children: [
            Icon(total == 100 ? Icons.check_circle_rounded : Icons.warning_amber_rounded, size: 16, color: total == 100 ? DispatchColors.green : DispatchColors.amber),
            const SizedBox(width: 6),
            Text('Weights total ${total.toStringAsFixed(0)}%', style: context.text.bodyMedium?.copyWith(color: total == 100 ? DispatchColors.green : DispatchColors.amber)),
          ]),
          const SizedBox(height: Sp.lg),
          SectionLabel('Confidence scales the benefit value'),
          const SizedBox(height: Sp.sm),
          Wrap(spacing: Sp.lg, runSpacing: Sp.md, children: [
            for (final k in const ['high', 'medium', 'low'])
              _NumField(
                label: '${humanise(k)} confidence ×',
                initial: asDoubleOr(scale[k], k == 'high' ? 1 : (k == 'medium' ? 0.7 : 0.4)),
                enabled: isAdmin,
                onChanged: (v) => _setConfidence(k, v),
                width: 200,
              ),
          ]),
          const SizedBox(height: Sp.lg),
          TmInfoBox(
            'Scores are normalised against the 90th percentile and rescaled nightly so the top item sits near 100. '
            'A delivery lead can override one item’s score with a reason and an expiry.',
          ),
        ]),
      ),
      const SizedBox(height: Sp.lg),
      AdmObjectiveWeights(
        weights: _objectiveWeights,
        isAdmin: isAdmin,
        onChanged: _setObjective,
        policyVersion: config.policy.version,
        targetLoadMin: config.policy.targetLoadMin,
        targetLoadMax: config.policy.targetLoadMax,
      ),
    ]);
  }
}

// ─── Skills catalogue ─────────────────────────────────────────────────────

class _SkillsCatalogueSection extends StatefulWidget {
  const _SkillsCatalogueSection();

  @override
  State<_SkillsCatalogueSection> createState() => _SkillsCatalogueSectionState();
}

class _SkillsCatalogueSectionState extends State<_SkillsCatalogueSection> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _skills = const [];

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
      final r = await Api.post('skills.php', 'list');
      if (!mounted) return;
      setState(() {
        _skills = [for (final s in (r['skills'] as List? ?? const [])) if (s is Map) Map<String, dynamic>.from(s)];
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SkeletonPanel(rows: 6);
    if (_error != null) return ErrorState(title: 'We could not load the skills', message: _error, onRetry: _load);
    return Panel(
      title: 'Skills catalogue',
      subtitle: '${_skills.length} tracked skills · manage them from Team & skills',
      padding: EdgeInsets.zero,
      dividerAfterHeader: true,
      child: TmTable(
        columns: const [
          TmCol('Skill', flex: 3),
          TmCol('Category', flex: 2),
          TmCol('People at L3+', width: 120, align: TextAlign.right),
          TmCol('Status', width: 110),
        ],
        rows: [
          for (final s in _skills)
            [
              Text(asStrOr(s['name'], ''), style: context.text.titleSmall),
              Text(asStrOr(s['category'], '—'), style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
              Text('${asIntOr(s['people_at_3_plus'], 0)}', style: DispatchTheme.numeric(size: 14, weight: FontWeight.w700, color: context.inkColor)),
              asBool(s['retired'])
                  ? const ToneChip('Retired', compact: true)
                  : (asBool(s['single_point']) ? const ToneChip('Single point', tone: 'bad', compact: true) : const ToneChip('Active', tone: 'ok', compact: true)),
            ],
        ],
      ),
    );
  }
}

// ─── Teams & roles ────────────────────────────────────────────────────────

class _TeamsRolesSection extends StatefulWidget {
  const _TeamsRolesSection();

  @override
  State<_TeamsRolesSection> createState() => _TeamsRolesSectionState();
}

class _TeamsRolesSectionState extends State<_TeamsRolesSection> {
  static const permissions = [
    (role: 'viewer', can: 'Read schedule, pipeline, team and reports for their workspace'),
    (role: 'requester', can: 'Viewer plus add work, edit own items while draft, comment'),
    (role: 'team_member', can: 'Requester plus edit own profile, skills and availability; log progress; acknowledge changes'),
    (role: 'benefit_owner', can: 'Team member plus create and update benefits they own; confirm realised value'),
    (role: 'team_lead', can: 'Team member plus endorse skills, manage rota and availability for the team, estimate items'),
    (role: 'delivery_lead', can: 'Team lead plus review and commit proposals, approve changes inside the freeze horizon, fix assignments, override priority with reason'),
    (role: 'admin', can: 'Delivery lead plus configure work types, sizes, policy, weights, roles, integrations; read the audit log; override guardrails with reason'),
  ];

  bool _loading = true;
  String? _error;
  List<DevUser> _users = const [];

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
      final users = await Api.listDevUsers();
      if (!mounted) return;
      setState(() {
        _users = users;
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SkeletonPanel(rows: 6);
    if (_error != null) return ErrorState(title: 'We could not load the users', message: _error, onRetry: _load);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        title: 'People and roles',
        subtitle: 'Roles come from the identity provider’s group claims',
        padding: EdgeInsets.zero,
        dividerAfterHeader: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TmTable(
            columns: const [
              TmCol('Person', flex: 3),
              TmCol('Email', flex: 3),
              TmCol('Role', width: 200),
            ],
            rows: [
              for (final u in _users)
                [
                  Row(children: [
                    PersonAvatar(u.initials ?? initialsOf(u.displayName), colourHex: u.colour, seed: u.id, size: 28),
                    const SizedBox(width: Sp.md),
                    Flexible(child: Text(u.displayName, style: context.text.titleSmall, overflow: TextOverflow.ellipsis)),
                  ]),
                  Text(u.email ?? '—', style: context.text.bodyMedium?.copyWith(color: context.mutedColor), overflow: TextOverflow.ellipsis),
                  DropdownButtonFormField<String>(
                    initialValue: u.role,
                    isDense: true,
                    items: [for (final r in kRoleOrder) DropdownMenuItem(value: r, child: Text(roleLabel(r)))],
                    // No role-assignment endpoint exists yet; group sync owns this.
                    onChanged: null,
                  ),
                ],
            ],
          ),
          const Padding(
            padding: EdgeInsets.all(Sp.lg),
            child: TmInfoBox('Role assignment is synchronised from Entra ID group claims. Changing a role here is not available in this build.'),
          ),
        ]),
      ),
      const SizedBox(height: Sp.lg),
      Panel(
        title: 'What each role can do',
        subtitle: 'Reference — enforced by the API on every request',
        padding: EdgeInsets.zero,
        dividerAfterHeader: true,
        child: TmTable(
          columns: const [
            TmCol('Role', width: 170),
            TmCol('Can', flex: 5),
          ],
          rows: [
            for (final p in permissions)
              [
                Text(roleLabel(p.role), style: context.text.titleSmall),
                Text(p.can, style: context.text.bodyMedium),
              ],
          ],
        ),
      ),
    ]);
  }
}

// ─── Integrations ─────────────────────────────────────────────────────────

class _IntegrationsSection extends StatelessWidget {
  const _IntegrationsSection({required this.rows});

  /// Connector rows as the API reports them. This panel used to hardcode six
  /// systems and show three of them as "Connected"; none were, nothing read
  /// dbo.integrations, and none of the connectors are built. A settings screen
  /// that misreports the state of the system is worse than an empty one.
  final List<Map<String, dynamic>> rows;

  static const _labels = <String, ({String name, String detail, IconData icon})>{
    'jira': (name: 'Jira / Azure DevOps', detail: 'Import work items by query and write planned dates back', icon: Icons.developer_board_outlined),
    'servicenow': (name: 'ServiceNow', detail: 'Assigned incidents above a severity threshold become interrupt-driven work', icon: Icons.support_agent_outlined),
    'hr_leave': (name: 'HR leave feed', detail: 'Approved leave as availability; only a type is stored, never a reason', icon: Icons.event_busy_outlined),
    'm365': (name: 'Microsoft 365', detail: 'Out-of-office in, committed assignments out as a calendar feed', icon: Icons.calendar_month_outlined),
    'teams': (name: 'Microsoft Teams', detail: 'Proposals, approvals and digests posted to a channel', icon: Icons.forum_outlined),
    'timesheets': (name: 'Timesheets', detail: 'Actual effort per item, for estimate accuracy and utilisation', icon: Icons.schedule_outlined),
    'powerbi': (name: 'Power BI', detail: 'Read-only analytics views', icon: Icons.insert_chart_outlined),
  };


  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = (c.maxWidth / 320).floor().clamp(1, 3);
      return Wrap(
        spacing: Sp.lg,
        runSpacing: Sp.lg,
        children: [
          for (final row in rows)
            SizedBox(
              width: cols == 1 ? c.maxWidth : (c.maxWidth - Sp.lg * (cols - 1)) / cols,
              child: Builder(builder: (context) {
                final key = asStrOr(row['system'], '');
                final meta = _labels[key];
                final on = asBool(row['enabled'], fallback: false);
                final sync = asStr(row['last_sync_at']);
                return DispatchCard(
                  padding: const EdgeInsets.all(Sp.lg),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
                      Icon(meta?.icon ?? Icons.extension_outlined, size: 20, color: context.mutedColor),
                      const SizedBox(width: Sp.sm),
                      Expanded(child: Text(meta?.name ?? humanise(key), style: context.text.titleSmall)),
                      ToneChip(on ? 'Connected' : 'Not connected', tone: on ? 'ok' : null, compact: true),
                    ]),
                    const SizedBox(height: Sp.sm),
                    Text(meta?.detail ?? '', style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
                    const SizedBox(height: Sp.sm),
                    TmSwitchRow(
                      label: on ? 'Enabled' : 'Disabled',
                      value: on,
                      onChanged: null,
                      disabledNote: on && sync != null ? 'Last synced ${fmtShortDate(parseDate(sync))}' : 'No connector is built yet',
                    ),
                  ]),
                );
              }),
            ),
        ],
      );
    });
  }
}

// ─── Notification defaults ────────────────────────────────────────────────

class _NotificationDefaultsSection extends StatefulWidget {
  const _NotificationDefaultsSection();

  @override
  State<_NotificationDefaultsSection> createState() => _NotificationDefaultsSectionState();
}

class _NotificationDefaultsSectionState extends State<_NotificationDefaultsSection> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _prefs = const [];

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
      final r = await Api.post('notifications.php', 'prefs');
      if (!mounted) return;
      setState(() {
        _prefs = [for (final p in (r['prefs'] as List? ?? const [])) if (p is Map) Map<String, dynamic>.from(p)];
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SkeletonPanel(rows: 6);
    if (_error != null) return ErrorState(title: 'We could not load the notification defaults', message: _error, onRetry: _load);
    Widget tick(bool on) => Icon(on ? Icons.check_circle_rounded : Icons.remove_circle_outline_rounded, size: 16, color: on ? DispatchColors.green : context.mutedColor);
    return Panel(
      title: 'Notification defaults',
      subtitle: 'Applied to new people; everyone can change their own on the notifications page',
      padding: EdgeInsets.zero,
      dividerAfterHeader: true,
      child: TmTable(
        columns: const [
          TmCol('When', flex: 4),
          TmCol('In app', width: 80, align: TextAlign.center),
          TmCol('Push', width: 80, align: TextAlign.center),
          TmCol('Email', width: 80, align: TextAlign.center),
          TmCol('Teams', width: 80, align: TextAlign.center),
          TmCol('Digest', width: 110),
        ],
        rows: [
          for (final p in _prefs)
            [
              Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(asStr(p['label']) ?? '', style: context.text.bodyMedium),
                if (asBool(p['urgent_bypasses_digest']))
                  Text('Urgent notifications bypass the digest', style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
              ]),
              tick(asBool(p['in_app'])),
              tick(asBool(p['push'])),
              tick(asBool(p['email_digest'])),
              tick(asBool(p['teams'])),
              Text(humanise(asStr(p['digest'])), style: context.text.bodyMedium),
            ],
        ],
      ),
    );
  }
}

// ─── Audit log ────────────────────────────────────────────────────────────

class _AuditLogSection extends StatefulWidget {
  const _AuditLogSection();

  @override
  State<_AuditLogSection> createState() => _AuditLogSectionState();
}

class _AuditLogSectionState extends State<_AuditLogSection> {
  final TextEditingController _q = TextEditingController();
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _events = const [];
  int _total = 0;
  String? _entity;
  List<String> _entities = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await Api.post('audit.php', 'list', {
        if (_q.text.trim().isNotEmpty) 'q': _q.text.trim(),
        if (_entity != null) 'entity': _entity,
        'limit': 100,
      });
      if (!mounted) return;
      setState(() {
        _events = [for (final e in (r['events'] as List? ?? const [])) if (e is Map) Map<String, dynamic>.from(e)];
        _total = asIntOr(r['total'], _events.length);
        _entities = asStrList(r['entities']);
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
    try {
      final r = await Api.post('audit.php', 'export_csv', {if (_q.text.trim().isNotEmpty) 'q': _q.text.trim()});
      if (!mounted) return;
      await showTmCsvDialog(context, title: 'Export audit log', csv: asStrOr(r['csv'], ''), filename: asStr(r['filename']));
    } on ApiException catch (e) {
      if (mounted) tmToast(context, e.message, bad: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'Audit log',
      subtitle: _loading ? null : '$_total events · every mutation with before and after',
      trailing: SecondaryButton('Export', icon: Icons.file_download_outlined, onPressed: _loading ? null : _export),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: _q,
              onSubmitted: (_) => _load(),
              decoration: InputDecoration(
                hintText: 'Search the audit log',
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                suffixIcon: IconButton(onPressed: _load, icon: const Icon(Icons.arrow_forward_rounded, size: 18), tooltip: 'Search'),
              ),
            ),
          ),
          if (_entities.isNotEmpty) ...[
            const SizedBox(width: Sp.md),
            SizedBox(
              width: 200,
              child: DropdownButtonFormField<String?>(
                initialValue: _entity,
                isDense: true,
                items: [
                  const DropdownMenuItem(value: null, child: Text('All entities')),
                  for (final e in _entities) DropdownMenuItem(value: e, child: Text(humanise(e))),
                ],
                onChanged: (v) {
                  setState(() => _entity = v);
                  _load();
                },
              ),
            ),
          ],
        ]),
        const SizedBox(height: Sp.md),
        if (_loading)
          const SkeletonPanel(rows: 6)
        else if (_error != null)
          ErrorState(title: 'We could not load the audit log', message: _error, onRetry: _load, compact: true)
        else if (_events.isEmpty)
          const EmptyState(icon: Icons.receipt_long_outlined, title: 'Nothing matches', message: 'Try a different search or clear the entity filter.', compact: true)
        else
          Column(children: [
            for (final e in _events) _AuditRow(event: e),
          ]),
      ]),
    );
  }
}

class _AuditRow extends StatelessWidget {
  const _AuditRow({required this.event});
  final Map<String, dynamic> event;

  @override
  Widget build(BuildContext context) {
    final at = asDate(event['occurred_at']);
    final before = event['before'];
    final after = event['after'];
    final hasDetail = before != null || after != null || asStr(event['reason']) != null;
    const encoder = JsonEncoder.withIndent('  ');

    final header = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 150,
        child: Text(
          at == null ? '—' : '${fmtShortDate(at)} ${fmtTime(at)}',
          style: DispatchTheme.numeric(size: 12.5, weight: FontWeight.w600, color: context.mutedColor),
        ),
      ),
      const SizedBox(width: Sp.md),
      SizedBox(width: 110, child: ToneChip(humanise(asStr(event['action'])), compact: true)),
      const SizedBox(width: Sp.md),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(asStr(event['entity_label']) ?? '', style: context.text.bodyMedium),
          Text(dotJoin([humanise(asStr(event['entity'])), asStr(event['actor_name'])]), style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
        ]),
      ),
    ]);

    if (!hasDetail) {
      return Padding(padding: const EdgeInsets.symmetric(vertical: Sp.sm), child: header);
    }
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: 150 + Sp.md, bottom: Sp.md),
        title: header,
        children: [
          if (asStr(event['reason']) != null && asStr(event['reason'])!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.sm),
              child: Text('Reason: ${asStr(event['reason'])}', style: context.text.bodyMedium),
            ),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _JsonBlock(label: 'Before', json: before == null ? '—' : encoder.convert(before))),
            const SizedBox(width: Sp.md),
            Expanded(child: _JsonBlock(label: 'After', json: after == null ? '—' : encoder.convert(after))),
          ]),
        ],
      ),
    );
  }
}

class _JsonBlock extends StatelessWidget {
  const _JsonBlock({required this.label, required this.json});
  final String label;
  final String json;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: context.text.labelMedium?.copyWith(color: context.mutedColor)),
      const SizedBox(height: 4),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Sp.sm),
        decoration: BoxDecoration(
          color: context.isDark ? const Color(0xFF111B2E) : DispatchColors.surfaceAlt,
          borderRadius: DispatchRadius.chipR,
          border: Border.all(color: context.borderColor),
        ),
        child: SelectableText(json, style: DispatchTheme.numeric(size: 11.5, weight: FontWeight.w500, color: context.inkColor)),
      ),
    ]);
  }
}

// ─── Skeleton ─────────────────────────────────────────────────────────────

class _SettingsSkeleton extends StatelessWidget {
  const _SettingsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: const [
      SizedBox(
        width: 210,
        child: Column(children: [
          Skeleton(width: double.infinity, height: 38),
          SizedBox(height: 6),
          Skeleton(width: double.infinity, height: 38),
          SizedBox(height: 6),
          Skeleton(width: double.infinity, height: 38),
        ]),
      ),
      SizedBox(width: Sp.lg),
      Expanded(child: SkeletonPanel(rows: 6)),
    ]);
  }
}

// ─── Parsing (workspace_config.php get) ───────────────────────────────────

class _WorkTypeRow {
  const _WorkTypeRow({
    required this.id,
    required this.name,
    required this.plural,
    required this.prefix,
    required this.colour,
    this.policy = 'planned',
    this.requiresEstimate = true,
    this.requiresBenefit = false,
    this.description,
    this.defaultSizeStamp,
    this.allowedSizes = const [],
    this.itemCount = 0,
    this.openItemCount = 0,
    this.sortOrder = 0,
    this.retired = false,
  });

  final int id;
  final String name;
  final String plural;
  final String prefix;
  final String colour;
  final String policy;
  final bool requiresEstimate;
  final bool requiresBenefit;
  final String? description;

  /// CFG-02: pre-selected on the Add work form. Null when the type has none.
  final String? defaultSizeStamp;

  /// CFG-02: empty means every size is allowed (the API stores that as null).
  final List<String> allowedSizes;
  final int itemCount;
  final int openItemCount;
  final int sortOrder;
  final bool retired;

  bool get isInterrupt => policy == 'interrupt';

  factory _WorkTypeRow.fromJson(Map<String, dynamic> j) => _WorkTypeRow(
        id: asIntOr(j['id'], 0),
        name: asStrOr(j['name'], ''),
        plural: asStrOr(j['plural'], asStrOr(j['name'], '')),
        prefix: asStrOr(j['prefix'], ''),
        colour: asStrOr(j['colour'], '#3B6BD6'),
        policy: asStrOr(j['policy'], 'planned'),
        requiresEstimate: asBool(j['requires_estimate'], fallback: true),
        requiresBenefit: asBool(j['requires_benefit']),
        description: asStr(j['description']),
        defaultSizeStamp: asStr(j['default_size_stamp']),
        allowedSizes: asStrList(j['allowed_sizes']),
        itemCount: asIntOr(j['item_count'], 0),
        openItemCount: asIntOr(j['open_item_count'], 0),
        sortOrder: asIntOr(j['sort_order'], 0),
        retired: asBool(j['retired']),
      );
}

class _SizeClassRow {
  const _SizeClassRow({
    required this.id,
    required this.name,
    required this.stamp,
    this.workTypeId,
    this.minDays,
    this.maxDays,
    this.planningDays,
    this.defaultEstimateClass = 3,
    this.granularity = 'day',
    this.countsForWip = true,
    this.isCustom = false,
  });

  final int id;
  final String name;
  final String stamp;
  final int? workTypeId;
  final double? minDays;
  final double? maxDays;
  final double? planningDays;
  final int defaultEstimateClass;
  final String granularity;
  final bool countsForWip;
  final bool isCustom;

  factory _SizeClassRow.fromJson(Map<String, dynamic> j) => _SizeClassRow(
        id: asIntOr(j['id'], 0),
        name: asStrOr(j['name'], ''),
        stamp: asStrOr(j['stamp'], '?'),
        workTypeId: asInt(j['work_type_id']),
        minDays: asDouble(j['min_days']),
        maxDays: asDouble(j['max_days']),
        planningDays: asDouble(j['planning_days']),
        defaultEstimateClass: asIntOr(j['default_estimate_class'], 3),
        granularity: asStrOr(j['granularity'], 'day'),
        countsForWip: asBool(j['counts_for_wip'], fallback: true),
        isCustom: asBool(j['is_custom']),
      );
}

class _Config {
  const _Config({
    required this.workspace,
    required this.workTypes,
    required this.sizeClasses,
    required this.incidentSizeClasses,
    required this.policy,
    required this.dayRates,
    required this.integrations,
    this.incidentWorkTypeId,
  });

  final Map<String, dynamic> workspace;
  final List<_WorkTypeRow> workTypes;
  final List<_SizeClassRow> sizeClasses;
  final List<_SizeClassRow> incidentSizeClasses;
  final Policy policy;
  final List<Map<String, dynamic>> dayRates;
  /// Real connector state from dbo.integrations, not a hardcoded list.
  final List<Map<String, dynamic>> integrations;
  final int? incidentWorkTypeId;

  String get workspaceName => asStrOr(workspace['name'], 'workspace');

  factory _Config.fromJson(Map<String, dynamic> j) => _Config(
        workspace: asMap(j['workspace']),
        workTypes: asList(j['work_types'], _WorkTypeRow.fromJson),
        sizeClasses: asList(j['size_classes'], _SizeClassRow.fromJson),
        incidentSizeClasses: asList(j['incident_size_classes'], _SizeClassRow.fromJson),
        policy: Policy.fromJson(asMap(j['policy'])),
        dayRates: [for (final r in (j['day_rates'] as List? ?? const [])) if (r is Map) Map<String, dynamic>.from(r)],
        integrations: [for (final r in (j['integrations'] as List? ?? const [])) if (r is Map) Map<String, dynamic>.from(r)],
        incidentWorkTypeId: asInt(j['incident_work_type_id']),
      );
}

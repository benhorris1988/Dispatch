import 'dart:async';

import 'package:flutter/material.dart';
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
import '../widgets/wc_filters.dart';
import '../widgets/wc_selection_table.dart';
import '../widgets/widgets.dart';
import '../widgets/work_widgets.dart';
import 'parts/add_work_form.dart';
import 'parts/wc_bulk_actions.dart';

/// Pipeline (PIP-03, web-02): every item with type, size stamp, priority,
/// benefit, estimate range, required skills and status, with filters and a
/// queue-health strip.
class PipelineScreen extends StatefulWidget {
  const PipelineScreen({super.key, this.query});

  /// Optional search text from the shell search field (?q=).
  final String? query;

  @override
  State<PipelineScreen> createState() => _PipelineScreenState();
}

const _statusTabs = ['all', 'unscheduled', 'scheduled', 'in_progress', 'delivered'];
const _statusLabels = ['All', 'Unscheduled', 'Scheduled', 'In progress', 'Delivered'];
const _sortOptions = <String, String>{
  'priority_score': 'Priority score',
  'needed_by': 'Needed by',
  'benefit_value': 'Benefit',
  'ref': 'Reference',
  'updated_at': 'Recently updated',
};

class _PipelineScreenState extends State<PipelineScreen> {
  final _search = TextEditingController();
  Timer? _debounce;

  List<WorkRow> _items = const [];
  Map<String, dynamic> _counts = const {};
  Map<String, dynamic> _queueHealth = const {};
  int _total = 0;
  bool _loading = true;
  String? _error;

  int _tab = 0;
  int? _typeId;
  String? _sizeStamp;
  int? _skillId;
  int? _teamId;
  String _sort = 'priority_score';
  String _q = '';

  List<Skill> _skills = const [];
  List<({int id, String name})> _teams = const [];

  final Set<String> _hiddenColumns = {};

  /// Work item ids ticked for a bulk action (PIP-10).
  final Set<int> _selected = {};

  @override
  void initState() {
    super.initState();
    _q = widget.query ?? '';
    _search.text = _q;
    _load();
    _loadFilters();
  }

  @override
  void didUpdateWidget(covariant PipelineScreen old) {
    super.didUpdateWidget(old);
    // The shell search field pushes /pipeline?q=... again.
    if (old.query != widget.query && (widget.query ?? '') != _q) {
      _q = widget.query ?? '';
      _search.text = _q;
      _load();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadFilters() async {
    try {
      final r = await Api.post('skills.php', 'list');
      if (mounted) setState(() => _skills = asList(r['skills'], Skill.fromJson).where((s) => !s.retired).toList());
    } on ApiException {
      // Filters degrade to "all" quietly.
    }
    try {
      final r = await Api.post('people.php', 'list');
      final teams = (r['teams'] as List?)?.whereType<Map>().map((e) => (id: asIntOr(e['id'], 0), name: asStrOr(e['name'], ''))).toList() ?? const <({int id, String name})>[];
      if (mounted) setState(() => _teams = teams);
    } on ApiException {
      // As above.
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = _items.isEmpty;
      _error = null;
    });
    try {
      final r = await Api.post('work_items.php', 'list', {
        'status': _statusTabs[_tab],
        if (_typeId != null) 'type_id': _typeId,
        if (_sizeStamp != null) 'size_stamp': _sizeStamp,
        if (_skillId != null) 'skill_id': _skillId,
        if (_teamId != null) 'team_id': _teamId,
        if (_q.trim().isNotEmpty) 'q': _q.trim(),
        'sort': _sort,
        'limit': 100,
      });
      if (!mounted) return;
      setState(() {
        _items = (r['items'] as List?)?.whereType<Map>().map((e) => WorkRow(Map<String, dynamic>.from(e))).toList() ?? const [];
        _counts = asMap(r['counts']);
        _queueHealth = asMap(r['queue_health']);
        _total = asIntOr(r['total'], _items.length);
        _loading = false;
        // A filter or a bulk change can take a ticked row off the page; a
        // selection the user can no longer see must not travel with them.
        _selected.retainAll(_items.map((i) => i.id).toSet());
      });
      context.read<ShellState>().setPageTitle('Pipeline');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() => _q = v);
      _load();
    });
  }

  void _importFromJira() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Import from Jira'),
        content: SizedBox(
          width: 460,
          child: Text(
            'Jira import is configured in Settings → Integrations: a saved query, then a field mapping to work type, '
            'size and skills. No integration is enabled for this workspace yet, so there is nothing to import.',
            style: dialogContext.text.bodyMedium,
          ),
        ),
        actions: [
          SecondaryButton('Close', onPressed: () => Navigator.of(dialogContext).pop()),
          PrimaryButton('Open settings', onPressed: () {
            Navigator.of(dialogContext).pop();
            context.go(Routes.settings);
          }),
        ],
      ),
    );
  }

  Future<void> _runBulk(String op) async {
    final ids = _items.where((i) => _selected.contains(i.id)).map((i) => i.id).toList();
    if (ids.isEmpty) return;
    final updated = await showWcBulkDialog(context, op: op, ids: ids);
    if (updated == null || !mounted) return;
    final skipped = ids.length - updated;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(dotJoin([
        '$updated ${updated == 1 ? 'item' : 'items'} updated',
        skipped > 0 ? '$skipped already had that value' : null,
      ])),
    ));
    setState(_selected.clear);
    await _load();
  }

  Future<void> _addWork() async {
    if (Breaks.isPhone(context)) {
      context.go(Routes.addWork);
      return;
    }
    final ref = await showAddWorkDialog(context);
    if (ref != null && mounted) context.go(Routes.item(ref));
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _counts.isEmpty
        ? null
        : dotJoin([
            '${asIntOr(_counts['all'], 0)} items',
            '${asIntOr(_counts['unscheduled'], 0)} unscheduled',
            '${asIntOr(_counts['needs_estimate'], 0)} waiting for an estimate',
          ]);

    return PageBody(
      onRefresh: _load,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(
          title: 'Pipeline',
          subtitle: subtitle,
          actions: [
            SecondaryButton('Import from Jira', icon: Icons.upload_rounded, onPressed: _importFromJira),
            _columnsButton(),
            PrimaryButton('Add work', icon: Icons.add_rounded, onPressed: _addWork),
          ],
        ),
        const SizedBox(height: Sp.lg),
        _filterRow(),
        const SizedBox(height: Sp.lg),
        if (_loading)
          const SkeletonPanel(rows: 8)
        else if (_error != null)
          ErrorState(title: 'The pipeline could not be loaded', message: _error, onRetry: _load)
        else ...[
          _queueStrip(),
          if (_canBulk && _selected.isNotEmpty)
            WcBulkBar(
              count: _selected.length,
              total: _items.length,
              onClear: () => setState(_selected.clear),
              onSelectAll: () => setState(() => _selected.addAll(_items.map((i) => i.id))),
              onAction: _runBulk,
            ),
          Panel(
            padding: EdgeInsets.zero,
            child: _items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(Sp.xl),
                    child: EmptyState(
                      icon: Icons.filter_alt_outlined,
                      title: _q.isNotEmpty || _typeId != null || _sizeStamp != null || _skillId != null || _teamId != null || _tab != 0
                          ? 'Nothing matches these filters'
                          : 'The pipeline is empty',
                      message: _q.isNotEmpty || _typeId != null || _sizeStamp != null || _skillId != null || _teamId != null || _tab != 0
                          ? 'Clear a filter or widen the search to see more work.'
                          : 'Add the first piece of work so the scheduler has something to place.',
                      action: PrimaryButton('Add work', icon: Icons.add_rounded, onPressed: _addWork),
                    ),
                  )
                : LayoutBuilder(builder: (context, box) => box.maxWidth < 800 ? _cards() : _table()),
          ),
          const SizedBox(height: Sp.md),
          _footer(),
        ],
      ]),
    );
  }

  /// `work_items.php bulk` is team_lead and above; the controls are hidden
  /// below that rather than left to fail with a 403.
  bool get _canBulk => context.watch<Session>().isTeamLead;

  Widget _columnsButton() {
    const toggleable = ['Type', 'Size', 'Priority', 'Benefit', 'ROM days', 'Required skills', 'Status'];
    return PopupMenuButton<String>(
      tooltip: 'Choose columns',
      onSelected: (c) => setState(() => _hiddenColumns.contains(c) ? _hiddenColumns.remove(c) : _hiddenColumns.add(c)),
      itemBuilder: (context) => [
        for (final c in toggleable) CheckedPopupMenuItem(value: c, checked: !_hiddenColumns.contains(c), child: Text(c)),
      ],
      child: IgnorePointer(child: SecondaryButton('Columns', icon: Icons.view_column_outlined, onPressed: () {})),
    );
  }

  Widget _filterRow() {
    final cfg = context.watch<WorkspaceConfig>();
    return Wrap(spacing: Sp.md, runSpacing: Sp.md, crossAxisAlignment: WrapCrossAlignment.center, children: [
      SegmentedTabs(
        labels: _statusLabels,
        selected: _tab,
        compact: true,
        onChanged: (i) {
          setState(() => _tab = i);
          _load();
        },
      ),
      _dropdown<int?>(
        value: _typeId,
        hint: 'All types',
        icon: Icons.category_outlined,
        items: [
          const DropdownMenuItem<int?>(value: null, child: Text('All types')),
          for (final t in cfg.activeWorkTypes) DropdownMenuItem<int?>(value: t.id, child: Text(t.name)),
        ],
        onChanged: (v) {
          setState(() => _typeId = v);
          _load();
        },
      ),
      _dropdown<String?>(
        value: _sizeStamp,
        hint: 'Any size',
        icon: Icons.crop_square_rounded,
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('Any size')),
          for (final s in cfg.defaultSizeClasses) DropdownMenuItem<String?>(value: s.stamp, child: Text('${s.stamp} · ${s.name}')),
        ],
        onChanged: (v) {
          setState(() => _sizeStamp = v);
          _load();
        },
      ),
      _dropdown<int?>(
        value: _skillId,
        hint: 'Any skill',
        icon: Icons.handyman_outlined,
        items: [
          const DropdownMenuItem<int?>(value: null, child: Text('Any skill')),
          for (final s in _skills) DropdownMenuItem<int?>(value: s.id, child: Text(s.name)),
        ],
        onChanged: (v) {
          setState(() => _skillId = v);
          _load();
        },
      ),
      if (_teams.length > 1)
        _dropdown<int?>(
          value: _teamId,
          hint: 'All teams',
          icon: Icons.people_alt_outlined,
          // Teams nest now (ORG-01), so their names are longer and there are more
          // of them. Cap the control and ellipsise, rather than letting the
          // longest team name decide how wide the toolbar is.
          maxWidth: 190,
          items: [
            const DropdownMenuItem<int?>(value: null, child: Text('All teams')),
            for (final t in _teams) DropdownMenuItem<int?>(value: t.id, child: Text(t.name)),
          ],
          onChanged: (v) {
            setState(() => _teamId = v);
            _load();
          },
        ),
      SizedBox(
        width: 260,
        child: TextField(
          controller: _search,
          onChanged: _onSearch,
          decoration: InputDecoration(
            hintText: 'Search work, refs, tags',
            prefixIcon: const Icon(Icons.search_rounded, size: 18),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear the search',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () {
                      _search.clear();
                      setState(() => _q = '');
                      _load();
                    },
                  ),
          ),
        ),
      ),
      _dropdown<String>(
        value: _sort,
        hint: 'Sort',
        icon: Icons.sort_rounded,
        items: [for (final e in _sortOptions.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
        onChanged: (v) {
          setState(() => _sort = v ?? 'priority_score');
          _load();
        },
      ),
    ]);
  }

  /// The toolbar dropdown now lives in `widgets/wc_filters.dart` so the
  /// Benefits register can wear the same control (BEN-05).
  Widget _dropdown<T>({
    required T? value,
    required String hint,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
    IconData? icon,
    double? maxWidth,
  }) =>
      WcFilterDropdown<T>(value: value, hint: hint, items: items, onChanged: onChanged, icon: icon, maxWidth: maxWidth);

  Widget _queueStrip() {
    final parts = <String>[];
    void add(String key, String Function(int n, int days) copy) {
      final m = asMap(_queueHealth[key]);
      final n = asIntOr(m['count'], 0);
      if (n > 0) parts.add(copy(n, asIntOr(m['oldest_days'], 0)));
    }

    add('needs_estimate', (n, d) => '$n waiting for an estimate · oldest $d day${d == 1 ? '' : 's'}');
    add('needs_benefit', (n, d) => '$n missing a benefit case');
    add('skills_gap', (n, d) => '$n with a skills gap');
    if (parts.isEmpty) return const SizedBox.shrink();

    final message = Row(children: [
      const Icon(Icons.pending_actions_rounded, size: 18, color: DispatchColors.amber),
      const SizedBox(width: Sp.sm),
      Expanded(child: Text('Queue health: ${parts.join(' · ')}', style: context.text.bodyMedium)),
    ]);
    // The link is a whole sentence; beside a multi-line message it has nothing
    // like the room it needs on a phone, so it takes its own line there and
    // stays a flexible child of the row everywhere else.
    final link = TextButton(
      onPressed: () => context.go(Routes.estimates),
      child: const Text('Open the estimate queue', maxLines: 1, overflow: TextOverflow.ellipsis),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.md),
      child: DispatchCard(
        tint: DispatchColors.tint(DispatchColors.amber, opacity: context.isDark ? 0.16 : 0.10),
        accent: DispatchColors.amber,
        padding: const EdgeInsets.symmetric(horizontal: Sp.md, vertical: Sp.sm),
        child: Breaks.isPhone(context)
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                message,
                link,
              ])
            : Row(children: [
                Expanded(child: message),
                Flexible(child: link),
              ]),
      ),
    );
  }

  bool _show(String column) => !_hiddenColumns.contains(column);

  Widget _table() {
    final columns = <TableCol>[
      const TableCol('Ref', width: 92),
      const TableCol('Work', flex: 5),
      if (_show('Type')) const TableCol('Type', width: 122),
      if (_show('Size')) const TableCol('Size', width: 54),
      if (_show('Priority')) const TableCol('Priority', width: 118),
      if (_show('Benefit')) const TableCol('Benefit £k/yr', width: 108, alignRight: true),
      if (_show('ROM days')) const TableCol('ROM days', width: 92, alignRight: true),
      if (_show('Required skills')) const TableCol('Required skills', flex: 3),
      if (_show('Status')) const TableCol('Status', width: 118),
    ];

    final cells = <List<Widget>>[
      for (final i in _items)
        [
            Text(i.ref, style: DispatchTheme.numeric(size: 13, weight: FontWeight.w600, color: context.mutedColor)),
            Text(i.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            if (_show('Type')) TypeChip(i.typeName, colourHex: i.typeColour, compact: true),
            if (_show('Size')) SizeStamp(i.sizeStamp, size: 24, dashed: i.isCustom),
            if (_show('Priority')) PriorityBar(i.priorityScore, width: 64),
            if (_show('Benefit'))
              Text(i.benefitValue > 0 ? (i.benefitValue / 1000).round().toString() : '—', style: DispatchTheme.numeric(size: 13)),
            if (_show('ROM days')) Text(i.romLabel, style: DispatchTheme.numeric(size: 13, weight: FontWeight.w600)),
            if (_show('Required skills')) SkillChips(i.skills, max: 2),
            if (_show('Status')) StatusChip(i.displayStatus, compact: true),
          ],
    ];

    if (!_canBulk) {
      return DispatchTable(
        columns: columns,
        minWidth: 860,
        onRowTap: (i) => context.go(Routes.item(_items[i].ref)),
        rowSemantics: (i) => '${_items[i].ref} ${_items[i].title}',
        rows: cells,
      );
    }

    return WcSelectionTable(
      columns: columns,
      // The checkbox column adds 44px, so the table asks for that much more
      // before it starts scrolling sideways.
      minWidth: 904,
      rows: cells,
      isSelected: (i) => _selected.contains(_items[i].id),
      onSelect: (i, on) => setState(() => on ? _selected.add(_items[i].id) : _selected.remove(_items[i].id)),
      onSelectAll: (all) => setState(() {
        _selected.clear();
        if (all) _selected.addAll(_items.map((i) => i.id));
      }),
      onRowTap: (i) => context.go(Routes.item(_items[i].ref)),
      rowSemantics: (i) => '${_items[i].ref} ${_items[i].title}',
      rowLabel: (i) => 'Select ${_items[i].ref} ${_items[i].title}',
    );
  }

  Widget _cards() {
    return Column(children: [
      for (final i in _items)
        InkWell(
          onTap: () => context.go(Routes.item(i.ref)),
          child: Container(
            padding: const EdgeInsets.all(Sp.md),
            decoration: BoxDecoration(
              color: _selected.contains(i.id) ? DispatchColors.tint(DispatchColors.typeBlue, opacity: context.isDark ? 0.18 : 0.07) : null,
              border: Border(bottom: BorderSide(color: context.borderColor)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (_canBulk)
                  Padding(
                    padding: const EdgeInsets.only(right: Sp.sm),
                    child: Checkbox(
                      value: _selected.contains(i.id),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      semanticLabel: 'Select ${i.ref} ${i.title}',
                      onChanged: (v) => setState(() => (v ?? false) ? _selected.add(i.id) : _selected.remove(i.id)),
                    ),
                  ),
                // The reference gives way before the status chip does, so the
                // checkbox can join the row on a phone without crowding it.
                Expanded(
                  child: Row(children: [
                    Flexible(
                      child: Text(
                        i.ref,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DispatchTheme.numeric(size: 12.5, color: context.mutedColor),
                      ),
                    ),
                    const SizedBox(width: Sp.sm),
                    SizeStamp(i.sizeStamp, size: 22, dashed: i.isCustom),
                  ]),
                ),
                const SizedBox(width: Sp.sm),
                StatusChip(i.displayStatus, compact: true),
              ]),
              const SizedBox(height: Sp.xs),
              Text(i.title, style: context.text.titleSmall),
              const SizedBox(height: Sp.sm),
              Row(children: [
                TypeChip(i.typeName, colourHex: i.typeColour, compact: true),
                const SizedBox(width: Sp.sm),
                PriorityBar(i.priorityScore, width: 52),
                const Spacer(),
                Flexible(
                  child: Text(
                    dotJoin([
                      i.romLabel == '—' ? null : 'ROM ${i.romLabel} ${i.romUnit}',
                      i.benefitValue > 0 ? fmtMoneyK(i.benefitValue) : null,
                    ]),
                    style: context.text.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                  ),
                ),
              ]),
              if (i.skills.isNotEmpty) ...[
                const SizedBox(height: Sp.sm),
                SkillChips(i.skills, max: 3),
              ],
            ]),
          ),
        ),
    ]);
  }

  Widget _footer() {
    return Wrap(
      spacing: Sp.md,
      runSpacing: Sp.sm,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Showing ${_items.length} of $_total', style: context.text.bodySmall),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: Sp.md, vertical: 6),
          decoration: BoxDecoration(
            color: context.scheme.surfaceContainerHighest,
            borderRadius: DispatchRadius.buttonR,
            border: Border.all(color: context.borderColor),
          ),
          child: Text('Custom size “C” means effort is entered directly rather than by size class', style: context.text.bodySmall),
        ),
      ],
    );
  }
}

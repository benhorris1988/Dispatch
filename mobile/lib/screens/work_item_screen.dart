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
import '../widgets/widgets.dart';
import '../widgets/work_widgets.dart';
import 'parts/wc_dependency_dialog.dart';

/// Work item (web-03 / mobile-work-item): what it is, who can do it, what it
/// depends on, when it is planned, how big it is and why it is worth doing.
class WorkItemScreen extends StatefulWidget {
  const WorkItemScreen({super.key, required this.ref});

  /// Work item reference, e.g. WI-1042.
  final String ref;

  @override
  State<WorkItemScreen> createState() => _WorkItemScreenState();
}

class _WorkItemScreenState extends State<WorkItemScreen> {
  Map<String, dynamic>? _item;
  bool _loading = true;
  String? _error;
  int _tab = 0;
  bool _priorityOpen = false;
  final _comment = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant WorkItemScreen old) {
    super.didUpdateWidget(old);
    if (old.ref != widget.ref) {
      _item = null;
      _tab = 0;
      _load();
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = _item == null;
      _error = null;
    });
    try {
      final r = await Api.post('work_items.php', 'get', {'ref': widget.ref});
      if (!mounted) return;
      final item = asMap(r['item']);
      setState(() {
        _item = item;
        _loading = false;
      });
      context.read<ShellState>().setPageTitle(
            '${asStrOr(item['ref'], widget.ref)} ${asStrOr(item['title'], '')}',
            breadcrumb: ['Pipeline', asStrOr(item['ref'], widget.ref)],
          );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  WorkRow get _row => WorkRow(_item ?? const {});
  List<SkillNeed> get _skills =>
      (_item?['skills'] as List?)?.whereType<Map>().map((e) => SkillNeed.fromJson(Map<String, dynamic>.from(e))).toList() ?? const [];
  List<Map<String, dynamic>> _list(String key, [Map<String, dynamic>? from]) =>
      ((from ?? _item)?[key] as List?)?.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() ?? const [];

  // ─── Actions ────────────────────────────────────────────────────────────

  void _snack(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _setStatus(String status) async {
    try {
      await Api.post('work_items.php', 'set_status', {
        'id': _row.id,
        'status': status,
        if (status == 'delivered') 'actual_effort_days': asDouble(_item?['actual_effort_days']) ?? asDouble(asMap(_item?['estimate'])['likely']) ?? 1,
      });
      _snack('${_row.ref} is now ${humanise(status)}.');
      await _load();
    } on ApiException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _showHistory() async {
    List<Map<String, dynamic>> events = const [];
    String? error;
    try {
      final r = await Api.post('work_items.php', 'history', {'id': _row.id});
      events = (r['events'] as List?)?.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() ?? const [];
    } on ApiException catch (e) {
      error = e.message;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (sheetContext, controller) => Padding(
          padding: const EdgeInsets.fromLTRB(Sp.xl, 0, Sp.xl, Sp.xl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.md),
              child: Text('History of ${_row.ref}', style: sheetContext.text.headlineSmall),
            ),
            Expanded(
              child: error != null
                  ? ErrorState(title: 'The history could not be loaded', message: error)
                  : events.isEmpty
                      ? const EmptyState(icon: Icons.history_rounded, title: 'Nothing has changed yet', message: 'Every edit to this item will be listed here with who, when and before and after.')
                      : ListView.separated(
                          controller: controller,
                          itemCount: events.length,
                          separatorBuilder: (_, _) => Divider(height: 1, color: sheetContext.borderColor),
                          itemBuilder: (context, i) {
                            final e = events[i];
                            final field = asStr(e['field']);
                            final before = e['before'];
                            final after = e['after'];
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: Sp.md),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(
                                  dotJoin([humanise(asStr(e['action'])), field == null ? asStr(e['entity']) : humanise(field)]),
                                  style: context.text.titleSmall,
                                ),
                                if (before != null || after != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text('${_short(before)} → ${_short(after)}', style: context.text.bodySmall?.copyWith(color: context.inkColor)),
                                  ),
                                const SizedBox(height: 2),
                                Text(
                                  dotJoin([asStr(e['actor_name']), _stamp(asDate(e['occurred_at'])), asStr(e['reason'])]),
                                  style: context.text.bodySmall,
                                ),
                              ]),
                            );
                          },
                        ),
            ),
          ]),
        ),
      ),
    );
  }

  static String _short(dynamic v) {
    if (v == null) return '—';
    final s = v is Map || v is List ? v.toString() : v.toString();
    return s.length > 80 ? '${s.substring(0, 79)}…' : s;
  }

  static String _stamp(DateTime? d) => d == null ? '' : '${fmtShortDate(d)} ${fmtTime(d)}';

  Future<void> _edit() async {
    final title = TextEditingController(text: _row.title);
    final summary = TextEditingController(text: _row.summary ?? '');
    final sponsor = TextEditingController(text: _row.sponsor ?? '');
    final requestedBy = TextEditingController(text: _row.requestedBy ?? '');
    final tags = TextEditingController(text: _row.tags.join(', '));
    DateTime? neededBy = _row.neededBy;
    DateTime? earliestStart = _row.earliestStart;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          title: Text('Edit ${_row.ref}'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')),
                const SizedBox(height: Sp.md),
                TextField(controller: summary, minLines: 3, maxLines: 6, decoration: const InputDecoration(labelText: 'Summary')),
                const SizedBox(height: Sp.md),
                Row(children: [
                  Expanded(child: TextField(controller: requestedBy, decoration: const InputDecoration(labelText: 'Requested by'))),
                  const SizedBox(width: Sp.md),
                  Expanded(child: TextField(controller: sponsor, decoration: const InputDecoration(labelText: 'Sponsor'))),
                ]),
                const SizedBox(height: Sp.md),
                TextField(controller: tags, decoration: const InputDecoration(labelText: 'Tags', hintText: 'Comma separated')),
                const SizedBox(height: Sp.md),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: _DateField(
                      label: 'Needed by',
                      value: neededBy,
                      helpText: 'Needed by',
                      onPick: (d) => setLocal(() => neededBy = d),
                    ),
                  ),
                  const SizedBox(width: Sp.md),
                  Expanded(
                    child: _DateField(
                      label: 'Earliest start',
                      value: earliestStart,
                      helpText: 'Earliest start',
                      onPick: (d) => setLocal(() => earliestStart = d),
                    ),
                  ),
                ]),
                const SizedBox(height: Sp.xs),
                Text(
                  'The scheduler will not place this work before its earliest start, '
                  'so use it for a date the team genuinely cannot begin before.',
                  style: dialogContext.text.bodySmall,
                ),
              ]),
            ),
          ),
          actions: [
            SecondaryButton('Cancel', onPressed: () => Navigator.of(dialogContext).pop(false)),
            PrimaryButton('Save changes', onPressed: () => Navigator.of(dialogContext).pop(true)),
          ],
        ),
      ),
    );

    if (saved != true) return;
    try {
      await Api.post('work_items.php', 'update', {
        'id': _row.id,
        'title': title.text.trim(),
        'summary': summary.text.trim(),
        'sponsor': sponsor.text.trim(),
        'requested_by': requestedBy.text.trim(),
        'tags': tags.text.trim(),
        'needed_by': neededBy == null ? '' : _iso(neededBy!),
        'earliest_start': earliestStart == null ? '' : _iso(earliestStart!),
      });
      _snack('${_row.ref} updated.');
      await _load();
    } on ApiException catch (e) {
      _snack(e.message);
    }
  }

  static String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _overridePriority() async {
    final points = TextEditingController(text: '10');
    final reason = TextEditingController();
    DateTime expires = DateTime.now().add(const Duration(days: 28));
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          title: const Text('Override the priority'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('An override adds or removes up to 20 points and expires on a date you choose. The reason is recorded.',
                  style: dialogContext.text.bodySmall),
              const SizedBox(height: Sp.md),
              TextField(controller: points, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Points (−20 to +20)')),
              const SizedBox(height: Sp.md),
              TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason')),
              const SizedBox(height: Sp.md),
              OutlinedButton.icon(
                icon: const Icon(Icons.event_rounded, size: 18),
                label: Align(alignment: Alignment.centerLeft, child: Text('Expires ${fmtDate(expires)}')),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: dialogContext,
                    initialDate: expires,
                    firstDate: DateTime.now(),
                    lastDate: DateTime(DateTime.now().year + 2),
                  );
                  if (picked != null) setLocal(() => expires = picked);
                },
              ),
            ]),
          ),
          actions: [
            SecondaryButton('Cancel', onPressed: () => Navigator.of(dialogContext).pop(false)),
            PrimaryButton('Apply override', onPressed: () => Navigator.of(dialogContext).pop(true)),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (reason.text.trim().isEmpty) {
      _snack('An override needs a reason.');
      return;
    }
    try {
      await Api.post('work_items.php', 'override_priority', {
        'id': _row.id,
        'points': int.tryParse(points.text.trim()) ?? 0,
        'reason': reason.text.trim(),
        'expires': _iso(expires),
      });
      _snack('Priority override applied.');
      await _load();
    } on ApiException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _clearOverride() async {
    try {
      await Api.post('work_items.php', 'clear_override', {'id': _row.id});
      _snack('Priority override cleared.');
      await _load();
    } on ApiException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _logProgress() async {
    var pct = _row.progressPct.toDouble();
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          title: const Text('Log progress'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${pct.round()}% complete', style: dialogContext.text.titleMedium),
              Slider(value: pct, max: 100, divisions: 20, label: '${pct.round()}%', onChanged: (v) => setLocal(() => pct = v)),
              TextField(controller: note, decoration: const InputDecoration(labelText: 'Note (optional)')),
            ]),
          ),
          actions: [
            SecondaryButton('Cancel', onPressed: () => Navigator.of(dialogContext).pop(false)),
            PrimaryButton('Save progress', onPressed: () => Navigator.of(dialogContext).pop(true)),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await Api.post('work_items.php', 'log_progress', {
        'id': _row.id,
        'progress_pct': pct.round(),
        if (note.text.trim().isNotEmpty) 'note': note.text.trim(),
      });
      _snack('Progress saved.');
      await _load();
    } on ApiException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _addSkillRequirement() async {
    List<Skill> catalogue = const [];
    try {
      final r = await Api.post('skills.php', 'list');
      catalogue = asList(r['skills'], Skill.fromJson).where((s) => !s.retired).toList();
    } on ApiException catch (e) {
      _snack(e.message);
      return;
    }
    final taken = _skills.map((s) => s.skillId).toSet();
    final available = catalogue.where((s) => !taken.contains(s.id)).toList();
    if (!mounted) return;
    if (available.isEmpty) {
      _snack('Every skill in the catalogue is already required.');
      return;
    }
    var chosen = available.first;
    var level = 3;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          title: const Text('Add a required skill'),
          content: SizedBox(
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
                labels: const ['1', '2', '3', '4'],
                selected: level - 1,
                compact: true,
                onChanged: (i) => setLocal(() => level = i + 1),
              ),
              const SizedBox(height: Sp.sm),
              Text(kProficiencyLabels[level.clamp(0, 4)], style: dialogContext.text.bodySmall),
            ]),
          ),
          actions: [
            SecondaryButton('Cancel', onPressed: () => Navigator.of(dialogContext).pop(false)),
            PrimaryButton('Add skill', onPressed: () => Navigator.of(dialogContext).pop(true)),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await Api.post('work_items.php', 'set_skill_requirement', {'id': _row.id, 'skill_id': chosen.id, 'min_proficiency': level});
      await _load();
    } on ApiException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _removeSkillRequirement(SkillNeed s) async {
    try {
      await Api.post('work_items.php', 'remove_skill_requirement', {'id': _row.id, 'skill_id': s.skillId});
      await _load();
    } on ApiException catch (e) {
      _snack(e.message);
    }
  }

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
      return PageBody(
        child: ErrorState(
          title: '${widget.ref} could not be loaded',
          message: _error,
          onRetry: _load,
        ),
      );
    }

    final item = _item!;
    final session = context.watch<Session>();
    final row = _row;
    final plan = asMap(item['plan']);
    final tasks = _list('tasks');
    final comments = _list('comments');

    final tabs = <String>[
      'Overview',
      'Requirements',
      'Estimate',
      'Benefits',
      'Tasks (${tasks.length})',
      'Schedule',
      'Discussion (${comments.length})',
    ];

    return PageBody(
      onRefresh: _load,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _breadcrumb(row),
        const SizedBox(height: Sp.sm),
        _headerBlock(row, plan, session),
        const SizedBox(height: Sp.lg),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedTabs(labels: tabs, selected: _tab, compact: true, onChanged: (i) => setState(() => _tab = i)),
        ),
        const SizedBox(height: Sp.lg),
        switch (_tab) {
          0 => _overviewTab(row, plan),
          1 => _requirementsTab(item),
          2 => _estimateTab(item),
          3 => _benefitsTab(item),
          4 => _tasksTab(tasks, item),
          5 => _scheduleTab(item),
          _ => _discussionTab(comments),
        },
      ]),
    );
  }

  Widget _breadcrumb(WorkRow row) {
    return Row(children: [
      TextButton(onPressed: () => context.go(Routes.pipeline), child: const Text('Pipeline')),
      Icon(Icons.chevron_right_rounded, size: 16, color: context.mutedColor),
      const SizedBox(width: Sp.sm),
      Flexible(child: Text('${row.ref} ${row.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodyMedium)),
    ]);
  }

  Widget _headerBlock(WorkRow row, Map<String, dynamic> plan, Session session) {
    final committed = asBool(plan['committed']);
    final chips = Wrap(spacing: Sp.sm, runSpacing: Sp.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Text(row.ref, style: DispatchTheme.numeric(size: 15, color: context.mutedColor)),
      TypeChip(row.typeName, colourHex: row.typeColour, compact: true),
      SizeStamp(row.sizeStamp, size: 24, dashed: row.isCustom),
      if (row.health != null && row.health!.isNotEmpty && row.health != 'on_track') StatusChip(row.health, compact: true),
      StatusChip(committed ? 'committed' : 'scheduled', label: committed ? 'Committed' : 'Scheduled', icon: committed ? Icons.lock_outline_rounded : null, compact: true),
    ]);

    final actions = <Widget>[
      SecondaryButton('History', icon: Icons.history_rounded, onPressed: _showHistory),
      if (session.can('requester')) SecondaryButton('Edit', icon: Icons.edit_outlined, onPressed: _edit),
      if (session.can('team_member')) SecondaryButton('Log progress', icon: Icons.timeline_rounded, onPressed: _logProgress),
      _statusMenu(session),
      PrimaryButton('Adjust schedule', icon: Icons.calendar_month_rounded, navy: true, onPressed: () => context.go(Routes.schedule)),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (Breaks.isPhone(context)) ...[
        chips,
        const SizedBox(height: Sp.md),
        Text(row.title, style: context.text.headlineMedium),
        const SizedBox(height: Sp.xs),
        Text(_metaLine(row), style: context.text.bodySmall),
        const SizedBox(height: Sp.md),
        Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: actions),
      ] else
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              chips,
              const SizedBox(height: Sp.md),
              Text(row.title, style: context.text.displaySmall),
              const SizedBox(height: Sp.xs),
              Text(_metaLine(row), style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
            ]),
          ),
          const SizedBox(width: Sp.lg),
          // Flexible, because a Wrap handed unbounded width by a Row measures itself as if
          // the header were infinitely wide and so never wraps — it just overflows.
          Flexible(child: Wrap(spacing: Sp.sm, runSpacing: Sp.sm, alignment: WrapAlignment.end, children: actions)),
        ]),
    ]);
  }

  String _metaLine(WorkRow row) => dotJoin([
        row.requestedBy == null ? null : 'Requested by ${row.requestedBy}',
        row.sponsor == null ? null : 'Sponsor: ${row.sponsor}',
        row.createdAt == null ? null : 'Created ${fmtDayMonth(row.createdAt)} ${row.createdAt!.year}',
      ]);

  Widget _statusMenu(Session session) {
    const options = ['ready', 'scheduled', 'in_progress', 'blocked', 'delivered', 'cancelled', 'draft'];
    return PopupMenuButton<String>(
      tooltip: 'Change the status',
      onSelected: _setStatus,
      itemBuilder: (context) => [
        for (final s in options)
          PopupMenuItem(value: s, enabled: s != _row.status, child: Text(humanise(s == 'needs_benefit' ? 'needs benefit case' : s))),
      ],
      child: IgnorePointer(
        child: SecondaryButton('Status: ${humanise(_row.status)}', icon: Icons.flag_outlined, onPressed: () {}),
      ),
    );
  }

  // ─── Overview tab ───────────────────────────────────────────────────────

  Widget _overviewTab(WorkRow row, Map<String, dynamic> plan) {
    final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _summaryPanel(row),
      const SizedBox(height: Sp.lg),
      _skillsPanel(),
      const SizedBox(height: Sp.lg),
      _dependenciesPanel(),
    ]);
    final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _planPanel(row, plan),
      const SizedBox(height: Sp.lg),
      _romPanel(),
      const SizedBox(height: Sp.lg),
      _benefitPanel(),
    ]);

    if (Breaks.isDesktop(context)) {
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(flex: 7, child: left),
        const SizedBox(width: Sp.lg),
        SizedBox(width: 400, child: right),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [left, const SizedBox(height: Sp.lg), right]);
  }

  Widget _summaryPanel(WorkRow row) {
    return Panel(
      title: 'Summary',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          row.summary?.isNotEmpty == true ? row.summary! : 'No summary yet. Use Edit to say what this work is and what it unblocks.',
          style: row.summary?.isNotEmpty == true
              ? context.text.bodyLarge
              : context.text.bodyLarge?.copyWith(color: context.mutedColor, fontStyle: FontStyle.italic),
        ),
        if (row.tags.isNotEmpty) ...[
          const SizedBox(height: Sp.lg),
          Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
            for (final t in row.tags)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: Sp.md, vertical: 6),
                decoration: BoxDecoration(borderRadius: DispatchRadius.buttonR, border: Border.all(color: context.borderColor)),
                child: Text(t, style: context.text.bodySmall?.copyWith(color: context.inkColor)),
              ),
          ]),
        ],
      ]),
    );
  }

  Widget _skillsPanel() {
    final skills = _skills;
    final session = context.read<Session>();
    return Panel(
      title: 'Required skills',
      subtitle: 'Coverage across the team over the planned window',
      trailing: session.isTeamLead ? SecondaryButton('Add skill', icon: Icons.add_rounded, onPressed: _addSkillRequirement) : null,
      padding: EdgeInsets.zero,
      child: skills.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(Sp.xl),
              child: EmptyState(
                icon: Icons.handyman_outlined,
                title: 'No skills declared',
                message: 'The scheduler needs at least one required skill before it can match people to this work.',
                compact: true,
              ),
            )
          : Column(children: [
              for (final s in skills)
                Container(
                  padding: const EdgeInsets.all(Sp.md),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: s == skills.last ? Colors.transparent : context.borderColor))),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(s.name, style: context.text.titleSmall),
                        const SizedBox(height: 2),
                        Text(
                          dotJoin(['Minimum level ${s.minProficiency}', s.coverageLabel, s.effortDays == null ? null : fmtDaysShort(s.effortDays)]),
                          style: context.text.bodySmall,
                        ),
                      ]),
                    ),
                    const SizedBox(width: Sp.sm),
                    SkillLevelBadge(s.minProficiency),
                    const SizedBox(width: Sp.sm),
                    if (s.gap)
                      const ToneChip('No one qualifies', tone: 'bad', icon: Icons.error_outline_rounded, compact: true)
                    else if (s.singlePoint)
                      ToneChip(
                        s.qualified.isEmpty ? '1 person' : 'Only ${s.qualified.first.firstName}',
                        tone: 'warn',
                        icon: Icons.warning_amber_rounded,
                        compact: true,
                      )
                    else
                      const ToneChip('Covered', tone: 'ok', compact: true),
                    if (context.read<Session>().isTeamLead)
                      IconButton(
                        tooltip: 'Remove ${s.name}',
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () => _removeSkillRequirement(s),
                      ),
                  ]),
                ),
            ]),
    );
  }

  /// Every item already on the other end of a dependency, so the picker cannot
  /// offer one that would only come back as "That dependency already exists".
  Set<int> get _linkedIds {
    final deps = asMap(_item?['dependencies']);
    return {
      for (final d in [..._list('needs', deps), ..._list('unblocks', deps)]) asIntOr(d['id'], -1),
    }..remove(-1);
  }

  Future<void> _addDependency() async {
    final added = await showWcAddDependencyDialog(
      context,
      itemId: _row.id,
      itemRef: _row.ref,
      linkedIds: _linkedIds,
    );
    if (added == true) {
      _snack('Dependency added to ${_row.ref}.');
      await _load();
    }
  }

  Future<void> _removeDependency(String direction, Map<String, dynamic> row) async {
    final label = '${asStrOr(row['ref'], '')} ${asStrOr(row['title'], '')}'.trim();
    final ok = await showWcConfirm(
      context,
      title: 'Remove this dependency?',
      message: direction == 'Needs'
          ? '${_row.ref} will no longer wait for $label. The scheduler may place it earlier at the next replan.'
          : '$label will no longer wait for ${_row.ref}. The scheduler may place it earlier at the next replan.',
      confirmLabel: 'Remove dependency',
    );
    if (ok != true) return;
    try {
      await Api.post('work_items.php', 'remove_dependency', {'id': asIntOr(row['dependency_id'], 0)});
      _snack('Dependency removed.');
      await _load();
    } on ApiException catch (e) {
      _snack(e.message);
    }
  }

  Widget _dependenciesPanel() {
    final session = context.watch<Session>();
    final canEdit = session.isTeamLead;
    final deps = asMap(_item?['dependencies']);
    final needs = _list('needs', deps);
    final unblocks = _list('unblocks', deps);
    final all = [
      for (final d in needs) (label: 'Needs', row: d),
      for (final d in unblocks) (label: 'Unblocks', row: d),
    ];

    return Panel(
      title: 'Dependencies',
      subtitle: all.isEmpty ? null : 'What this waits for, and what waits on it',
      trailing: canEdit ? SecondaryButton('Add dependency', icon: Icons.add_link_rounded, onPressed: _addDependency) : null,
      padding: EdgeInsets.zero,
      child: all.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(Sp.xl),
              child: EmptyState(
                icon: Icons.link_off_rounded,
                title: 'Nothing depends on this, and it waits for nothing',
                message: 'Add a dependency when this work cannot start until another item finishes.',
                compact: true,
                action: canEdit ? PrimaryButton('Add a dependency', icon: Icons.add_link_rounded, onPressed: _addDependency) : null,
              ),
            )
          : Column(children: [
              for (final d in all)
                InkWell(
                  onTap: () => context.go(Routes.item(asStrOr(d.row['ref'], ''))),
                  child: Container(
                    padding: const EdgeInsets.all(Sp.md),
                    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: d == all.last ? Colors.transparent : context.borderColor))),
                    child: Row(children: [
                      ToneChip(d.label, compact: true),
                      const SizedBox(width: Sp.md),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${asStrOr(d.row['ref'], '')} ${asStrOr(d.row['title'], '')}', style: context.text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 2),
                          Text(
                            dotJoin([
                              asStrOr(d.row['dep_type'], '') == 'soft' ? 'Soft' : 'Finish to start',
                              asDate(d.row['needed_by']) == null ? null : 'Due ${fmtDayMonth(asDate(d.row['needed_by']))}',
                              humanise(asStr(d.row['status'])),
                              asDate(d.row['cleared_at']) == null ? null : 'cleared',
                            ]),
                            style: context.text.bodySmall,
                          ),
                        ]),
                      ),
                      Icon(
                        asDate(d.row['cleared_at']) != null ? Icons.check_circle_outline_rounded : Icons.arrow_forward_rounded,
                        size: 18,
                        color: asDate(d.row['cleared_at']) != null ? DispatchColors.green : context.mutedColor,
                      ),
                      if (canEdit)
                        IconButton(
                          tooltip: 'Remove the dependency on ${asStrOr(d.row['ref'], '')}',
                          icon: const Icon(Icons.link_off_rounded, size: 18),
                          onPressed: () => _removeDependency(d.label, d.row),
                        ),
                    ]),
                  ),
                ),
            ]),
    );
  }

  Widget _planPanel(WorkRow row, Map<String, dynamic> plan) {
    final session = context.watch<Session>();
    final terms = asMap(_item?['priority_terms']);
    final override = asMap(_item?['priority_override']);
    final assignees = (plan['assignees'] as List?)?.whereType<Map>().map((e) => PersonLite.fromJson(Map<String, dynamic>.from(e))).toList() ?? const <PersonLite>[];
    final changes = asIntOr(plan['changes_30d'], 0);
    final entersOn = asDate(plan['enters_committed_on']);

    return Panel(
      title: 'Plan',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        MetaRow(
          'Priority score',
          child: Row(children: [
            PriorityBar(row.priorityScore, width: 90),
            const Spacer(),
            if (terms.isNotEmpty)
              IconButton(
                tooltip: _priorityOpen ? 'Hide the priority breakdown' : 'Show the priority breakdown',
                icon: Icon(_priorityOpen ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20),
                onPressed: () => setState(() => _priorityOpen = !_priorityOpen),
              ),
          ]),
        ),
        if (_priorityOpen && terms.isNotEmpty) _priorityBreakdown(terms),
        if (asBool(override['active']))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.sm),
            child: NoteCard(
              tone: 'info',
              icon: Icons.push_pin_outlined,
              title: 'Priority override in force',
              body: dotJoin([
                override['points'] == null ? null : '${asIntOr(override['points'], 0) > 0 ? '+' : ''}${asIntOr(override['points'], 0)} points',
                override['pinned_score'] == null ? null : 'pinned at ${asDouble(override['pinned_score'])!.round()}',
                asStr(override['reason']),
              ]),
              suggestion: asDate(override['expires']) == null ? null : 'Expires ${fmtShortDate(asDate(override['expires']))}',
            ),
          ),
        MetaRow('Planned window', value: row.plannedFrom == null && row.plannedTo == null ? 'Not scheduled yet' : fmtDateRange(row.plannedFrom, row.plannedTo)),
        MetaRow('Needed by', value: dotJoin([row.neededBy == null ? 'Not set' : fmtShortDate(row.neededBy), asStr(plan['slack_label'])])),
        MetaRow(
          'Earliest start',
          value: row.earliestStart == null ? 'Not set' : 'Not before ${fmtShortDate(row.earliestStart)}',
        ),
        MetaRow('Assigned', child: assignees.isEmpty
            ? Text('No one yet', style: context.text.bodyMedium?.copyWith(color: context.mutedColor))
            : Row(children: [
                AssigneeAvatars(assignees, size: 26),
                const SizedBox(width: Sp.sm),
                Expanded(child: Text(assignees.map((a) => a.firstName).join(', '), style: context.text.bodyMedium, overflow: TextOverflow.ellipsis)),
              ])),
        MetaRow('Stability', child: Row(children: [
          Flexible(child: Text('$changes change${changes == 1 ? '' : 's'} in 30 days', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodyMedium)),
          const SizedBox(width: Sp.sm),
          ToneChip(asStrOr(plan['stability_label'], 'Steady'), tone: asStrOr(plan['stability_label'], 'Steady') == 'Steady' ? 'ok' : 'warn', compact: true),
        ])),
        MetaRow('Freeze', value: entersOn == null ? 'Not in the committed window' : 'Enters committed window ${fmtShortDate(entersOn)}'),
        if (session.isDeliveryLead) ...[
          const SizedBox(height: Sp.sm),
          Row(children: [
            SecondaryButton('Override priority', icon: Icons.tune_rounded, onPressed: _overridePriority),
            if (asBool(override['active'])) ...[
              const SizedBox(width: Sp.sm),
              SecondaryButton('Clear', onPressed: _clearOverride),
            ],
          ]),
        ],
      ]),
    );
  }

  /// Priority breakdown (BEN-04's display).
  ///
  /// Interrupt-driven work scores from its severity alone — `priority.php`
  /// marks the five planned terms "skipped: interrupt policy" and they all read
  /// zero — so an incident shows its severity term and a line saying the
  /// benefit case is bypassed, never five empty bars. `severity` is read
  /// defensively: an older API that does not send it still renders.
  Widget _priorityBreakdown(Map<String, dynamic> terms) {
    const planned = {
      'value': 'Business value',
      'urgency': 'Urgency',
      'risk': 'Risk',
      'leverage': 'Leverage',
      'age': 'Age in the queue',
    };
    final severity = asMap(terms['severity']);
    final marked = planned.keys.any((k) => asStr(asMap(terms[k])['skipped']) != null);
    final allZero = planned.keys.every((k) => (asDouble(asMap(terms[k])['contribution']) ?? 0) == 0);
    final isInterrupt = severity.isNotEmpty || marked || _row.typePolicy == 'interrupt';
    final hidePlanned = isInterrupt && (marked || allZero);
    final severityLabel = 'Severity ${asStrOr(severity['input'], asStrOr(_item?['severity'], ''))}'.trim();
    final shown = <MapEntry<String, String>>[
      if (severity.isNotEmpty) MapEntry('severity', severityLabel),
      if (!hidePlanned) ...planned.entries,
    ];

    final override = asMap(terms['override']);
    final points = asIntOr(override['points'], 0);
    final pinned = asDouble(override['pinned']);
    final hasOverride = points != 0 || pinned != null;

    return Container(
      margin: const EdgeInsets.only(bottom: Sp.sm),
      padding: const EdgeInsets.all(Sp.md),
      decoration: BoxDecoration(color: context.scheme.surfaceContainerHighest, borderRadius: DispatchRadius.cardR),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final e in shown)
          if (terms[e.key] is Map) _priorityTermRow(e.value, asMap(terms[e.key])),
        // The API has not sent a severity term yet: say what drives the score
        // rather than leave the expander empty.
        if (hidePlanned && severity.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              SizedBox(width: 120, child: Text(severityLabel, style: context.text.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis)),
              Expanded(
                child: Text('Scored from severity', style: context.text.bodySmall?.copyWith(color: context.inkColor), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: Sp.sm),
              SizedBox(
                width: 56,
                child: Text(
                  (_row.priorityScore ?? 0).toStringAsFixed(1),
                  textAlign: TextAlign.right,
                  style: DispatchTheme.numeric(size: 12.5),
                ),
              ),
            ]),
          ),
        if (hasOverride)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              SizedBox(width: 120, child: Text('Override', style: context.text.bodySmall)),
              Expanded(
                child: Text(
                  pinned != null ? 'Pinned at ${pinned.round()}' : 'Manual adjustment',
                  style: context.text.bodySmall?.copyWith(color: context.inkColor),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: Sp.sm),
              SizedBox(
                width: 56,
                child: Text(
                  pinned != null ? '—' : '${points > 0 ? '+' : ''}$points',
                  textAlign: TextAlign.right,
                  style: DispatchTheme.numeric(size: 12.5),
                ),
              ),
            ]),
          ),
        const SizedBox(height: Sp.sm),
        Text(
          isInterrupt
              ? 'Interrupt-driven work scores from its severity, so the benefit case — value, urgency, risk, '
                  'leverage and age — is skipped and it enters the queue at the top.'
              : 'Weighted from business value, urgency, risk, leverage and age; the nightly run rescales so the top item sits near 100.',
          style: context.text.bodySmall,
        ),
      ]),
    );
  }

  Widget _priorityTermRow(String label, Map<String, dynamic> term) {
    final contribution = asDouble(term['contribution']) ?? 0;
    final weight = asDouble(term['weight']);
    // contribution = normalised x weight, so the bar reads as a share of what
    // this term could have scored — never a share of a hard-coded 40.
    final fraction = asDouble(term['normalised']) ?? (weight != null && weight > 0 ? contribution / weight : contribution / 40);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(
          width: 120,
          child: Text(label, style: context.text.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        Expanded(child: ProgressBar(fraction.clamp(0, 1), colour: DispatchColors.typeBlue)),
        const SizedBox(width: Sp.sm),
        SizedBox(
          width: 56,
          child: Text(contribution.toStringAsFixed(1), textAlign: TextAlign.right, style: DispatchTheme.numeric(size: 12.5)),
        ),
      ]),
    );
  }

  Widget _romPanel() {
    final est = asMap(_item?['estimate']);
    if (est.isEmpty) {
      return Panel(
        title: 'Rough order of magnitude',
        child: EmptyState(
          icon: Icons.straighten_rounded,
          title: 'No estimate yet',
          message: 'This item cannot be scheduled until it has a rough order of magnitude.',
          compact: true,
          action: PrimaryButton('Estimate this work', onPressed: () => context.go(Routes.estimate(_row.ref))),
        ),
      );
    }
    final o = asDouble(est['optimistic']);
    final m = asDouble(est['likely']);
    final p = asDouble(est['pessimistic']);

    return Panel(
      title: 'Rough order of magnitude',
      trailing: ToneChip('Class ${asIntOr(est['estimate_class'], 3)} · ${classToleranceLabel(asInt(est['estimate_class']))}', compact: true),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(child: _romFigure('Optimistic', o, null)),
          Expanded(child: _romFigure('Most likely', m, DispatchColors.orange, big: true)),
          Expanded(child: _romFigure('Pessimistic', p, null, alignRight: true)),
        ]),
        const SizedBox(height: Sp.md),
        RangeGradientBar(low: o, likely: m, high: p),
        const SizedBox(height: Sp.md),
        Row(children: [
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(text: 'Expected (PERT) ', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
              TextSpan(text: fmtDaysShort(asDouble(est['expected'])), style: DispatchTheme.numeric(size: 14, color: context.inkColor)),
            ])),
          ),
          Text.rich(TextSpan(children: [
            TextSpan(text: 'Blended cost ', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
            TextSpan(text: fmtMoneyK(asDouble(est['cost_likely'])), style: DispatchTheme.numeric(size: 14, color: context.inkColor)),
          ])),
        ]),
        if (asStr(est['assumptions'])?.isNotEmpty ?? false) ...[
          const SizedBox(height: Sp.md),
          Text(asStrOr(est['assumptions'], ''), style: context.text.bodySmall),
        ],
        const SizedBox(height: Sp.md),
        SecondaryButton('Open the estimate', icon: Icons.open_in_new_rounded, onPressed: () => context.go(Routes.estimate(_row.ref))),
      ]),
    );
  }

  Widget _romFigure(String label, double? days, Color? colour, {bool big = false, bool alignRight = false}) {
    return Column(
      crossAxisAlignment: alignRight ? CrossAxisAlignment.end : (big ? CrossAxisAlignment.center : CrossAxisAlignment.start),
      children: [
        Text(label, style: context.text.bodySmall),
        const SizedBox(height: 2),
        Text.rich(TextSpan(children: [
          TextSpan(
            text: days == null ? '—' : (days == days.roundToDouble() ? days.toInt().toString() : days.toStringAsFixed(1)),
            style: DispatchTheme.numeric(size: big ? 28 : 22, weight: FontWeight.w800, color: colour ?? context.inkColor),
          ),
          TextSpan(text: ' days', style: context.text.bodySmall),
        ])),
      ],
    );
  }

  Widget _benefitPanel() {
    final benefits = _list('benefits');
    final total = asIntOr(_item?['benefit_total'], 0);
    final confidence = asStr(_item?['benefit_confidence']);
    final payback = asDouble(_item?['payback_months']);
    final realisedFrom = asDate(_item?['benefit_realised_from']);

    return Panel(
      title: 'Business benefit',
      trailing: confidence == null ? null : ToneChip('${humanise(confidence)} confidence', tone: confidence == 'high' ? 'ok' : (confidence == 'low' ? 'warn' : null), compact: true),
      child: benefits.isEmpty
          ? EmptyState(
              icon: Icons.trending_up_rounded,
              title: 'No benefit case yet',
              message: 'Benefit value feeds the priority score, scaled by its confidence.',
              compact: true,
              action: context.read<Session>().can('benefit_owner') ? PrimaryButton('Add a benefit', onPressed: _addBenefit) : null,
            )
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(child: _figure('Annual value', fmtMoneyK(total))),
                Expanded(child: _figure('Payback', payback == null ? '—' : payback.toStringAsFixed(1), unit: 'months')),
                Expanded(child: _figure('Realised from', realisedFrom == null ? '—' : _quarter(realisedFrom))),
              ]),
              const SizedBox(height: Sp.lg),
              for (final b in benefits)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    Container(width: 10, height: 10, decoration: BoxDecoration(color: DispatchColors.parseHex(asStr(b['type_colour'])), borderRadius: BorderRadius.circular(3))),
                    const SizedBox(width: Sp.sm),
                    Expanded(
                      child: Text(
                        dotJoin([asStr(b['type_label']), asStr(b['narrative'])]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.bodyMedium,
                      ),
                    ),
                    Text(fmtMoneyK(asIntOr(b['annual_value'], 0)), style: DispatchTheme.numeric(size: 13.5)),
                  ]),
                ),
              if (context.read<Session>().can('benefit_owner')) ...[
                const SizedBox(height: Sp.md),
                SecondaryButton('Add a benefit', icon: Icons.add_rounded, onPressed: _addBenefit),
              ],
            ]),
    );
  }

  String _quarter(DateTime d) => 'Q${((d.month - 1) ~/ 3) + 1} ${d.year}';

  Widget _figure(String label, String value, {String? unit}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: context.text.bodySmall),
      const SizedBox(height: 2),
      Text.rich(TextSpan(children: [
        TextSpan(text: value, style: DispatchTheme.numeric(size: 22, weight: FontWeight.w800, color: context.inkColor)),
        if (unit != null) TextSpan(text: ' $unit', style: context.text.bodySmall),
      ])),
    ]);
  }

  Future<void> _addBenefit() async {
    final value = TextEditingController();
    final narrative = TextEditingController();
    var type = 'cost_avoidance';
    var confidence = 'medium';
    DateTime realisationFrom = DateTime.now().add(const Duration(days: 90));
    const types = {
      'cost_avoidance': 'Cost avoidance',
      'productivity': 'Productivity',
      'revenue': 'Revenue',
      'risk_reduction': 'Risk reduction',
      'compliance': 'Compliance',
      'other': 'Other',
    };

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          title: const Text('Add a benefit'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              DropdownButtonFormField<String>(
                initialValue: type,
                decoration: const InputDecoration(labelText: 'Benefit type'),
                items: [for (final e in types.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: (v) => setLocal(() => type = v ?? 'other'),
              ),
              const SizedBox(height: Sp.md),
              TextField(controller: value, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Annual value, £')),
              const SizedBox(height: Sp.md),
              DropdownButtonFormField<String>(
                initialValue: confidence,
                decoration: const InputDecoration(labelText: 'Confidence'),
                items: const [
                  DropdownMenuItem(value: 'low', child: Text('Low')),
                  DropdownMenuItem(value: 'medium', child: Text('Medium')),
                  DropdownMenuItem(value: 'high', child: Text('High')),
                ],
                onChanged: (v) => setLocal(() => confidence = v ?? 'medium'),
              ),
              const SizedBox(height: Sp.md),
              TextField(controller: narrative, decoration: const InputDecoration(labelText: 'What changes (optional)')),
              const SizedBox(height: Sp.md),
              OutlinedButton.icon(
                icon: const Icon(Icons.event_rounded, size: 18),
                label: Align(alignment: Alignment.centerLeft, child: Text('Realised from ${fmtDate(realisationFrom)}')),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: dialogContext,
                    initialDate: realisationFrom,
                    firstDate: DateTime(DateTime.now().year - 1),
                    lastDate: DateTime(DateTime.now().year + 5),
                  );
                  if (picked != null) setLocal(() => realisationFrom = picked);
                },
              ),
            ]),
          ),
          actions: [
            SecondaryButton('Cancel', onPressed: () => Navigator.of(dialogContext).pop(false)),
            PrimaryButton('Save benefit', onPressed: () => Navigator.of(dialogContext).pop(true)),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await Api.post('benefits.php', 'save', {
        'work_item_id': _row.id,
        'type': type,
        'annual_value': double.tryParse(value.text.trim().replaceAll(',', '')) ?? 0,
        'confidence': confidence,
        'realisation_from': _iso(realisationFrom),
        if (narrative.text.trim().isNotEmpty) 'narrative': narrative.text.trim(),
      });
      _snack('Benefit saved.');
      await _load();
    } on ApiException catch (e) {
      _snack(e.message);
    }
  }

  // ─── Other tabs ─────────────────────────────────────────────────────────

  Widget _requirementsTab(Map<String, dynamic> item) {
    final text = asStr(item['requirements_text']);
    final readiness = asMap(item['readiness']);
    final checks = _list('items', readiness);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        title: 'Requirements',
        child: text == null || text.trim().isEmpty
            ? const EmptyState(
                icon: Icons.description_outlined,
                title: 'No requirements written yet',
                message: 'Acceptance criteria, links and constraints belong here. A template per work type can pre-populate it.',
                compact: true,
              )
            : Text(text, style: context.text.bodyLarge),
      ),
      const SizedBox(height: Sp.lg),
      Panel(
        title: 'Readiness',
        subtitle: asBool(readiness['ready']) ? 'Complete — this item can be Ready' : 'Complete every item before this work can be Ready',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final c in checks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Icon(
                  asBool(c['done']) ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                  size: 18,
                  color: asBool(c['done']) ? DispatchColors.green : context.mutedColor,
                ),
                const SizedBox(width: Sp.sm),
                Expanded(child: Text(asStrOr(c['label'], ''), style: context.text.bodyMedium)),
                Text(asBool(c['done']) ? 'Done' : 'Outstanding', style: context.text.bodySmall),
              ]),
            ),
        ]),
      ),
    ]);
  }

  Widget _estimateTab(Map<String, dynamic> item) {
    final est = asMap(item['estimate']);
    return Panel(
      title: 'Estimate',
      subtitle: est.isEmpty ? null : 'Version ${asIntOr(est['version'], 1)} · ${asStrOr(est['method'], '')} · ${asStrOr(est['author_name'], 'unknown author')}',
      trailing: SecondaryButton('Open the estimate screen', icon: Icons.open_in_new_rounded, onPressed: () => context.go(Routes.estimate(_row.ref))),
      child: est.isEmpty
          ? const EmptyState(
              icon: Icons.straighten_rounded,
              title: 'No estimate yet',
              message: 'Estimate by size class, three-point or task roll-up on the estimate screen.',
              compact: true,
            )
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: _figure('Optimistic', fmtDaysShort(asDouble(est['optimistic'])))),
                Expanded(child: _figure('Most likely', fmtDaysShort(asDouble(est['likely'])))),
                Expanded(child: _figure('Pessimistic', fmtDaysShort(asDouble(est['pessimistic'])))),
              ]),
              const SizedBox(height: Sp.lg),
              Row(children: [
                Expanded(child: _figure('Expected (PERT)', fmtDaysShort(asDouble(est['expected'])))),
                Expanded(child: _figure('P80', fmtDaysShort(asDouble(est['p80'])))),
                Expanded(child: _figure('Cost at most likely', fmtMoneyK(asDouble(est['cost_likely'])))),
              ]),
              if (asStr(est['assumptions'])?.isNotEmpty ?? false) ...[
                const SizedBox(height: Sp.lg),
                Text('Assumptions and exclusions', style: context.text.titleSmall),
                const SizedBox(height: Sp.xs),
                Text(asStrOr(est['assumptions'], ''), style: context.text.bodyMedium),
              ],
            ]),
    );
  }

  Widget _benefitsTab(Map<String, dynamic> item) => _benefitPanel();

  Widget _tasksTab(List<Map<String, dynamic>> tasks, Map<String, dynamic> item) {
    final session = context.watch<Session>();
    return Panel(
      title: 'Tasks',
      subtitle: tasks.isEmpty ? null : 'Roll-up ${fmtDaysShort(asDouble(item['tasks_rollup_days']))}',
      trailing: session.isTeamLead && tasks.isNotEmpty
          ? SecondaryButton('Roll up to an estimate', icon: Icons.functions_rounded, onPressed: () async {
              try {
                await Api.post('work_items.php', 'rollup_tasks', {'id': _row.id});
                _snack('Estimate created from the task roll-up.');
                await _load();
              } on ApiException catch (e) {
                _snack(e.message);
              }
            })
          : null,
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (tasks.isEmpty)
          const Padding(
            padding: EdgeInsets.all(Sp.xl),
            child: EmptyState(
              icon: Icons.checklist_rounded,
              title: 'No tasks yet',
              message: 'Split the work into tasks when you want to roll the effort up from the parts.',
              compact: true,
            ),
          )
        else
          for (final t in tasks)
            Container(
              padding: const EdgeInsets.all(Sp.md),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.borderColor))),
              child: Row(children: [
                SizedBox(width: 28, child: Text('${asIntOr(t['sequence'], 0)}', style: DispatchTheme.numeric(size: 12.5, color: context.mutedColor))),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(asStrOr(t['title'], ''), style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    Text(dotJoin([asStr(t['skill_name']), fmtDaysShort(asDouble(t['effort_days']))]), style: context.text.bodySmall),
                  ]),
                ),
                StatusChip(asStr(t['status']), compact: true),
                if (session.can('team_member'))
                  IconButton(
                    tooltip: 'Delete this task',
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    onPressed: () async {
                      try {
                        await Api.post('work_items.php', 'delete_task', {'task_id': asIntOr(t['id'], 0)});
                        await _load();
                      } on ApiException catch (e) {
                        _snack(e.message);
                      }
                    },
                  ),
              ]),
            ),
        if (session.can('team_member'))
          Padding(
            padding: const EdgeInsets.all(Sp.md),
            child: Align(alignment: Alignment.centerLeft, child: SecondaryButton('Add a task', icon: Icons.add_rounded, onPressed: _addTask)),
          ),
      ]),
    );
  }

  Future<void> _addTask() async {
    final title = TextEditingController();
    final days = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add a task'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, decoration: const InputDecoration(labelText: 'Task')),
            const SizedBox(height: Sp.md),
            TextField(controller: days, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Effort in days')),
          ]),
        ),
        actions: [
          SecondaryButton('Cancel', onPressed: () => Navigator.of(dialogContext).pop(false)),
          PrimaryButton('Add task', onPressed: () => Navigator.of(dialogContext).pop(true)),
        ],
      ),
    );
    if (ok != true || title.text.trim().isEmpty) return;
    try {
      await Api.post('work_items.php', 'add_task', {
        'id': _row.id,
        'title': title.text.trim(),
        if (double.tryParse(days.text.trim()) != null) 'effort_days': double.parse(days.text.trim()),
      });
      await _load();
    } on ApiException catch (e) {
      _snack(e.message);
    }
  }

  Widget _scheduleTab(Map<String, dynamic> item) {
    final assignments = _list('assignments');
    return Panel(
      title: 'Schedule',
      subtitle: 'Committed plan',
      trailing: SecondaryButton('Adjust schedule', icon: Icons.calendar_month_rounded, onPressed: () => context.go(Routes.schedule)),
      padding: EdgeInsets.zero,
      child: assignments.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(Sp.xl),
              child: EmptyState(
                icon: Icons.event_note_outlined,
                title: 'Not on the committed plan',
                message: 'This work is scheduled at the next replan, once it is Ready.',
                compact: true,
              ),
            )
          : Column(children: [
              for (final a in assignments)
                Container(
                  padding: const EdgeInsets.all(Sp.md),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.borderColor))),
                  child: Row(children: [
                    PersonAvatar(asStrOr(a['initials'], initialsOf(asStr(a['person_name']))), colourHex: asStr(a['colour']), size: 28),
                    const SizedBox(width: Sp.md),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(asStrOr(a['person_name'], ''), style: context.text.titleSmall),
                        Text(
                          dotJoin([
                            fmtDateRange(asDate(a['from_date']), asDate(a['to_date'])),
                            '${asIntOr(a['allocation_pct'], 100)}% of the day',
                            asStr(a['role_label']),
                          ]),
                          style: context.text.bodySmall,
                        ),
                      ]),
                    ),
                    if (asBool(a['locked'])) const ToneChip('Locked', icon: Icons.lock_outline_rounded, compact: true),
                    StatusChip(asStr(a['state']), compact: true),
                  ]),
                ),
            ]),
    );
  }

  Widget _discussionTab(List<Map<String, dynamic>> comments) {
    return Panel(
      title: 'Discussion',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (comments.isEmpty)
          const EmptyState(
            icon: Icons.forum_outlined,
            title: 'No comments yet',
            message: 'Mention a colleague with @ to notify them.',
            compact: true,
          )
        else
          for (final c in comments)
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.lg),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                PersonAvatar(initialsOf(asStr(c['author_name'])), seed: asStr(c['author_name']), size: 30),
                const SizedBox(width: Sp.md),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(dotJoin([asStr(c['author_name']), _stamp(asDate(c['created_at']))]), style: context.text.bodySmall),
                    const SizedBox(height: 2),
                    Text(asStrOr(c['body'], ''), style: context.text.bodyMedium),
                  ]),
                ),
              ]),
            ),
        const SizedBox(height: Sp.sm),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: TextField(
              controller: _comment,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(hintText: 'Add a comment. Use @ to mention someone.'),
            ),
          ),
          const SizedBox(width: Sp.md),
          PrimaryButton('Comment', onPressed: () async {
            final body = _comment.text.trim();
            if (body.isEmpty) return;
            try {
              await Api.post('work_items.php', 'add_comment', {'id': _row.id, 'body': body});
              _comment.clear();
              await _load();
            } on ApiException catch (e) {
              _snack(e.message);
            }
          }),
        ]),
      ]),
    );
  }
}

/// Labelled date control used by the Edit dialog for needed-by and
/// earliest-start (PIP-01). The button carries only the date, so two sit side
/// by side without either label wrapping.
class _DateField extends StatelessWidget {
  const _DateField({required this.label, required this.value, required this.onPick, required this.helpText});

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onPick;
  final String helpText;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: context.text.labelMedium?.copyWith(color: context.mutedColor)),
      const SizedBox(height: Sp.xs),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.calendar_today_rounded, size: 18),
            label: Align(
              alignment: Alignment.centerLeft,
              child: Text(value == null ? 'Not set' : fmtDate(value), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            onPressed: () async {
              final now = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: value ?? now,
                firstDate: DateTime(now.year - 2),
                lastDate: DateTime(now.year + 3),
                helpText: helpText,
              );
              if (picked != null) onPick(picked);
            },
          ),
        ),
        if (value != null)
          IconButton(
            tooltip: 'Clear the ${label.toLowerCase()} date',
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: () => onPick(null),
          ),
      ]),
    ]);
  }
}

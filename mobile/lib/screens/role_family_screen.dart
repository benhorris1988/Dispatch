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
import '../widgets/pf_metrics.dart';
import '../widgets/team_widgets.dart';
import '../widgets/tm_loan_list.dart';
import '../widgets/widgets.dart';

/// Role family view (ORG-02, TEAM-09): one discipline's people, grouped by the
/// team each of them sits in, with the same six figures per row and the family
/// beneath — not summed, so the single-skill count can be lower than any one
/// computed the same way as a row. Reads `role_families.php overview`;
/// admin can rename it and move teams in and out.
class RoleFamilyScreen extends StatefulWidget {
  const RoleFamilyScreen({super.key, required this.id});
  final String id;

  static String route(Object id) => '/role-families/$id';

  @override
  State<RoleFamilyScreen> createState() => _RoleFamilyScreenState();
}

class _RoleFamilyScreenState extends State<RoleFamilyScreen> {
  bool _loading = true;
  String? _error;
  _Overview? _data;

  int get _roleFamilyId => int.tryParse(widget.id) ?? 0;

  ShellState? _shell;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant RoleFamilyScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _shell = context.read<ShellState>();
  }

  @override
  void dispose() {
    final shell = _shell;
    if (shell != null) WidgetsBinding.instance.addPostFrameCallback((_) => shell.setPageTitle(null));
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await Api.post('role_families.php', 'overview', {'role_family_id': _roleFamilyId});
      final d = _Overview.fromJson(r);
      if (!mounted) return;
      setState(() {
        _data = d;
        _loading = false;
      });
      final shell = context.read<ShellState>();
      WidgetsBinding.instance.addPostFrameCallback((_) => shell.setPageTitle(d.name, breadcrumb: const ['Team & skills']));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  // ─── Admin actions ────────────────────────────────────────────────────

  Future<void> _rename() async {
    final d = _data;
    if (d == null) return;
    final saved = await showDialog<bool>(context: context, builder: (context) => _RenameDialog(overview: d));
    if (saved == true) await _load();
  }

  // ─── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final policy = context.watch<WorkspaceConfig>().policy;
    final d = _data;

    final actions = <Widget>[
      SecondaryButton('Team & skills', icon: Icons.people_alt_outlined, onPressed: () => context.go(Routes.team)),
      SecondaryButton('Organisation', icon: Icons.account_tree_outlined, onPressed: () => context.go(Routes.org)),
      if (session.isAdmin && d != null) SecondaryButton('Rename', icon: Icons.edit_outlined, onPressed: _rename),
    ];

    return PageBody(
      onRefresh: _load,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Breadcrumb(name: d?.name),
        const SizedBox(height: Sp.md),
        PageHeader(
          title: d?.name ?? 'Role family',
          subtitle: d == null
              ? 'One discipline, across the teams it sits in'
              : dotJoin([
                  d.description,
                  if (d.leadName != null) 'Lead ${d.leadName}',
                  '${d.totals.headcount} ${d.totals.headcount == 1 ? 'person' : 'people'}',
                  'across ${d.teams.length} ${d.teams.length == 1 ? 'team' : 'teams'}',
                  if (d.windowFrom != null && d.windowTo != null) 'Next four weeks from ${fmtDayMonth(d.windowFrom)}',
                ]),
          actions: actions,
        ),
        const SizedBox(height: Sp.xl),
        if (_loading)
          const _Skeleton()
        else if (_error != null)
          ErrorState(title: 'We could not load this role family', message: _error, onRetry: _load)
        else if (d == null)
          const EmptyState(icon: Icons.badge_outlined, title: 'Role family not found', message: 'It may have been deleted.')
        else ...[
          if (d.teams.isEmpty)
            const Panel(
              child: EmptyState(
                icon: Icons.groups_outlined,
                title: 'Nobody in this role family yet',
                message: 'Set somebody\u2019s role family on the Team & skills page, and they will appear here beside everyone else who does the same job.',
                compact: true,
              ),
            )
          else
            LayoutBuilder(builder: (context, c) {
              // Side by side where there is room; stacked on a phone.
              final cols = c.maxWidth >= 1000 ? d.teams.length.clamp(1, 3) : (c.maxWidth >= 640 ? d.teams.length.clamp(1, 2) : 1);
              final w = cols == 1 ? c.maxWidth : (c.maxWidth - Sp.lg * (cols - 1)) / cols;
              return Wrap(spacing: Sp.lg, runSpacing: Sp.lg, children: [
                for (final t in d.teams)
                  SizedBox(
                    width: w,
                    child: _TeamCard(
                      team: t,
                      overview: d,
                      policy: policy,
                      onRemove: null,
                    ),
                  ),
              ]);
            }),
          const SizedBox(height: Sp.xl),
          TmMetricTitle(
            title: 'The role family as one group',
            subtitle: 'Computed the same way as a row, not summed',
            definition: '${d.definitionFor('load', PfMetrics.load(targetMin: d.targetLoadMin, targetMax: d.targetLoadMax))}\n\n'
                '${d.definitionFor('single_skill_deps', PfMetrics.singleSkillDeps)}\n\n'
                '${d.definitionFor('stability_index', PfMetrics.stabilityIndex)}\n\n'
                '${d.definitionFor('open_proposals', PfMetrics.openProposals)}',
          ),
          const SizedBox(height: Sp.md),
          _TotalsRow(figures: d.totals, overview: d),
          const SizedBox(height: Sp.xl),
          TmMetricPanel(
            title: 'Loans between teams',
            subtitle: d.loans.isEmpty ? null : '${d.loans.length} touching the planned window',
            definition: PfMetrics.loans,
            child: d.loans.isEmpty
                ? const EmptyState(
                    icon: Icons.swap_horiz_rounded,
                    title: 'No loans',
                    message: 'Nobody in this role family is on loan in the planned window.',
                    compact: true,
                  )
                : TmLoanList(loans: d.loans, today: d.windowFrom ?? DateTime.now()),
          ),
        ],
      ]),
    );
  }
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({this.name});
  final String? name;

  @override
  Widget build(BuildContext context) {
    final muted = context.text.bodySmall?.copyWith(color: context.mutedColor);
    return Row(children: [
      InkWell(
        onTap: () => context.go(Routes.team),
        borderRadius: BorderRadius.circular(4),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2), child: Text('Team & skills', style: muted?.copyWith(color: DispatchColors.typeBlue))),
      ),
      Text('  ›  ', style: muted),
      Flexible(child: Text(name ?? 'Role family', style: muted, overflow: TextOverflow.ellipsis)),
    ]);
  }
}

// ─── Team card ──────────────────────────────────────────────────────────

class _TeamCard extends StatelessWidget {
  const _TeamCard({required this.team, required this.overview, required this.policy, this.onRemove});
  final _TeamFigures team;
  final _Overview overview;
  final Policy policy;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final t = team;
    final targetMax = overview.targetLoadMax;
    final targetMin = overview.targetLoadMin;
    final loadTone = t.loadPct > 100
        ? StatTone.bad
        : t.loadPct > targetMax
            ? StatTone.warn
            : t.loadPct < targetMin
                ? StatTone.neutral
                : StatTone.good;
    final borrowed = overview.loans.where((l) => l.toTeamId == t.id).map((l) => l.personName).whereType<String>().toSet().toList();
    final lent = overview.loans.where((l) => l.fromTeamId == t.id).map((l) => l.personName).whereType<String>().toSet().toList();

    final figures = <_Figure>[
      _Figure(
        label: 'Headcount',
        value: '${t.headcount}',
        note: t.poolSize != t.headcount ? 'pool of ${t.poolSize} with loans' : 'nobody loaned in',
        definition: PfMetrics.headcount,
      ),
      _Figure(
        label: 'Loaned in · out',
        value: '${t.loanedIn} · ${t.loanedOut}',
        note: dotJoin([
          if (borrowed.isNotEmpty) 'in: ${borrowed.join(', ')}',
          if (lent.isNotEmpty) 'out: ${lent.join(', ')}',
        ]).ifEmpty('no loans in the window'),
        definition: PfMetrics.loans,
        tone: t.loanedOut > 0 ? StatTone.warn : StatTone.neutral,
      ),
      _Figure(
        label: 'Load, next 4 weeks',
        value: '${t.loadPct.round()}%',
        note: 'target $targetMin–$targetMax% · ${fmtHours(t.assignedHours)} of ${fmtHours(t.availableHours)}',
        definition: overview.definitionFor('load', PfMetrics.load(targetMin: targetMin, targetMax: targetMax)),
        tone: loadTone,
      ),
      _Figure(
        label: 'Single-skill dependencies',
        value: '${t.singleSkillDeps}',
        note: t.singleSkillNames.isEmpty ? 'every needed skill has cover' : t.singleSkillNames.join(', '),
        definition: overview.definitionFor('single_skill_deps', PfMetrics.singleSkillDeps),
        tone: t.singleSkillDeps == 0 ? StatTone.good : StatTone.bad,
      ),
      _Figure(
        label: 'Stability index',
        value: t.stabilityIndex == null ? '—' : '${t.stabilityIndex!.round()}%',
        note: t.totalDays4w == 0 ? 'nothing planned to move' : '${fmtDays(t.movedDays4w)} moved of ${fmtDays(t.totalDays4w)}',
        definition: overview.definitionFor('stability_index', PfMetrics.stabilityIndex),
        tone: (t.stabilityIndex ?? 100) < 80 ? StatTone.warn : StatTone.good,
      ),
      _Figure(
        label: 'Open proposals',
        value: '${t.openProposals}',
        note: t.openProposals == 0 ? 'nothing waiting for review' : 'pending changes naming this team',
        definition: overview.definitionFor('open_proposals', PfMetrics.openProposals),
        tone: t.openProposals > 0 ? StatTone.accent : StatTone.neutral,
      ),
    ];

    return Panel(
      padding: const EdgeInsets.fromLTRB(Sp.lg, Sp.sm, Sp.lg, Sp.lg),
      title: t.name,
      subtitle: dotJoin([
        if (t.path != null && t.path != t.name) t.path,
        '${t.headcount} ${t.headcount == 1 ? 'person' : 'people'} in this family',
      ]),
      trailing: null,
      child: LayoutBuilder(builder: (context, c) {
        final two = c.maxWidth >= 300;
        final w = two ? (c.maxWidth - Sp.md) / 2 : c.maxWidth;
        return Wrap(spacing: Sp.md, runSpacing: Sp.md, children: [
          for (final f in figures) SizedBox(width: w, child: _FigureTile(figure: f)),
        ]);
      }),
    );
  }
}

class _Figure {
  const _Figure({required this.label, required this.value, this.note, this.definition, this.tone = StatTone.neutral});
  final String label;
  final String value;
  final String? note;
  final String? definition;
  final StatTone tone;
}

/// A small figure inside a team card. Tapping it opens the definition, the
/// way the Person screen's tiles do.
class _FigureTile extends StatelessWidget {
  const _FigureTile({required this.figure});
  final _Figure figure;

  @override
  Widget build(BuildContext context) {
    final f = figure;
    final toneColour = statToneColor(context, f.tone);
    return InkWell(
      onTap: f.definition == null ? null : () => showTmInfoDialog(context, f.label, f.definition!),
      borderRadius: DispatchRadius.cardR,
      child: Container(
        padding: const EdgeInsets.all(Sp.md),
        decoration: BoxDecoration(
          color: context.isDark ? DispatchColors.darkBg.withValues(alpha: 0.5) : DispatchColors.surfaceAlt.withValues(alpha: 0.6),
          borderRadius: DispatchRadius.cardR,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(f.label, style: context.text.labelMedium?.copyWith(color: context.mutedColor), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text(f.value, style: DispatchTheme.numeric(size: 24, weight: FontWeight.w800, color: f.tone == StatTone.neutral ? context.inkColor : toneColour, height: 1.1),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          if (f.note != null && f.note!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(f.note!, style: context.text.bodySmall?.copyWith(color: context.mutedColor), maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ]),
      ),
    );
  }
}

// ─── Totals ─────────────────────────────────────────────────────────────

class _TotalsRow extends StatelessWidget {
  const _TotalsRow({required this.figures, required this.overview});
  final _Figures figures;
  final _Overview overview;

  @override
  Widget build(BuildContext context) {
    final f = figures;
    final over = f.loadPct > overview.targetLoadMax;
    return StatRow(minTileWidth: 200, tiles: [
      StatTile(label: 'Headcount', value: '${f.headcount}', unit: f.poolSize != f.headcount ? 'pool ${f.poolSize}' : null, footnote: 'across ${overview.teams.length} teams', footnoteIcon: Icons.groups_outlined),
      StatTile(
        label: 'Loaned in · out',
        value: '${f.loanedIn} · ${f.loanedOut}',
        footnote: 'loans between its own teams count as neither',
        footnoteIcon: Icons.swap_horiz_rounded,
      ),
      StatTile(
        label: 'Load, next 4 weeks',
        value: '${f.loadPct.round()}%',
        unit: 'target ${overview.targetLoadMin}–${overview.targetLoadMax}%',
        footnote: '${fmtHours(f.assignedHours)} of ${fmtHours(f.availableHours)}',
        tone: over ? StatTone.warn : StatTone.good,
        footnoteIcon: over ? Icons.warning_amber_rounded : Icons.check_rounded,
      ),
      StatTile(
        label: 'Single-skill dependencies',
        value: '${f.singleSkillDeps}',
        footnote: f.singleSkillNames.isEmpty ? 'every needed skill has cover' : f.singleSkillNames.join(', '),
        tone: f.singleSkillDeps == 0 ? StatTone.good : StatTone.bad,
        footnoteIcon: f.singleSkillDeps == 0 ? Icons.check_rounded : Icons.warning_amber_rounded,
      ),
      StatTile(
        label: 'Stability index',
        value: f.stabilityIndex == null ? '—' : '${f.stabilityIndex!.round()}%',
        footnote: '${fmtDays(f.movedDays4w)} moved of ${fmtDays(f.totalDays4w)}',
        tone: (f.stabilityIndex ?? 100) < 80 ? StatTone.warn : StatTone.good,
        footnoteIcon: Icons.timeline_outlined,
      ),
      StatTile(
        label: 'Open proposals',
        value: '${f.openProposals}',
        footnote: f.openProposals == 0 ? 'nothing waiting for review' : 'pending changes naming these teams',
        tone: f.openProposals > 0 ? StatTone.accent : StatTone.neutral,
        footnoteIcon: Icons.swap_calls_rounded,
      ),
    ]);
  }
}

// ─── Rename dialog ──────────────────────────────────────────────────────

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.overview});
  final _Overview overview;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.overview.name);
  late final TextEditingController _description = TextEditingController(text: widget.overview.description ?? '');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.post('role_families.php', 'save', {
        'id': widget.overview.id,
        'name': _name.text.trim(),
        'description': _description.text.trim(),
        if (widget.overview.leadPersonId != null) 'lead_person_id': widget.overview.leadPersonId,
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message; // 409 on a duplicate name, as the server words it
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename role family'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TmField(label: 'Name', child: TextField(controller: _name, autofocus: true, onChanged: (_) => setState(() {}))),
          const SizedBox(height: Sp.md),
          TmField(label: 'Description', child: TextField(controller: _description, maxLines: 3)),
          if (_error != null) TmInlineError(_error!),
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        PrimaryButton('Save', busy: _busy, onPressed: _name.text.trim().isEmpty ? null : _save),
      ],
    );
  }
}

// ─── Skeleton ───────────────────────────────────────────────────────────

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final two = c.maxWidth >= 640;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (two)
          const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: SkeletonPanel(rows: 6)),
            SizedBox(width: Sp.lg),
            Expanded(child: SkeletonPanel(rows: 6)),
          ])
        else
          const SkeletonPanel(rows: 6),
        const SizedBox(height: Sp.xl),
        const SkeletonPanel(rows: 2),
      ]);
    });
  }
}

// ─── Parsing (role_families.php overview) ───────────────────────────────

String fmtHours(num? h) => h == null ? '—' : '${h % 1 == 0 ? h.toInt() : h.toStringAsFixed(1)}h';

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// The six figures the API computes for a set of teams.
class _Figures {
  const _Figures({
    this.headcount = 0,
    this.poolSize = 0,
    this.loanedIn = 0,
    this.loanedOut = 0,
    this.availableHours = 0,
    this.assignedHours = 0,
    this.loadPct = 0,
    this.singleSkillDeps = 0,
    this.singleSkillNames = const [],
    this.stabilityIndex,
    this.movedDays4w = 0,
    this.totalDays4w = 0,
    this.openProposals = 0,
  });
  final int headcount;
  final int poolSize;
  final int loanedIn;
  final int loanedOut;
  final double availableHours;
  final double assignedHours;
  final double loadPct;
  final int singleSkillDeps;
  final List<String> singleSkillNames;
  final double? stabilityIndex;
  final double movedDays4w;
  final double totalDays4w;
  final int openProposals;

  factory _Figures.fromJson(Map<String, dynamic> j) => _Figures(
        headcount: asIntOr(j['headcount'], 0),
        poolSize: asIntOr(j['pool_size'], asIntOr(j['headcount'], 0)),
        loanedIn: asIntOr(j['loaned_in'], 0),
        loanedOut: asIntOr(j['loaned_out'], 0),
        availableHours: asDoubleOr(j['available_hours'], 0),
        assignedHours: asDoubleOr(j['assigned_hours'], 0),
        loadPct: asDoubleOr(j['load_pct'], 0),
        singleSkillDeps: asIntOr(j['single_skill_deps'], 0),
        singleSkillNames: asStrList(j['single_skill_names']),
        stabilityIndex: asDouble(j['stability_index']),
        movedDays4w: asDoubleOr(j['moved_days_4w'], 0),
        totalDays4w: asDoubleOr(j['total_days_4w'], 0),
        openProposals: asIntOr(j['open_proposals'], 0),
      );
}

class _TeamFigures extends _Figures {
  const _TeamFigures({
    required this.id,
    required this.name,
    this.leadName,
    this.path,
    super.headcount,
    super.poolSize,
    super.loanedIn,
    super.loanedOut,
    super.availableHours,
    super.assignedHours,
    super.loadPct,
    super.singleSkillDeps,
    super.singleSkillNames,
    super.stabilityIndex,
    super.movedDays4w,
    super.totalDays4w,
    super.openProposals,
  });
  final int id;
  final String name;
  final String? leadName;
  /// Where the team sits in the tree, so a row reads 'Digital & Data > Data Platform'.
  final String? path;

  factory _TeamFigures.fromJson(Map<String, dynamic> j) {
    final f = _Figures.fromJson(j);
    return _TeamFigures(
      id: asIntOr(j['id'], 0),
      name: asStrOr(j['name'], 'No team'),
      leadName: asStr(asMap(j['lead'])['name']),
      path: asStr(j['path']),
      headcount: f.headcount,
      poolSize: f.poolSize,
      loanedIn: f.loanedIn,
      loanedOut: f.loanedOut,
      availableHours: f.availableHours,
      assignedHours: f.assignedHours,
      loadPct: f.loadPct,
      singleSkillDeps: f.singleSkillDeps,
      singleSkillNames: f.singleSkillNames,
      stabilityIndex: f.stabilityIndex,
      movedDays4w: f.movedDays4w,
      totalDays4w: f.totalDays4w,
      openProposals: f.openProposals,
    );
  }
}

class _Overview {
  const _Overview({
    required this.id,
    required this.name,
    this.description,
    this.leadName,
    this.leadPersonId,
    required this.teams,
    required this.totals,
    required this.loans,
    this.windowFrom,
    this.windowTo,
    this.targetLoadMin = 80,
    this.targetLoadMax = 90,
    this.definitions = const {},
  });
  final int id;
  final String name;
  final String? description;
  final String? leadName;
  final int? leadPersonId;
  final List<_TeamFigures> teams;
  final _Figures totals;
  final List<Loan> loans;
  final DateTime? windowFrom;
  final DateTime? windowTo;
  final int targetLoadMin;
  final int targetLoadMax;
  final Map<String, dynamic> definitions;

  /// The server's wording for a figure when it sends one, else the client's.
  String definitionFor(String key, String fallback) {
    final s = asStr(definitions[key]);
    return s == null || s.isEmpty ? fallback : s;
  }

  factory _Overview.fromJson(Map<String, dynamic> j) {
    final p = asMap(j['role_family']);
    final w = asMap(j['window']);
    return _Overview(
      id: asIntOr(p['id'], 0),
      name: asStrOr(p['name'], 'Role family'),
      description: asStr(p['description']),
      leadName: asStr(p['lead_name']),
      leadPersonId: asInt(p['lead_person_id']),
      teams: asList(j['teams'], _TeamFigures.fromJson),
      totals: _Figures.fromJson(asMap(j['totals'])),
      loans: asList(j['loans'], Loan.fromJson),
      windowFrom: asDate(w['from']),
      windowTo: asDate(w['to']),
      targetLoadMin: asIntOr(j['target_load_min'], 80),
      targetLoadMax: asIntOr(j['target_load_max'], 90),
      definitions: asMap(j['definitions']),
    );
  }
}

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
import '../widgets/adm_metrics.dart';
import '../widgets/pf_metrics.dart';
import '../widgets/team_widgets.dart';
import '../widgets/tm_loan_chip.dart';
import '../widgets/tm_loan_list.dart';
import '../widgets/tm_scope_picker.dart';
import '../widgets/widgets.dart';
import 'parts/adm_rota_panel.dart';
import 'parts/tm_loan_dialog.dart';
import 'role_family_screen.dart';

/// Team & skills (TEAM-01, TEAM-04, spec 9.4.6).
///
/// Four views over `skills.php matrix` and `people.php list`: the proficiency
/// matrix with its coverage footer, the people cards, the skills catalogue and
/// availability by week.
///
/// TEAM-09: a scope selector at the top narrows both calls to one team or one
/// portfolio's teams. A scoped view is that scope's *planning pool* — its home
/// members plus anyone loaned in for the horizon — so a borrowed person shows
/// on the row with where they came from, and a home member lent elsewhere with
/// where they went. Team leads can add and end loans from the People tab.
class TeamSkillsScreen extends StatefulWidget {
  const TeamSkillsScreen({super.key});

  @override
  State<TeamSkillsScreen> createState() => _TeamSkillsScreenState();
}

class _TeamSkillsScreenState extends State<TeamSkillsScreen> {
  static const _tabs = ['Matrix', 'People', 'Skills', 'Availability'];

  int _tab = 0;
  bool _loading = true;
  String? _error;

  _Matrix? _matrix;
  List<Person> _people = const [];
  List<_Team> _teams = const [];

  /// TEAM-09 scope: the whole workspace, a portfolio or a team.
  PlanScope _scope = const PlanScope.workspace();
  PlanScopeOptions _scopeOptions = PlanScopeOptions.empty;
  bool _scopeOptionsLoaded = false;

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
      if (!_scopeOptionsLoaded) {
        // The picker's portfolios and teams. A failure here leaves the picker
        // on the workspace rather than failing the screen.
        try {
          _scopeOptions = await PlanScopeOptions.load();
        } on ApiException {
          _scopeOptions = PlanScopeOptions.empty;
        }
        _scopeOptionsLoaded = true;
      }
      final results = await Future.wait([
        Api.post('skills.php', 'matrix', {..._scope.params}),
        // ADM-03: deactivated people are shown distinctly rather than hidden, so
        // a lead can see who has left and that their work still needs moving.
        Api.post('people.php', 'list', {'include_inactive': true, ..._scope.params}),
      ]);
      final m = _Matrix.fromJson(results[0]);
      final people = asList(results[1]['people'], Person.fromJson);
      final teams = asList(results[1]['teams'], _Team.fromJson);
      final rota = <int, List<DateTime>>{};
      for (final raw in (results[1]['people'] as List? ?? const [])) {
        if (raw is Map) {
          final id = asIntOr(raw['id'], 0);
          rota[id] = (raw['on_rota_weeks'] as List? ?? const []).map((e) => asDate(e)).whereType<DateTime>().toList();
        }
      }
      // The demo clock can differ from the browser's (config `fake_today`), so
      // the rota weeks are anchored on the window the API reports.
      final serverToday = asDate(asMap(results[1]['window'])['from']);
      if (!mounted) return;
      setState(() {
        _matrix = m;
        _people = people;
        _teams = teams;
        _rota = rota;
        _today = serverToday ?? DateTime.now();
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

  Map<int, List<DateTime>> _rota = const {};
  DateTime _today = DateTime.now();

  bool _canEditSkill(Session s, int personId) => s.isTeamLead || s.user?.personId == personId;

  // ─── Actions ────────────────────────────────────────────────────────────

  Future<void> _pickLevel(_Matrix m, _MatrixPerson p, _SkillRow skill) async {
    final current = m.cell(p.id, skill.id)?.proficiency ?? 0;
    final level = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('${p.name} · ${skill.name}'),
        children: [
          for (var i = 0; i <= 4; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(i),
              child: Row(children: [
                ProficiencySquare(i, size: 22),
                const SizedBox(width: Sp.md),
                Expanded(child: Text('$i · ${kProficiencyLabels[i]}', style: context.text.bodyLarge)),
                if (i == current) const Icon(Icons.check_rounded, size: 18, color: DispatchColors.green),
              ]),
            ),
        ],
      ),
    );
    if (level == null || level == current) return;
    try {
      await Api.post('people.php', 'set_skill', {'person_id': p.id, 'skill_id': skill.id, 'proficiency': level});
      if (!mounted) return;
      tmToast(context, '${p.name} set to ${kProficiencyLabels[level]} in ${skill.name}');
      await _load();
    } on ApiException catch (e) {
      if (mounted) tmToast(context, e.message, bad: true);
    }
  }

  Future<void> _togglePairing(_Development d, bool value) async {
    try {
      await Api.post('people.php', 'set_skill', {
        'person_id': d.personId,
        'skill_id': d.skillId,
        'proficiency': d.fromLevel,
        'development_target': d.toLevel,
        'pairing_enabled': value,
      });
      if (!mounted) return;
      tmToast(context, value ? 'Pairing enabled for ${d.person} on ${d.skill}' : 'Pairing turned off for ${d.person} on ${d.skill}');
      await _load();
    } on ApiException catch (e) {
      if (mounted) tmToast(context, e.message, bad: true);
    }
  }

  void _exportMatrix() {
    final m = _matrix;
    if (m == null) return;
    final lines = <String>[
      csvLine(['Person', 'Role', 'Days per week', ...m.skills.map((s) => s.name), 'Load %']),
      for (final p in m.people)
        csvLine([
          p.name,
          p.roleTitle ?? '',
          p.daysPerWeek,
          ...m.skills.map((s) => m.cell(p.id, s.id)?.proficiency ?? 0),
          p.loadPct?.round() ?? '',
        ]),
      csvLine(['People at L3 or above', '', '', ...m.skills.map((s) => s.peopleAt3Plus), '']),
      csvLine(['Items needing skill, next 6 weeks', '', '', ...m.skills.map((s) => s.demandItems6w), '']),
    ];
    showTmCsvDialog(context, title: 'Export skills matrix', csv: lines.join('\n'), filename: 'skills-matrix.csv');
  }

  Future<void> _addLeave({int? personId}) async {
    final saved = await showTmAddLeave(
      context,
      people: [for (final p in _people.where((p) => p.active)) (id: p.id, name: p.name)],
      personId: personId,
    );
    if (saved) await _load();
  }

  Future<void> _addPerson() async {
    final saved = await showDialog<bool>(context: context, builder: (context) => _PersonDialog(teams: _teams));
    if (saved == true) await _load();
  }

  void _setScope(PlanScope s) {
    if (s == _scope) return;
    setState(() => _scope = s);
    _load();
  }

  /// The role family this view relates to, when one has been chosen. A team no
  /// longer implies a discipline: that is the point of the rename.
  int? get _roleFamilyId => _scope.isRoleFamily ? _scope.id : null;

  /// People who can be lent from here: active home members of the scope (in a
  /// scoped view), or anyone active in the workspace.
  List<Person> get _lendable => [for (final p in _people) if (p.active && !p.isBorrowed) p];

  Future<void> _addLoan({int? personId}) async {
    final teams = _scopeOptions.teams.isNotEmpty
        ? _scopeOptions.teams
        : [for (final t in _teams) ScopeTeam(id: t.id, name: t.name, parentTeamId: t.parentTeamId, parentName: t.parentName, depth: t.depth)];
    final saved = await showTmAddLoan(context, people: _lendable, teams: teams, personId: personId, today: _today);
    if (saved) {
      if (mounted) tmToast(context, 'Loan added');
      await _load();
    }
  }

  Future<void> _endLoan(Loan loan) async {
    final done = await confirmTmEndLoan(context, loan, today: _today);
    if (done) await _load();
  }

  /// The loan to show on a person's row from this scope's point of view, if any.
  ({Loan loan, LoanSide side})? _loanFor(Person p) {
    if (p.loanedFrom != null) return (loan: p.loanedFrom!, side: LoanSide.borrowed);
    final out = p.onLoanTo ??
        // Not lent today, but lent within the horizon: still worth a word on the row.
        p.loans.where((l) => l.fromTeamId == p.teamId && !l.endedBefore(_today)).firstOrNull;
    if (out == null) return null;
    return (loan: out, side: LoanSide.lent);
  }

  /// Every loan touching anyone in the list, once each, soonest first.
  List<Loan> get _loans {
    final seen = <int>{};
    final out = <Loan>[];
    for (final p in _people) {
      for (final l in [...p.loans, if (p.loanedFrom != null) p.loanedFrom!, if (p.onLoanTo != null) p.onLoanTo!]) {
        if (seen.add(l.id)) out.add(l);
      }
    }
    out.sort((a, b) => a.fromDate.compareTo(b.fromDate));
    return out;
  }

  // ─── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final policy = context.watch<WorkspaceConfig>().policy;
    final m = _matrix;

    final roleFamilyId = _roleFamilyId;
    final actions = <Widget>[
      SegmentedTabs(labels: _tabs, selected: _tab, onChanged: (i) => setState(() => _tab = i)),
      if (_scopeOptions.hasChoices) TmScopePicker(options: _scopeOptions, value: _scope, onChanged: _setScope, enabled: !_loading),
      if (roleFamilyId != null)
        SecondaryButton('Role family view', icon: Icons.badge_outlined, onPressed: () => context.go(RoleFamilyScreen.route(roleFamilyId))),
      SecondaryButton('Organisation', icon: Icons.account_tree_outlined, onPressed: () => context.go(Routes.org)),
      SecondaryButton('Export', icon: Icons.file_download_outlined, onPressed: m == null ? null : _exportMatrix),
      if (session.isTeamLead && _scopeOptions.teams.length > 1)
        SecondaryButton('Add loan', icon: Icons.swap_horiz_rounded, onPressed: _loading ? null : () => _addLoan()),
      if (session.isTeamLead) PrimaryButton('Add person', icon: Icons.person_add_alt_1_rounded, onPressed: _addPerson),
    ];

    return PageBody(
      onRefresh: _load,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(
          title: 'Team & skills',
          subtitle: m == null
              ? 'Proficiency 0–4'
              : dotJoin([
                  switch (_scope.kind) {
                    'portfolio' => '${_scope.name} portfolio',
                    'team' => '${_scope.name} team',
                    _ => _scopeOptions.teams.length > 1 ? 'Whole workspace' : '${m.teamName} team',
                  },
                  '${m.peopleCount} ${m.peopleCount == 1 ? 'person' : 'people'}'
                      '${m.loanedInCount > 0 ? ' (${m.loanedInCount} on loan in)' : ''}',
                  '${m.skillsCount} tracked skills',
                  'proficiency 0–4',
                ]),
          actions: actions,
        ),
        const SizedBox(height: Sp.xl),
        if (_loading)
          const _MatrixSkeleton()
        else if (_error != null)
          ErrorState(title: 'We could not load the team', message: _error, onRetry: _load)
        else if (m == null)
          const EmptyState(icon: Icons.groups_outlined, title: 'No team yet', message: 'Add people to the workspace to see the skills matrix.')
        else
          switch (_tab) {
            1 => _PeopleTab(
                people: _people,
                policy: policy,
                scope: _scope,
                teams: _teams,
                loans: _loans,
                today: _today,
                loanFor: _loanFor,
                canLend: session.isTeamLead && _scopeOptions.teams.length > 1,
                onAddLoan: (pid) => _addLoan(personId: pid),
                onEndLoan: _endLoan,
              ),
            2 => _SkillsTab(matrix: m, canManage: session.isAdmin, onChanged: _load),
            3 => _AvailabilityTab(
                matrix: m,
                people: _people,
                rota: _rota,
                today: _today,
                policy: policy,
                canEdit: session.isTeamLead,
                onAddLeave: () => _addLeave(),
                onReload: _load,
              ),
            _ => _MatrixTab(
                matrix: m,
                session: session,
                policy: policy,
                loanFor: (pid) {
                  final p = _people.where((x) => x.id == pid).firstOrNull;
                  return p == null ? null : _loanFor(p);
                },
                today: _today,
                canEdit: (pid) => _canEditSkill(session, pid),
                onCellTap: (p, s) => _pickLevel(m, p, s),
                onPairing: _togglePairing,
              ),
          },
      ]),
    );
  }
}

// ─── Matrix tab ───────────────────────────────────────────────────────────

class _MatrixTab extends StatelessWidget {
  const _MatrixTab({
    required this.matrix,
    required this.session,
    required this.policy,
    required this.loanFor,
    required this.today,
    required this.canEdit,
    required this.onCellTap,
    required this.onPairing,
  });
  final _Matrix matrix;
  final Session session;
  final Policy policy;
  final ({Loan loan, LoanSide side})? Function(int personId) loanFor;
  final DateTime today;
  final bool Function(int personId) canEdit;
  final void Function(_MatrixPerson, _SkillRow) onCellTap;
  final void Function(_Development, bool) onPairing;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _SummaryStrip(matrix: matrix),
      const SizedBox(height: Sp.lg),
      TmMetricPanel(
        title: 'Skills matrix',
        subtitle: 'Proficiency 0–4',
        // The table carries two metrics: the coverage footers and the load
        // column, so both definitions sit behind the one info icon.
        definition: '${AdmMetrics.skillsMatrix}\n\n${AdmMetrics.coverage}\n\n'
            '${AdmMetrics.load(targetMin: policy.targetLoadMin, targetMax: policy.targetLoadMax)}',
        padding: EdgeInsets.zero,
        dividerAfterHeader: true,
        child: _MatrixTable(matrix: matrix, canEdit: canEdit, onCellTap: onCellTap, loanFor: loanFor, today: today),
      ),
      const SizedBox(height: Sp.lg),
      LayoutBuilder(builder: (context, c) {
        final panels = [
          _AvailabilityPanel(matrix: matrix),
          _DevelopmentPanel(matrix: matrix, canEdit: session.isTeamLead, onPairing: onPairing),
          _DemandSupplyPanel(matrix: matrix),
        ];
        if (c.maxWidth < 1000) {
          return Column(children: [
            for (final p in panels) Padding(padding: const EdgeInsets.only(bottom: Sp.lg), child: p),
          ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < panels.length; i++) ...[
            if (i > 0) const SizedBox(width: Sp.lg),
            Expanded(child: panels[i]),
          ],
        ]);
      }),
    ]);
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.matrix});
  final _Matrix matrix;

  @override
  Widget build(BuildContext context) {
    final single = matrix.singlePointSkills;
    final two = matrix.twoPersonSkills;
    return Wrap(spacing: Sp.md, runSpacing: Sp.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
      if (single.isNotEmpty)
        ToneChip('${single.length} ${single.length == 1 ? 'skill relies' : 'skills rely'} on one person: ${single.join(', ')}',
            tone: 'bad', icon: Icons.warning_amber_rounded),
      if (two.isNotEmpty) ToneChip('${two.length} ${two.length == 1 ? 'skill has' : 'skills have'} two people at L3+', tone: 'warn'),
      if (matrix.wellCovered > 0) ToneChip('${matrix.wellCovered} skills well covered', tone: 'ok'),
      const SizedBox(width: Sp.sm),
      for (var i = 0; i <= 4; i++)
        Row(mainAxisSize: MainAxisSize.min, children: [
          ProficiencySquare(i, size: 16, tooltip: kProficiencyLabels[i]),
          const SizedBox(width: 5),
          Text(matrix.levels.length > i ? matrix.levels[i] : kProficiencyLabels[i], style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
          const SizedBox(width: Sp.sm),
        ]),
    ]);
  }
}

class _MatrixTable extends StatelessWidget {
  const _MatrixTable({required this.matrix, required this.canEdit, required this.onCellTap, required this.loanFor, required this.today});
  final _Matrix matrix;
  final bool Function(int personId) canEdit;
  final void Function(_MatrixPerson, _SkillRow) onCellTap;
  final ({Loan loan, LoanSide side})? Function(int personId) loanFor;
  final DateTime today;

  static const double _personW = 250;
  static const double _daysW = 70;
  static const double _skillW = 84;
  static const double _loadW = 120;

  @override
  Widget build(BuildContext context) {
    final m = matrix;
    final width = _personW + _daysW + _skillW * m.skills.length + _loadW;
    final headStyle = context.text.labelMedium?.copyWith(color: context.mutedColor, fontWeight: FontWeight.w600);
    final maxDemand = m.skills.fold<int>(1, (a, s) => a > s.demandItems6w ? a : s.demandItems6w);

    Widget headCell(String text, double w, {TextAlign align = TextAlign.left}) =>
        SizedBox(width: w, child: Text(text, style: headStyle, textAlign: align, maxLines: 2));

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: width,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Header
          Container(
            color: context.isDark ? const Color(0xFF1B2842) : DispatchColors.surfaceAlt,
            padding: const EdgeInsets.symmetric(horizontal: Sp.lg, vertical: Sp.md),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              headCell('Person', _personW - Sp.lg),
              headCell('Days/wk', _daysW, align: TextAlign.right),
              for (final s in m.skills) headCell(s.name, _skillW, align: TextAlign.center),
              headCell('Load', _loadW - Sp.lg, align: TextAlign.right),
            ]),
          ),
          for (final p in m.people) ...[
            Divider(height: 1, thickness: 1, color: context.borderColor),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.lg, vertical: Sp.sm),
              child: Row(children: [
                SizedBox(
                  width: _personW - Sp.lg,
                  child: InkWell(
                    onTap: () => context.go(Routes.person(p.id)),
                    borderRadius: DispatchRadius.cardR,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(children: [
                        PersonAvatar(p.initials ?? initialsOf(p.name), colourHex: p.colourHex, seed: p.id, size: 30),
                        const SizedBox(width: Sp.md),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                            Text(p.name, style: context.text.titleSmall, overflow: TextOverflow.ellipsis),
                            if (p.roleTitle != null)
                              Text(p.roleTitle ?? '', style: context.text.bodySmall?.copyWith(color: context.mutedColor), overflow: TextOverflow.ellipsis),
                            // TEAM-09: the pool includes borrowed people; say so on the row.
                            if (loanFor(p.id) case final l?)
                              Padding(padding: const EdgeInsets.only(top: 3), child: TmLoanChip(l.loan, side: l.side, today: today))
                            else if (p.loanedIn)
                              const Padding(padding: EdgeInsets.only(top: 3), child: ToneChip('On loan in', tone: 'info', compact: true)),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                ),
                SizedBox(
                  width: _daysW,
                  child: Text(p.daysPerWeek.toStringAsFixed(1),
                      textAlign: TextAlign.right, style: DispatchTheme.numeric(size: 13.5, color: context.inkColor)),
                ),
                for (final s in m.skills)
                  SizedBox(
                    width: _skillW,
                    child: Center(
                      child: _MatrixCell(
                        level: m.cell(p.id, s.id)?.proficiency ?? 0,
                        certified: m.cell(p.id, s.id)?.certified ?? false,
                        person: p,
                        skill: s,
                        editable: canEdit(p.id),
                        onTap: () => onCellTap(p, s),
                      ),
                    ),
                  ),
                SizedBox(width: _loadW - Sp.lg, child: Align(alignment: Alignment.centerRight, child: TmLoadBar(p.loadPct))),
              ]),
            ),
          ],
          Divider(height: 1, thickness: 1, color: context.borderColor),
          // Footer: people at L3+
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.lg, vertical: Sp.md),
            child: Row(children: [
              SizedBox(width: _personW - Sp.lg + _daysW, child: Text('People at L3 or above', style: context.text.bodyMedium?.copyWith(color: context.mutedColor))),
              for (final s in m.skills)
                SizedBox(
                  width: _skillW,
                  child: Center(
                    child: Tooltip(
                      message: s.peopleAt3Plus <= 1 ? '${s.name}: single point of failure' : '${s.peopleAt3Plus} people at L3 or above',
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (s.peopleAt3Plus <= 2)
                          Padding(
                            padding: const EdgeInsets.only(right: 3),
                            child: Icon(Icons.warning_amber_rounded, size: 13, color: s.peopleAt3Plus <= 1 ? DispatchColors.red : DispatchColors.amber),
                          ),
                        Text(
                          '${s.peopleAt3Plus}',
                          style: DispatchTheme.numeric(
                            size: 14,
                            weight: FontWeight.w800,
                            color: s.peopleAt3Plus <= 1
                                ? DispatchColors.red
                                : (s.peopleAt3Plus == 2 ? DispatchColors.amber : context.inkColor),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
              SizedBox(width: _loadW - Sp.lg),
            ]),
          ),
          Divider(height: 1, thickness: 1, color: context.borderColor),
          // Footer: demand next 6 weeks
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.lg, vertical: Sp.md),
            child: Row(children: [
              SizedBox(
                width: _personW - Sp.lg + _daysW,
                child: Text('Items needing skill, next 6 weeks', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
              ),
              for (final s in m.skills)
                SizedBox(
                  width: _skillW,
                  child: Center(
                    child: Tooltip(
                      message: s.exceeds
                          ? '${s.demandItems6w} items · demand ${fmtDays(s.demandDays6w)} exceeds supply ${fmtDays(s.supplyDays6w)}'
                          : '${s.demandItems6w} items · demand ${fmtDays(s.demandDays6w)} of ${fmtDays(s.supplyDays6w)} supply',
                      child: TmMiniBar(
                        fraction: s.demandItems6w / maxDemand,
                        colour: s.exceeds ? DispatchColors.red : DispatchColors.typeBlue,
                        width: 40,
                        trailing: '${s.demandItems6w}',
                      ),
                    ),
                  ),
                ),
              SizedBox(width: _loadW - Sp.lg),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _MatrixCell extends StatelessWidget {
  const _MatrixCell({
    required this.level,
    required this.certified,
    required this.person,
    required this.skill,
    required this.editable,
    required this.onTap,
  });
  final int level;
  final bool certified;
  final _MatrixPerson person;
  final _SkillRow skill;
  final bool editable;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tip = '${person.name} · ${skill.name}: $level ${kProficiencyLabels[level.clamp(0, 4)]}'
        '${certified ? ' · certified' : ''}${editable ? ' · tap to change' : ''}';
    final square = Stack(clipBehavior: Clip.none, children: [
      _LevelSquare(level: level),
      if (certified)
        Positioned(
          right: -3,
          top: -3,
          child: Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: DispatchColors.green, shape: BoxShape.circle, border: Border.all(color: context.panelColor, width: 1.5)),
          ),
        ),
    ]);
    if (!editable) return Tooltip(message: tip, child: square);
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(padding: const EdgeInsets.all(4), child: square),
      ),
    );
  }
}

/// Proficiency square that also shows its number, so level is not carried by
/// colour alone.
class _LevelSquare extends StatelessWidget {
  const _LevelSquare({required this.level});
  final int level;
  static const double size = 28;

  @override
  Widget build(BuildContext context) {
    final fill = ProficiencySquare.fillFor(level);
    if (fill == null) return ProficiencySquare(0, size: size);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(6)),
      child: Text(
        '$level',
        style: DispatchTheme.numeric(size: size * 0.46, weight: FontWeight.w800, color: level >= 3 ? Colors.white : DispatchColors.ink),
      ),
    );
  }
}

class _AvailabilityPanel extends StatelessWidget {
  const _AvailabilityPanel({required this.matrix});
  final _Matrix matrix;

  @override
  Widget build(BuildContext context) {
    return TmMetricPanel(
      title: 'Availability, next 4 weeks',
      definition: AdmMetrics.availability,
      child: matrix.availability.isEmpty
          ? const EmptyState(
              icon: Icons.event_available_outlined,
              title: 'Everyone is available',
              message: 'No leave, training or rota weeks in the next four weeks.',
              compact: true,
            )
          : Column(children: [
              for (final a in matrix.availability)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Sp.sm),
                  child: Row(children: [
                    PersonAvatar(initialsOf(a.person), seed: a.personId, size: 26),
                    const SizedBox(width: Sp.md),
                    Expanded(child: Text(dotJoin([a.person, a.label]), style: context.text.bodyMedium)),
                    const SizedBox(width: Sp.sm),
                    _availabilityBadge(a),
                  ]),
                ),
            ]),
    );
  }

  Widget _availabilityBadge(_Availability a) => switch (a.kind) {
        'rota' => ToneChip(a.badge, tone: 'bad', compact: true),
        'pattern' => ToneChip(a.badge, compact: true),
        'training' => ToneChip(a.badge, tone: 'info', compact: true),
        _ => ToneChip(a.badge, compact: true),
      };
}

class _DevelopmentPanel extends StatelessWidget {
  const _DevelopmentPanel({required this.matrix, required this.canEdit, required this.onPairing});
  final _Matrix matrix;
  final bool canEdit;
  final void Function(_Development, bool) onPairing;

  @override
  Widget build(BuildContext context) {
    return TmMetricPanel(
      title: 'Development plans',
      subtitle: 'Skills people want to grow',
      definition: AdmMetrics.development,
      child: matrix.development.isEmpty
          ? const EmptyState(icon: Icons.school_outlined, title: 'No development targets', message: 'Set a target level on a person to plan pairing.', compact: true)
          : Column(children: [
              for (final d in matrix.development)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Sp.sm),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    PersonAvatar(initialsOf(d.person), seed: d.personId, size: 26),
                    const SizedBox(width: Sp.md),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        RichText(
                          text: TextSpan(style: context.text.titleSmall, children: [
                            TextSpan(text: d.skill),
                            TextSpan(text: '  L${d.fromLevel} → L${d.toLevel}', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
                          ]),
                        ),
                        const SizedBox(height: 2),
                        Text(d.note, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
                      ]),
                    ),
                    const SizedBox(width: Sp.sm),
                    Tooltip(
                      message: d.pairingEnabled ? 'The scheduler pairs on this skill' : 'Not yet used in scheduling',
                      child: Switch(value: d.pairingEnabled, onChanged: canEdit ? (v) => onPairing(d, v) : null),
                    ),
                  ]),
                ),
            ]),
    );
  }
}

class _DemandSupplyPanel extends StatelessWidget {
  const _DemandSupplyPanel({required this.matrix});
  final _Matrix matrix;

  @override
  Widget build(BuildContext context) {
    final rows = matrix.demandVsSupply;
    return TmMetricPanel(
      title: 'Skill demand vs supply',
      subtitle: 'Person-days, next 6 weeks',
      definition: AdmMetrics.demandVsSupply,
      child: rows.isEmpty
          ? const EmptyState(icon: Icons.bar_chart_rounded, title: 'Nothing to compare', message: 'No skill demand in the next six weeks.', compact: true)
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TmGroupedBarChart(
                height: 140,
                barWidth: 9,
                groups: [
                  for (final r in rows)
                    TmBarGroup(
                      r.skill,
                      [
                        TmBar(r.demandDays, r.exceeds ? DispatchColors.red : DispatchColors.ink, tooltip: '${r.skill} demand ${fmtDays(r.demandDays)}'),
                        TmBar(r.supplyDays, const Color(0xFFAFC5EC), tooltip: '${r.skill} qualified supply ${fmtDays(r.supplyDays)}'),
                      ],
                      flag: r.exceeds ? '!' : null,
                    ),
                ],
              ),
              const SizedBox(height: Sp.md),
              const TmLegend([
                (label: 'Demand', colour: DispatchColors.ink),
                (label: 'Qualified supply', colour: Color(0xFFAFC5EC)),
                (label: 'Demand exceeds supply (!)', colour: DispatchColors.red),
              ]),
            ]),
    );
  }
}

// ─── People tab ───────────────────────────────────────────────────────────

class _PeopleTab extends StatelessWidget {
  const _PeopleTab({
    required this.people,
    required this.policy,
    required this.scope,
    required this.teams,
    required this.loans,
    required this.today,
    required this.loanFor,
    required this.canLend,
    required this.onAddLoan,
    required this.onEndLoan,
  });
  final List<Person> people;
  final Policy policy;
  final PlanScope scope;
  final List<_Team> teams;
  final List<Loan> loans;
  final DateTime today;
  final ({Loan loan, LoanSide side})? Function(Person) loanFor;
  final bool canLend;
  final void Function(int? personId) onAddLoan;
  final void Function(Loan) onEndLoan;

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) {
      return const EmptyState(icon: Icons.groups_outlined, title: 'No people yet', message: 'Add someone to the team to start planning.');
    }
    // ADM-03: deactivated people stay in the list, after the active ones and
    // visibly different, so their flagged assignments are not forgotten.
    final active = people.where((p) => p.active).toList();
    final inactive = people.where((p) => !p.active).toList();
    final ordered = [...active, ...inactive];

    final borrowed = active.where((p) => p.isBorrowed).length;
    // Teams in the view, with a link to the portfolio each sits in (TEAM-09).
    final teamsShown = [
      for (final t in teams)
        if (scope.isWorkspace || people.any((p) => p.teamId == t.id)) t,
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TmMetricTitle(
        title: 'People and load',
        subtitle: dotJoin([
          '${active.length} active',
          if (borrowed > 0) '$borrowed on loan in',
          if (inactive.isNotEmpty) '${inactive.length} deactivated',
        ]),
        definition: AdmMetrics.load(targetMin: policy.targetLoadMin, targetMax: policy.targetLoadMax),
      ),
      if (teamsShown.length > 1 || teamsShown.any((t) => t.parentTeamId != null)) ...[
        const SizedBox(height: Sp.sm),
        Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
          for (final t in teamsShown)
            InfoPill(
              dotJoin([t.name, t.parentName]),
              icon: Icons.groups_outlined,
              onTap: () => context.go(Routes.org),
            ),
        ]),
      ],
      const SizedBox(height: Sp.md),
      LayoutBuilder(builder: (context, c) {
        final cols = (c.maxWidth / 340).floor().clamp(1, 4);
        return Wrap(
          spacing: Sp.lg,
          runSpacing: Sp.lg,
          children: [
            for (final p in ordered)
              SizedBox(
                width: cols == 1 ? c.maxWidth : (c.maxWidth - Sp.lg * (cols - 1)) / cols,
                child: Opacity(
                  opacity: p.active ? 1 : 0.68,
                  child: DispatchCard(
                    onTap: () => context.go(Routes.person(p.id)),
                    padding: const EdgeInsets.all(Sp.lg),
                    dashed: !p.active,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Row(children: [
                        PersonAvatar.person(p, size: 40, outlined: !p.active),
                        const SizedBox(width: Sp.md),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                            Text(p.name, style: context.text.titleMedium, overflow: TextOverflow.ellipsis),
                            Text(dotJoin([p.roleTitle, p.teamName]),
                                style: context.text.bodySmall?.copyWith(color: context.mutedColor), overflow: TextOverflow.ellipsis),
                          ]),
                        ),
                        if (!p.active) ...[
                          const SizedBox(width: Sp.sm),
                          const ToneChip('Deactivated', compact: true, icon: Icons.person_off_outlined),
                        ],
                      ]),
                      if (loanFor(p) case final l?) ...[
                        const SizedBox(height: Sp.sm),
                        Align(alignment: Alignment.centerLeft, child: TmLoanChip(l.loan, side: l.side, today: today)),
                      ],
                      const SizedBox(height: Sp.md),
                      if (p.tagline != null && p.tagline!.isNotEmpty) ...[
                        Text(p.tagline ?? '', style: context.text.bodyMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: Sp.md),
                      ],
                      Row(children: [
                        Expanded(
                          child: Text(
                            p.active ? '${p.daysPerWeek.toStringAsFixed(1)} days/week' : 'No longer available to plan',
                            style: context.text.bodySmall?.copyWith(color: context.mutedColor),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (p.active) TmLoadBar(p.loadPct),
                      ]),
                    ]),
                  ),
                ),
              ),
          ],
        );
      }),
      const SizedBox(height: Sp.lg),
      _LoansPanel(loans: loans, today: today, scope: scope, canLend: canLend, onAddLoan: () => onAddLoan(null), onEndLoan: onEndLoan),
    ]);
  }
}

/// Loans touching the people in view (TEAM-09): who went where, for how long
/// and at what share, with *End early* for a team lead. Reasons are business
/// reasons the lender typed; there is no personal data here (ADM-05).
class _LoansPanel extends StatelessWidget {
  const _LoansPanel({required this.loans, required this.today, required this.scope, required this.canLend, required this.onAddLoan, required this.onEndLoan});
  final List<Loan> loans;
  final DateTime today;
  final PlanScope scope;
  final bool canLend;
  final VoidCallback onAddLoan;
  final void Function(Loan) onEndLoan;

  @override
  Widget build(BuildContext context) {
    return TmMetricPanel(
      title: 'Loans between teams',
      subtitle: loans.isEmpty ? null : '${loans.length} ${loans.length == 1 ? 'loan' : 'loans'} from today to the planning horizon',
      definition: PfMetrics.loans,
      trailing: canLend ? SecondaryButton('Add loan', icon: Icons.swap_horiz_rounded, onPressed: onAddLoan) : null,
      child: loans.isEmpty
          ? EmptyState(
              icon: Icons.swap_horiz_rounded,
              title: 'No loans',
              message: scope.isWorkspace
                  ? 'Nobody is lent to another team between now and the planning horizon.'
                  : 'Nobody is lent into or out of ${scope.phrase} between now and the planning horizon.',
              compact: true,
            )
          : TmLoanList(loans: loans, today: today, canEnd: canLend, onEnd: onEndLoan),
    );
  }
}

// ─── Skills tab ───────────────────────────────────────────────────────────

class _SkillsTab extends StatelessWidget {
  const _SkillsTab({required this.matrix, required this.canManage, required this.onChanged});
  final _Matrix matrix;
  final bool canManage;
  final Future<void> Function() onChanged;

  Future<void> _edit(BuildContext context, {_SkillRow? skill}) async {
    final saved = await showDialog<bool>(context: context, builder: (context) => _SkillDialog(skill: skill));
    if (saved == true) await onChanged();
  }

  Future<void> _merge(BuildContext context, _SkillRow from) async {
    final into = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Merge “${from.name}” into'),
        children: [
          for (final s in matrix.skills.where((s) => s.id != from.id))
            SimpleDialogOption(onPressed: () => Navigator.of(context).pop(s.id), child: Text(s.name, style: context.text.bodyLarge)),
        ],
      ),
    );
    if (into == null || !context.mounted) return;
    final ok = await showTmConfirm(
      context,
      title: 'Merge skill',
      message: 'Everyone’s level in “${from.name}” moves to the target skill, keeping the higher level. This cannot be undone.',
      confirmLabel: 'Merge',
    );
    if (!ok || !context.mounted) return;
    try {
      await Api.post('skills.php', 'merge', {'from_id': from.id, 'into_id': into});
      if (context.mounted) tmToast(context, '“${from.name}” merged');
      await onChanged();
    } on ApiException catch (e) {
      if (context.mounted) tmToast(context, e.message, bad: true);
    }
  }

  Future<void> _retire(BuildContext context, _SkillRow s) async {
    final ok = await showTmConfirm(
      context,
      title: 'Retire ${s.name}?',
      message: 'Retired skills stay on delivered work but cannot be added to new items or people.',
      confirmLabel: 'Retire',
      danger: true,
    );
    if (!ok || !context.mounted) return;
    try {
      await Api.post('skills.php', 'retire', {'id': s.id});
      if (context.mounted) tmToast(context, '${s.name} retired');
      await onChanged();
    } on ApiException catch (e) {
      if (context.mounted) tmToast(context, e.message, bad: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TmMetricPanel(
      title: 'Skills catalogue',
      subtitle: '${matrix.skills.length} tracked skills',
      definition: '${AdmMetrics.coverage}\n\n${AdmMetrics.demandVsSupply}',
      trailing: canManage ? PrimaryButton('Add skill', icon: Icons.add_rounded, onPressed: () => _edit(context)) : null,
      padding: EdgeInsets.zero,
      dividerAfterHeader: true,
      child: LayoutBuilder(builder: (context, c) {
        if (TmTable.isNarrow(c.maxWidth)) {
          return Padding(
            padding: const EdgeInsets.all(Sp.lg),
            child: Column(children: [
              for (final s in matrix.skills)
                Padding(
                  padding: const EdgeInsets.only(bottom: Sp.md),
                  child: DispatchCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Row(children: [
                        Expanded(child: Text(s.name, style: context.text.titleSmall)),
                        if (s.singlePoint) const ToneChip('Single point', tone: 'bad', compact: true),
                      ]),
                      const SizedBox(height: 4),
                      Text(dotJoin([s.category, '${s.peopleAt3Plus} at L3 or above']), style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
                      const SizedBox(height: 4),
                      Text('Demand ${fmtDays(s.demandDays6w)} · supply ${fmtDays(s.supplyDays6w)} over six weeks',
                          style: context.text.bodySmall?.copyWith(color: s.exceeds ? DispatchColors.red : context.mutedColor)),
                    ]),
                  ),
                ),
            ]),
          );
        }
        return TmTable(
          columns: const [
            TmCol('Skill', flex: 3),
            TmCol('Category', flex: 2),
            TmCol('People at L3+', width: 110, align: TextAlign.right),
            TmCol('Demand 6w', width: 100, align: TextAlign.right),
            TmCol('Supply 6w', width: 100, align: TextAlign.right),
            TmCol('', width: 96, align: TextAlign.right),
          ],
          rows: [
            for (final s in matrix.skills)
              [
                Row(children: [
                  Flexible(child: Text(s.name, style: context.text.titleSmall, overflow: TextOverflow.ellipsis)),
                  if (s.singlePoint) ...[const SizedBox(width: Sp.sm), const ToneChip('Single point', tone: 'bad', compact: true)],
                  if (s.retired) ...[const SizedBox(width: Sp.sm), const ToneChip('Retired', compact: true)],
                ]),
                Text(s.category ?? '—', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
                Text('${s.peopleAt3Plus}',
                    style: DispatchTheme.numeric(size: 14, weight: FontWeight.w700, color: s.peopleAt3Plus <= 1 ? DispatchColors.red : context.inkColor)),
                Text(fmtDays(s.demandDays6w),
                    style: DispatchTheme.numeric(size: 13.5, color: s.exceeds ? DispatchColors.red : context.inkColor)),
                Text(fmtDays(s.supplyDays6w), style: DispatchTheme.numeric(size: 13.5, color: context.inkColor)),
                if (canManage)
                  Row(mainAxisAlignment: MainAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      onPressed: () => _edit(context, skill: s),
                      icon: const Icon(Icons.edit_outlined, size: 17),
                      tooltip: 'Edit ${s.name}',
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      onPressed: () => _merge(context, s),
                      icon: const Icon(Icons.merge_rounded, size: 17),
                      tooltip: 'Merge ${s.name} into another skill',
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      onPressed: s.retired ? null : () => _retire(context, s),
                      icon: const Icon(Icons.archive_outlined, size: 17),
                      tooltip: 'Retire ${s.name}',
                      visualDensity: VisualDensity.compact,
                    ),
                  ])
                else
                  const SizedBox(),
              ],
          ],
        );
      }),
    );
  }
}

class _SkillDialog extends StatefulWidget {
  const _SkillDialog({this.skill});
  final _SkillRow? skill;

  @override
  State<_SkillDialog> createState() => _SkillDialogState();
}

class _SkillDialogState extends State<_SkillDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.skill?.name ?? '');
  late final TextEditingController _category = TextEditingController(text: widget.skill?.category ?? '');
  late final TextEditingController _description = TextEditingController(text: widget.skill?.description ?? '');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _category.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.post('skills.php', 'save', {
        if (widget.skill != null) 'id': widget.skill!.id,
        'name': _name.text.trim(),
        'category': _category.text.trim(),
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
      title: Text(widget.skill == null ? 'Add skill' : 'Edit ${widget.skill!.name}'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TmField(label: 'Name', child: TextField(controller: _name, autofocus: true)),
          const SizedBox(height: Sp.md),
          TmField(label: 'Category', hint: 'For example Platform, Data or Reporting.', child: TextField(controller: _category)),
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

// ─── Availability tab ─────────────────────────────────────────────────────

class _AvailabilityTab extends StatelessWidget {
  const _AvailabilityTab({
    required this.matrix,
    required this.people,
    required this.rota,
    required this.today,
    required this.policy,
    required this.canEdit,
    required this.onAddLeave,
    required this.onReload,
  });
  final _Matrix matrix;
  final List<Person> people;
  final Map<int, List<DateTime>> rota;
  final DateTime today;
  final Policy policy;
  final bool canEdit;
  final VoidCallback onAddLeave;
  final Future<void> Function() onReload;

  @override
  Widget build(BuildContext context) {
    // Group the next four weeks by week commencing.
    final byWeek = <DateTime, List<_Availability>>{};
    for (final a in matrix.availability) {
      final from = a.from;
      if (from == null) continue;
      final monday = from.subtract(Duration(days: from.weekday - 1));
      byWeek.putIfAbsent(DateTime(monday.year, monday.month, monday.day), () => []).add(a);
    }
    final weeks = byWeek.keys.toList()..sort();

    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 900;
      final left = TmMetricPanel(
        title: 'Availability by week',
        subtitle: 'Next four weeks',
        definition: AdmMetrics.availability,
        trailing: canEdit ? SecondaryButton('Add leave', icon: Icons.event_busy_outlined, onPressed: onAddLeave) : null,
        child: weeks.isEmpty
            ? const EmptyState(
                icon: Icons.event_available_outlined,
                title: 'Everyone is available',
                message: 'No leave, training or rota weeks in the next four weeks.',
                compact: true,
              )
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final w in weeks) ...[
                  SectionLabel(fmtWeekCommencing(w)),
                  for (final a in byWeek[w]!)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Sp.sm),
                      child: Row(children: [
                        PersonAvatar(initialsOf(a.person), seed: a.personId, size: 26),
                        const SizedBox(width: Sp.md),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                            Text(a.person, style: context.text.titleSmall),
                            Text(dotJoin([a.label, fmtDateRange(a.from, a.to)]), style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
                          ]),
                        ),
                        ToneChip(a.badge, tone: a.kind == 'rota' ? 'bad' : null, compact: true),
                      ]),
                    ),
                  const SizedBox(height: Sp.sm),
                ],
              ]),
      );

      // TEAM-08: the rota is assigned here, not just listed. set_rota and
      // clear_rota recompute that person's capacity for the week.
      final right = AdmRotaPanel(
        people: [
          for (final p in people)
            AdmRotaPerson(id: p.id, name: p.name, initials: p.initials, colourHex: p.colourHex, active: p.active),
        ],
        rota: rota,
        today: today,
        canEdit: canEdit,
        onChanged: onReload,
        incidentReservePct: policy.incidentReservePct,
        rotaReservePct: matrix.rotaReservePct ?? policy.rotaReservePct,
      );

      if (!wide) {
        return Column(children: [left, const SizedBox(height: Sp.lg), right]);
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(flex: 3, child: left),
        const SizedBox(width: Sp.lg),
        Expanded(flex: 2, child: right),
      ]);
    });
  }
}

/// Add or edit a person (people.php save).
class _PersonDialog extends StatefulWidget {
  const _PersonDialog({required this.teams});
  final List<_Team> teams;

  @override
  State<_PersonDialog> createState() => _PersonDialogState();
}

class _PersonDialogState extends State<_PersonDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _roleTitle = TextEditingController();
  final TextEditingController _tagline = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _days = TextEditingController(text: '5.0');
  late int? _teamId = widget.teams.isNotEmpty ? widget.teams.first.id : null;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _roleTitle.dispose();
    _tagline.dispose();
    _email.dispose();
    _days.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.post('people.php', 'save', {
        'name': _name.text.trim(),
        'role_title': _roleTitle.text.trim(),
        'tagline': _tagline.text.trim(),
        'email': _email.text.trim(),
        'days_per_week': double.tryParse(_days.text.trim()) ?? 5,
        if (_teamId != null) 'team_id': _teamId,
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
      title: const Text('Add person'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TmField(label: 'Name', child: TextField(controller: _name, autofocus: true)),
            const SizedBox(height: Sp.md),
            TmField(label: 'Role title', child: TextField(controller: _roleTitle)),
            const SizedBox(height: Sp.md),
            TmField(label: 'Tagline', hint: 'Shown under their name, e.g. “Terraform and Databricks lead”.', child: TextField(controller: _tagline)),
            const SizedBox(height: Sp.md),
            TmField(label: 'Email', child: TextField(controller: _email, keyboardType: TextInputType.emailAddress)),
            const SizedBox(height: Sp.md),
            Row(children: [
              Expanded(child: TmField(label: 'Days per week', child: TextField(controller: _days, keyboardType: TextInputType.number))),
              const SizedBox(width: Sp.md),
              Expanded(
                child: TmField(
                  label: 'Team',
                  child: DropdownButtonFormField<int>(
                    initialValue: _teamId,
                    items: [for (final t in widget.teams) DropdownMenuItem(value: t.id, child: Text(t.name))],
                    onChanged: (v) => setState(() => _teamId = v),
                  ),
                ),
              ),
            ]),
            if (_error != null) TmInlineError(_error!),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        PrimaryButton('Save', busy: _busy, onPressed: _save),
      ],
    );
  }
}

// ─── Loading skeleton ─────────────────────────────────────────────────────

class _MatrixSkeleton extends StatelessWidget {
  const _MatrixSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // A Row of three fixed 180px bars is 564px wide and overflowed a phone.
      const Wrap(spacing: Sp.md, runSpacing: Sp.sm, children: [
        Skeleton(width: 180, height: 26),
        Skeleton(width: 180, height: 26),
        Skeleton(width: 180, height: 26),
      ]),
      const SizedBox(height: Sp.lg),
      const SkeletonPanel(rows: 8),
      const SizedBox(height: Sp.lg),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < (Breaks.isPhone(context) ? 1 : 3); i++) ...[
          if (i > 0) const SizedBox(width: Sp.lg),
          const Expanded(child: SkeletonPanel(rows: 4)),
        ],
      ]),
    ]);
  }
}

// ─── Parsing (skills.php matrix) ──────────────────────────────────────────

/// A team as `people.php list` reports it: ORG-01 means it has a place in a
/// tree now, so it carries its parent and how deep it sits.
class _Team {
  const _Team({required this.id, required this.name, this.parentTeamId, this.parentName, this.depth = 0, this.path = ''});
  final int id;
  final String name;
  final int? parentTeamId;
  final String? parentName;
  final int depth;
  final String path;
  factory _Team.fromJson(Map<String, dynamic> j) => _Team(
        id: asIntOr(j['id'], 0),
        name: asStrOr(j['name'], ''),
        parentTeamId: asInt(j['parent_team_id']),
        parentName: asStr(j['parent_team_name']),
        depth: asIntOr(j['depth'], 0),
        path: asStrOr(j['path'], ''),
      );
}

class _SkillRow {
  const _SkillRow({
    required this.id,
    required this.name,
    this.category,
    this.description,
    this.retired = false,
    this.peopleAt3Plus = 0,
    this.demandDays6w = 0,
    this.demandItems6w = 0,
    this.supplyDays6w = 0,
    this.exceeds = false,
    this.singlePoint = false,
  });
  final int id;
  final String name;
  final String? category;
  final String? description;
  final bool retired;
  final int peopleAt3Plus;
  final double demandDays6w;
  final int demandItems6w;
  final double supplyDays6w;
  final bool exceeds;
  final bool singlePoint;

  factory _SkillRow.fromJson(Map<String, dynamic> j) => _SkillRow(
        id: asIntOr(j['id'], 0),
        name: asStrOr(j['name'], ''),
        category: asStr(j['category']),
        description: asStr(j['description']),
        retired: asBool(j['retired']),
        peopleAt3Plus: asIntOr(j['people_at_3_plus'], 0),
        demandDays6w: asDoubleOr(j['demand_days_6w'], 0),
        demandItems6w: asIntOr(j['demand_items_6w'], 0),
        supplyDays6w: asDoubleOr(j['supply_days_6w'], 0),
        exceeds: asBool(j['exceeds']),
        singlePoint: asBool(j['single_point']),
      );
}

class _MatrixPerson {
  const _MatrixPerson({required this.id, required this.name, this.initials, this.colourHex, this.roleTitle, this.daysPerWeek = 5, this.loadPct, this.loanedIn = false});
  final int id;
  final String name;
  final String? initials;
  final String? colourHex;
  final String? roleTitle;
  final double daysPerWeek;
  final double? loadPct;
  /// TEAM-09: borrowed into the scope the matrix was built for.
  final bool loanedIn;

  factory _MatrixPerson.fromJson(Map<String, dynamic> j) => _MatrixPerson(
        id: asIntOr(j['id'], 0),
        name: asStrOr(j['name'], ''),
        initials: asStr(j['initials']),
        colourHex: asStr(j['colour']),
        roleTitle: asStr(j['role_title']),
        daysPerWeek: asDoubleOr(j['days_per_week'], 5),
        loadPct: asDouble(j['load_pct']),
        loanedIn: asBool(j['loaned_in']),
      );
}

class _Cell {
  const _Cell({this.proficiency = 0, this.certified = false, this.developmentTarget, this.pairingEnabled = false, this.endorsed = false});
  final int proficiency;
  final bool certified;
  final int? developmentTarget;
  final bool pairingEnabled;
  final bool endorsed;

  factory _Cell.fromJson(Map<String, dynamic> j) => _Cell(
        proficiency: asIntOr(j['proficiency'], 0),
        certified: asBool(j['certified']),
        developmentTarget: asInt(j['development_target']),
        pairingEnabled: asBool(j['pairing_enabled']),
        endorsed: asBool(j['endorsed']),
      );
}

class _Availability {
  const _Availability({required this.personId, required this.person, required this.label, required this.badge, required this.kind, this.from, this.to, this.days});
  final int personId;
  final String person;
  final String label;
  final String badge;
  final String kind;
  final DateTime? from;
  final DateTime? to;
  final double? days;

  factory _Availability.fromJson(Map<String, dynamic> j) => _Availability(
        personId: asIntOr(j['person_id'], 0),
        person: asStrOr(j['person'], ''),
        label: asStrOr(j['label'], ''),
        badge: asStrOr(j['badge'], ''),
        kind: asStrOr(j['kind'], 'leave'),
        from: asDate(j['from']),
        to: asDate(j['to']),
        days: asDouble(j['days']),
      );
}

class _Development {
  const _Development({
    required this.personId,
    required this.person,
    required this.skillId,
    required this.skill,
    required this.fromLevel,
    required this.toLevel,
    required this.pairingEnabled,
    required this.note,
  });
  final int personId;
  final String person;
  final int skillId;
  final String skill;
  final int fromLevel;
  final int toLevel;
  final bool pairingEnabled;
  final String note;

  factory _Development.fromJson(Map<String, dynamic> j) => _Development(
        personId: asIntOr(j['person_id'], 0),
        person: asStrOr(j['person'], ''),
        skillId: asIntOr(j['skill_id'], 0),
        skill: asStrOr(j['skill'], ''),
        fromLevel: asIntOr(j['from_level'], 0),
        toLevel: asIntOr(j['to_level'], 0),
        pairingEnabled: asBool(j['pairing_enabled']),
        note: asStrOr(j['note'], ''),
      );
}

class _DemandSupply {
  const _DemandSupply({required this.skill, required this.demandDays, required this.supplyDays, required this.exceeds});
  final String skill;
  final double demandDays;
  final double supplyDays;
  final bool exceeds;

  factory _DemandSupply.fromJson(Map<String, dynamic> j) => _DemandSupply(
        skill: asStrOr(j['skill'], ''),
        demandDays: asDoubleOr(j['demand_days'], 0),
        supplyDays: asDoubleOr(j['supply_days'], 0),
        exceeds: asBool(j['exceeds']),
      );
}

class _Matrix {
  _Matrix({
    required this.skills,
    required this.people,
    required this.cells,
    required this.availability,
    required this.development,
    required this.demandVsSupply,
    required this.singlePointSkills,
    required this.twoPersonSkills,
    required this.wellCovered,
    required this.peopleCount,
    required this.skillsCount,
    required this.teamName,
    required this.levels,
    this.rotaReservePct,
  });

  final List<_SkillRow> skills;
  final List<_MatrixPerson> people;
  final Map<String, _Cell> cells;
  final List<_Availability> availability;
  final List<_Development> development;
  final List<_DemandSupply> demandVsSupply;
  final List<String> singlePointSkills;
  final List<String> twoPersonSkills;
  final int wellCovered;
  final int peopleCount;
  final int skillsCount;
  final String teamName;
  final List<String> levels;
  final double? rotaReservePct;

  /// Cells are keyed `"<person_id>:<skill_id>"`.
  _Cell? cell(int personId, int skillId) => cells['$personId:$skillId'];

  int get loanedInCount => people.where((p) => p.loanedIn).length;

  factory _Matrix.fromJson(Map<String, dynamic> j) {
    final summary = asMap(j['summary']);
    final rawCells = asMap(j['cells']);
    return _Matrix(
      skills: asList(j['skills'], _SkillRow.fromJson),
      people: asList(j['people'], _MatrixPerson.fromJson),
      cells: {for (final e in rawCells.entries) e.key: _Cell.fromJson(asMap(e.value))},
      availability: asList(j['availability_4w'], _Availability.fromJson),
      development: asList(j['development'], _Development.fromJson),
      demandVsSupply: asList(j['demand_vs_supply'], _DemandSupply.fromJson),
      singlePointSkills: asStrList(summary['single_point_skills']),
      twoPersonSkills: asStrList(summary['two_person_skills']),
      wellCovered: asIntOr(summary['well_covered'], 0),
      peopleCount: asIntOr(summary['people_count'], 0),
      skillsCount: asIntOr(summary['skills_count'], 0),
      teamName: asStrOr(summary['team_name'], 'Team'),
      levels: asStrList(summary['levels']),
      rotaReservePct: asDouble(summary['rota_reserve_pct']),
    );
  }
}

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
import '../widgets/adm_metrics.dart';
import '../widgets/pf_metrics.dart';
import '../widgets/team_widgets.dart';
import '../widgets/tm_loan_list.dart';
import '../widgets/widgets.dart';
import 'parts/tm_pattern_dialog.dart';

/// Person (TEAM-*, spec 9.4.7): load and concurrency against their own limits,
/// plan changes over eight weeks, assignments with the incident reserve shown
/// explicitly, skills with endorsements and single-point flags, and the working
/// pattern and preferences the scheduler respects.
class PersonScreen extends StatefulWidget {
  const PersonScreen({super.key, required this.id});

  /// Person id (path parameter, as a string).
  final String id;

  @override
  State<PersonScreen> createState() => _PersonScreenState();
}

class _PersonScreenState extends State<PersonScreen> {
  static const _tabs = ['Overview', 'Skills', 'Assignments', 'Availability', 'Preferences', 'History'];

  int _tab = 0;
  bool _loading = true;
  String? _error;
  _PersonDetail? _detail;

  int get _personId => int.tryParse(widget.id) ?? 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PersonScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) _load();
  }

  /// Captured while the element is still active: an ancestor lookup from a
  /// disposing element is not allowed, and [dispose] needs the shell.
  ShellState? _shell;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _shell = context.read<ShellState>();
  }

  @override
  void dispose() {
    // Hand the title back to the route default.
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
      final r = await Api.post('people.php', 'get', {'id': _personId});
      final d = _PersonDetail.fromJson(r);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
      });
      final shell = context.read<ShellState>();
      WidgetsBinding.instance.addPostFrameCallback((_) => shell.setPageTitle(d.person.name, breadcrumb: const ['Team & skills']));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  bool _canEdit(Session s) => s.isTeamLead || s.user?.personId == _personId;

  Future<void> _addLeave() async {
    final d = _detail;
    if (d == null) return;
    final saved = await showTmAddLeave(context, people: [(id: d.person.id, name: d.person.name)], personId: d.person.id);
    if (saved) await _load();
  }

  /// TEAM-02: the working pattern is what the scheduler books against, and it was read-only
  /// everywhere in the client until now.
  Future<void> _editPattern() async {
    final d = _detail;
    if (d == null) return;
    final hpd = context.read<WorkspaceConfig>().workspace?.hoursPerDay ?? 7.5;
    final saved = await showTmPatternDialog(context,
        personId: d.person.id, personName: d.person.name, pattern: d.person.workingPattern,
        patternLabel: d.person.patternLabel, hoursPerDay: hpd);
    if (saved) await _load();
  }

  /// TEAM-07: an imported record can be corrected but not deleted, so editing is offered on every
  /// row and deleting only on the ones this app owns.
  Future<void> _editAvailability(_AvailabilityRow a) async {
    final d = _detail;
    if (d == null) return;
    final saved = await showTmEditLeave(context,
        id: a.id, personName: d.person.name, type: a.type, from: a.from, to: a.to, fraction: a.fraction, source: a.source);
    if (saved) await _load();
  }

  Future<void> _deleteAvailability(_AvailabilityRow a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this record?'),
        content: Text('${a.label} ${fmtDateRange(a.from, a.to)} will be removed and those days handed back to the plan.'),
        actions: [
          SecondaryButton('Cancel', onPressed: () => Navigator.of(context).pop(false)),
          PrimaryButton('Remove', navy: true, onPressed: () => Navigator.of(context).pop(true)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await Api.post('people.php', 'delete_availability', {'id': a.id});
      await _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _editProfile() async {
    final d = _detail;
    if (d == null) return;
    final saved = await showDialog<bool>(context: context, builder: (context) => _EditProfileDialog(person: d.person));
    if (saved == true) await _load();
  }

  Future<void> _setLevel(_PersonSkillRow s) async {
    final level = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(s.name),
        children: [
          for (var i = 0; i <= 4; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(i),
              child: Row(children: [
                ProficiencySquare(i, size: 22),
                const SizedBox(width: Sp.md),
                Expanded(child: Text('$i · ${kProficiencyLabels[i]}', style: context.text.bodyLarge)),
                if (i == s.proficiency) const Icon(Icons.check_rounded, size: 18, color: DispatchColors.green),
              ]),
            ),
        ],
      ),
    );
    if (level == null || level == s.proficiency) return;
    try {
      await Api.post('people.php', 'set_skill', {'person_id': _personId, 'skill_id': s.skillId, 'proficiency': level});
      if (!mounted) return;
      tmToast(context, '${s.name} set to ${kProficiencyLabels[level]}');
      await _load();
    } on ApiException catch (e) {
      if (mounted) tmToast(context, e.message, bad: true);
    }
  }

  /// ADM-03. `people.php deactivate` marks the person and their user inactive,
  /// notes every future assignment as needing reassignment, raises an urgent
  /// replan trigger and deletes their capacity from today. None of that is
  /// reversible from the app, so the confirmation says how much work is
  /// affected before it happens.
  Future<void> _deactivate() async {
    final d = _detail;
    if (d == null) return;
    final n = d.assignments.length;
    final ok = await showTmConfirm(
      context,
      title: 'Deactivate ${d.person.name}?',
      message: n == 0
          ? '${d.person.firstName} has no future assignments.\n\n'
              'Deactivating marks the person and their sign-in inactive and removes their capacity from today, so the scheduler stops planning work for them. '
              'This cannot be undone from the app.'
          : '${d.person.firstName} has $n future ${n == 1 ? 'assignment' : 'assignments'} in the committed plan.\n\n'
              'Deactivating flags ${n == 1 ? 'it' : 'them'} as needing reassignment and starts an urgent replan for the people affected. '
              'It also marks the person and their sign-in inactive and removes their capacity from today, so the scheduler stops planning work for them. '
              'This cannot be undone from the app.',
      confirmLabel: 'Deactivate',
      danger: true,
    );
    if (!ok || !mounted) return;
    try {
      final r = await Api.post('people.php', 'deactivate', {'id': _personId});
      final raw = r['flagged_assignments'];
      final flagged = raw is List ? raw.length : asIntOr(raw, n);
      if (!mounted) return;
      tmToast(
        context,
        flagged == 0
            ? '${d.person.name} deactivated'
            : '${d.person.name} deactivated · $flagged future ${flagged == 1 ? 'assignment' : 'assignments'} flagged for reassignment',
      );
      await _load();
    } on ApiException catch (e) {
      if (mounted) tmToast(context, e.message, bad: true);
    }
  }

  Future<void> _endorse(_PersonSkillRow s) async {
    try {
      await Api.post('people.php', 'endorse_skill', {'person_id': _personId, 'skill_id': s.skillId});
      if (!mounted) return;
      tmToast(context, 'Endorsed ${s.name}');
      await _load();
    } on ApiException catch (e) {
      if (mounted) tmToast(context, e.message, bad: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final policy = context.watch<WorkspaceConfig>().policy;
    final d = _detail;

    return PageBody(
      onRefresh: _load,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Breadcrumb(name: d?.person.name),
        const SizedBox(height: Sp.md),
        if (_loading)
          const _PersonSkeleton()
        else if (_error != null)
          ErrorState(title: 'We could not load this person', message: _error, onRetry: _load)
        else if (d == null)
          const EmptyState(icon: Icons.person_off_outlined, title: 'Person not found', message: 'They may have been deactivated.')
        else ...[
          _Header(
            detail: d,
            canEdit: _canEdit(session),
            // ADM-03 is admin-only server-side; the control is omitted for
            // everyone else rather than shown and 403'd.
            canDeactivate: session.isAdmin && d.person.active && session.user?.personId != d.person.id,
            onAddLeave: _addLeave,
            onEditProfile: _editProfile,
            onDeactivate: _deactivate,
            onOpenSchedule: () => context.go(Routes.schedule),
          ),
          const SizedBox(height: Sp.lg),
          Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedTabs(labels: _tabs, selected: _tab, onChanged: (i) => setState(() => _tab = i)),
            ),
          ),
          const SizedBox(height: Sp.lg),
          switch (_tab) {
            1 => _SkillsTab(detail: d, canEdit: _canEdit(session), isLead: session.isTeamLead, onSetLevel: _setLevel, onEndorse: _endorse),
            2 => _AssignmentsTab(detail: d, policy: policy),
            3 => _AvailabilityTab(detail: d, policy: policy, canEdit: _canEdit(session), onAddLeave: _addLeave,
                onEditLeave: _editAvailability, onDeleteLeave: _deleteAvailability),
            4 => _PreferencesTab(detail: d, canEdit: _canEdit(session), onEditPattern: _editPattern),
            5 => _HistoryTab(detail: d),
            _ => _OverviewTab(
                detail: d,
                policy: policy,
                canEdit: _canEdit(session),
                isLead: session.isTeamLead,
                onSetLevel: _setLevel,
                onEndorse: _endorse,
              ),
          },
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
    return Row(children: [
      InkWell(
        onTap: () => context.go(Routes.team),
        borderRadius: DispatchRadius.chipR,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text('Team & skills', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
        ),
      ),
      Icon(Icons.chevron_right_rounded, size: 16, color: context.mutedColor),
      const SizedBox(width: 4),
      Text(name ?? '…', style: context.text.bodyMedium),
    ]);
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.detail,
    required this.canEdit,
    required this.canDeactivate,
    required this.onAddLeave,
    required this.onEditProfile,
    required this.onDeactivate,
    required this.onOpenSchedule,
  });
  final _PersonDetail detail;
  final bool canEdit;
  final bool canDeactivate;
  final VoidCallback onAddLeave;
  final VoidCallback onEditProfile;
  final VoidCallback onDeactivate;
  final VoidCallback onOpenSchedule;

  @override
  Widget build(BuildContext context) {
    final p = detail.person;
    final subtitle = dotJoin([
      p.roleTitle,
      p.teamName,
      '${p.daysPerWeek.toStringAsFixed(p.daysPerWeek == p.daysPerWeek.roundToDouble() ? 0 : 1)} days/week',
      p.tagline,
    ]);
    return LayoutBuilder(builder: (context, c) {
      // Flexible, not Expanded: the block has to be able to shrink-wrap so the
      // Wrap below can measure it against the width the header really has.
      final titleBlock = Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
        PersonAvatar.person(p, size: 56, outlined: !p.active),
        const SizedBox(width: Sp.lg),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Wrap(spacing: Sp.md, runSpacing: Sp.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(p.name, style: context.text.headlineLarge),
              if (!p.active) const ToneChip('Deactivated', tone: 'bad', icon: Icons.person_off_outlined),
            ]),
            const SizedBox(height: 2),
            Text(
              p.active ? subtitle : dotJoin([subtitle, 'no longer available to plan']),
              style: context.text.bodyLarge?.copyWith(color: context.mutedColor),
            ),
          ]),
        ),
      ]);
      final actions = <Widget>[
        if (canEdit && p.active) SecondaryButton('Add leave', icon: Icons.event_busy_outlined, onPressed: onAddLeave),
        if (canEdit) SecondaryButton('Edit profile', icon: Icons.edit_outlined, onPressed: onEditProfile),
        if (canDeactivate) SecondaryButton('Deactivate', icon: Icons.person_off_outlined, danger: true, onPressed: onDeactivate),
        PrimaryButton('Open in schedule', icon: Icons.calendar_month_outlined, navy: true, onPressed: onOpenSchedule),
      ];
      if (c.maxWidth < 760) {
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: c.maxWidth, child: titleBlock),
          const SizedBox(height: Sp.md),
          Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: actions),
        ]);
      }
      // A Row hands a non-flex child unbounded width, so the action row was
      // measured as if the header were infinitely wide and overflowed it once a
      // fourth button (Deactivate) appeared. A Wrap measures both halves
      // against the real width and drops the actions onto their own line when
      // the two cannot share one — the same fix PageHeader carries.
      return Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Sp.lg,
        runSpacing: Sp.md,
        children: [
          titleBlock,
          Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: actions),
        ],
      );
    });
  }
}

// ─── Overview ─────────────────────────────────────────────────────────────

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.detail,
    required this.policy,
    required this.canEdit,
    required this.isLead,
    required this.onSetLevel,
    required this.onEndorse,
  });
  final _PersonDetail detail;
  final Policy policy;
  final bool canEdit;
  final bool isLead;
  final void Function(_PersonSkillRow) onSetLevel;
  final void Function(_PersonSkillRow) onEndorse;

  @override
  Widget build(BuildContext context) {
    final s = detail.stats;
    final overTarget = (s.loadPct4w ?? 0) > s.targetLoadMax;
    // REP-04: each figure carries its own definition. StatTile has no header of
    // its own to hang TmMetricTitle on, so the tile itself opens the same
    // dialog the info icon does.
    void define(String title, String body) => showTmInfoDialog(context, title, body);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      StatRow(tiles: [
        StatTile(
          label: 'Load, next 4 weeks',
          value: s.loadPct4w == null ? '—' : '${s.loadPct4w!.round()}%',
          footnote: s.loadNote,
          tone: overTarget ? StatTone.warn : StatTone.good,
          footnoteIcon: overTarget ? Icons.warning_amber_rounded : Icons.check_rounded,
          onTap: () => define('Load, next 4 weeks', AdmMetrics.load(targetMin: s.targetLoadMin, targetMax: s.targetLoadMax)),
        ),
        StatTile(
          label: 'Concurrent items',
          value: '${s.concurrentNow}',
          unit: 'max ${s.concurrentMax}',
          footnote: s.concurrentNote,
          tone: s.concurrentNow >= s.concurrentMax ? StatTone.warn : StatTone.neutral,
          onTap: () => define('Concurrent items', AdmMetrics.concurrentItems),
        ),
        StatTile(
          label: 'Changes to plan, last 8 weeks',
          value: '${s.changes8w}',
          footnote: s.changesNote,
          tone: s.changes8w <= s.teamMedianChanges8w ? StatTone.good : StatTone.warn,
          footnoteIcon: s.changes8w <= s.teamMedianChanges8w ? Icons.south_east_rounded : Icons.north_east_rounded,
          onTap: () => define('Changes to plan, last 8 weeks', '${AdmMetrics.personChanges}\n\n${AdmMetrics.stabilityIndex}'),
        ),
        StatTile(
          label: 'Incident rota',
          value: s.nextRotaLabel ?? 'Not on rota',
          footnote: s.nextRotaNote,
          tone: StatTone.neutral,
          footnoteIcon: Icons.shield_outlined,
          onTap: () => define(
            'Incident rota',
            AdmMetrics.incidentRota(incidentReservePct: policy.incidentReservePct, rotaReservePct: policy.rotaReservePct),
          ),
        ),
      ]),
      const SizedBox(height: Sp.sm),
      Text('Select a figure for how it is measured.', style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
      const SizedBox(height: Sp.md),
      LayoutBuilder(builder: (context, c) {
        final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _AssignmentsPanel(detail: detail, policy: policy, limit: 4),
          const SizedBox(height: Sp.lg),
          _ChangesPanel(detail: detail),
        ]);
        final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _SkillsPanel(detail: detail, canEdit: canEdit, isLead: isLead, onSetLevel: onSetLevel, onEndorse: onEndorse),
          const SizedBox(height: Sp.lg),
          _LoansPanel(detail: detail),
          const SizedBox(height: Sp.lg),
          _PatternPanel(detail: detail),
        ]);
        if (c.maxWidth < 1000) {
          return Column(children: [left, const SizedBox(height: Sp.lg), right]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 3, child: left),
          const SizedBox(width: Sp.lg),
          Expanded(flex: 2, child: right),
        ]);
      }),
    ]);
  }
}

class _AssignmentsPanel extends StatelessWidget {
  const _AssignmentsPanel({required this.detail, required this.policy, this.limit});
  final _PersonDetail detail;
  final Policy policy;
  final int? limit;

  @override
  Widget build(BuildContext context) {
    final all = detail.assignments;
    final shown = limit == null ? all : all.take(limit!).toList();
    return TmMetricPanel(
      title: 'Current and upcoming assignments',
      definition: AdmMetrics.incidentReserve(incidentReservePct: policy.incidentReservePct, rotaReservePct: policy.rotaReservePct),
      trailing: (limit != null && all.length > limit!) ? Text('${all.length} in total', style: context.text.bodySmall?.copyWith(color: context.mutedColor)) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (shown.isEmpty)
          const EmptyState(
            icon: Icons.event_note_outlined,
            title: 'Nothing scheduled',
            message: 'This person has no committed or planned work from today.',
            compact: true,
          )
        else
          for (final a in shown) _AssignmentRow(assignment: a),
        const SizedBox(height: Sp.sm),
        _ReserveRow(note: detail.stats.reserveNote ?? ''),
      ]),
    );
  }
}

class _AssignmentRow extends StatelessWidget {
  const _AssignmentRow({required this.assignment});
  final _PersonAssignment assignment;

  ({String? status, String? label}) _statusFor(_PersonAssignment a) {
    if (a.health == 'at_risk') {
      return (status: 'at_risk', label: a.riskReason == null ? 'At risk' : 'At risk · ${a.riskReason}');
    }
    if (a.itemStatus == 'in_progress') return (status: a.health ?? 'in_progress', label: null);
    return (status: a.state, label: null);
  }

  @override
  Widget build(BuildContext context) {
    final a = assignment;
    final st = _statusFor(a);
    return InkWell(
      onTap: a.ref == null ? null : () => context.go(Routes.item(a.ref!)),
      borderRadius: DispatchRadius.cardR,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizeStamp(a.sizeStamp, size: 26),
          const SizedBox(width: Sp.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(dotJoin([a.ref, a.title]), style: context.text.titleSmall),
              const SizedBox(height: 2),
              Text(
                dotJoin([
                  a.typeName,
                  '${a.allocationPct.round()}%',
                  a.from != null && a.to != null && a.from!.month == a.to!.month && a.from!.day == a.to!.day
                      ? 'on ${fmtShortDate(a.from)}'
                      : (a.from != null && a.from!.isAfter(DateTime.now()) ? fmtDateRange(a.from, a.to) : 'to ${fmtShortDate(a.to)}'),
                  if (a.withNames.isNotEmpty) 'with ${a.withNames.join(', ')}',
                ]),
                style: context.text.bodySmall?.copyWith(color: context.mutedColor),
              ),
            ]),
          ),
          const SizedBox(width: Sp.md),
          StatusChip(st.status, label: st.label),
        ]),
      ),
    );
  }
}

class _ReserveRow extends StatelessWidget {
  const _ReserveRow({required this.note});
  final String note;

  @override
  Widget build(BuildContext context) {
    return DashedBox(
      child: Padding(
        padding: const EdgeInsets.all(Sp.md),
        child: Row(children: [
          SizeStamp('?', size: 26, dashed: true),
          const SizedBox(width: Sp.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('Incident reserve', style: context.text.titleSmall),
              const SizedBox(height: 2),
              Text(note, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
            ]),
          ),
          const SizedBox(width: Sp.md),
          const ToneChip('Reserve'),
        ]),
      ),
    );
  }
}

class _ChangesPanel extends StatelessWidget {
  const _ChangesPanel({required this.detail});
  final _PersonDetail detail;

  @override
  Widget build(BuildContext context) {
    final h = detail.changeHistory;
    return TmMetricPanel(
      title: 'Plan changes affecting ${detail.person.firstName}',
      subtitle: 'Last 8 weeks',
      definition: '${AdmMetrics.personChanges}\n\n${AdmMetrics.stabilityIndex}',
      child: h.isEmpty
          ? const EmptyState(icon: Icons.timeline_outlined, title: 'No changes recorded', message: 'Their plan has not moved in the last eight weeks.', compact: true)
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TmGroupedBarChart(
                height: 110,
                barWidth: 30,
                maxValue: h.fold<double>(1, (a, w) => a > w.changes ? a : w.changes.toDouble()),
                groups: [
                  for (final w in h)
                    TmBarGroup(
                      w.label,
                      [
                        TmBar(
                          w.changes.toDouble(),
                          w.insideFreeze > 0 ? DispatchColors.red : DispatchColors.orange,
                          tooltip: '${w.label}: ${w.changes} ${w.changes == 1 ? 'change' : 'changes'}'
                              '${w.insideFreeze > 0 ? ', ${w.insideFreeze} inside the freeze horizon' : ''}',
                        ),
                      ],
                      flag: w.insideFreeze > 0 ? '!' : null,
                    ),
                ],
              ),
              const SizedBox(height: Sp.md),
              Text(detail.stabilityNote, style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
            ]),
    );
  }
}

class _SkillsPanel extends StatelessWidget {
  const _SkillsPanel({required this.detail, required this.canEdit, required this.isLead, required this.onSetLevel, required this.onEndorse});
  final _PersonDetail detail;
  final bool canEdit;
  final bool isLead;
  final void Function(_PersonSkillRow) onSetLevel;
  final void Function(_PersonSkillRow) onEndorse;

  @override
  Widget build(BuildContext context) {
    final skills = detail.skills.where((s) => s.proficiency > 0).toList()..sort((a, b) => b.proficiency.compareTo(a.proficiency));
    return TmMetricPanel(
      title: 'Skills',
      definition: '${AdmMetrics.coverage}\n\n${AdmMetrics.development}',
      trailing: canEdit ? SecondaryButton('Add', icon: Icons.add_rounded, onPressed: () => _addSkill(context)) : null,
      child: skills.isEmpty
          ? const EmptyState(icon: Icons.psychology_outlined, title: 'No skills recorded', message: 'Add a skill so the scheduler can match work.', compact: true)
          : Column(children: [
              for (var i = 0; i < skills.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _SkillRowTile(skill: skills[i], canEdit: canEdit, isLead: isLead, onSetLevel: onSetLevel, onEndorse: onEndorse),
              ],
            ]),
    );
  }

  void _addSkill(BuildContext context) {
    final missing = detail.skills.where((s) => s.proficiency == 0).toList();
    if (missing.isEmpty) {
      tmToast(context, 'Every tracked skill already has a level');
      return;
    }
    showDialog<void>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Add a skill'),
        children: [
          for (final s in missing)
            SimpleDialogOption(
              onPressed: () {
                Navigator.of(context).pop();
                onSetLevel(s);
              },
              child: Text(s.name, style: context.text.bodyLarge),
            ),
        ],
      ),
    );
  }
}

class _SkillRowTile extends StatelessWidget {
  const _SkillRowTile({required this.skill, required this.canEdit, required this.isLead, required this.onSetLevel, required this.onEndorse});
  final _PersonSkillRow skill;
  final bool canEdit;
  final bool isLead;
  final void Function(_PersonSkillRow) onSetLevel;
  final void Function(_PersonSkillRow) onEndorse;

  @override
  Widget build(BuildContext context) {
    final s = skill;
    final sub = dotJoin([
      s.levelName ?? kProficiencyLabels[s.proficiency.clamp(0, 4)],
      if (s.endorsedBy.isNotEmpty) 'endorsed by ${s.endorsedBy.length}',
      if (s.certified) 'certified',
      if (s.developmentTarget != null) 'growing to L${s.developmentTarget}',
    ]);
    return InkWell(
      onTap: canEdit ? () => onSetLevel(s) : null,
      borderRadius: DispatchRadius.cardR,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.md),
        child: Row(children: [
          Tooltip(
            message: 'Level ${s.proficiency} · ${kProficiencyLabels[s.proficiency.clamp(0, 4)]}',
            child: Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: ProficiencySquare.fillFor(s.proficiency), borderRadius: BorderRadius.circular(6)),
              child: Text(
                '${s.proficiency}',
                style: DispatchTheme.numeric(size: 13, weight: FontWeight.w800, color: s.proficiency >= 3 ? Colors.white : DispatchColors.ink),
              ),
            ),
          ),
          const SizedBox(width: Sp.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(s.name, style: context.text.titleSmall),
              Text(sub, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
            ]),
          ),
          if (s.singlePoint) ...[
            const SizedBox(width: Sp.sm),
            const ToneChip('Single point', tone: 'warn', compact: true),
          ],
          if (isLead) ...[
            const SizedBox(width: 4),
            IconButton(
              onPressed: () => onEndorse(s),
              icon: const Icon(Icons.verified_outlined, size: 17),
              tooltip: 'Endorse ${s.name}',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ]),
      ),
    );
  }
}

/// TEAM-09: where this person has been lent, or is about to be. `people.php get`
/// returns loans from 90 days back to the horizon and the one moving them today.
class _LoansPanel extends StatelessWidget {
  const _LoansPanel({required this.detail});
  final _PersonDetail detail;

  @override
  Widget build(BuildContext context) {
    final p = detail.person;
    // `people.php get` sends no clock; the browser's date only decides which
    // state chip a loan gets, so it is close enough here.
    final today = DateTime.now();
    final loans = [...p.loans];
    if (p.onLoanTo != null && !loans.any((l) => l.id == p.onLoanTo!.id)) loans.insert(0, p.onLoanTo!);
    loans.sort((a, b) => b.fromDate.compareTo(a.fromDate));
    final current = p.onLoanTo;
    return TmMetricPanel(
      title: 'Loans',
      subtitle: current != null
          ? 'With ${current.toTeamName ?? 'another team'} until ${fmtDayMonth(current.toDate)} at ${current.allocationPct}%'
          : (loans.isEmpty ? null : 'Last 90 days to the planning horizon'),
      definition: PfMetrics.loans,
      child: loans.isEmpty
          ? EmptyState(
              icon: Icons.swap_horiz_rounded,
              title: 'No loans',
              message: '${p.firstName} has not been lent to another team in the last 90 days, and none is planned.',
              compact: true,
            )
          : TmLoanList(loans: loans, today: today, showPerson: false, dense: true),
    );
  }
}

class _PatternPanel extends StatelessWidget {
  const _PatternPanel({required this.detail});
  final _PersonDetail detail;

  @override
  Widget build(BuildContext context) {
    final p = detail.person;
    return Panel(
      title: 'Working pattern and preferences',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TmKeyValue('Hours', detail.patternHoursLabel ?? p.patternLabel),
        TmKeyValue('Max concurrent', detail.patternMaxConcurrentLabel),
        TmKeyValue('Focus blocks', detail.patternFocusLabel),
        TmKeyValue('Prefers', p.prefers),
        TmKeyValue('Avoid', p.avoid),
        TmKeyValue('Line manager', p.lineManager),
      ]),
    );
  }
}

// ─── Other tabs ───────────────────────────────────────────────────────────

class _SkillsTab extends StatelessWidget {
  const _SkillsTab({required this.detail, required this.canEdit, required this.isLead, required this.onSetLevel, required this.onEndorse});
  final _PersonDetail detail;
  final bool canEdit;
  final bool isLead;
  final void Function(_PersonSkillRow) onSetLevel;
  final void Function(_PersonSkillRow) onEndorse;

  @override
  Widget build(BuildContext context) {
    final byCategory = <String, List<_PersonSkillRow>>{};
    for (final s in detail.skills) {
      byCategory.putIfAbsent(s.category ?? 'Other', () => []).add(s);
    }
    final categories = byCategory.keys.toList()..sort();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final c in categories) ...[
        Panel(
          title: c,
          subtitle: '${byCategory[c]!.length} skills',
          child: Column(children: [
            for (var i = 0; i < byCategory[c]!.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              _SkillRowTile(skill: byCategory[c]![i], canEdit: canEdit, isLead: isLead, onSetLevel: onSetLevel, onEndorse: onEndorse),
            ],
          ]),
        ),
        const SizedBox(height: Sp.lg),
      ],
    ]);
  }
}

class _AssignmentsTab extends StatelessWidget {
  const _AssignmentsTab({required this.detail, required this.policy});
  final _PersonDetail detail;
  final Policy policy;

  @override
  Widget build(BuildContext context) => _AssignmentsPanel(detail: detail, policy: policy);
}

class _AvailabilityTab extends StatelessWidget {
  const _AvailabilityTab({
    required this.detail,
    required this.policy,
    required this.canEdit,
    required this.onAddLeave,
    required this.onEditLeave,
    required this.onDeleteLeave,
  });
  final _PersonDetail detail;
  final Policy policy;
  final bool canEdit;
  final VoidCallback onAddLeave;
  final void Function(_AvailabilityRow) onEditLeave;
  final void Function(_AvailabilityRow) onDeleteLeave;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (detail.leave != null) ...[
        _LeavePanel(balance: detail.leave!),
        const SizedBox(height: Sp.lg),
      ],
      TmMetricPanel(
        title: 'Availability',
        subtitle: 'Leave, training and sickness — only the type is stored',
        definition: AdmMetrics.availability,
        trailing: canEdit ? SecondaryButton('Add leave', icon: Icons.event_busy_outlined, onPressed: onAddLeave) : null,
        child: detail.availability.isEmpty
            ? const EmptyState(icon: Icons.event_available_outlined, title: 'No absence recorded', message: 'Nothing booked in the last 90 days or ahead.', compact: true)
            : Column(children: [
                for (final a in detail.availability)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Sp.sm),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Text(a.label, style: context.text.titleSmall),
                          Text(dotJoin([fmtDateRange(a.from, a.to), a.fraction < 1 ? 'half days' : null, 'source: ${a.source}']),
                              style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
                        ]),
                      ),
                      ToneChip(humanise(a.type), compact: true),
                      if (canEdit) ...[
                        IconButton(
                          tooltip: a.source == 'manual' ? 'Correct these dates' : 'Correct this imported record',
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          onPressed: () => onEditLeave(a),
                        ),
                        // TEAM-07: an imported record can be corrected but never deleted here.
                        IconButton(
                          tooltip: a.source == 'manual' ? 'Remove this record' : 'Came from ${a.source}: correct it, do not delete it',
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: a.source == 'manual' ? () => onDeleteLeave(a) : null,
                        ),
                      ],
                    ]),
                  ),
              ]),
      ),
      const SizedBox(height: Sp.lg),
      TmMetricPanel(
        title: 'Incident rota',
        subtitle: detail.stats.nextRotaNote,
        definition: AdmMetrics.incidentRota(incidentReservePct: policy.incidentReservePct, rotaReservePct: policy.rotaReservePct),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (detail.rota.isEmpty)
            const EmptyState(icon: Icons.shield_outlined, title: 'Not on the rota', message: 'No rota weeks scheduled for this person.', compact: true)
          else ...[
            Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [for (final w in detail.rota) ToneChip(fmtWeekCommencing(w), tone: 'bad')]),
            const SizedBox(height: Sp.sm),
            Text(
              'Their incident reserve rises to ${policy.rotaReservePct.round()}% in each of these weeks, so they can take less planned work.',
              style: context.text.bodySmall?.copyWith(color: context.mutedColor),
            ),
          ],
          const SizedBox(height: Sp.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: SecondaryButton(
              'Manage the rota',
              icon: Icons.shield_outlined,
              onPressed: () => context.go(Routes.team),
            ),
          ),
        ]),
      ),
    ]);
  }
}

/// Annual leave: what this person is entitled to, what they have booked and what is left.
///
/// Days are counted in their own working days, so a Mon-Thu worker booking a full week spends
/// four, and a bank holiday inside a booking costs nobody anything. It is a planning figure and
/// the card says so: Dispatch is not the system of record for leave.
class _LeavePanel extends StatelessWidget {
  const _LeavePanel({required this.balance});
  final _LeaveBalance balance;

  @override
  Widget build(BuildContext context) {
    final b = balance;
    final over = b.remainingDays < 0;
    return Panel(
      title: 'Annual leave',
      subtitle: b.from == null ? null : 'Leave year ${fmtDayMonth(b.from)} to ${fmtDayMonth(b.to)}',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: Sp.xl, runSpacing: Sp.md, children: [
          _stat(context, 'Entitlement', fmtDays(b.entitlementDays), b.source == 'person' ? 'Set for this person' : 'Workspace default'),
          _stat(context, 'Booked', fmtDays(b.bookedDays), '${fmtDays(b.takenDays)} taken · ${fmtDays(b.upcomingDays)} ahead'),
          _stat(context, 'Remaining', fmtDays(b.remainingDays), over ? 'More booked than the entitlement' : 'Left this leave year',
              tone: over ? DispatchColors.red : null),
        ]),
        const SizedBox(height: Sp.md),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: b.usedFraction,
            minHeight: 8,
            backgroundColor: context.borderColor,
            valueColor: AlwaysStoppedAnimation<Color>(over ? DispatchColors.red : DispatchColors.orange),
          ),
        ),
        if (b.note != null) ...[
          const SizedBox(height: Sp.md),
          Text(b.note!, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
        ],
      ]),
    );
  }

  Widget _stat(BuildContext context, String label, String value, String sub, {Color? tone}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
          Text(value, style: context.text.headlineSmall?.copyWith(color: tone)),
          Text(sub, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
        ],
      );
}

class _PreferencesTab extends StatelessWidget {
  const _PreferencesTab({required this.detail, this.canEdit = false, this.onEditPattern});
  final _PersonDetail detail;
  final bool canEdit;
  final VoidCallback? onEditPattern;

  @override
  Widget build(BuildContext context) {
    final p = detail.person;
    // Every weekday somebody could work, not just Monday to Friday: a pattern may give hours to a
    // Saturday, and capacity is derived for any day it does.
    final days = [...kWeekdays.take(5), for (final d in kWeekdays.skip(5)) if ((p.workingPattern[d] ?? 0) > 0) d];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        title: 'Working pattern',
        subtitle: 'The scheduler never books beyond these hours',
        trailing: canEdit && onEditPattern != null
            ? SecondaryButton('Edit pattern', icon: Icons.edit_calendar_outlined, onPressed: onEditPattern)
            : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: Sp.md, runSpacing: Sp.md, children: [
            for (final d in days)
              Container(
                width: 92,
                padding: const EdgeInsets.symmetric(vertical: Sp.md),
                decoration: BoxDecoration(
                  color: (p.workingPattern[d] ?? 0) > 0 ? DispatchColors.tint(DispatchColors.typeBlue, opacity: context.isDark ? 0.2 : 0.08) : Colors.transparent,
                  borderRadius: DispatchRadius.cardR,
                  border: Border.all(color: context.borderColor),
                ),
                child: Column(children: [
                  Text(d, style: context.text.labelLarge),
                  const SizedBox(height: 4),
                  Text(
                    (p.workingPattern[d] ?? 0) > 0 ? '${p.workingPattern[d]!.toStringAsFixed(p.workingPattern[d]! % 1 == 0 ? 0 : 2)} h' : 'Not working',
                    style: context.text.bodySmall?.copyWith(color: context.mutedColor),
                  ),
                ]),
              ),
          ]),
          const SizedBox(height: Sp.lg),
          TmKeyValue('Hours', detail.patternHoursLabel ?? p.patternLabel),
          TmKeyValue('Days per week', p.daysPerWeek.toStringAsFixed(1)),
          if (detail.leave != null)
            TmKeyValue('Annual leave', '${fmtDays(detail.leave!.entitlementDays)} a year'
                '${detail.leave!.source == 'workspace' ? ' (workspace default)' : ''}'),
        ]),
      ),
      const SizedBox(height: Sp.lg),
      Panel(
        title: 'Preferences the scheduler respects',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TmKeyValue('Max concurrent', detail.patternMaxConcurrentLabel),
          TmKeyValue('Focus blocks', detail.patternFocusLabel),
          TmKeyValue('Prefers', p.prefers),
          TmKeyValue('Avoid', p.avoid),
          TmKeyValue('Line manager', p.lineManager),
          TmKeyValue('Email', p.email),
        ]),
      ),
    ]);
  }
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab({required this.detail});
  final _PersonDetail detail;

  @override
  Widget build(BuildContext context) {
    final h = detail.changeHistory;
    return TmMetricPanel(
      title: 'Plan changes by week',
      subtitle: 'Last 8 weeks · team median ${detail.stats.teamMedianChanges8w}',
      definition: '${AdmMetrics.personChanges}\n\n${AdmMetrics.stabilityIndex}',
      padding: EdgeInsets.zero,
      dividerAfterHeader: true,
      child: h.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(Sp.lg),
              child: EmptyState(icon: Icons.history_rounded, title: 'No history yet', message: 'Nothing has moved in their plan.', compact: true),
            )
          : TmTable(
              columns: const [
                TmCol('Week'),
                TmCol('Changes', width: 100, align: TextAlign.right),
                TmCol('Inside freeze horizon', width: 170, align: TextAlign.right),
                TmCol('Assignment-days moved', width: 190, align: TextAlign.right),
              ],
              rows: [
                for (final w in h)
                  [
                    Text(dotJoin([w.label, w.weekStart == null ? null : fmtWeekCommencing(w.weekStart!)]), style: context.text.bodyMedium),
                    Text('${w.changes}', style: DispatchTheme.numeric(size: 13.5, color: context.inkColor)),
                    Row(mainAxisAlignment: MainAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                      if (w.insideFreeze > 0) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.lock_outline_rounded, size: 14, color: DispatchColors.red)),
                      Text('${w.insideFreeze}',
                          style: DispatchTheme.numeric(size: 13.5, color: w.insideFreeze > 0 ? DispatchColors.red : context.inkColor)),
                    ]),
                    Text(fmtDays(w.assignmentDays), style: DispatchTheme.numeric(size: 13.5, color: context.inkColor)),
                  ],
              ],
            ),
    );
  }
}

// ─── Edit profile ─────────────────────────────────────────────────────────

class _EditProfileDialog extends StatefulWidget {
  const _EditProfileDialog({required this.person});
  final Person person;

  @override
  State<_EditProfileDialog> createState() => _EditProfileDialogState();
}

class _EditProfileDialogState extends State<_EditProfileDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.person.name);
  late final TextEditingController _roleTitle = TextEditingController(text: widget.person.roleTitle);
  late final TextEditingController _tagline = TextEditingController(text: widget.person.tagline);
  late final TextEditingController _prefers = TextEditingController(text: widget.person.prefers);
  late final TextEditingController _avoid = TextEditingController(text: widget.person.avoid);
  late final TextEditingController _days = TextEditingController(text: widget.person.daysPerWeek.toStringAsFixed(1));
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _roleTitle.dispose();
    _tagline.dispose();
    _prefers.dispose();
    _avoid.dispose();
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
        'id': widget.person.id,
        'name': _name.text.trim(),
        'role_title': _roleTitle.text.trim(),
        'tagline': _tagline.text.trim(),
        'prefers': _prefers.text.trim(),
        'avoid': _avoid.text.trim(),
        'days_per_week': double.tryParse(_days.text.trim()) ?? widget.person.daysPerWeek,
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
      title: Text('Edit ${widget.person.firstName}’s profile'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TmField(label: 'Name', child: TextField(controller: _name)),
            const SizedBox(height: Sp.md),
            TmField(label: 'Role title', child: TextField(controller: _roleTitle)),
            const SizedBox(height: Sp.md),
            TmField(label: 'Tagline', child: TextField(controller: _tagline)),
            const SizedBox(height: Sp.md),
            TmField(label: 'Days per week', child: TextField(controller: _days, keyboardType: TextInputType.number)),
            const SizedBox(height: Sp.md),
            TmField(label: 'Prefers', child: TextField(controller: _prefers)),
            const SizedBox(height: Sp.md),
            TmField(label: 'Avoid', child: TextField(controller: _avoid)),
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

// ─── Skeleton ─────────────────────────────────────────────────────────────

class _PersonSkeleton extends StatelessWidget {
  const _PersonSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: const [
        Skeleton.circle(size: 56),
        SizedBox(width: Sp.lg),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Skeleton(width: 220, height: 26), SizedBox(height: 8), Skeleton(width: 360)])),
      ]),
      const SizedBox(height: Sp.xl),
      const SkeletonPanel(rows: 2),
      const SizedBox(height: Sp.lg),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: const [
        Expanded(flex: 3, child: SkeletonPanel(rows: 4)),
        SizedBox(width: Sp.lg),
        Expanded(flex: 2, child: SkeletonPanel(rows: 5)),
      ]),
    ]);
  }
}

// ─── Parsing (people.php get) ─────────────────────────────────────────────

class _PersonStats {
  const _PersonStats({
    this.loadPct4w,
    this.loadNote,
    this.targetLoadMin = 80,
    this.targetLoadMax = 90,
    this.concurrentNow = 0,
    this.concurrentMax = 2,
    this.concurrentNote,
    this.changes8w = 0,
    this.changesInsideFreeze8w = 0,
    this.teamMedianChanges8w = 0,
    this.changesNote,
    this.nextRotaLabel,
    this.nextRotaNote,
    this.reserveNote,
  });

  final double? loadPct4w;
  final String? loadNote;
  final double targetLoadMin;
  final double targetLoadMax;
  final int concurrentNow;
  final int concurrentMax;
  final String? concurrentNote;
  final int changes8w;
  final int changesInsideFreeze8w;
  final double teamMedianChanges8w;
  final String? changesNote;
  final String? nextRotaLabel;
  final String? nextRotaNote;
  final String? reserveNote;

  factory _PersonStats.fromJson(Map<String, dynamic> j) => _PersonStats(
        loadPct4w: asDouble(j['load_pct_4w']),
        loadNote: asStr(j['load_note']),
        targetLoadMin: asDoubleOr(j['target_load_min'], 80),
        targetLoadMax: asDoubleOr(j['target_load_max'], 90),
        concurrentNow: asIntOr(j['concurrent_now'], 0),
        concurrentMax: asIntOr(j['concurrent_max'], 2),
        concurrentNote: asStr(j['concurrent_note']),
        changes8w: asIntOr(j['changes_8w'], 0),
        changesInsideFreeze8w: asIntOr(j['changes_inside_freeze_8w'], 0),
        teamMedianChanges8w: asDoubleOr(j['team_median_changes_8w'], 0),
        changesNote: asStr(j['changes_note']),
        nextRotaLabel: asStr(j['next_rota_label']),
        nextRotaNote: asStr(j['next_rota_note']),
        reserveNote: asStr(j['reserve_note']),
      );
}

class _PersonAssignment {
  const _PersonAssignment({
    required this.id,
    this.ref,
    this.title,
    this.typeName,
    this.typeColour,
    this.sizeStamp,
    this.from,
    this.to,
    this.allocationPct = 100,
    this.state,
    this.itemStatus,
    this.health,
    this.riskReason,
    this.isReserve = false,
    this.withNames = const [],
  });

  final int id;
  final String? ref;
  final String? title;
  final String? typeName;
  final String? typeColour;
  final String? sizeStamp;
  final DateTime? from;
  final DateTime? to;
  final double allocationPct;
  final String? state;
  final String? itemStatus;
  final String? health;
  final String? riskReason;
  final bool isReserve;
  final List<String> withNames;

  factory _PersonAssignment.fromJson(Map<String, dynamic> j) => _PersonAssignment(
        id: asIntOr(j['id'], 0),
        ref: asStr(j['ref']),
        title: asStr(j['title']),
        typeName: asStr(j['type_name']),
        typeColour: asStr(j['type_colour']),
        sizeStamp: asStr(j['size_stamp']),
        from: asDate(j['from_date']),
        to: asDate(j['to_date']),
        allocationPct: asDoubleOr(j['allocation_pct'], 100),
        state: asStr(j['state']),
        itemStatus: asStr(j['item_status']),
        health: asStr(j['health']),
        riskReason: asStr(j['risk_reason'] ?? j['health_reason']),
        isReserve: asBool(j['is_reserve']),
        withNames: asStrList(j['with']),
      );
}

class _PersonSkillRow {
  const _PersonSkillRow({
    required this.skillId,
    required this.name,
    this.category,
    this.proficiency = 0,
    this.levelName,
    this.endorsedBy = const [],
    this.certified = false,
    this.developmentTarget,
    this.pairingEnabled = false,
    this.singlePoint = false,
  });

  final int skillId;
  final String name;
  final String? category;
  final int proficiency;
  final String? levelName;
  final List<String> endorsedBy;
  final bool certified;
  final int? developmentTarget;
  final bool pairingEnabled;
  final bool singlePoint;

  factory _PersonSkillRow.fromJson(Map<String, dynamic> j) => _PersonSkillRow(
        skillId: asIntOr(j['skill_id'], 0),
        name: asStrOr(j['name'], ''),
        category: asStr(j['category']),
        proficiency: asIntOr(j['proficiency'], 0),
        levelName: asStr(j['level_name']),
        endorsedBy: asStrList(j['endorsed_by']),
        certified: asBool(j['certified']),
        developmentTarget: asInt(j['development_target']),
        pairingEnabled: asBool(j['pairing_enabled']),
        singlePoint: asBool(j['single_point']),
      );
}

class _AvailabilityRow {
  const _AvailabilityRow({required this.id, required this.type, required this.label, this.from, this.to, this.fraction = 1, this.source = 'manual'});
  final int id;
  final String type;
  final String label;
  final DateTime? from;
  final DateTime? to;
  final double fraction;
  final String source;

  factory _AvailabilityRow.fromJson(Map<String, dynamic> j) => _AvailabilityRow(
        id: asIntOr(j['id'], 0),
        type: asStrOr(j['type'], 'leave'),
        label: asStrOr(j['label'], ''),
        from: asDate(j['from_date']),
        to: asDate(j['to_date']),
        fraction: asDoubleOr(j['fraction'], 1),
        source: asStrOr(j['source'], 'manual'),
      );
}

/// The leave year, what is booked in it and what is left (TEAM-06).
///
/// Days are the person's own: a Mon-Thu worker booking Mon-Fri spends four, and a bank holiday
/// inside the range costs nobody anything. Informational — Dispatch is not the system of record
/// for leave, and the copy on the card says so.
class _LeaveBalance {
  const _LeaveBalance({
    required this.entitlementDays,
    required this.bookedDays,
    required this.remainingDays,
    required this.takenDays,
    required this.upcomingDays,
    this.from,
    this.to,
    this.source = 'workspace',
    this.note,
  });
  final double entitlementDays;
  final double bookedDays;
  final double remainingDays;
  final double takenDays;
  final double upcomingDays;
  final DateTime? from;
  final DateTime? to;
  final String source;
  final String? note;

  double get usedFraction => entitlementDays > 0 ? (bookedDays / entitlementDays).clamp(0, 1).toDouble() : 0;

  factory _LeaveBalance.fromJson(Map<String, dynamic> j) => _LeaveBalance(
        entitlementDays: asDoubleOr(j['entitlement_days'], 0),
        bookedDays: asDoubleOr(j['booked_days'], 0),
        remainingDays: asDoubleOr(j['remaining_days'], 0),
        takenDays: asDoubleOr(j['taken_days'], 0),
        upcomingDays: asDoubleOr(j['upcoming_days'], 0),
        from: asDate(j['leave_year_from']),
        to: asDate(j['leave_year_to']),
        source: asStrOr(j['entitlement_source'], 'workspace'),
        note: asStr(j['note']),
      );
}

class _ChangeWeek {
  const _ChangeWeek({required this.label, this.weekStart, this.changes = 0, this.insideFreeze = 0, this.assignmentDays = 0});
  final String label;
  final DateTime? weekStart;
  final int changes;
  final int insideFreeze;
  final double assignmentDays;

  factory _ChangeWeek.fromJson(Map<String, dynamic> j) => _ChangeWeek(
        label: asStrOr(j['label'], ''),
        weekStart: asDate(j['week_start']),
        changes: asIntOr(j['changes'], 0),
        insideFreeze: asIntOr(j['inside_freeze'], 0),
        assignmentDays: asDoubleOr(j['assignment_days'], 0),
      );
}

class _PersonDetail {
  const _PersonDetail({
    required this.person,
    required this.skills,
    required this.assignments,
    required this.availability,
    required this.rota,
    required this.stats,
    required this.changeHistory,
    required this.stabilityNote,
    this.patternHoursLabel,
    this.patternMaxConcurrentLabel,
    this.patternFocusLabel,
    this.leave,
  });

  final Person person;
  final List<_PersonSkillRow> skills;
  final List<_PersonAssignment> assignments;
  final List<_AvailabilityRow> availability;
  final List<DateTime> rota;
  final _PersonStats stats;
  final List<_ChangeWeek> changeHistory;
  final String stabilityNote;
  final String? patternHoursLabel;
  final String? patternMaxConcurrentLabel;
  final String? patternFocusLabel;
  final _LeaveBalance? leave;

  factory _PersonDetail.fromJson(Map<String, dynamic> j) {
    final pattern = asMap(j['pattern']);
    return _PersonDetail(
      person: Person.fromJson(asMap(j['person'])),
      skills: asList(j['skills'], _PersonSkillRow.fromJson),
      assignments: asList(j['assignments'], _PersonAssignment.fromJson),
      availability: asList(j['availability'], _AvailabilityRow.fromJson),
      rota: (j['rota'] as List? ?? const []).map((e) => asDate(e)).whereType<DateTime>().toList(),
      stats: _PersonStats.fromJson(asMap(j['stats'])),
      changeHistory: asList(j['change_history'], _ChangeWeek.fromJson),
      stabilityNote: asStrOr(j['stability_note'], ''),
      patternHoursLabel: asStr(pattern['hours_label']),
      patternMaxConcurrentLabel: asStr(pattern['max_concurrent_label']),
      patternFocusLabel: asStr(pattern['focus_label']),
      leave: j['leave'] is Map ? _LeaveBalance.fromJson(asMap(j['leave'])) : null,
    );
  }
}

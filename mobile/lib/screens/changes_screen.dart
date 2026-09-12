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
import '../widgets/schedule_widgets.dart';
import '../widgets/widgets.dart';
import 'parts/sch_change_card.dart';
import 'parts/sch_models.dart';

/// Proposed changes — review the open proposal change by change (CHG-01..08,
/// STAB-02..04). A delivery lead accepts, rejects or edits; everyone else sees
/// the changes affecting them, with an acknowledgement.
class ChangesScreen extends StatefulWidget {
  const ChangesScreen({super.key});

  @override
  State<ChangesScreen> createState() => _ChangesScreenState();
}

class _ChangesScreenState extends State<ChangesScreen> {
  ChangesData? _data;
  List<SchChange> _mine = const [];
  List<SchProposal> _past = const [];
  bool _loading = true;
  bool _busy = false;
  bool _showPast = false;
  String? _error;
  final Set<int> _selected = {};

  bool get _canReview => context.read<Session>().isDeliveryLead;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final review = _canReview;
      final raw = await Api.post('changes.php', review ? 'current' : 'mine');
      if (!mounted) return;
      if (review) {
        final data = ChangesData.fromJson(raw);
        setState(() {
          _data = data;
          _loading = false;
          _error = null;
          _selected
            ..clear()
            ..addAll(data.changes.where((c) => c.selectable).map((c) => c.id));
        });
      } else {
        setState(() {
          _mine = asList(raw['changes'], SchChange.fromJson);
          _loading = false;
          _error = null;
        });
      }
      if (mounted) context.read<ShellState>().refreshCounts();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _loadPast() async {
    if (_past.isNotEmpty) return;
    try {
      final r = await Api.post('changes.php', 'list', {'limit': 12});
      if (!mounted) return;
      setState(() => _past = asList(r['proposals'], SchProposal.fromJson));
    } catch (_) {/* the panel simply stays empty */}
  }

  // ---------------------------------------------------------------------------
  // Decisions
  // ---------------------------------------------------------------------------

  Future<void> _decide(SchChange c, String decision) async {
    final session = context.read<Session>();
    String? reason;
    if (decision == 'accepted' && c.isHeld) {
      if (!session.isAdmin) {
        _snack(c.guardrailReason ?? 'This change is held by a guardrail and needs an administrator override.', error: true);
        return;
      }
      reason = await schReasonDialog(
        context,
        title: 'Override the guardrail',
        message: c.guardrailReason ?? 'This change was held by a guardrail. Say why you are applying it anyway.',
        confirmLabel: 'Override and accept',
      );
      if (reason == null) return;
    } else if (decision == 'accepted' && c.needsApproval) {
      reason = await schReasonDialog(
        context,
        title: 'Approve a change inside the freeze horizon',
        message: c.guardrailReason ?? 'This change falls inside the freeze horizon, so it needs a named approver and a reason.',
        confirmLabel: 'Approve',
      );
      if (reason == null) return;
    } else if (decision == 'rejected') {
      reason = await schReasonDialog(
        context,
        title: 'Reject this change',
        message: c.headline,
        confirmLabel: 'Reject',
        required: false,
      );
      if (reason == null) return;
    }
    await _run(() async {
      await Api.post('changes.php', 'decide', {
        'change_id': c.id,
        'decision': decision,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      });
      if (!mounted) return;
      _snack(decision == 'accepted'
          ? 'Accepted — commit when you have finished reviewing'
          : 'Rejected');
      await _load(silent: true);
    });
  }

  Future<void> _acceptSelected() async {
    final data = _data;
    if (data?.proposal == null) return;
    final chosen = data!.changes.where((c) => _selected.contains(c.id) && c.selectable).toList();
    if (chosen.isEmpty) return;
    String? reason;
    if (chosen.any((c) => c.needsApproval)) {
      reason = await schReasonDialog(
        context,
        title: 'Approve changes inside the freeze horizon',
        message: '${chosen.where((c) => c.needsApproval).length} of these changes fall inside the freeze horizon, so they need a named approver and a reason.',
        confirmLabel: 'Approve and accept',
      );
      if (reason == null) return;
    }
    await _run(() async {
      for (final c in chosen) {
        await Api.post('changes.php', 'decide', {
          'change_id': c.id,
          'decision': 'accepted',
          if (reason != null && reason.isNotEmpty) 'reason': reason,
        });
      }
      await Api.post('changes.php', 'commit', {'proposal_id': data.proposal!.id});
      if (!mounted) return;
      _snack('New plan version committed');
      await _load(silent: true);
      if (mounted) context.read<ShellState>().refreshCounts();
    });
  }

  Future<void> _commitAccepted() async {
    final p = _data?.proposal;
    if (p == null) return;
    await _run(() async {
      await Api.post('changes.php', 'commit', {'proposal_id': p.id});
      if (!mounted) return;
      _snack('New plan version committed');
      await _load(silent: true);
      if (mounted) context.read<ShellState>().refreshCounts();
    });
  }

  Future<void> _rejectAll() async {
    final p = _data?.proposal;
    if (p == null) return;
    final reason = await schReasonDialog(
      context,
      title: 'Reject every change in this proposal',
      message: 'The committed plan stays as it is. The next replan runs at the usual time.',
      confirmLabel: 'Reject all',
      required: false,
    );
    if (reason == null) return;
    await _run(() async {
      await Api.post('changes.php', 'reject_all', {'proposal_id': p.id, if (reason.isNotEmpty) 'reason': reason});
      if (!mounted) return;
      _snack('All changes rejected');
      await _load(silent: true);
    });
  }

  Future<void> _edit(SchChange c) async {
    final people = <SchPersonLite>[];
    for (final ch in [...?_data?.changes, ...?_data?.held]) {
      for (final p in [ch.person, ...ch.affectedPeople]) {
        if (p != null && !people.any((x) => x.id == p.id)) people.add(p);
      }
    }
    people.sort((a, b) => a.name.compareTo(b.name));
    final payload = await schEditChangeDialog(context, change: c, people: people);
    if (payload == null) return;
    await _run(() async {
      await Api.post('changes.php', 'edit', payload);
      if (!mounted) return;
      _snack('Change edited and accepted');
      await _load(silent: true);
    });
  }

  Future<void> _acknowledge(SchChange c) async {
    await _run(() async {
      await Api.post('changes.php', 'acknowledge', {'change_id': c.id});
      if (!mounted) return;
      _snack('Acknowledged');
      await _load(silent: true);
    });
  }

  Future<void> _proposeNow() async {
    await _run(() async {
      final r = await Api.post('replan.php', 'propose', {'kind': 'manual'});
      if (!mounted) return;
      final n = asIntOr(r['changes'], 0);
      _snack(n == 0 ? 'The replan found nothing worth changing' : '$n ${n == 1 ? 'change' : 'changes'} proposed');
      await _load(silent: true);
    });
  }

  Future<void> _run(Future<void> Function() body) async {
    setState(() => _busy = true);
    try {
      await body();
    } on ApiException catch (e) {
      if (mounted) _snack(e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: error ? DispatchColors.red : null),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    if (_loading) {
      return const PageBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Skeleton(width: 240, height: 28),
            SizedBox(height: Sp.sm),
            Skeleton(width: 420, height: 14),
            SizedBox(height: Sp.xl),
            SkeletonPanel(rows: 3),
            SizedBox(height: Sp.lg),
            SkeletonPanel(rows: 3),
          ],
        ),
      );
    }
    if (_error != null) {
      return PageBody(child: ErrorState(title: 'The proposal could not be loaded', message: _error, onRetry: _load));
    }
    if (!session.isDeliveryLead) return _mineBody();

    final data = _data;
    final phone = Breaks.isPhone(context);
    if (data == null || !data.hasOpenProposal) return _emptyBody(data);

    return PageBody(
      onRefresh: () => _load(silent: true),
      child: phone ? _phoneReview(data) : _wideReview(data),
    );
  }

  // --- wide ------------------------------------------------------------------

  Widget _wideReview(ChangesData data) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(data),
        const SizedBox(height: Sp.xl),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 3, child: _cards(data, stacked: false)),
            const SizedBox(width: Sp.xl),
            SizedBox(width: 360, child: _sidePanels(data)),
          ],
        ),
      ],
    );
  }

  Widget _phoneReview(ChangesData data) {
    final p = data.proposal!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Changes', style: context.text.headlineSmall),
        Text(dotJoin([p.kindLabel, '${data.changes.length} proposed']), style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
        const SizedBox(height: Sp.lg),
        DispatchCard(
          child: Row(
            children: [
              Expanded(child: SchBudgetMeter(used: p.budgetUsed, limit: p.budgetLimit, width: double.infinity)),
              const SizedBox(width: Sp.lg),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('Stability', style: context.text.labelMedium?.copyWith(color: context.mutedColor)),
                  Text(
                    fmtPct(asDouble(schSummary(p.summaryAfter, 'stability_index'))),
                    style: DispatchTheme.numeric(size: 20),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: Sp.lg),
        _cards(data, stacked: true),
        const SizedBox(height: Sp.xl),
        _sidePanels(data),
      ],
    );
  }

  Widget _header(ChangesData data) {
    final p = data.proposal!;
    final generated = p.generatedAt;
    final subtitle = dotJoin([
      p.kindLabel,
      if (generated != null) 'generated ${fmtTime(generated)} ${fmtRelativeDay(generated).toLowerCase()}',
      '${data.changes.length} ${data.changes.length == 1 ? 'change' : 'changes'} proposed'
          '${data.held.isEmpty ? '' : ', ${data.held.length} held back by guardrails'}',
    ]);
    final selectable = data.changes.where((c) => _selected.contains(c.id) && c.selectable).length;
    final accepted = p.count('accepted');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Proposed changes', style: context.text.headlineMedium),
              const SizedBox(height: 2),
              Text(subtitle, style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
              if (p.carriedOverNote != null) ...[
                const SizedBox(height: Sp.sm),
                SchChip(p.carriedOverNote!, tone: 'info', icon: Icons.history),
              ],
            ],
          ),
        ),
        const SizedBox(width: Sp.lg),
        SchBudgetMeter(used: p.budgetUsed, limit: p.budgetLimit),
        const SizedBox(width: Sp.lg),
        Wrap(
          spacing: Sp.sm,
          runSpacing: Sp.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SecondaryButton('Reject all', danger: true, onPressed: _busy ? null : _rejectAll),
            if (accepted > 0 && selectable == 0)
              PrimaryButton('Commit $accepted accepted', busy: _busy, onPressed: _busy ? null : _commitAccepted)
            else
              PrimaryButton(
                'Accept $selectable selected',
                icon: Icons.done_all,
                busy: _busy,
                onPressed: selectable == 0 || _busy ? null : _acceptSelected,
              ),
          ],
        ),
      ],
    );
  }

  Widget _cards(ChangesData data, {required bool stacked}) {
    final all = [...data.changes, ...data.held];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final c in all)
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.lg),
            child: SchChangeCard(
              change: c,
              stacked: stacked,
              selected: _selected.contains(c.id),
              onSelect: c.selectable && !_busy ? (v) => setState(() => v ? _selected.add(c.id) : _selected.remove(c.id)) : null,
              onAccept: c.isPending && !_busy ? () => _decide(c, 'accepted') : null,
              onReject: c.isPending && !_busy ? () => _decide(c, 'rejected') : null,
              onEdit: c.isPending && !_busy ? () => _edit(c) : null,
              onOpen: () => context.go(Routes.change(c.id)),
            ),
          ),
      ],
    );
  }

  Widget _sidePanels(ChangesData data) {
    final p = data.proposal!;
    final policy = context.watch<WorkspaceConfig>().policy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Panel(
          title: 'Why the plan changed',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (p.triggers.isEmpty)
                Text('No trigger was recorded for this cycle.', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
              for (final t in p.triggers)
                Padding(
                  padding: const EdgeInsets.only(bottom: Sp.md),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SchChip(humanise(t.type), tone: _triggerTone(t.type)),
                      const SizedBox(width: Sp.md),
                      Expanded(child: Text(t.label, style: context.text.bodyMedium)),
                    ],
                  ),
                ),
              if (p.improvementPct != null) ...[
                const Divider(height: Sp.xl),
                Row(
                  children: [
                    Icon(p.belowThreshold ? Icons.trending_flat : Icons.trending_up, size: 18, color: p.belowThreshold ? context.mutedColor : DispatchColors.green),
                    const SizedBox(width: Sp.sm),
                    Expanded(
                      child: Text(
                        p.belowThreshold
                            ? 'Overall improvement ${fmtPct(p.improvementPct)} — below the ${fmtPct(policy.minImprovementPct)} threshold, so nothing is applied automatically.'
                            : 'Overall improvement ${fmtPct(p.improvementPct)} against the committed plan.',
                        style: context.text.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: Sp.lg),
        Panel(title: 'Before and after', child: _beforeAfterTable(p)),
        const SizedBox(height: Sp.lg),
        Panel(
          title: 'Guardrails applied',
          trailing: TextButton(onPressed: () => context.go(Routes.settings), child: const Text('Edit')),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final g in data.guardrails)
                Padding(
                  padding: const EdgeInsets.only(bottom: Sp.md),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(_guardrailIcon(g.key), size: 18, color: context.mutedColor),
                      const SizedBox(width: Sp.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(g.label, style: context.text.titleSmall),
                            if (g.detail != null) Text(g.detail!, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
                          ],
                        ),
                      ),
                      const SizedBox(width: Sp.sm),
                      SchChip(g.enabled ? 'On' : 'Off', tone: g.enabled ? 'ok' : 'info'),
                    ],
                  ),
                ),
              const Divider(height: Sp.lg),
              Text(
                'Replan cadence: ${_cadence(policy.proposeCadence, 'propose')}, ${_cadence(policy.commitCadence, 'commit')}',
                style: context.text.bodySmall?.copyWith(color: context.mutedColor),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _beforeAfterTable(SchProposal p) {
    final before = p.summaryBefore;
    final after = p.summaryAfter;
    String num(Map<String, dynamic> m, String key) {
      final v = asDouble(schSummary(m, key));
      if (v == null) return '—';
      return v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
    }

    final rows = <BeforeAfterRow>[
      BeforeAfterRow('Items late against due date', num(before, 'late_items'), num(after, 'late_items')),
      BeforeAfterRow(
        'Value landing this quarter',
        fmtMoneyK(asDouble(schSummary(before, 'value_quarter'))),
        fmtMoneyK(asDouble(schSummary(after, 'value_quarter'))),
        improvementIsDown: false,
      ),
      BeforeAfterRow('People over 100%', num(before, 'people_over_100'), num(after, 'people_over_100')),
      BeforeAfterRow('Single-skill dependencies', num(before, 'single_skill_deps'), num(after, 'single_skill_deps')),
      BeforeAfterRow(
        'Assignment-days changed',
        '—',
        '${num(after, 'assignment_days_changed')} of ${num(after, 'total_assignment_days')}',
        improvementIsDown: true,
      ),
      BeforeAfterRow(
        'Plan stability (4 wk)',
        fmtPct(asDouble(schSummary(before, 'stability_index'))),
        fmtPct(asDouble(schSummary(after, 'stability_index'))),
        improvementIsDown: false,
      ),
    ];

    return Column(
      children: [
        Row(
          children: [
            const Expanded(flex: 5, child: SizedBox()),
            const SizedBox(width: Sp.sm),
            Expanded(flex: 2, child: Text('Now', textAlign: TextAlign.right, style: context.text.labelMedium?.copyWith(color: context.mutedColor))),
            const SizedBox(width: Sp.sm),
            Expanded(flex: 3, child: Text('Proposed', textAlign: TextAlign.right, style: context.text.labelMedium?.copyWith(color: context.mutedColor))),
          ],
        ),
        const SizedBox(height: Sp.sm),
        for (final r in rows) _beforeAfterRow(r, before, after),
      ],
    );
  }

  Widget _beforeAfterRow(BeforeAfterRow r, Map<String, dynamic> before, Map<String, dynamic> after) {
    final b = _numeric(r.before);
    final a = _numeric(r.after);
    Color? tone;
    String direction = '';
    if (b != null && a != null && a != b) {
      final better = r.improvementIsDown ? a < b : a > b;
      tone = better ? DispatchColors.green : DispatchColors.orange;
      direction = better ? ' (better)' : ' (worse)';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.sm),
      child: Semantics(
        label: '${r.label}: now ${r.before}, proposed ${r.after}$direction',
        excludeSemantics: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 5, child: Text(r.label, style: context.text.bodyMedium)),
            const SizedBox(width: Sp.sm),
            Expanded(
              flex: 2,
              child: Text(
                r.before,
                textAlign: TextAlign.right,
                maxLines: 2,
                style: DispatchTheme.numeric(size: 13, color: context.mutedColor),
              ),
            ),
            const SizedBox(width: Sp.sm),
            Expanded(
              flex: 3,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (tone != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3, right: 2),
                      child: Icon(tone == DispatchColors.green ? Icons.arrow_downward : Icons.arrow_upward, size: 12, color: tone),
                    ),
                  Flexible(
                    child: Text(
                      r.after,
                      textAlign: TextAlign.right,
                      maxLines: 2,
                      style: DispatchTheme.numeric(size: 13, color: tone ?? context.inkColor),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  double? _numeric(String s) {
    final cleaned = s.replaceAll(RegExp(r'[^0-9.\-]'), '');
    if (cleaned.isEmpty) return null;
    final v = double.tryParse(cleaned);
    if (v == null) return null;
    return s.contains('k') ? v * 1000 : v;
  }

  String _triggerTone(String type) => switch (type) {
        'incident' => 'bad',
        'leave' || 'sickness' => 'warn',
        'estimate' || 'intake' => 'info',
        _ => 'info',
      };

  IconData _guardrailIcon(String key) => switch (key) {
        'freeze' => Icons.lock_outline,
        'budget' => Icons.speed_outlined,
        'threshold' => Icons.percent,
        'reserve' => Icons.shield_outlined,
        _ => Icons.rule,
      };

  String _cadence(String raw, String verb) {
    final s = raw.toLowerCase();
    if (s.startsWith('daily')) return '$verb nightly';
    if (s.startsWith('weekly mon')) return '$verb Mondays';
    if (s.startsWith('weekly')) return '$verb weekly';
    return '$verb ${humanise(raw).toLowerCase()}';
  }

  // --- empty state + past proposals -----------------------------------------

  Widget _emptyBody(ChangesData? data) {
    final session = context.read<Session>();
    return PageBody(
      onRefresh: () => _load(silent: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Proposed changes', style: context.text.headlineMedium),
          const SizedBox(height: 2),
          Text('Nothing is waiting for review.', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
          const SizedBox(height: Sp.xl),
          Panel(
            child: EmptyState(
              icon: Icons.task_alt,
              title: 'No proposal is waiting for review',
              message: 'The next one runs at 02:00, or propose a replan now.',
              action: session.isDeliveryLead ? PrimaryButton('Propose a replan', icon: Icons.auto_awesome_outlined, busy: _busy, onPressed: _busy ? null : _proposeNow) : null,
            ),
          ),
          const SizedBox(height: Sp.lg),
          if (data != null && data.guardrails.isNotEmpty)
            SizedBox(width: 420, child: _guardrailsOnly(data)),
          const SizedBox(height: Sp.lg),
          _pastProposals(),
        ],
      ),
    );
  }

  Widget _guardrailsOnly(ChangesData data) => Panel(
        title: 'Guardrails in force',
        trailing: TextButton(onPressed: () => context.go(Routes.settings), child: const Text('Edit')),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final g in data.guardrails)
              Padding(
                padding: const EdgeInsets.only(bottom: Sp.sm),
                child: Row(
                  children: [
                    Icon(_guardrailIcon(g.key), size: 18, color: context.mutedColor),
                    const SizedBox(width: Sp.md),
                    Expanded(child: Text(g.label, style: context.text.bodyMedium)),
                  ],
                ),
              ),
          ],
        ),
      );

  Widget _pastProposals() {
    return Panel(
      title: 'Past proposals',
      trailing: TextButton(
        onPressed: () async {
          await _loadPast();
          if (mounted) setState(() => _showPast = !_showPast);
        },
        child: Text(_showPast ? 'Hide' : 'Show'),
      ),
      child: !_showPast
          ? Text('Earlier replan cycles and what was decided.', style: context.text.bodyMedium?.copyWith(color: context.mutedColor))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_past.isEmpty) Text('No earlier proposals.', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
                for (final p in _past)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(dotJoin([p.kindLabel, if (p.generatedAt != null) fmtShortDate(p.generatedAt)])),
                    subtitle: Text(dotJoin([
                      humanise(p.status),
                      '${p.count('accepted')} accepted',
                      '${p.count('rejected')} rejected',
                      if (p.improvementPct != null) 'improvement ${fmtPct(p.improvementPct)}',
                    ])),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.go(Routes.change(p.id)),
                  ),
              ],
            ),
    );
  }

  // --- "mine" (team member view, STAB-07) ------------------------------------

  Widget _mineBody() {
    final pending = _mine.where((c) => c.acknowledgedAt == null && c.insideFreeze && !c.isPending).toList();
    final phone = Breaks.isPhone(context);
    return PageBody(
      onRefresh: () => _load(silent: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Changes affecting you', style: context.text.headlineSmall),
          const SizedBox(height: 2),
          Text(
            _mine.isEmpty ? 'Nothing has changed in your plan in the last eight weeks.' : 'Plan changes from the last eight weeks, with the reason for each.',
            style: context.text.bodyMedium?.copyWith(color: context.mutedColor),
          ),
          const SizedBox(height: Sp.xl),
          if (pending.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(Sp.md),
              decoration: BoxDecoration(
                color: DispatchColors.tint(DispatchColors.amber, opacity: 0.12),
                borderRadius: DispatchRadius.cardR,
                border: Border.all(color: DispatchColors.amber.withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.notifications_active_outlined, size: 18, color: DispatchColors.amber),
                  const SizedBox(width: Sp.sm),
                  Expanded(
                    child: Text(
                      '${pending.length} ${pending.length == 1 ? 'change needs' : 'changes need'} your acknowledgement.',
                      style: context.text.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Sp.lg),
          ],
          if (_mine.isEmpty)
            const EmptyState(
              icon: Icons.check_circle_outline,
              title: 'Your plan has been steady',
              message: 'No changes have affected your work in the last eight weeks.',
            )
          else
            for (final c in _mine)
              Padding(
                padding: const EdgeInsets.only(bottom: Sp.lg),
                child: SchChangeCard(
                  change: c,
                  stacked: phone,
                  showSelect: false,
                  onAcknowledge: c.acknowledgedAt == null && !c.isPending && !_busy ? () => _acknowledge(c) : null,
                  onOpen: () => context.go(Routes.change(c.id)),
                ),
              ),
        ],
      ),
    );
  }
}

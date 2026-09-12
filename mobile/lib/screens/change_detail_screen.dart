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

/// One change in full (CHG-01, CHG-06): before and after, the reason, who is
/// affected, the comments and the decision controls.
///
/// The route id is a change id; notifications also link here with a proposal
/// id, so both are resolved.
class ChangeDetailScreen extends StatefulWidget {
  const ChangeDetailScreen({super.key, required this.id});

  /// Change proposal id (path parameter, as a string).
  final String id;

  @override
  State<ChangeDetailScreen> createState() => _ChangeDetailScreenState();
}

class _ChangeDetailScreenState extends State<ChangeDetailScreen> {
  SchChange? _change;
  SchProposal? _proposal;
  List<SchChange> _siblings = const [];
  List<SchComment> _comments = const [];
  List<SchGuardrail> _guardrails = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;
  final _commentController = TextEditingController();

  int get _id => int.tryParse(widget.id) ?? 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final found = await _resolve();
      if (!mounted) return;
      setState(() {
        _change = found.change;
        _proposal = found.proposal;
        _siblings = found.siblings;
        _comments = found.comments.where((c) => found.change == null || c.changeId == found.change!.id).toList();
        _guardrails = found.guardrails;
        _loading = false;
        _error = found.change == null && found.proposal == null ? 'This change no longer exists.' : null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// The id may be a change id or a proposal id. Try the proposal first (cheap),
  /// then fall back to scanning the open proposal and recent ones.
  Future<
      ({
        SchChange? change,
        SchProposal? proposal,
        List<SchChange> siblings,
        List<SchComment> comments,
        List<SchGuardrail> guardrails,
      })> _resolve() async {
    ChangesData? byProposal;
    try {
      byProposal = ChangesData.fromJson(await Api.post('changes.php', 'get', {'id': _id}));
    } on ApiException catch (e) {
      if (e.code != 404) rethrow;
    }
    if (byProposal != null) {
      final all = [...byProposal.changes, ...byProposal.held];
      final match = all.where((c) => c.id == _id).firstOrNull;
      return (
        change: match,
        proposal: byProposal.proposal,
        siblings: all,
        comments: byProposal.comments,
        guardrails: byProposal.guardrails,
      );
    }
    // Not a proposal id — look for a change with this id, open proposal first.
    final candidates = <ChangesData>[];
    try {
      candidates.add(ChangesData.fromJson(await Api.post('changes.php', 'current')));
    } catch (_) {/* keep looking */}
    try {
      final list = await Api.post('changes.php', 'list', {'limit': 10});
      for (final p in asList(list['proposals'], SchProposal.fromJson)) {
        if (candidates.any((c) => c.proposal?.id == p.id)) continue;
        candidates.add(ChangesData.fromJson(await Api.post('changes.php', 'get', {'id': p.id})));
        if (candidates.last.changes.any((c) => c.id == _id) || candidates.last.held.any((c) => c.id == _id)) break;
      }
    } catch (_) {/* fall through to "not found" */}
    for (final data in candidates) {
      final all = [...data.changes, ...data.held];
      final match = all.where((c) => c.id == _id).firstOrNull;
      if (match != null) {
        return (change: match, proposal: data.proposal, siblings: all, comments: data.comments, guardrails: data.guardrails);
      }
    }
    return (
      change: null,
      proposal: null,
      siblings: const <SchChange>[],
      comments: const <SchComment>[],
      guardrails: const <SchGuardrail>[],
    );
  }

  // --- actions ---------------------------------------------------------------

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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: error ? DispatchColors.red : null));
  }

  Future<void> _decide(String decision) async {
    final c = _change;
    if (c == null) return;
    final session = context.read<Session>();
    String? reason;
    if (decision == 'accepted' && c.isHeld) {
      if (!session.isAdmin) {
        _snack(c.guardrailReason ?? 'This change is held by a guardrail and needs an administrator override.', error: true);
        return;
      }
      reason = await schReasonDialog(context, title: 'Override the guardrail', message: c.guardrailReason, confirmLabel: 'Override and accept');
    } else if (decision == 'accepted' && c.needsApproval) {
      reason = await schReasonDialog(
        context,
        title: 'Approve a change inside the freeze horizon',
        message: c.guardrailReason ?? 'This change falls inside the freeze horizon, so it needs a named approver and a reason.',
        confirmLabel: 'Approve',
      );
    } else if (decision == 'rejected') {
      reason = await schReasonDialog(context, title: 'Reject this change', message: c.headline, confirmLabel: 'Reject', required: false);
    }
    if (reason == null && (decision == 'rejected' || c.isHeld || c.needsApproval)) return;
    await _run(() async {
      await Api.post('changes.php', 'decide', {
        'change_id': c.id,
        'decision': decision,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      });
      if (!mounted) return;
      _snack(decision == 'accepted' ? 'Accepted — commit the proposal when the review is done' : 'Rejected');
      await _load(silent: true);
      if (mounted) context.read<ShellState>().refreshCounts();
    });
  }

  Future<void> _edit() async {
    final c = _change;
    if (c == null) return;
    final people = <SchPersonLite>[];
    for (final ch in _siblings) {
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

  Future<void> _acknowledge() async {
    final c = _change;
    if (c == null) return;
    await _run(() async {
      await Api.post('changes.php', 'acknowledge', {'change_id': c.id});
      if (!mounted) return;
      _snack('Acknowledged');
      await _load(silent: true);
    });
  }

  Future<void> _comment() async {
    final c = _change;
    final body = _commentController.text.trim();
    if (c == null || body.isEmpty) return;
    await _run(() async {
      await Api.post('changes.php', 'comment', {'change_id': c.id, 'body': body});
      if (!mounted) return;
      _commentController.clear();
      await _load(silent: true);
    });
  }

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const PageBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Skeleton(width: 180, height: 14),
            SizedBox(height: Sp.md),
            Skeleton(width: 320, height: 28),
            SizedBox(height: Sp.xl),
            SkeletonPanel(rows: 4),
          ],
        ),
      );
    }
    final c = _change;
    if (c == null && _proposal == null) {
      return PageBody(
        child: ErrorState(
          title: 'This change could not be found',
          message: _error ?? 'It may have been superseded by a later proposal.',
          onRetry: _load,
        ),
      );
    }
    if (c == null) return _proposalBody();

    final session = context.watch<Session>();
    final phone = Breaks.isPhone(context);
    final canDecide = session.isDeliveryLead && c.isPending;
    final myPersonId = session.user?.person?.id;
    final affectsMe = myPersonId != null && (c.person?.id == myPersonId || c.affectedPeople.any((p) => p.id == myPersonId));

    return PageBody(
      onRefresh: () => _load(silent: true),
      maxWidth: 900,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton.icon(
            onPressed: () => context.go(Routes.changes),
            icon: const Icon(Icons.arrow_back, size: 16),
            label: const Text('All proposed changes'),
          ),
          const SizedBox(height: Sp.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (c.person != null) ...[
                PersonAvatar(c.person!.initialsOrDerived, colourHex: c.person!.colourHex, seed: c.person!.id, size: 40),
                const SizedBox(width: Sp.md),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.headline, style: context.text.headlineSmall),
                    const SizedBox(height: 2),
                    Text(
                      dotJoin([c.person?.name, c.workItemRef, c.workItemTitle, humanise(c.kind)]),
                      style: context.text.bodyMedium?.copyWith(color: context.mutedColor),
                    ),
                  ],
                ),
              ),
              if (!c.isPending) SchChip(humanise(c.decision), tone: c.decision == 'rejected' ? 'bad' : 'ok'),
            ],
          ),
          const SizedBox(height: Sp.xl),
          Panel(
            title: 'Before and after',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SchBeforeAfter(before: c.beforeLabel, after: c.afterLabel, vertical: phone),
                if (c.reason != null && c.reason!.isNotEmpty) ...[
                  const SizedBox(height: Sp.lg),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lightbulb_outline, size: 16, color: context.mutedColor),
                      const SizedBox(width: Sp.sm),
                      Expanded(child: Text(c.reason!, style: context.text.bodyMedium)),
                    ],
                  ),
                ],
                const SizedBox(height: Sp.lg),
                Wrap(
                  spacing: Sp.sm,
                  runSpacing: Sp.sm,
                  children: [
                    for (final chip in c.chips) SchChip(chip.label, tone: chip.tone),
                    if (c.chips.isEmpty) SchChip('Stability cost ${fmtDays(c.stabilityCostDays, unit: 'assignment-day')}', tone: 'info'),
                  ],
                ),
                if (c.guardrailReason != null) ...[
                  const SizedBox(height: Sp.lg),
                  Container(
                    padding: const EdgeInsets.all(Sp.md),
                    decoration: BoxDecoration(
                      color: DispatchColors.tint(c.isHeld ? DispatchColors.red : DispatchColors.amber, opacity: 0.1),
                      borderRadius: DispatchRadius.cardR,
                      border: Border.all(color: (c.isHeld ? DispatchColors.red : DispatchColors.amber).withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(c.isHeld ? Icons.block : Icons.lock_outline, size: 18, color: c.isHeld ? DispatchColors.red : DispatchColors.amber),
                        const SizedBox(width: Sp.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(c.guardrailLabel, style: context.text.titleSmall),
                              Text(c.guardrailReason!, style: context.text.bodyMedium),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: Sp.lg),
          if (c.affectedPeople.isNotEmpty)
            Panel(
              title: 'People affected',
              subtitle: 'Everyone here is notified before the change takes effect.',
              child: Wrap(
                spacing: Sp.lg,
                runSpacing: Sp.md,
                children: [
                  for (final p in c.affectedPeople)
                    InkWell(
                      onTap: () => context.go(Routes.person(p.id)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PersonAvatar(p.initialsOrDerived, colourHex: p.colourHex, seed: p.id, size: 26),
                          const SizedBox(width: Sp.sm),
                          Text(p.name, style: context.text.bodyMedium),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: Sp.lg),
          Panel(
            title: 'Decision',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!c.isPending)
                  Text(
                    dotJoin([
                      humanise(c.decision),
                      if (c.decidedByName != null) 'by ${c.decidedByName}',
                      if (c.decidedAt != null) fmtShortDate(c.decidedAt),
                    ]),
                    style: context.text.bodyMedium,
                  )
                else
                  Text('This change is waiting for a decision.', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
                if (c.decisionReason != null && c.decisionReason!.isNotEmpty) ...[
                  const SizedBox(height: Sp.sm),
                  Text('Reason: ${c.decisionReason}', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
                ],
                if (c.acknowledgedAt != null) ...[
                  const SizedBox(height: Sp.sm),
                  Text('Acknowledged ${fmtShortDate(c.acknowledgedAt)}', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
                ],
                if (canDecide || (affectsMe && c.acknowledgedAt == null && !c.isPending)) ...[
                  const SizedBox(height: Sp.lg),
                  Wrap(
                    spacing: Sp.sm,
                    runSpacing: Sp.sm,
                    children: [
                      if (canDecide) SecondaryButton('Edit', icon: Icons.edit_outlined, onPressed: _busy ? null : _edit),
                      if (canDecide) SecondaryButton('Reject', onPressed: _busy ? null : () => _decide('rejected')),
                      if (canDecide) PrimaryButton('Accept', icon: Icons.check, navy: true, onPressed: _busy ? null : () => _decide('accepted')),
                      if (affectsMe && c.acknowledgedAt == null && !c.isPending)
                        PrimaryButton('Acknowledge', icon: Icons.check, onPressed: _busy ? null : _acknowledge),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: Sp.lg),
          Panel(
            title: 'Comments',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_comments.isEmpty)
                  Text('No comments yet.', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
                for (final comment in _comments)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Sp.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          dotJoin([comment.author, if (comment.createdAt != null) fmtRelativeDay(comment.createdAt)]),
                          style: context.text.labelMedium?.copyWith(color: context.mutedColor),
                        ),
                        Text(comment.body, style: context.text.bodyMedium),
                      ],
                    ),
                  ),
                const SizedBox(height: Sp.sm),
                TextField(
                  controller: _commentController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Add a comment', hintText: 'Ask a question or note what you agreed'),
                ),
                const SizedBox(height: Sp.sm),
                Align(
                  alignment: Alignment.centerRight,
                  child: PrimaryButton('Post comment', busy: _busy, onPressed: _busy ? null : _comment),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The id was a proposal id (notifications link that way): list its changes.
  Widget _proposalBody() {
    final p = _proposal!;
    return PageBody(
      onRefresh: () => _load(silent: true),
      maxWidth: 900,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton.icon(
            onPressed: () => context.go(Routes.changes),
            icon: const Icon(Icons.arrow_back, size: 16),
            label: const Text('All proposed changes'),
          ),
          const SizedBox(height: Sp.sm),
          Text(p.kindLabel, style: context.text.headlineSmall),
          const SizedBox(height: 2),
          Text(
            dotJoin([
              if (p.generatedAt != null) 'generated ${fmtTime(p.generatedAt)} ${fmtRelativeDay(p.generatedAt).toLowerCase()}',
              humanise(p.status),
              '${_siblings.length} ${_siblings.length == 1 ? 'change' : 'changes'}',
            ]),
            style: context.text.bodyMedium?.copyWith(color: context.mutedColor),
          ),
          const SizedBox(height: Sp.xl),
          if (_guardrails.isNotEmpty && p.budgetLimit > 0) ...[
            SchBudgetMeter(used: p.budgetUsed, limit: p.budgetLimit, width: 260),
            const SizedBox(height: Sp.lg),
          ],
          for (final c in _siblings)
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.lg),
              child: SchChangeCard(
                change: c,
                showSelect: false,
                stacked: Breaks.isPhone(context),
                onOpen: () => context.go(Routes.change(c.id)),
              ),
            ),
          if (_siblings.isEmpty)
            const EmptyState(icon: Icons.inbox_outlined, title: 'This proposal has no changes'),
        ],
      ),
    );
  }
}

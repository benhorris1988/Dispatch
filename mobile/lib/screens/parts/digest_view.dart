import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/json.dart';
import '../../services/api.dart';
import '../../services/format.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/team_widgets.dart';
import '../../widgets/widgets.dart';
import '../../widgets/work_widgets.dart';

/// The weekly digest (NOT-04), rendered from `digest.php preview`'s structured
/// sections rather than its HTML: next week's assignments with effort against
/// capacity, changes since the last digest, changes awaiting acknowledgement,
/// watch-list entries naming the person, and the notifications their own
/// preferences routed to the digest channel.
///
/// The footer says how a digest actually reaches people, taken from the
/// response (`transport`, `delivery_note`): with no mail transport configured
/// it lands in-app, and the page says so rather than implying an email.
/// Admins can run the weekly send from here; its counts are shown verbatim.
class DigestSection extends StatefulWidget {
  const DigestSection({super.key, this.userId});

  /// Someone else's digest (team_lead+); null for your own.
  final int? userId;

  @override
  State<DigestSection> createState() => _DigestSectionState();
}

class _DigestSectionState extends State<DigestSection> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _digest = const {};
  String? _transport;
  String? _deliveryNote;

  bool _sending = false;
  Map<String, dynamic>? _sendResult;

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
      final r = await Api.post('digest.php', 'preview', {if (widget.userId != null) 'user_id': widget.userId});
      if (!mounted) return;
      setState(() {
        _digest = asMap(r['digest']);
        _transport = asStr(r['transport']);
        _deliveryNote = asStr(r['delivery_note']);
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

  Future<void> _sendNow() async {
    final ok = await showTmConfirm(
      context,
      title: 'Send the weekly digest now?',
      message: 'Composes and delivers a digest to everyone with an email digest switched on. '
          '${_transport == null ? 'No mail transport is configured, so each one lands as an in-app notification.' : 'Mail goes out through $_transport.'} '
          'Every send is audited.',
      confirmLabel: 'Send now',
    );
    if (!ok) return;
    setState(() {
      _sending = true;
      _sendResult = null;
    });
    try {
      final r = await Api.post('digest.php', 'send');
      if (!mounted) return;
      setState(() {
        _sendResult = r;
        _sending = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      tmToast(context, e.message, bad: true);
    }
  }

  void _go(String? link) {
    if (link != null && link.startsWith('/')) context.go(link);
  }

  List<Map<String, dynamic>> _rows(String key) => (_digest[key] as List?)?.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() ?? const [];

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    if (_loading) return const SkeletonPanel(rows: 6);
    if (_error != null) return ErrorState(title: 'We could not compose the digest', message: _error, onRetry: _load);

    final d = _digest;
    final user = asMap(d['user']);
    final period = asMap(d['period']);
    final summary = asMap(d['summary']);
    final nextWeek = _rows('next_week');
    final leave = _rows('leave');
    final changes = _rows('changes');
    final awaiting = _rows('awaiting_ack');
    final watch = _rows('watch_list');
    final carried = _rows('carried_notifications');
    final since = asDate(d['since']);
    final sinceDefault = asBool(d['since_is_default']);
    final hasPerson = asBool(summary['has_person']);
    final effort = asDoubleOr(summary['effort_days'], 0);
    final capacity = asDoubleOr(summary['capacity_days'], asDoubleOr(period['capacity_days'], 0));
    final loadPct = asIntOr(summary['load_pct'], 0);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // ── Header ──
      Panel(
        title: 'Weekly digest',
        subtitle: dotJoin([
          widget.userId == null ? null : 'For ${asStrOr(user['name'], 'user ${widget.userId}')}',
          asStr(period['label']),
          'composed ${fmtTime(asDate(d['generated_at']))}, nothing sent',
        ]),
        trailing: session.isAdmin
            ? SecondaryButton('Send now', icon: Icons.send_outlined, busy: _sending, onPressed: _sending ? null : _sendNow)
            : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(asStrOr(d['subject'], 'Your week ahead'), style: context.text.titleMedium),
          const SizedBox(height: Sp.xs),
          Text(asStrOr(d['summary_line'], ''), style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
          const SizedBox(height: Sp.sm),
          Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
            InfoPill(
              since == null
                  ? 'Changes since your last digest'
                  : (sinceDefault ? 'First digest: changes since ${fmtShortDate(since)}' : 'Changes since ${fmtShortDate(since)}'),
              icon: Icons.history_rounded,
            ),
            if (!hasPerson) const InfoPill('No team member is linked to this account, so there is no plan to show', icon: Icons.person_off_outlined),
          ]),
          if (_sendResult != null) ...[
            const SizedBox(height: Sp.md),
            _SendResult(_sendResult!),
          ],
        ]),
      ),
      const SizedBox(height: Sp.lg),

      // ── Next week ──
      Panel(
        title: 'Next week',
        subtitle: asStr(period['label']),
        trailing: hasPerson
            ? Text('${_days(effort)} of ${_days(capacity)} days · $loadPct%', style: DispatchTheme.numeric(size: 13, weight: FontWeight.w700, color: context.inkColor))
            : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (hasPerson) ...[
            ProgressBar(capacity > 0 ? (effort / capacity).clamp(0, 1) : 0, colour: loadPct > 100 ? DispatchColors.red : DispatchColors.typeBlue),
            const SizedBox(height: Sp.md),
          ],
          if (nextWeek.isEmpty)
            EmptyState(
              icon: Icons.event_available_outlined,
              title: hasPerson ? 'Nothing planned for you next week' : 'No plan to show',
              message: hasPerson ? 'Assignments from the committed plan appear here as they are made.' : 'Link a team member to this account and their committed assignments will appear here.',
              compact: true,
            )
          else
            for (var i = 0; i < nextWeek.length; i++) ...[
              if (i > 0) Divider(height: Sp.lg, color: context.borderColor),
              _AssignmentRow(nextWeek[i], onTap: () => _go(asStr(nextWeek[i]['link']))),
            ],
          if (leave.isNotEmpty) ...[
            const SizedBox(height: Sp.md),
            SectionLabel('Away', padding: const EdgeInsets.only(bottom: Sp.sm)),
            for (final l in leave)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Wrap(spacing: Sp.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  ToneChip(asStrOr(l['label'], humanise(asStr(l['type']))), compact: true),
                  Text(fmtDateRange(asDate(l['from_date']), asDate(l['to_date'])), style: context.text.bodyMedium),
                  if (asDouble(l['fraction']) != null && asDouble(l['fraction'])! < 1)
                    Text('${(asDouble(l['fraction'])! * 100).round()}% of the day', style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
                ]),
              ),
          ],
        ]),
      ),
      const SizedBox(height: Sp.lg),

      // ── Changes since last digest ──
      Panel(
        title: 'Changes since your last digest',
        subtitle: since == null ? null : 'Since ${fmtShortDate(since)}',
        child: changes.isEmpty
            ? const EmptyState(icon: Icons.check_circle_outline_rounded, title: 'No changes to your plan', message: 'Nothing has moved for you since the last digest.', compact: true)
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var i = 0; i < changes.length; i++) ...[
                  if (i > 0) Divider(height: Sp.lg, color: context.borderColor),
                  _ChangeRow(changes[i], onTap: () => _go(asStr(changes[i]['link']))),
                ],
              ]),
      ),
      const SizedBox(height: Sp.lg),

      // ── Awaiting acknowledgement ──
      Panel(
        title: 'Awaiting your acknowledgement',
        child: awaiting.isEmpty
            ? const EmptyState(icon: Icons.how_to_reg_outlined, title: 'Nothing to acknowledge', message: 'Committed changes that touch you wait here until you have seen them.', compact: true)
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var i = 0; i < awaiting.length; i++) ...[
                  if (i > 0) Divider(height: Sp.lg, color: context.borderColor),
                  InkWell(
                    onTap: () => _go(asStr(awaiting[i]['link'])),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(asStrOr(awaiting[i]['headline'], 'Change'), style: context.text.titleSmall),
                          const SizedBox(height: 2),
                          Text(
                            dotJoin([asStr(awaiting[i]['ref']), asStr(awaiting[i]['title']), asDate(awaiting[i]['decided_at']) == null ? null : 'committed ${fmtShortDate(asDate(awaiting[i]['decided_at']))}']),
                            style: context.text.bodySmall?.copyWith(color: context.mutedColor),
                          ),
                          if (asStr(awaiting[i]['reason']) != null) ...[
                            const SizedBox(height: 2),
                            Text(asStr(awaiting[i]['reason'])!, style: context.text.bodySmall),
                          ],
                        ]),
                      ),
                      if (asBool(awaiting[i]['inside_freeze'])) ...[const SizedBox(width: Sp.sm), const ToneChip('Inside freeze', tone: 'warn', compact: true)],
                      Icon(Icons.chevron_right_rounded, size: 20, color: context.mutedColor),
                    ]),
                  ),
                ],
              ]),
      ),
      const SizedBox(height: Sp.lg),

      // ── Watch list ──
      Panel(
        title: 'Watch-list mentions',
        subtitle: 'Entries that name you or work you own',
        child: watch.isEmpty
            ? const EmptyState(icon: Icons.visibility_outlined, title: 'Nothing on the watch list names you', compact: true)
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final w in watch)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Sp.sm),
                    child: NoteCard(
                      title: asStrOr(w['title'], humanise(asStr(w['kind']))),
                      body: asStr(w['body']),
                      suggestion: asStr(w['suggestion']),
                      tone: switch (asStr(w['tone'])) { 'bad' => 'bad', 'info' => 'info', _ => 'warn' },
                      icon: Icons.visibility_outlined,
                      onTap: asStr(w['link']) == null ? null : () => _go(asStr(w['link'])),
                    ),
                  ),
              ]),
      ),
      const SizedBox(height: Sp.lg),

      // ── Digest-routed notifications ──
      Panel(
        title: 'Notifications routed to this digest',
        subtitle: 'Kinds you asked to receive by digest rather than straight away',
        child: carried.isEmpty
            ? const EmptyState(icon: Icons.mark_email_read_outlined, title: 'None this time', message: 'Set a kind to the digest channel in your preferences and it will be gathered here.', compact: true)
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var i = 0; i < carried.length; i++) ...[
                  if (i > 0) Divider(height: Sp.lg, color: context.borderColor),
                  InkWell(
                    onTap: () => _go(asStr(carried[i]['link'])),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(asStrOr(carried[i]['title'], ''), style: context.text.titleSmall),
                          if (asStr(carried[i]['body']) != null) ...[
                            const SizedBox(height: 2),
                            Text(asStr(carried[i]['body'])!, style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
                          ],
                          const SizedBox(height: 2),
                          Text(dotJoin([humanise(asStr(carried[i]['kind'])), fmtShortDate(asDate(carried[i]['created_at']))]), style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
                        ]),
                      ),
                      if (asStr(carried[i]['link']) != null) Icon(Icons.chevron_right_rounded, size: 20, color: context.mutedColor),
                    ]),
                  ),
                ],
              ]),
      ),
      const SizedBox(height: Sp.lg),

      // ── Delivery: what the server says, never what we would like it to be ──
      TmInfoBox(_deliveryLine(), icon: _transport == null ? Icons.inbox_outlined : Icons.outgoing_mail),
    ]);
  }

  /// The transport fact from the `preview` response when it carries one;
  /// otherwise the plain truth of this repository: delivered in-app.
  String _deliveryLine() {
    final note = _deliveryNote;
    if (note != null && note.trim().isNotEmpty) return note;
    if (_transport != null) return 'Delivered by email ($_transport) on the weekly run; also written here as a notification of kind digest.';
    return 'Delivered in-app: the weekly run writes this digest to your notifications. No email is sent.';
  }

  static String _days(double d) => d == d.roundToDouble() ? d.toInt().toString() : d.toStringAsFixed(1);
}

/// One committed assignment in next week (clipped to the week).
class _AssignmentRow extends StatelessWidget {
  const _AssignmentRow(this.a, {required this.onTap});
  final Map<String, dynamic> a;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final days = asDoubleOr(a['days_in_week'], 0);
    final effort = asDoubleOr(a['effort_days'], 0);
    final alloc = asIntOr(a['allocation_pct'], 100);
    return InkWell(
      onTap: onTap,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: Sp.sm, runSpacing: Sp.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(asStrOr(a['ref'], ''), style: DispatchTheme.numeric(size: 13, color: context.mutedColor)),
              TypeChip(asStrOr(a['type_name'], ''), colourHex: asStr(a['type_colour']), compact: true),
              if (asBool(a['is_reserve'])) const ToneChip('Reserve', compact: true),
              if (asStr(a['role_label']) != null) ToneChip(asStr(a['role_label'])!, tone: 'info', compact: true),
            ]),
            const SizedBox(height: 4),
            Text(asStrOr(a['title'], ''), style: context.text.titleSmall),
            const SizedBox(height: 2),
            Text(
              dotJoin([
                fmtDateRange(asDate(a['in_week_from']), asDate(a['in_week_to'])),
                alloc == 100 ? null : '$alloc% allocation',
                asBool(a['starts_in_week']) && asBool(a['finishes_in_week'])
                    ? 'starts and finishes this week'
                    : asBool(a['starts_in_week'])
                        ? 'starts this week'
                        : asBool(a['finishes_in_week'])
                            ? 'finishes this week'
                            : null,
                asDate(a['needed_by']) == null ? null : 'needed by ${fmtShortDate(asDate(a['needed_by']))}',
              ]),
              style: context.text.bodySmall?.copyWith(color: context.mutedColor),
            ),
          ]),
        ),
        const SizedBox(width: Sp.md),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(_DigestSectionState._days(effort), style: DispatchTheme.numeric(size: 18, weight: FontWeight.w800, color: context.inkColor)),
          Text(days == effort ? 'days' : 'of ${_DigestSectionState._days(days)} days', style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
        ]),
      ]),
    );
  }
}

/// One change affecting the person since the last digest.
class _ChangeRow extends StatelessWidget {
  const _ChangeRow(this.c, {required this.onTap});
  final Map<String, dynamic> c;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: Sp.sm, runSpacing: Sp.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
              ToneChip(asStrOr(c['kind_label'], humanise(asStr(c['kind']))), tone: 'info', compact: true),
              if (asBool(c['inside_freeze'])) const ToneChip('Inside freeze', tone: 'warn', compact: true),
              Text(dotJoin([asStr(c['ref']), asDate(c['at']) == null ? null : fmtShortDate(asDate(c['at']))]), style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
            ]),
            const SizedBox(height: 4),
            Text(asStrOr(c['headline'], asStrOr(c['title'], 'Change')), style: context.text.titleSmall),
            if (asStr(c['reason']) != null) ...[
              const SizedBox(height: 2),
              Text(asStr(c['reason'])!, style: context.text.bodySmall),
            ],
          ]),
        ),
        if (asStr(c['link']) != null) Icon(Icons.chevron_right_rounded, size: 20, color: context.mutedColor),
      ]),
    );
  }
}

/// What `digest.php send` reported, verbatim counts and note.
class _SendResult extends StatelessWidget {
  const _SendResult(this.r);
  final Map<String, dynamic> r;

  @override
  Widget build(BuildContext context) {
    final transport = asStr(r['transport']);
    final note = asStr(r['note']);
    return DispatchCard(
      tint: DispatchColors.tint(DispatchColors.typeBlue, opacity: context.isDark ? 0.18 : 0.08),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Sent just now', style: context.text.titleSmall),
        const SizedBox(height: Sp.xs),
        Wrap(spacing: Sp.sm, runSpacing: Sp.xs, children: [
          InfoPill('${asIntOr(r['recipients'], 0)} recipients', icon: Icons.people_outline_rounded),
          InfoPill('${asIntOr(r['emailed'], 0)} emailed', icon: Icons.outgoing_mail),
          InfoPill('${asIntOr(r['in_app'], 0)} in-app', icon: Icons.inbox_outlined),
          InfoPill('${asIntOr(r['undelivered'], 0)} undelivered', icon: Icons.block_outlined),
          InfoPill(transport == null ? 'No mail transport' : 'Transport: $transport', icon: Icons.settings_ethernet_rounded),
        ]),
        if (note != null && note.isNotEmpty) ...[
          const SizedBox(height: Sp.sm),
          Text(note, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
        ],
      ]),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Overview (VIEW-06, web-01): what is landing, four headline measures, the
/// proposals waiting for review and the watch list.
class OverviewScreen extends StatefulWidget {
  const OverviewScreen({super.key});

  @override
  State<OverviewScreen> createState() => _OverviewScreenState();
}

enum _DeliverySort { due, owner, type }

class _OverviewScreenState extends State<OverviewScreen> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = true;
  bool _proposing = false;
  _DeliverySort _sort = _DeliverySort.due;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = _data == null;
      _error = null;
    });
    try {
      final r = await Api.post('overview.php', 'get');
      if (!mounted) return;
      setState(() {
        _data = r;
        _loading = false;
      });
      final shell = context.read<ShellState>();
      shell.setPageTitle('Overview');
      final pill = asStr(r['plan_pill']);
      if (pill != null && pill.isNotEmpty) shell.setPlanStatus(pill, committed: !pill.toLowerCase().startsWith('no committed'));
      shell.setPendingChanges(asIntOr(asMap(r['proposals'])['count'], 0));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  List<WorkRow> get _committedItems {
    final items = (asMap(_data?['committed'])['items'] as List?)?.whereType<Map>().map((e) => WorkRow(Map<String, dynamic>.from(e))).toList() ?? <WorkRow>[];
    switch (_sort) {
      case _DeliverySort.due:
        items.sort((a, b) => (a.due ?? DateTime(2100)).compareTo(b.due ?? DateTime(2100)));
      case _DeliverySort.owner:
        items.sort((a, b) {
          final an = a.assignees.isEmpty ? '~' : a.assignees.first.name;
          final bn = b.assignees.isEmpty ? '~' : b.assignees.first.name;
          return an.compareTo(bn);
        });
      case _DeliverySort.type:
        items.sort((a, b) => a.typeName.compareTo(b.typeName));
    }
    return items;
  }

  Future<void> _propose() async {
    setState(() => _proposing = true);
    try {
      final r = await Api.post('replan.php', 'propose', {'kind': 'manual'});
      final changes = asIntOr(r['changes'], 0);
      final held = asIntOr(r['held'], 0);
      final improvement = asDouble(r['improvement_pct']);
      if (!mounted) return;
      final message = changes == 0
          ? 'The planner found no worthwhile changes. The committed plan stands.'
          : '$changes change${changes == 1 ? '' : 's'} proposed'
              '${held > 0 ? ', $held held by a guardrail' : ''}'
              '${improvement != null ? ' · ${fmtPct(improvement, decimals: 1)} better' : ''}.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      context.read<ShellState>().setPendingChanges(changes);
      if (changes > 0) context.go(Routes.changes);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _proposing = false);
    }
  }

  void _export() {
    final items = _committedItems;
    final b = StringBuffer('Ref,Work,Type,Size,Who,Due,Status\n');
    String esc(String s) => '"${s.replaceAll('"', '""')}"';
    for (final i in items) {
      b.writeln([
        esc(i.ref),
        esc(i.title),
        esc(i.typeName),
        esc(i.sizeStamp ?? ''),
        esc(i.assignees.map((p) => p.name).join('; ')),
        esc(i.due == null ? '' : fmtShortDate(i.due)),
        esc(i.statusLabel ?? humanise(i.displayStatus)),
      ].join(','));
    }
    final csv = b.toString();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Export committed deliveries'),
        content: SizedBox(
          width: 560,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${items.length} item${items.length == 1 ? '' : 's'} as CSV. Copy the text below into a spreadsheet.',
                style: dialogContext.text.bodyMedium?.copyWith(color: dialogContext.mutedColor)),
            const SizedBox(height: Sp.md),
            Container(
              constraints: const BoxConstraints(maxHeight: 280),
              padding: const EdgeInsets.all(Sp.md),
              decoration: BoxDecoration(
                color: dialogContext.scheme.surfaceContainerHighest,
                borderRadius: DispatchRadius.cardR,
                border: Border.all(color: dialogContext.borderColor),
              ),
              child: SingleChildScrollView(child: SelectableText(csv, style: DispatchTheme.numeric(size: 12, weight: FontWeight.w500))),
            ),
          ]),
        ),
        actions: [
          SecondaryButton('Close', onPressed: () => Navigator.of(dialogContext).pop()),
          PrimaryButton('Copy to clipboard', icon: Icons.copy_rounded, onPressed: () async {
            final messenger = ScaffoldMessenger.of(dialogContext);
            final navigator = Navigator.of(dialogContext);
            await Clipboard.setData(ClipboardData(text: csv));
            navigator.pop();
            messenger.showSnackBar(const SnackBar(content: Text('Copied to the clipboard.')));
          }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();

    if (_loading) {
      return const PageBody(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SkeletonPanel(rows: 2),
          SizedBox(height: Sp.lg),
          SkeletonPanel(rows: 6),
        ]),
      );
    }
    if (_error != null) {
      return PageBody(child: ErrorState(title: 'Overview could not be loaded', message: _error, onRetry: _load));
    }

    final d = _data!;
    final committed = asMap(d['committed']);
    final load = asMap(d['load']);
    final stability = asMap(d['stability']);
    final reserve = asMap(d['reserve']);
    final proposals = asMap(d['proposals']);
    final watch = (d['watch_list'] as List?)?.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() ?? const [];
    final peopleCount = asIntOr(d['people_count'], 0);

    final loadPct = asIntOr(load['pct'], 0);
    final stabilityIdx = asInt(stability['index_pct']);
    final stabilityDelta = asInt(stability['delta_pts']);

    final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _committedPanel(committed),
      const SizedBox(height: Sp.lg),
      _effortPanel(d),
    ]);
    final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _proposalsPanel(proposals),
      const SizedBox(height: Sp.lg),
      _watchPanel(watch),
    ]);

    return PageBody(
      onRefresh: _load,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(
          title: 'Overview',
          subtitle: dotJoin([
            asStr(d['today_label']),
            '${asStrOr(d['workspace_name'], 'This')} team',
            '$peopleCount ${peopleCount == 1 ? 'person' : 'people'}',
          ]),
          actions: [
            InfoPill('Next replan proposal ${asStrOr(d['next_proposal_label'], '—')}', icon: Icons.schedule_rounded),
            SecondaryButton('Export', icon: Icons.download_rounded, onPressed: _export),
            if (session.isDeliveryLead)
              PrimaryButton('Propose replan now', icon: Icons.auto_awesome_rounded, busy: _proposing, onPressed: _propose),
          ],
        ),
        const SizedBox(height: Sp.lg),
        StatRow(tiles: [
          StatTile(
            label: 'Committed deliveries, next ${asIntOr(committed['working_days'], 10)} working days',
            value: '${asIntOr(committed['count'], 0)}',
            unit: '${asIntOr(committed['due_this_week'], 0)} due this week',
            footnote: _deltaFootnote(asIntOr(committed['delta_vs_last_fortnight'], 0)),
            tone: asIntOr(committed['delta_vs_last_fortnight'], 0) >= 0 ? StatTone.good : StatTone.warn,
          ),
          StatTile(
            label: 'Team load',
            value: '$loadPct%',
            unit: 'target ${asIntOr(load['target_min'], 80)}–${asIntOr(load['target_max'], 90)}%',
            footnote: asStrOr(load['band_label'], '—'),
            tone: asStrOr(load['band_label'], '') == 'Within band' ? StatTone.neutral : StatTone.warn,
          ),
          StatTile(
            label: 'Plan stability, rolling 4 weeks',
            value: stabilityIdx == null ? '—' : '$stabilityIdx%',
            unit: 'of plan unchanged',
            footnote: stabilityDelta == null ? 'No previous four weeks to compare' : '${fmtDelta(stabilityDelta)} vs previous 4 weeks',
            tone: (stabilityDelta ?? 0) >= 0 ? StatTone.good : StatTone.bad,
          ),
          StatTile(
            label: 'Incident buffer used this week',
            value: '${asIntOr(reserve['used_pct'], 0)}%',
            unit: 'of ${fmtPct(asDouble(reserve['reserve_pct']))} reserve',
            footnote: '${asIntOr(reserve['open_incidents'], 0)} open incident${asIntOr(reserve['open_incidents'], 0) == 1 ? '' : 's'}',
            footnoteIcon: Icons.shield_outlined,
          ),
        ]),
        const SizedBox(height: Sp.lg),
        if (Breaks.isDesktop(context))
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 7, child: left),
            const SizedBox(width: Sp.lg),
            SizedBox(width: 380, child: right),
          ])
        else ...[
          left,
          const SizedBox(height: Sp.lg),
          right,
        ],
      ]),
    );
  }

  String _deltaFootnote(int delta) {
    if (delta == 0) return 'The same as the last fortnight';
    return '${delta.abs()} ${delta > 0 ? 'more' : 'fewer'} than last fortnight';
  }

  Widget _committedPanel(Map<String, dynamic> committed) {
    final items = _committedItems;
    return Panel(
      title: 'Committed deliveries',
      subtitle: asStr(committed['window_label']),
      trailing: SegmentedTabs(
        labels: const ['Due date', 'Owner', 'Type'],
        selected: _DeliverySort.values.indexOf(_sort),
        compact: true,
        onChanged: (i) => setState(() => _sort = _DeliverySort.values[i]),
      ),
      padding: EdgeInsets.zero,
      child: items.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(Sp.xl),
              child: EmptyState(
                icon: Icons.event_available_outlined,
                title: 'Nothing is landing in the committed window',
                message: 'No item is due in the next ten working days. Propose a replan or add work to the pipeline.',
                compact: true,
              ),
            )
          : (Breaks.isPhone(context) ? _committedCards(items) : _committedTable(items)),
    );
  }

  Widget _committedTable(List<WorkRow> items) {
    return DispatchTable(
      columns: const [
        TableCol('Ref', width: 92),
        TableCol('Work', flex: 5),
        TableCol('Type', width: 120),
        TableCol('Size', width: 56),
        TableCol('Who', width: 96),
        TableCol('Due', width: 108),
        TableCol('Status', width: 110),
      ],
      rows: [
        for (final i in items)
          [
            Text(i.ref, style: DispatchTheme.numeric(size: 13, weight: FontWeight.w600, color: context.mutedColor)),
            Text(i.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            TypeChip(i.typeName, colourHex: i.typeColour, compact: true),
            SizeStamp(i.sizeStamp, size: 24, dashed: i.isCustom),
            AssigneeAvatars(i.assignees, size: 24),
            Text(i.dueLabel ?? fmtShortDate(i.due), style: context.text.bodyMedium),
            StatusChip(i.displayStatus, label: i.statusLabel, compact: true),
          ],
      ],
      onRowTap: (i) => context.go(Routes.item(items[i].ref)),
      rowSemantics: (i) => '${items[i].ref} ${items[i].title}',
    );
  }

  Widget _committedCards(List<WorkRow> items) {
    return Column(children: [
      for (final i in items)
        InkWell(
          onTap: () => context.go(Routes.item(i.ref)),
          child: Container(
            padding: const EdgeInsets.all(Sp.md),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.borderColor))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(i.ref, style: DispatchTheme.numeric(size: 12.5, color: context.mutedColor)),
                const SizedBox(width: Sp.sm),
                SizeStamp(i.sizeStamp, size: 22, dashed: i.isCustom),
                const Spacer(),
                StatusChip(i.displayStatus, label: i.statusLabel, compact: true),
              ]),
              const SizedBox(height: Sp.xs),
              Text(i.title, style: context.text.titleSmall),
              const SizedBox(height: Sp.sm),
              Row(children: [
                // The type name is workspace configuration, so it can be long
                // on a phone-width card; the chip ellipsises once it has to
                // share the row with the avatars and the due date.
                Flexible(child: TypeChip(i.typeName, colourHex: i.typeColour, compact: true)),
                const SizedBox(width: Sp.sm),
                AssigneeAvatars(i.assignees, size: 22),
                const Spacer(),
                Text(i.dueLabel ?? fmtShortDate(i.due), style: context.text.bodySmall),
              ]),
            ]),
          ),
        ),
    ]);
  }

  Widget _effortPanel(Map<String, dynamic> d) {
    final weeks = (d['effort_by_week'] as List?)?.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() ?? const [];
    final types = <String, Color>{};
    for (final w in weeks) {
      for (final t in (w['by_type'] as List?)?.whereType<Map>() ?? const <Map>[]) {
        types[asStrOr(t['type'], '')] = DispatchColors.parseHex(asStr(t['colour']));
      }
    }
    final unallocated = context.isDark ? DispatchColors.darkBorder : DispatchColors.surfaceAlt;

    return Panel(
      title: 'Planned effort by work type',
      trailing: Wrap(spacing: Sp.md, runSpacing: Sp.xs, children: [
        for (final e in types.entries) LegendDot(e.key, colour: e.value),
        LegendDot('Unallocated', colour: unallocated),
      ]),
      child: weeks.isEmpty
          ? const EmptyState(
              icon: Icons.bar_chart_rounded,
              title: 'No planned effort yet',
              message: 'Once a plan is committed, the next six weeks appear here.',
              compact: true,
            )
          : Padding(
              padding: const EdgeInsets.only(top: Sp.sm),
              child: StackedWeekBars(
                weeks: [
                  for (final w in weeks)
                    (
                      label: asStrOr(w['label'], ''),
                      segments: [
                        for (final t in (w['by_type'] as List?)?.whereType<Map>() ?? const <Map>[])
                          BarSegment(label: asStrOr(t['type'], ''), value: asDoubleOr(t['days'], 0), colour: DispatchColors.parseHex(asStr(t['colour']))),
                        BarSegment(label: 'Unallocated', value: asDoubleOr(w['unallocated_days'], 0), colour: unallocated),
                      ],
                    ),
                ],
              ),
            ),
    );
  }

  Widget _proposalsPanel(Map<String, dynamic> proposals) {
    final count = asIntOr(proposals['count'], 0);
    final items = (proposals['items'] as List?)?.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() ?? const [];
    final shown = items.take(3).toList();

    return Panel(
      title: 'Proposed changes',
      subtitle: count > 0 ? 'Waiting for your review' : null,
      trailing: count > 0
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: DispatchColors.tint(DispatchColors.orange, opacity: 0.16), borderRadius: DispatchRadius.chipR),
              child: Text('$count', style: DispatchTheme.numeric(size: 13, color: DispatchColors.orange)),
            )
          : null,
      padding: EdgeInsets.zero,
      child: shown.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(Sp.xl),
              child: EmptyState(
                icon: Icons.check_circle_outline_rounded,
                title: 'No changes are waiting',
                message: 'The scheduler proposes changes overnight, or on demand from this page.',
                compact: true,
              ),
            )
          : Column(children: [
              for (final c in shown)
                InkWell(
                  onTap: () => context.go(Routes.change(asIntOr(c['id'], 0))),
                  child: Container(
                    padding: const EdgeInsets.all(Sp.md),
                    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.borderColor))),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (c['person'] is Map)
                        PersonAvatar(
                          asStrOr(asMap(c['person'])['initials'], initialsOf(asStr(asMap(c['person'])['name']))),
                          colourHex: asStr(asMap(c['person'])['colour']),
                          size: 28,
                          tooltip: asStr(asMap(c['person'])['name']),
                        )
                      else
                        const PersonAvatar('?', size: 28),
                      const SizedBox(width: Sp.md),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(asStrOr(c['headline'], ''), style: context.text.titleSmall),
                          const SizedBox(height: 2),
                          Text(asStrOr(c['sub'], ''), style: context.text.bodySmall),
                        ]),
                      ),
                      Icon(Icons.chevron_right_rounded, size: 20, color: context.mutedColor),
                    ]),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(Sp.md),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => context.go(Routes.changes),
                    child: Text('Review all $count change${count == 1 ? '' : 's'}'),
                  ),
                ),
              ),
            ]),
    );
  }

  Widget _watchPanel(List<Map<String, dynamic>> watch) {
    return Panel(
      title: 'Watch list',
      subtitle: 'Things the scheduler cannot fix on its own',
      child: watch.isEmpty
          ? const EmptyState(
              icon: Icons.verified_outlined,
              title: 'Nothing needs a human decision',
              message: 'No skills gaps, missing estimates or over-committed people in the planning horizon.',
              compact: true,
            )
          : Column(children: [
              for (final w in watch) ...[
                NoteCard(
                  title: asStrOr(w['title'], ''),
                  body: asStr(w['body']),
                  suggestion: asStr(w['suggestion']),
                  tone: asStrOr(w['tone'], 'warn'),
                  icon: switch (asStrOr(w['kind'], '')) {
                    'no_estimate' => Icons.schedule_rounded,
                    'single_point' => Icons.warning_amber_rounded,
                    'over_capacity' => Icons.speed_rounded,
                    'late' => Icons.event_busy_rounded,
                    'skills_gap' => Icons.person_search_rounded,
                    _ => null,
                  },
                  onTap: () {
                    final link = asStr(w['link']);
                    if (link != null && link.isNotEmpty) context.go(link);
                  },
                ),
                if (w != watch.last) const SizedBox(height: Sp.md),
              ],
            ]),
    );
  }
}

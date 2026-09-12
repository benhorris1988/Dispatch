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

/// Estimates (EST-*): the queue of work waiting for a rough order of
/// magnitude, the estimates recorded recently, and how the team's estimates
/// have landed.
class EstimatesScreen extends StatefulWidget {
  const EstimatesScreen({super.key});

  @override
  State<EstimatesScreen> createState() => _EstimatesScreenState();
}

class _EstimatesScreenState extends State<EstimatesScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

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
      final r = await Api.post('estimates.php', 'list');
      if (!mounted) return;
      setState(() {
        _data = r;
        _loading = false;
      });
      context.read<ShellState>().setPageTitle('Estimates');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _items =>
      (_data?['items'] as List?)?.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() ?? const [];

  @override
  Widget build(BuildContext context) {
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
      return PageBody(child: ErrorState(title: 'Estimates could not be loaded', message: _error, onRetry: _load));
    }

    final waiting = _items.where((i) => asStrOr(i['status'], '') == 'needs_estimate').toList();
    final estimated = _items.where((i) => asIntOr(i['version'], 0) > 0).toList();

    final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _waitingPanel(waiting),
      const SizedBox(height: Sp.lg),
      _recentPanel(estimated),
    ]);
    final right = _calibrationPanel();

    return PageBody(
      onRefresh: _load,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(
          title: 'Estimates',
          subtitle: dotJoin([
            '${waiting.length} waiting for an estimate',
            '${estimated.length} estimated',
            'day rate ${fmtMoney(asDouble(_data?['day_rate']))}',
          ]),
        ),
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

  Widget _waitingPanel(List<Map<String, dynamic>> waiting) {
    return Panel(
      title: 'Waiting for an estimate',
      subtitle: waiting.isEmpty ? null : 'These cannot be scheduled until they are sized',
      padding: EdgeInsets.zero,
      child: waiting.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(Sp.xl),
              child: EmptyState(
                icon: Icons.check_circle_outline_rounded,
                title: 'Nothing is waiting for an estimate',
                message: 'Every open item has a rough order of magnitude.',
                compact: true,
              ),
            )
          : LayoutBuilder(
              builder: (context, box) => box.maxWidth < 800
                  ? Column(children: [for (final i in waiting) _card(i, waiting: true)])
                  : DispatchTable(
                      minWidth: 720,
                      columns: const [
                        TableCol('Ref', width: 92),
                        TableCol('Work', flex: 5),
                        TableCol('Type', width: 122),
                        TableCol('Size', width: 54),
                        TableCol('Waiting', width: 96, alignRight: true),
                        TableCol('', width: 110, alignRight: true),
                      ],
                      onRowTap: (i) => context.go(Routes.estimate(asStrOr(waiting[i]['ref'], ''))),
                      rowSemantics: (i) => 'Estimate ${asStrOr(waiting[i]['ref'], '')}',
                      rows: [
                        for (final i in waiting)
                          [
                            Text(asStrOr(i['ref'], ''), style: DispatchTheme.numeric(size: 13, weight: FontWeight.w600, color: context.mutedColor)),
                            Text(asStrOr(i['title'], ''), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                            TypeChip(asStrOr(i['type_name'], ''), colourHex: asStr(i['type_colour']), compact: true),
                            SizeStamp(asStr(i['size_stamp']), size: 24, dashed: asBool(i['is_custom'])),
                            Text('${asIntOr(i['waiting_days'], 0)} days', style: DispatchTheme.numeric(size: 13)),
                            TextButton(onPressed: () => context.go(Routes.estimate(asStrOr(i['ref'], ''))), child: const Text('Estimate')),
                          ],
                      ],
                    ),
            ),
    );
  }

  Widget _recentPanel(List<Map<String, dynamic>> estimated) {
    return Panel(
      title: 'Recent estimates',
      padding: EdgeInsets.zero,
      child: estimated.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(Sp.xl),
              child: EmptyState(
                icon: Icons.straighten_rounded,
                title: 'No estimates recorded yet',
                message: 'Estimates appear here as soon as the first one is saved.',
                compact: true,
              ),
            )
          : LayoutBuilder(
              builder: (context, box) => box.maxWidth < 800
                  ? Column(children: [for (final i in estimated.take(25)) _card(i)])
                  : DispatchTable(
                      minWidth: 860,
                      columns: const [
                        TableCol('Ref', width: 92),
                        TableCol('Work', flex: 5),
                        TableCol('Version', width: 78),
                        TableCol('Class', width: 96),
                        TableCol('Likely', width: 74, alignRight: true),
                        TableCol('Expected', width: 86, alignRight: true),
                        TableCol('P80', width: 68, alignRight: true),
                        TableCol('Author', width: 130),
                        TableCol('Updated', width: 100),
                      ],
                      onRowTap: (i) => context.go(Routes.estimate(asStrOr(estimated[i]['ref'], ''))),
                      rowSemantics: (i) => 'Estimate for ${asStrOr(estimated[i]['ref'], '')}',
                      rows: [
                        for (final i in estimated.take(25))
                          [
                            Text(asStrOr(i['ref'], ''), style: DispatchTheme.numeric(size: 13, weight: FontWeight.w600, color: context.mutedColor)),
                            Text(asStrOr(i['title'], ''), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                            Text('v${asIntOr(i['version'], 0)}', style: DispatchTheme.numeric(size: 13)),
                            ToneChip('${asIntOr(i['estimate_class'], 3)} ${classToleranceLabel(asInt(i['estimate_class']))}', compact: true),
                            Text(fmtRange(asDouble(i['likely']), asDouble(i['likely'])), style: DispatchTheme.numeric(size: 13)),
                            Text(fmtRange(asDouble(i['expected']), asDouble(i['expected'])), style: DispatchTheme.numeric(size: 13)),
                            Text(
                              fmtRange(asDouble(i['p80']), asDouble(i['p80'])),
                              style: DispatchTheme.numeric(size: 13, color: DispatchColors.orange),
                            ),
                            Text(asStrOr(i['author_name'], '—'), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodyMedium),
                            Text(fmtDayMonth(asDate(i['estimate_updated_at'])), style: context.text.bodyMedium),
                          ],
                      ],
                    ),
            ),
    );
  }

  Widget _card(Map<String, dynamic> i, {bool waiting = false}) {
    return InkWell(
      onTap: () => context.go(Routes.estimate(asStrOr(i['ref'], ''))),
      child: Container(
        padding: const EdgeInsets.all(Sp.md),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.borderColor))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(asStrOr(i['ref'], ''), style: DispatchTheme.numeric(size: 12.5, color: context.mutedColor)),
            const SizedBox(width: Sp.sm),
            SizeStamp(asStr(i['size_stamp']), size: 22, dashed: asBool(i['is_custom'])),
            const Spacer(),
            if (waiting)
              ToneChip('${asIntOr(i['waiting_days'], 0)} days waiting', tone: 'warn', compact: true)
            else
              ToneChip('v${asIntOr(i['version'], 0)} · ${classToleranceLabel(asInt(i['estimate_class']))}', compact: true),
          ]),
          const SizedBox(height: Sp.xs),
          Text(asStrOr(i['title'], ''), style: context.text.titleSmall),
          const SizedBox(height: Sp.xs),
          Text(
            waiting
                ? dotJoin([asStr(i['type_name']), 'needs a rough order of magnitude'])
                : dotJoin([
                    'Likely ${fmtDaysShort(asDouble(i['likely']))}',
                    'P80 ${fmtDaysShort(asDouble(i['p80']))}',
                    asStr(i['author_name']),
                  ]),
            style: context.text.bodySmall,
          ),
        ]),
      ),
    );
  }

  Widget _calibrationPanel() {
    final cal = asMap(_data?['calibration']);
    final byStamp = (cal['by_stamp'] as List?)?.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() ?? const [];
    return Panel(
      title: 'Calibration',
      subtitle: "How this team's estimates have landed",
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        NoteCard(
          tone: 'warn',
          icon: Icons.trending_up_rounded,
          title: asStrOr(cal['recommendation'], 'Not enough delivered work to calibrate yet.'),
        ),
        if (byStamp.isNotEmpty) ...[
          const SizedBox(height: Sp.lg),
          for (final b in byStamp)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                SizedBox(width: 28, child: SizeStamp(asStr(b['stamp']), size: 22, dashed: asStrOr(b['stamp'], '') == 'C')),
                const SizedBox(width: Sp.sm),
                Expanded(
                  child: ProgressBar(
                    ((asDouble(b['median_ratio']) ?? 1) / 1.6).clamp(0, 1),
                    colour: (asDouble(b['median_ratio']) ?? 1) > 1.1 ? DispatchColors.orange : DispatchColors.ink,
                  ),
                ),
                const SizedBox(width: Sp.sm),
                SizedBox(
                  width: 92,
                  child: Text(
                    '×${(asDouble(b['median_ratio']) ?? 1).toStringAsFixed(2)} · n ${asIntOr(b['n'], 0)}',
                    textAlign: TextAlign.right,
                    style: DispatchTheme.numeric(size: 12.5),
                  ),
                ),
              ]),
            ),
          const SizedBox(height: Sp.sm),
          Text('Actual ÷ most-likely, median by size class · items delivered in the last 12 months', style: context.text.bodySmall),
        ],
      ]),
    );
  }
}

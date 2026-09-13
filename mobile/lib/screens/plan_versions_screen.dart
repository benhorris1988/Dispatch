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
import 'parts/sch_plan_models.dart';

/// Plan version history (CHG-05). Accepting changes commits a new plan
/// version and the previous one is kept: this is where those versions can be
/// read, compared and — for a delivery lead — restored.
///
/// Restoring never rewinds. `plan.php restore` writes the old version's
/// assignments into a **new** committed version, so the history stays intact
/// and the restore is itself auditable. The screen says so before it acts.
class PlanVersionsScreen extends StatefulWidget {
  const PlanVersionsScreen({super.key, this.versionId});

  /// Linkable: `/schedule/versions`, optionally `?v=6` to open one version.
  static const String route = '/schedule/versions';
  static String forVersion(Object id) => '$route?v=$id';

  final int? versionId;

  @override
  State<PlanVersionsScreen> createState() => _PlanVersionsScreenState();
}

class _PlanVersionsScreenState extends State<PlanVersionsScreen> {
  List<SchPlanVersion> _versions = const [];
  Map<int, String> _people = const {};
  SchVersionDetail? _detail;
  int? _selectedId;
  bool _loading = true;
  bool _detailLoading = false;
  bool _busy = false;
  /// Phone shows the list or one version, not both.
  bool _phoneShowingDetail = false;
  String? _error;
  String? _detailError;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.versionId;
    _phoneShowingDetail = widget.versionId != null; // a link to one version opens it
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final raw = await Api.post('plan.php', 'versions');
      final versions = asList(raw['versions'], SchPlanVersion.fromJson);
      if (!mounted) return;
      setState(() {
        _versions = versions;
        _loading = false;
        _error = null;
      });
      final chosen = versions.where((v) => v.id == _selectedId).firstOrNull ??
          versions.where((v) => v.isCommitted).firstOrNull ??
          versions.firstOrNull;
      if (chosen != null) await _select(chosen.id);
      await _loadPeople();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _loadPeople() async {
    if (_people.isNotEmpty) return;
    try {
      final r = await Api.post('people.php', 'list');
      final map = <int, String>{};
      for (final p in (r['people'] is List ? r['people'] as List : const []).whereType<Map>()) {
        map[asIntOr(p['id'], 0)] = asStrOr(p['name'], 'Unknown');
      }
      if (mounted) setState(() => _people = map);
    } catch (_) {
      // The assignment list still reads without names.
    }
  }

  Future<void> _select(int id) async {
    setState(() {
      _selectedId = id;
      _detailLoading = true;
      _detailError = null;
    });
    try {
      final raw = await Api.post('plan.php', 'version', {'id': id});
      if (!mounted) return;
      setState(() {
        _detail = SchVersionDetail.fromJson(raw);
        _detailLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _detailError = e.message;
        _detailLoading = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Restore (CHG-05)
  // ---------------------------------------------------------------------------

  Future<void> _restore(SchPlanVersion v) async {
    final next = _versions.isEmpty ? v.versionNo + 1 : _versions.map((x) => x.versionNo).reduce((a, b) => a > b ? a : b) + 1;
    final current = _versions.where((x) => x.isCommitted).firstOrNull;
    final message = [
      'Restoring version ${v.versionNo} creates a NEW committed version — version $next — holding version ${v.versionNo}\'s assignments.',
      'It does not rewind the plan.'
          '${current == null ? '' : ' Version ${current.versionNo} stays in the history as superseded.'}'
          ' Everyone whose work moves is notified, and the restore is recorded in the audit trail.',
      if ((v.assignmentCount ?? 0) == 0)
        'Version ${v.versionNo} has no stored assignments, so the new committed version would have none either.',
    ].join('\n\n');

    final reason = await schReasonDialog(
      context,
      title: 'Restore version ${v.versionNo}?',
      message: message,
      confirmLabel: 'Restore as version $next',
    );
    if (reason == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final r = await Api.post('plan.php', 'restore', {'plan_version_id': v.id, 'reason': reason});
      if (!mounted) return;
      final created = SchPlanVersion.fromJson(asMap(r['plan_version']));
      final changed = asIntOr(r['changes'], 0);
      _selectedId = created.id;
      await _load(silent: true);
      if (!mounted) return;
      context.read<ShellState>().refreshCounts();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Version ${v.versionNo} restored as committed version ${created.versionNo}'
              '${changed == 0 ? '' : ', $changed ${changed == 1 ? 'assignment' : 'assignments'} changed'}'),
          action: SnackBarAction(label: 'Open schedule', onPressed: () => context.go(Routes.schedule)),
        ),
      );
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message), backgroundColor: DispatchColors.red));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const PageBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Skeleton(width: 260, height: 28),
            SizedBox(height: Sp.sm),
            Skeleton(width: 420, height: 14),
            SizedBox(height: Sp.xl),
            SkeletonPanel(rows: 4),
            SizedBox(height: Sp.lg),
            SkeletonPanel(rows: 4),
          ],
        ),
      );
    }
    if (_error != null) {
      return PageBody(child: ErrorState(title: 'The version history could not be loaded', message: _error, onRetry: _load));
    }
    final phone = Breaks.isPhone(context);
    if (_versions.isEmpty) {
      return PageBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(),
            const SizedBox(height: Sp.xl),
            const Panel(
              child: EmptyState(
                icon: Icons.history_toggle_off_outlined,
                title: 'No plan versions yet',
                message: 'A version is written every time a proposal is committed. Run a replan to make the first one.',
              ),
            ),
          ],
        ),
      );
    }

    final selected = _versions.where((v) => v.id == _selectedId).firstOrNull;
    if (phone) {
      return PageBody(
        onRefresh: () => _load(silent: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(),
            const SizedBox(height: Sp.lg),
            if (selected == null || !_phoneShowingDetail)
              ..._versionList()
            else ...[
              SecondaryButton('All versions', icon: Icons.arrow_back, onPressed: () => setState(() => _phoneShowingDetail = false)),
              const SizedBox(height: Sp.lg),
              _detailPane(selected, phone: true),
            ],
          ],
        ),
      );
    }

    return PageBody(
      onRefresh: () => _load(silent: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(),
          const SizedBox(height: Sp.xl),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: Breaks.isDesktop(context) ? 420 : 330,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _versionList()),
              ),
              const SizedBox(width: Sp.xl),
              Expanded(child: selected == null ? const SizedBox() : _detailPane(selected, phone: false)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _header() {
    final committed = _versions.where((v) => v.isCommitted).firstOrNull;
    final subtitle = dotJoin([
      '${_versions.length} ${_versions.length == 1 ? 'version' : 'versions'}',
      committed == null ? 'no committed plan' : 'version ${committed.versionNo} in force',
      'restoring one creates a new committed version',
    ]);
    return LayoutBuilder(
      builder: (context, constraints) {
        final title = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Plan version history', style: Breaks.isPhone(context) ? context.text.headlineSmall : context.text.headlineMedium),
            const SizedBox(height: 2),
            Text(subtitle, style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
          ],
        );
        final back = SecondaryButton('Back to schedule', icon: Icons.calendar_month_outlined, onPressed: () => context.go(Routes.schedule));
        if (constraints.maxWidth < 720) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, const SizedBox(height: Sp.md), back]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Expanded(child: title), const SizedBox(width: Sp.md), back],
        );
      },
    );
  }

  List<Widget> _versionList() {
    final session = context.watch<Session>();
    return [
      for (final v in _versions)
        Padding(
          padding: const EdgeInsets.only(bottom: Sp.md),
          child: _versionCard(v, canRestore: session.isDeliveryLead),
        ),
    ];
  }

  Widget _versionCard(SchPlanVersion v, {required bool canRestore}) {
    final selected = v.id == _selectedId;
    return Semantics(
      selected: selected,
      button: true,
      child: DispatchCard(
        accent: selected ? DispatchColors.orange : null,
        onTap: () {
          _select(v.id);
          if (Breaks.isPhone(context)) setState(() => _phoneShowingDetail = true);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('v${v.versionNo}', style: DispatchTheme.numeric(size: 20)),
                const SizedBox(width: Sp.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(v.whenLabel(), maxLines: 2, overflow: TextOverflow.ellipsis, style: context.text.titleSmall),
                      Text(
                        dotJoin([humanise(v.engine), if (v.policyVersion != null) 'policy v${v.policyVersion}']),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.labelSmall?.copyWith(color: context.mutedColor),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Sp.sm),
                SchChip(v.statusLabel, tone: v.statusTone),
              ],
            ),
            const SizedBox(height: Sp.md),
            Wrap(
              spacing: Sp.md,
              runSpacing: Sp.xs,
              children: [
                _fact('Objective', v.objectiveScore == null ? '—' : v.objectiveScore!.toStringAsFixed(1)),
                _fact('Stability cost', fmtDays(v.stabilityCostDays)),
                _fact('Assignments', '${v.assignmentCount ?? 0}'),
                _fact('Changes', '${v.changeCount ?? 0}'),
              ],
            ),
            if (v.notes != null && v.notes!.isNotEmpty) ...[
              const SizedBox(height: Sp.sm),
              Text(v.notes!, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
            ],
            if (canRestore && v.canRestore) ...[
              const SizedBox(height: Sp.md),
              Align(
                alignment: Alignment.centerLeft,
                child: SecondaryButton(
                  'Restore',
                  icon: Icons.settings_backup_restore,
                  busy: _busy,
                  onPressed: _busy ? null : () => _restore(v),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _fact(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: context.text.labelSmall?.copyWith(color: context.mutedColor)),
          Text(value, style: DispatchTheme.numeric(size: 14)),
        ],
      );

  // --- the selected version ---------------------------------------------------

  Widget _detailPane(SchPlanVersion v, {required bool phone}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Panel(
          title: 'Version ${v.versionNo}',
          subtitle: v.whenLabel(),
          trailing: SchChip(v.statusLabel, tone: v.statusTone),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (v.notes != null && v.notes!.isNotEmpty) ...[
                Text(v.notes!, style: context.text.bodyMedium),
                const SizedBox(height: Sp.lg),
              ],
              StatRow(
                minTileWidth: phone ? 140 : 160,
                tiles: [
                  StatTile(
                    label: 'Objective score',
                    value: v.objectiveScore == null ? '—' : v.objectiveScore!.toStringAsFixed(1),
                    footnote: 'Lower is better',
                  ),
                  StatTile(label: 'Stability cost', value: fmtDays(v.stabilityCostDays), footnote: 'Assignment-days moved'),
                  StatTile(label: 'Assignments', value: '${v.assignmentCount ?? _detail?.assignments.length ?? 0}'),
                  StatTile(label: 'Changes', value: '${v.changeCount ?? 0}', footnote: 'Proposed against this version'),
                ],
              ),
              const SizedBox(height: Sp.lg),
              _line('Committed through', v.committedThrough == null ? 'Not committed' : fmtShortDate(v.committedThrough)),
              _line('Engine', dotJoin([humanise(v.engine), if (v.solveSeconds != null) '${v.solveSeconds!.toStringAsFixed(2)}s', if (v.provedOptimal) 'optimum proved'])),
              _line('Policy version', v.policyVersion == null ? '—' : 'v${v.policyVersion}'),
              if (v.inputsHash != null && v.inputsHash!.isNotEmpty)
                _line('Inputs hash', v.inputsHash!.length <= 12 ? v.inputsHash! : '${v.inputsHash!.substring(0, 12)}…'),
              if (v.objectiveTerms.isNotEmpty) ...[
                const SizedBox(height: Sp.md),
                const SectionLabel('Objective weights'),
                const SizedBox(height: Sp.sm),
                Wrap(
                  spacing: Sp.sm,
                  runSpacing: Sp.sm,
                  children: [
                    for (final e in v.objectiveTerms.entries) SchChip('${_termLabel(e.key)} ×${e.value}', tone: 'info'),
                  ],
                ),
              ],
              if (v.canRestore && context.watch<Session>().isDeliveryLead) ...[
                const Divider(height: Sp.xl),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 18, color: context.mutedColor),
                    const SizedBox(width: Sp.sm),
                    Expanded(
                      child: Text(
                        'Restoring this version creates a new committed version with these assignments. It does not rewind the plan.',
                        style: context.text.bodyMedium,
                      ),
                    ),
                    const SizedBox(width: Sp.sm),
                    PrimaryButton(
                      'Restore version ${v.versionNo}',
                      icon: Icons.settings_backup_restore,
                      busy: _busy,
                      onPressed: _busy ? null : () => _restore(v),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: Sp.lg),
        Panel(
          title: 'Assignments in this version',
          subtitle: _detail == null ? null : '${_detail!.assignments.length} rows',
          child: _assignments(v),
        ),
      ],
    );
  }

  Widget _line(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 140, child: Text(label, style: context.text.labelMedium?.copyWith(color: context.mutedColor))),
            Expanded(child: Text(value, style: context.text.bodyMedium)),
          ],
        ),
      );

  Widget _assignments(SchPlanVersion v) {
    if (_detailLoading) return const SkeletonPanel(rows: 4);
    if (_detailError != null) {
      return ErrorState(
        title: 'This version could not be opened',
        message: _detailError,
        compact: true,
        onRetry: () => _select(v.id),
      );
    }
    final rows = _detail?.assignments ?? const <SchBlock>[];
    if (rows.isEmpty) {
      return EmptyState(
        icon: Icons.event_busy_outlined,
        compact: true,
        title: 'No assignments stored for version ${v.versionNo}',
        message: 'The version keeps its facts — objective score, stability cost and policy version — but no rows. '
            'Restoring it would leave the plan empty.',
      );
    }
    final byPerson = <int, List<SchBlock>>{};
    for (final a in rows) {
      byPerson.putIfAbsent(a.personId, () => <SchBlock>[]).add(a);
    }
    final ids = byPerson.keys.toList()
      ..sort((a, b) => (_people[a] ?? 'Person $a').compareTo(_people[b] ?? 'Person $b'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final id in ids) ...[
          SectionLabel(
            _people[id] ?? 'Person $id',
            trailing: Text(
              '${byPerson[id]!.length} ${byPerson[id]!.length == 1 ? 'assignment' : 'assignments'}',
              style: context.text.labelSmall?.copyWith(color: context.mutedColor),
            ),
          ),
          for (final a in byPerson[id]!..sort((x, y) => x.from.compareTo(y.from)))
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 3,
                    height: 32,
                    margin: const EdgeInsets.only(right: Sp.md),
                    decoration: BoxDecoration(
                      color: DispatchColors.parseHex(a.typeColour),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(dotJoin([a.ref, a.title]), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.titleSmall),
                        Text(
                          dotJoin([
                            fmtDateRange(a.from, a.to),
                            '${a.allocationPct}%',
                            humanise(a.state),
                            a.roleLabel,
                          ]),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.bodySmall?.copyWith(color: context.mutedColor),
                        ),
                      ],
                    ),
                  ),
                  if (a.sizeStamp != null) Padding(padding: const EdgeInsets.only(left: Sp.sm), child: SizeStamp(a.sizeStamp, size: 22)),
                ],
              ),
            ),
          const SizedBox(height: Sp.sm),
        ],
      ],
    );
  }

  String _termLabel(String key) => switch (key) {
        'valueCompletion' => 'Value completion',
        'lateness' => 'Lateness',
        'unscheduledValue' => 'Unscheduled value',
        'loadImbalance' => 'Load imbalance',
        'contextSwitching' => 'Context switching',
        'stabilityPlanned' => 'Stability',
        'preferences' => 'Preferences',
        _ => humanise(key),
      };
}

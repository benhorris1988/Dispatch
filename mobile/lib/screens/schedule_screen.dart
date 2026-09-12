import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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
import '../widgets/schedule_widgets.dart';
import '../widgets/widgets.dart';
import 'parts/sch_models.dart';

/// Schedule — a lane per person across the horizon (VIEW-01..05, SCH-06/07/09,
/// STAB-01/06). Committed weeks are tinted and locked, today is an orange
/// line, indicative work is dashed and hatched, leave is hatched grey.
/// A delivery lead can drag a block; the knock-on effect is previewed before
/// anything is saved and recorded as a manual change.
class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

enum SchZoom { weeks, days, months }

class _ScheduleScreenState extends State<ScheduleScreen> {
  // --- data -----------------------------------------------------------------
  ScheduleData? _data;
  bool _loading = true;
  String? _error;

  SchZoom _zoom = SchZoom.weeks;
  bool _overlay = false;
  int? _openProposalId;
  bool _proposing = false;

  int? _teamId;
  int? _typeId;
  int? _skillId;
  int? _itemId;
  List<({int id, String name})> _teams = const [];
  List<({int id, String name})> _skills = const [];

  // --- geometry -------------------------------------------------------------
  static const double _laneCol = 268; // frozen left column
  static const double _headerH = 56;
  static const double _blockH = 38;
  static const double _blockGap = 6;
  static const double _lanePad = 7;

  List<DateTime> _days = const []; // working days across the range
  Map<String, int> _dayIndex = const {};
  List<double> _laneHeights = const [];
  List<double> _laneTops = const [];
  Map<int, List<_Placed>> _laneBlocks = const {};

  // --- scrolling ------------------------------------------------------------
  final _hHeader = ScrollController();
  final _hBody = ScrollController();
  final _vLeft = ScrollController();
  final _vRight = ScrollController();
  bool _syncing = false;

  // --- interaction ----------------------------------------------------------
  final Map<int, FocusNode> _focusNodes = {};
  int? _draggingId;
  Offset _dragDelta = Offset.zero;
  final Map<int, int> _nudge = {}; // assignment id → working-day offset pending confirmation
  /// Owned by the screen, not the sheet, so it outlives the sheet's exit animation.
  final TextEditingController _moveReason = TextEditingController();
  int? _selectedPersonId; // phone view

  @override
  void initState() {
    super.initState();
    _hHeader.addListener(() => _mirror(_hHeader, _hBody));
    _hBody.addListener(() => _mirror(_hBody, _hHeader));
    _vLeft.addListener(() => _mirror(_vLeft, _vRight));
    _vRight.addListener(() => _mirror(_vRight, _vLeft));
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final n in _focusNodes.values) {
      n.dispose();
    }
    _moveReason.dispose();
    _hHeader.dispose();
    _hBody.dispose();
    _vLeft.dispose();
    _vRight.dispose();
    super.dispose();
  }

  void _mirror(ScrollController from, ScrollController to) {
    if (_syncing || !from.hasClients || !to.hasClients) return;
    if ((from.offset - to.offset).abs() < 0.5) return;
    _syncing = true;
    to.jumpTo(from.offset.clamp(to.position.minScrollExtent, to.position.maxScrollExtent));
    _syncing = false;
  }

  // ---------------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------------

  int get _weeksForZoom => switch (_zoom) { SchZoom.days => 2, SchZoom.weeks => 6, SchZoom.months => 26 };

  double get _dayWidth => switch (_zoom) { SchZoom.days => 92, SchZoom.weeks => 38, SchZoom.months => 13 };

  double get _colWidth => _zoom == SchZoom.days ? _dayWidth : _dayWidth * 5;

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final lock = await _lockState();
      final body = <String, dynamic>{
        'weeks': _weeksForZoom,
        if (_teamId != null) 'team_id': _teamId,
        if (_typeId != null) 'type_id': _typeId,
        if (_skillId != null) 'skill_id': _skillId,
        if (_itemId != null) 'item_id': _itemId,
        if (_overlay && _openProposalId != null) 'overlay_proposal_id': _openProposalId,
      };
      // The API defaults to six weeks from Monday; ask for the zoom's range explicitly.
      final from = _mondayOf(DateTime.now());
      body['from'] = _iso(from);
      body['to'] = _iso(from.add(Duration(days: _weeksForZoom * 7 - 1)));
      final raw = await Api.post('plan.php', 'schedule', body);
      final data = ScheduleData.fromJson(raw);
      if (!mounted) return;
      // The range the server actually used drives the columns.
      setState(() {
        _data = data;
        _openProposalId = lock ?? _openProposalId;
        _loading = false;
        _error = null;
        _nudge.clear();
        _selectedPersonId ??= data.people.isNotEmpty ? data.people.first.id : null;
        _layout();
      });
      final through = data.committedThrough;
      if (mounted && through != null) {
        context.read<ShellState>().setPlanStatus('Plan committed to ${fmtShortDate(through)}');
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<int?> _lockState() async {
    try {
      final r = await Api.post('plan.php', 'lock_state');
      return asInt(r['open_proposal_id']);
    } catch (_) {
      return null;
    }
  }

  /// Working-day axis, lane heights and block placement — recomputed whenever
  /// the data or the zoom changes, so paint and hit-testing stay cheap.
  void _layout() {
    final d = _data;
    if (d == null) return;
    final days = <DateTime>[];
    final index = <String, int>{};
    var cur = DateTime(d.from.year, d.from.month, d.from.day);
    final end = DateTime(d.to.year, d.to.month, d.to.day);
    while (!cur.isAfter(end)) {
      if (cur.weekday <= DateTime.friday) {
        index[_iso(cur)] = days.length;
        days.add(cur);
      }
      cur = cur.add(const Duration(days: 1));
    }
    _days = days;
    _dayIndex = index;

    final blocks = <int, List<_Placed>>{};
    final heights = <double>[];
    final tops = <double>[];
    final overlayById = {for (final b in d.overlayBlocks) b.id: b};
    double top = 0;

    for (final p in d.people) {
      final items = <_Placed>[];
      Iterable<SchBlock> source = d.blocks.where((b) => b.personId == p.id);
      if (_overlay && d.hasOverlay) {
        // Overlay: the proposed plan, plus a ghost at the committed position of anything that moved.
        source = d.overlayBlocks.where((b) => b.personId == p.id);
      }
      for (final b in source) {
        final placed = _place(b, ghost: false);
        if (placed != null) items.add(placed);
        if (_overlay && b.changed) {
          final committed = d.blocks.where((c) => c.workItemId == b.workItemId).toList();
          for (final c in committed) {
            if (overlayById[c.id]?.changed == false) continue;
            final ghost = _place(c, ghost: true);
            if (ghost != null && ghost.personId == p.id) items.add(ghost);
          }
        }
      }
      for (final a in d.away.where((a) => a.personId == p.id)) {
        final placed = _placeAway(a);
        if (placed != null) items.add(placed);
      }
      _stack(items);
      final rows = items.isEmpty ? 1 : items.map((i) => i.row).reduce(math.max) + 1;
      final h = _lanePad * 2 + rows * _blockH + (rows - 1) * _blockGap;
      blocks[p.id] = items;
      heights.add(h);
      tops.add(top);
      top += h;
    }
    _laneBlocks = blocks;
    _laneHeights = heights;
    _laneTops = tops;
  }

  _Placed? _place(SchBlock b, {required bool ghost}) {
    final range = _range(b.from, b.to);
    if (range == null) return null;
    return _Placed(
      startIdx: range.$1,
      endIdx: range.$2,
      block: b,
      ghost: ghost,
      personId: b.personId,
    );
  }

  _Placed? _placeAway(SchAway a) {
    final range = _range(a.from, a.to);
    if (range == null) return null;
    return _Placed(startIdx: range.$1, endIdx: range.$2, away: a, personId: a.personId);
  }

  /// Clamp a date range onto the working-day axis. Returns null when it does
  /// not overlap the visible range at all.
  (int, int)? _range(DateTime from, DateTime to) {
    if (_days.isEmpty) return null;
    if (to.isBefore(_days.first) || from.isAfter(_days.last)) return null;
    int start = 0;
    while (start < _days.length && _days[start].isBefore(from)) {
      start++;
    }
    int end = _days.length - 1;
    while (end >= 0 && _days[end].isAfter(to)) {
      end--;
    }
    if (start > end) {
      // Falls entirely in a weekend gap — show it on the next working day.
      start = start.clamp(0, _days.length - 1);
      end = start;
    }
    return (start, end);
  }

  /// Greedy sub-row packing so overlapping assignments stack rather than overlap.
  void _stack(List<_Placed> items) {
    items.sort((a, b) => a.startIdx == b.startIdx ? a.endIdx.compareTo(b.endIdx) : a.startIdx.compareTo(b.startIdx));
    final rowEnds = <int>[];
    for (final it in items) {
      var placed = false;
      for (var r = 0; r < rowEnds.length; r++) {
        if (rowEnds[r] < it.startIdx) {
          it.row = r;
          rowEnds[r] = it.endIdx;
          placed = true;
          break;
        }
      }
      if (!placed) {
        it.row = rowEnds.length;
        rowEnds.add(it.endIdx);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final phone = Breaks.isPhone(context);
    if (_loading && _data == null) return _skeleton(phone);
    if (_error != null && _data == null) {
      return PageBody(child: ErrorState(title: 'The schedule could not be loaded', message: _error, onRetry: _load));
    }
    final d = _data!;
    return phone ? _phoneBody(d) : _wideBody(d);
  }

  Widget _skeleton(bool phone) => PageBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Skeleton(width: 220, height: 28),
            const SizedBox(height: Sp.sm),
            const Skeleton(width: 420, height: 14),
            const SizedBox(height: Sp.xl),
            SkeletonPanel(rows: phone ? 4 : 8),
          ],
        ),
      );

  // --- wide (desktop + tablet) ----------------------------------------------

  Widget _wideBody(ScheduleData d) {
    final session = context.watch<Session>();
    final config = context.watch<WorkspaceConfig>();
    final policy = config.policy;
    final gutter = Breaks.gutter(context);
    final canPlan = session.isDeliveryLead;

    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, Sp.xl, gutter, Sp.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _headerRow(d, canPlan),
          const SizedBox(height: Sp.md),
          LayoutBuilder(
            builder: (context, constraints) {
              final pills = [
                InfoPill('Freeze horizon: ${policy.freezeHorizonDays} working days', icon: Icons.lock_outline),
                InfoPill('Incident reserve: ${fmtPct(policy.incidentReservePct)} per person', icon: Icons.shield_outlined),
              ];
              if (constraints.maxWidth < 1120) return SchLegend(workTypes: config.activeWorkTypes, trailing: pills);
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: SchLegend(workTypes: config.activeWorkTypes)),
                  const SizedBox(width: Sp.md),
                  Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: pills),
                ],
              );
            },
          ),
          const SizedBox(height: Sp.md),
          Expanded(child: _grid(d, canPlan: canPlan && Breaks.isDesktop(context), policy: policy)),
          const SizedBox(height: Sp.md),
          _footer(d),
        ],
      ),
    );
  }

  Widget _headerRow(ScheduleData d, bool canPlan) {
    final subtitle = dotJoin([
      d.people.isNotEmpty ? (d.people.first.teamName ?? 'All teams') : 'No people',
      '$_weeksForZoom weeks from ${fmtShortDate(d.from)}',
      d.committedThrough != null ? 'committed through ${fmtShortDate(d.committedThrough)}' : 'no committed plan',
    ]);
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Schedule', style: context.text.headlineMedium),
        const SizedBox(height: 2),
        Text(subtitle, style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 1120;
        final controls = _controls(canPlan);
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [title, const SizedBox(height: Sp.md), controls],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Expanded(child: title), const SizedBox(width: Sp.md), controls],
        );
      },
    );
  }

  Widget _controls(bool canPlan) {
    return Wrap(
          spacing: Sp.sm,
          runSpacing: Sp.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedTabs(
              labels: const ['Weeks', 'Days', 'Months'],
              selected: switch (_zoom) { SchZoom.weeks => 0, SchZoom.days => 1, SchZoom.months => 2 },
              onChanged: (i) {
                setState(() => _zoom = switch (i) { 1 => SchZoom.days, 2 => SchZoom.months, _ => SchZoom.weeks });
                _load();
              },
            ),
            _overlayToggle(),
            SecondaryButton(
              _filterCount == 0 ? 'Filter' : 'Filter ($_filterCount)',
              icon: Icons.filter_alt_outlined,
              onPressed: _openFilters,
            ),
            if (canPlan)
              PrimaryButton(
                'Propose replan',
                icon: Icons.auto_awesome_outlined,
                busy: _proposing,
                onPressed: _proposing ? null : _proposeReplan,
              ),
      ],
    );
  }

  int get _filterCount => [_teamId, _typeId, _skillId, _itemId].where((v) => v != null).length;

  Widget _overlayToggle() {
    final on = _overlay;
    final enabled = _openProposalId != null;
    return Tooltip(
      message: enabled
          ? 'Overlay the open proposal on the committed plan'
          : 'No proposal is open, so there is nothing to overlay',
      child: InfoPill(
        'Committed + proposed',
        icon: on ? Icons.visibility : Icons.visibility_outlined,
        dot: on ? DispatchColors.orange : null,
        onTap: enabled
            ? () {
                setState(() => _overlay = !_overlay);
                _load();
              }
            : null,
      ),
    );
  }

  // --- the grid --------------------------------------------------------------

  Widget _grid(ScheduleData d, {required bool canPlan, required Policy policy}) {
    if (d.people.isEmpty) {
      return Panel(
        child: EmptyState(
          icon: Icons.groups_outlined,
          title: 'No people match these filters',
          message: 'Clear the filters to see the whole team.',
          action: _filterCount == 0 ? null : SecondaryButton('Clear filters', onPressed: _clearFilters),
        ),
      );
    }
    if (_laneHeights.length != d.people.length) _layout();
    final totalW = _days.length * _dayWidth;
    return Container(
      decoration: BoxDecoration(
        color: context.panelColor,
        borderRadius: DispatchRadius.panelR,
        border: Border.all(color: context.borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // header: frozen cell + week columns
          SizedBox(
            height: _headerH,
            child: Row(
              children: [
                Container(
                  width: _laneCol,
                  height: _headerH,
                  padding: const EdgeInsets.symmetric(horizontal: Sp.md),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: context.isDark ? DispatchColors.darkPanel : DispatchColors.surfaceAlt,
                    border: Border(right: BorderSide(color: context.borderColor), bottom: BorderSide(color: context.borderColor)),
                  ),
                  child: Text(
                    '${d.people.length} ${d.people.length == 1 ? 'person' : 'people'} · ${fmtDays(d.daysPerWeekTotal)}/week',
                    style: context.text.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _hHeader,
                    scrollDirection: Axis.horizontal,
                    physics: const ClampingScrollPhysics(),
                    child: SizedBox(width: totalW, height: _headerH, child: _columnHeaders(d)),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                SizedBox(
                  width: _laneCol,
                  child: DecoratedBox(
                    decoration: BoxDecoration(border: Border(right: BorderSide(color: context.borderColor))),
                    child: ListView.builder(
                      controller: _vLeft,
                      physics: const ClampingScrollPhysics(),
                      itemCount: d.people.length,
                      itemBuilder: (_, i) => SchLaneHeader(
                        person: d.people[i],
                        height: _laneHeights[i],
                        targetMin: policy.targetLoadMin,
                        targetMax: policy.targetLoadMax,
                        onRota: d.rota.any((r) => r.personId == d.people[i].id),
                        onTap: () => context.go(Routes.person(d.people[i].id)),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Scrollbar(
                    controller: _hBody,
                    child: SingleChildScrollView(
                      controller: _hBody,
                      scrollDirection: Axis.horizontal,
                      physics: const ClampingScrollPhysics(),
                      child: SizedBox(
                        width: totalW,
                        child: ListView.builder(
                          controller: _vRight,
                          physics: const ClampingScrollPhysics(),
                          itemCount: d.people.length,
                          itemBuilder: (_, i) => _lane(d, i, totalW, canPlan),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _columnHeaders(ScheduleData d) {
    final today = d.today;
    if (_zoom == SchZoom.days) {
      return Row(
        children: [
          for (var i = 0; i < _days.length; i++)
            Container(
              width: _dayWidth,
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(color: context.borderColor.withValues(alpha: _days[i].weekday == DateTime.friday ? 1 : 0.4)),
                  bottom: BorderSide(color: context.borderColor),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: Sp.sm, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_dow(_days[i]), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.titleSmall?.copyWith(height: 1.2)),
                  Text(
                    fmtDayMonth(_days[i]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.labelSmall?.copyWith(
                      height: 1.2,
                      color: today != null && _sameDay(_days[i], today) ? DispatchColors.orange : context.mutedColor,
                      fontWeight: today != null && _sameDay(_days[i], today) ? FontWeight.w700 : null,
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    }
    final weeks = _weekStarts();
    return Row(
      children: [
        for (final w in weeks) _weekHeaderCell(d, w),
      ],
    );
  }

  Widget _weekHeaderCell(ScheduleData d, DateTime weekStart) {
    final state = _stateFor(d, weekStart);
    final isCurrent = d.today != null && _mondayOf(d.today!) == weekStart;
    final freezeEnd = d.freezeEnd;
    final lockHere = freezeEnd != null && _mondayOf(freezeEnd) == weekStart;
    return Container(
      width: _colWidth,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: context.borderColor), bottom: BorderSide(color: context.borderColor)),
      ),
      padding: EdgeInsets.symmetric(horizontal: _zoom == SchZoom.months ? 4 : Sp.md, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _zoom == SchZoom.months ? fmtDayMonth(weekStart) : fmtWeekCommencing(weekStart),
            style: context.text.titleSmall,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Flexible(
                child: Text(
                  isCurrent ? 'Today' : humanise(state),
                  overflow: TextOverflow.ellipsis,
                  style: context.text.labelSmall?.copyWith(
                    color: isCurrent ? DispatchColors.orange : context.mutedColor,
                    fontWeight: isCurrent ? FontWeight.w700 : null,
                  ),
                ),
              ),
              if (lockHere && _zoom != SchZoom.months) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: 'Committed through ${fmtShortDate(freezeEnd)}',
                  child: Icon(Icons.lock_outline, size: 12, color: context.mutedColor),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _lane(ScheduleData d, int laneIndex, double totalW, bool canPlan) {
    final person = d.people[laneIndex];
    final height = _laneHeights[laneIndex];
    final items = _laneBlocks[person.id] ?? const <_Placed>[];
    return SizedBox(
      height: height,
      width: totalW,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _LanePainter(
                days: _days,
                dayWidth: _dayWidth,
                zoom: _zoom,
                today: d.today,
                freezeEnd: d.freezeEnd,
                plannedEnd: d.plannedEnd,
                gridColour: context.borderColor,
                weekColour: context.borderColor.withValues(alpha: 0.45),
                committedTint: DispatchColors.ink.withValues(alpha: context.isDark ? 0.16 : 0.035),
                hatchColour: context.mutedColor.withValues(alpha: 0.10),
                todayColour: DispatchColors.orange,
              ),
            ),
          ),
          for (final it in items) _positioned(d, it, person, canPlan),
        ],
      ),
    );
  }

  Widget _positioned(ScheduleData d, _Placed it, SchPerson person, bool canPlan) {
    final nudged = it.block != null ? (_nudge[it.block!.id] ?? 0) : 0;
    final start = (it.startIdx + nudged).clamp(0, math.max(0, _days.length - 1));
    final left = start * _dayWidth;
    final width = math.max(_dayWidth * 0.9, (it.endIdx - it.startIdx + 1) * _dayWidth - 4);
    final top = _lanePad + it.row * (_blockH + _blockGap);
    final dragging = it.block != null && _draggingId == it.block!.id;

    Widget child;
    if (it.away != null) {
      final a = it.away!;
      final returns = _nextWorkingDay(a.to);
      child = SchBlockCard(
        away: true,
        title: dotJoin([a.label, if (returns != null) 'returns ${fmtDayMonth(returns)}']),
      );
      child = Semantics(label: '${person.name}: ${a.label}, ${fmtDateRange(a.from, a.to)}', child: child);
    } else {
      final b = it.block!;
      child = SchBlockCard(
        title: dotJoin([b.ref, b.title]),
        subtitle: b.subLabel,
        railColour: DispatchColors.parseHex(b.typeColour),
        indicative: b.isIndicative,
        moved: !it.ghost && ((_overlay && b.changed) || nudged != 0),
        ghost: it.ghost,
        locked: b.locked && !b.fixedDates && !b.fixedPerson,
        fixed: b.fixedPerson || b.fixedDates,
        dense: _zoom == SchZoom.months,
      );
      if (!it.ghost) child = _interactive(d, b, person, child, canPlan: canPlan, nudged: nudged);
    }

    return Positioned(
      left: left + (dragging ? _dragDelta.dx : 0),
      top: top + (dragging ? _dragDelta.dy : 0),
      width: width,
      height: _blockH,
      child: IgnorePointer(ignoring: it.ghost, child: Opacity(opacity: it.ghost ? 0.9 : 1, child: child)),
    );
  }

  Widget _interactive(ScheduleData d, SchBlock b, SchPerson person, Widget child, {required bool canPlan, required int nudged}) {
    final node = _focusNodes.putIfAbsent(b.id, () => FocusNode(debugLabel: 'block-${b.id}'));
    final draggable = canPlan && !b.fixedDates && !_overlay;

    Widget inner = Focus(
      focusNode: node,
      onKeyEvent: (_, event) => _onKey(d, b, person, event),
      child: Builder(
        builder: (ctx) {
          final focused = Focus.of(ctx).hasFocus;
          return Container(
            decoration: focused
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(DispatchRadius.card + 2),
                    border: Border.all(color: DispatchColors.orange, width: 2),
                  )
                : null,
            child: child,
          );
        },
      ),
    );

    inner = Semantics(
      button: true,
      label: [
        person.name,
        dotJoin([b.ref, b.title]),
        fmtDateRange(b.from, b.to),
        if (b.allocationPct != 100) '${b.allocationPct}% allocation',
        if (b.isIndicative) 'indicative',
        if (b.locked) 'inside the freeze horizon',
        if (nudged != 0) 'nudged ${nudged.abs()} working ${nudged.abs() == 1 ? 'day' : 'days'} ${nudged > 0 ? 'later' : 'earlier'}, press Enter to confirm',
      ].join(', '),
      excludeSemantics: true,
      child: inner,
    );

    return MouseRegion(
      cursor: draggable ? SystemMouseCursors.grab : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          node.requestFocus();
          _showBlockDetails(d, b, person);
        },
        onLongPressStart: draggable
            ? (_) => setState(() {
                  _draggingId = b.id;
                  _dragDelta = Offset.zero;
                })
            : null,
        onLongPressMoveUpdate: draggable ? (e) => setState(() => _dragDelta = e.offsetFromOrigin) : null,
        onLongPressEnd: draggable ? (_) => _endDrag(d, b) : null,
        onLongPressCancel: draggable
            ? () => setState(() {
                  _draggingId = null;
                  _dragDelta = Offset.zero;
                })
            : null,
        child: Tooltip(
          message: draggable ? 'Press and hold to drag, or focus and use Shift + arrow keys' : dotJoin([b.ref, b.title]),
          waitDuration: const Duration(milliseconds: 700),
          child: inner,
        ),
      ),
    );
  }

  // --- keyboard (9.6) --------------------------------------------------------

  KeyEventResult _onKey(ScheduleData d, SchBlock b, SchPerson person, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      final n = _nudge[b.id] ?? 0;
      if (n != 0) {
        _confirmMove(d, b, dayDelta: n, targetPersonId: b.personId);
      } else {
        _showBlockDetails(d, b, person);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_nudge.remove(b.id) != null) {
        setState(() {});
        _announce('Move cancelled for ${b.ref}');
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final left = key == LogicalKeyboardKey.arrowLeft;
    final right = key == LogicalKeyboardKey.arrowRight;
    final up = key == LogicalKeyboardKey.arrowUp;
    final down = key == LogicalKeyboardKey.arrowDown;
    if (!left && !right && !up && !down) return KeyEventResult.ignored;

    if (shift && (left || right)) {
      final delta = (_nudge[b.id] ?? 0) + (right ? 1 : -1);
      setState(() => _nudge[b.id] = delta);
      final target = _dateAtIndex(_indexOf(b.from) + delta);
      _announce(
        '${b.ref} moved to ${fmtShortDate(target)}, ${delta.abs()} working ${delta.abs() == 1 ? 'day' : 'days'} ${delta > 0 ? 'later' : 'earlier'}. Press Enter to confirm, Escape to cancel.',
      );
      return KeyEventResult.handled;
    }
    if (shift && (up || down)) {
      final lane = d.people.indexWhere((p) => p.id == b.personId);
      final target = lane + (down ? 1 : -1);
      if (target < 0 || target >= d.people.length) return KeyEventResult.handled;
      _confirmMove(d, b, dayDelta: _nudge[b.id] ?? 0, targetPersonId: d.people[target].id);
      return KeyEventResult.handled;
    }

    // Plain arrows move focus between blocks.
    final lane = d.people.indexWhere((p) => p.id == b.personId);
    if (left || right) {
      final siblings = (_laneBlocks[b.personId] ?? const <_Placed>[]).where((p) => p.block != null && !p.ghost).toList()
        ..sort((x, y) => x.startIdx.compareTo(y.startIdx));
      final i = siblings.indexWhere((p) => p.block!.id == b.id);
      final next = i + (right ? 1 : -1);
      if (next >= 0 && next < siblings.length) {
        _focusNodes[siblings[next].block!.id]?.requestFocus();
        _announceBlock(siblings[next].block!, d);
      }
      return KeyEventResult.handled;
    }
    final targetLane = lane + (down ? 1 : -1);
    if (targetLane < 0 || targetLane >= d.people.length) return KeyEventResult.handled;
    final neighbours = (_laneBlocks[d.people[targetLane].id] ?? const <_Placed>[]).where((p) => p.block != null && !p.ghost).toList();
    if (neighbours.isEmpty) return KeyEventResult.handled;
    neighbours.sort((x, y) => (x.startIdx - _indexOf(b.from)).abs().compareTo((y.startIdx - _indexOf(b.from)).abs()));
    final target = neighbours.first.block!;
    _focusNodes.putIfAbsent(target.id, () => FocusNode(debugLabel: 'block-${target.id}')).requestFocus();
    _announceBlock(target, d);
    return KeyEventResult.handled;
  }

  void _announceBlock(SchBlock b, ScheduleData d) {
    final person = d.people.where((p) => p.id == b.personId).firstOrNull;
    _announce(dotJoin([person?.name, b.ref, b.title, fmtDateRange(b.from, b.to)]));
  }

  void _announce(String message) {
    if (!mounted) return;
    SemanticsService.sendAnnouncement(View.of(context), message, Directionality.of(context));
  }

  // --- drag → preview → confirm ---------------------------------------------

  void _endDrag(ScheduleData d, SchBlock b) {
    final delta = _dragDelta;
    setState(() {
      _draggingId = null;
      _dragDelta = Offset.zero;
    });
    final dayDelta = (delta.dx / _dayWidth).round();
    final lane = d.people.indexWhere((p) => p.id == b.personId);
    if (lane < 0) return;
    var targetLane = lane;
    if (delta.dy.abs() > 12 && _laneTops.isNotEmpty) {
      final origin = _laneTops[lane] + delta.dy;
      targetLane = 0;
      for (var i = 0; i < _laneTops.length; i++) {
        if (origin >= _laneTops[i]) targetLane = i;
      }
    }
    final targetPerson = d.people[targetLane.clamp(0, d.people.length - 1)].id;
    if (dayDelta == 0 && targetPerson == b.personId) return;
    _confirmMove(d, b, dayDelta: dayDelta, targetPersonId: targetPerson);
  }

  Future<void> _confirmMove(ScheduleData d, SchBlock b, {required int dayDelta, required int targetPersonId}) async {
    final startIdx = _indexOf(b.from) + dayDelta;
    final span = _indexOf(b.to) - _indexOf(b.from);
    final newFrom = _dateAtIndex(startIdx);
    final newTo = _dateAtIndex(startIdx + span);
    final person = d.people.where((p) => p.id == targetPersonId).firstOrNull;

    MovePreview? preview;
    String? previewError;
    try {
      final raw = await Api.post('plan.php', 'move_assignment', {
        'assignment_id': b.id,
        'from_date': _iso(newFrom),
        'to_date': _iso(newTo),
        'person_id': targetPersonId,
        'allocation_pct': b.allocationPct,
        'preview': true,
      });
      preview = MovePreview.fromJson(raw);
    } on ApiException catch (e) {
      previewError = e.message;
    }
    if (!mounted) return;

    final session = context.read<Session>();
    final insideFreeze = preview?.insideFreeze ?? false;
    final reasonController = _moveReason..clear();
    var applyKnockOn = false;
    var busy = false;

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) {
          final needsReason = insideFreeze;
          final knockOnCount = preview?.knockOn.length ?? 0;
          final canConfirm = session.isDeliveryLead && (!needsReason || reasonController.text.trim().isNotEmpty) && previewError == null;
          return Padding(
            padding: EdgeInsets.fromLTRB(Sp.xl, 0, Sp.xl, MediaQuery.viewInsetsOf(sheetContext).bottom + Sp.xl),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(preview?.headline ?? 'Move ${b.ref}', style: context.text.titleLarge),
                  const SizedBox(height: Sp.xs),
                  Text(
                    dotJoin([person?.name, fmtDateRange(newFrom, newTo), if (b.allocationPct != 100) '${b.allocationPct}%']),
                    style: context.text.bodyMedium?.copyWith(color: context.mutedColor),
                  ),
                  const SizedBox(height: Sp.lg),
                  if (previewError != null)
                    ErrorState(title: 'The preview could not be produced', message: previewError, compact: true)
                  else ...[
                    SchBeforeAfter(
                      before: dotJoin([b.ref, fmtDateRange(b.from, b.to)]),
                      after: dotJoin([b.ref, fmtDateRange(newFrom, newTo), if (person != null && person.id != b.personId) person.name]),
                      vertical: Breaks.isPhone(context),
                    ),
                    const SizedBox(height: Sp.lg),
                    Wrap(
                      spacing: Sp.sm,
                      runSpacing: Sp.sm,
                      children: [
                        SchChip('Stability cost ${fmtDays(preview?.stabilityCostDays ?? 0, unit: 'assignment-day')}',
                            tone: (preview?.stabilityCostDays ?? 0) > 0 ? 'warn' : 'ok'),
                        if (insideFreeze) const SchChip('Inside freeze horizon · needs your approval', tone: 'warn'),
                        if (knockOnCount > 0) SchChip('$knockOnCount knock-on ${knockOnCount == 1 ? 'change' : 'changes'}', tone: 'info'),
                      ],
                    ),
                    if ((preview?.warnings ?? const []).isNotEmpty) ...[
                      const SizedBox(height: Sp.md),
                      for (final w in preview!.warnings)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.warning_amber_rounded, size: 16, color: DispatchColors.amber),
                              const SizedBox(width: Sp.sm),
                              Expanded(child: Text(w, style: context.text.bodyMedium)),
                            ],
                          ),
                        ),
                    ],
                    if ((preview?.knockOn ?? const []).isNotEmpty) ...[
                      const SizedBox(height: Sp.lg),
                      const SectionLabel('Knock-on effects'),
                      for (final k in preview!.knockOn)
                        Padding(
                          padding: const EdgeInsets.only(bottom: Sp.sm),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.subdirectory_arrow_right, size: 16),
                              const SizedBox(width: Sp.sm),
                              Expanded(
                                child: Text(
                                  dotJoin([k.person, k.effect ?? '${k.ref} moves', if (k.from != null) fmtDateRange(k.from, k.to)]),
                                  style: context.text.bodyMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: applyKnockOn,
                        onChanged: (v) => setSheet(() => applyKnockOn = v),
                        title: const Text('Apply the knock-on changes as well'),
                        subtitle: const Text('Otherwise only this assignment moves and the next replan settles the rest.'),
                      ),
                    ],
                    if (insideFreeze) ...[
                      const SizedBox(height: Sp.lg),
                      Container(
                        padding: const EdgeInsets.all(Sp.md),
                        decoration: BoxDecoration(
                          color: DispatchColors.tint(DispatchColors.amber, opacity: 0.12),
                          borderRadius: DispatchRadius.cardR,
                          border: Border.all(color: DispatchColors.amber.withValues(alpha: 0.5)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.lock_outline, size: 18, color: DispatchColors.amber),
                            const SizedBox(width: Sp.sm),
                            Expanded(
                              child: Text(
                                'Inside the freeze horizon. Ask a delivery lead to approve, or move the start to ${_nextMondayLabel(d)}.',
                                style: context.text.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: Sp.md),
                      TextField(
                        controller: reasonController,
                        onChanged: (_) => setSheet(() {}),
                        decoration: const InputDecoration(
                          labelText: 'Reason for the approval',
                          hintText: 'Why this change is worth the disruption',
                        ),
                        minLines: 2,
                        maxLines: 3,
                      ),
                    ],
                  ],
                  const SizedBox(height: Sp.xl),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      SecondaryButton('Cancel', onPressed: () => Navigator.of(sheetContext).pop(false)),
                      const SizedBox(width: Sp.sm),
                      PrimaryButton(
                        'Confirm move',
                        busy: busy,
                        onPressed: canConfirm
                            ? () async {
                                setSheet(() => busy = true);
                                Navigator.of(sheetContext).pop(true);
                              }
                            : null,
                      ),
                    ],
                  ),
                  if (!session.isDeliveryLead)
                    Padding(
                      padding: const EdgeInsets.only(top: Sp.sm),
                      child: Text('Only a delivery lead can move committed work.', style: context.text.labelMedium?.copyWith(color: context.mutedColor)),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (confirmed != true) {
      setState(() => _nudge.remove(b.id));
      return;
    }
    try {
      await Api.post('plan.php', 'move_assignment', {
        'assignment_id': b.id,
        'from_date': _iso(newFrom),
        'to_date': _iso(newTo),
        'person_id': targetPersonId,
        'allocation_pct': b.allocationPct,
        'preview': false,
        'apply_knock_on': applyKnockOn,
        if (reasonController.text.trim().isNotEmpty) 'reason': reasonController.text.trim(),
      });
      if (!mounted) return;
      _snack('Recorded as a manual change');
      _announce('${b.ref} moved to ${fmtShortDate(newFrom)} and recorded as a manual change');
      await _load(silent: true);
      if (mounted) context.read<ShellState>().refreshCounts();
    } on ApiException catch (e) {
      if (mounted) _snack(e.message, error: true);
    }
  }

  String _nextMondayLabel(ScheduleData d) {
    final freeze = d.freezeEnd ?? d.today ?? DateTime.now();
    var m = freeze.add(const Duration(days: 1));
    while (m.weekday != DateTime.monday) {
      m = m.add(const Duration(days: 1));
    }
    return 'Monday ${fmtDayMonth(m)}';
  }

  // --- block details popover -------------------------------------------------

  Future<void> _showBlockDetails(ScheduleData d, SchBlock b, SchPerson person) async {
    final session = context.read<Session>();
    var fixedPerson = b.fixedPerson;
    var fixedDates = b.fixedDates;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialog) => AlertDialog(
          title: Text(dotJoin([b.ref, b.title])),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    PersonAvatar(person.initialsOrDerived, colourHex: person.colourHex, seed: person.id, size: 28),
                    const SizedBox(width: Sp.sm),
                    Expanded(child: Text(dotJoin([person.name, person.roleTitle]), style: context.text.bodyMedium)),
                  ],
                ),
                const SizedBox(height: Sp.md),
                _detail('Dates', fmtDateRange(b.from, b.to)),
                _detail('Allocation', '${b.allocationPct}%'),
                if (b.roleLabel != null) _detail('Role', b.roleLabel!),
                _detail('Window', humanise(b.state)),
                if (b.typeName != null) _detail('Work type', dotJoin([b.typeName, b.sizeStamp])),
                if (b.note != null && b.note!.isNotEmpty) _detail('Note', b.note!),
                if (session.isDeliveryLead) ...[
                  const Divider(height: Sp.xl),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: fixedPerson,
                    title: const Text('Fix the person'),
                    subtitle: const Text('The scheduler plans around this assignee.'),
                    onChanged: (v) => setDialog(() => fixedPerson = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: fixedDates,
                    title: const Text('Fix the dates'),
                    subtitle: const Text('The scheduler may not move this block.'),
                    onChanged: (v) => setDialog(() => fixedDates = v),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (b.ref != null)
              SecondaryButton(
                'Open item',
                icon: Icons.open_in_new,
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  context.go(Routes.item(b.ref!));
                },
              ),
            if (session.isDeliveryLead)
              PrimaryButton(
                'Save',
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  await _saveFix(b, fixedPerson, fixedDates);
                },
              )
            else
              SecondaryButton('Close', onPressed: () => Navigator.of(dialogContext).pop()),
          ],
        ),
      ),
    );
  }

  Widget _detail(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 100, child: Text(label, style: context.text.labelMedium?.copyWith(color: context.mutedColor))),
            Expanded(child: Text(value, style: context.text.bodyMedium)),
          ],
        ),
      );

  Future<void> _saveFix(SchBlock b, bool fixedPerson, bool fixedDates) async {
    if (fixedPerson == b.fixedPerson && fixedDates == b.fixedDates) return;
    try {
      if (!fixedPerson && !fixedDates) {
        await Api.post('plan.php', 'unfix', {'assignment_id': b.id});
      } else {
        await Api.post('plan.php', 'fix_assignment', {
          'assignment_id': b.id,
          'fixed_person': fixedPerson,
          'fixed_dates': fixedDates,
        });
      }
      if (!mounted) return;
      _snack(fixedPerson || fixedDates ? 'The scheduler will plan around this assignment' : 'This assignment is no longer fixed');
      await _load(silent: true);
    } on ApiException catch (e) {
      if (mounted) _snack(e.message, error: true);
    }
  }

  // --- replan / filters ------------------------------------------------------

  Future<void> _proposeReplan() async {
    setState(() => _proposing = true);
    try {
      final r = await Api.post('replan.php', 'propose', {'kind': 'manual'});
      if (!mounted) return;
      final changes = asIntOr(r['changes'], 0);
      final held = asIntOr(r['held'], 0);
      setState(() {
        _openProposalId = asInt(r['proposal_id']) ?? _openProposalId;
        _overlay = changes > 0;
      });
      await _load(silent: true);
      if (!mounted) return;
      context.read<ShellState>().refreshCounts();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(changes == 0
              ? 'The replan found nothing worth changing'
              : '$changes ${changes == 1 ? 'change' : 'changes'} proposed${held > 0 ? ', $held held by guardrails' : ''}'),
          action: changes == 0 ? null : SnackBarAction(label: 'Review', onPressed: () => context.go(Routes.changes)),
        ),
      );
    } on ApiException catch (e) {
      if (mounted) _snack(e.message, error: true);
    } finally {
      if (mounted) setState(() => _proposing = false);
    }
  }

  Future<void> _loadFilterOptions() async {
    if (_teams.isNotEmpty || _skills.isNotEmpty) return;
    try {
      final r = await Api.post('people.php', 'list');
      _teams = (r['teams'] is List ? r['teams'] as List : const [])
          .whereType<Map>()
          .map((m) => (id: asIntOr(m['id'], 0), name: asStrOr(m['name'], '')))
          .toList();
    } catch (_) {/* the filter still works without teams */}
    try {
      final r = await Api.post('skills.php', 'list');
      _skills = (r['skills'] is List ? r['skills'] as List : const [])
          .whereType<Map>()
          .map((m) => (id: asIntOr(m['id'], 0), name: asStrOr(m['name'], '')))
          .toList();
    } catch (_) {/* ditto for skills */}
  }

  void _clearFilters() {
    setState(() {
      _teamId = null;
      _typeId = null;
      _skillId = null;
      _itemId = null;
    });
    _load();
  }

  Future<void> _openFilters() async {
    await _loadFilterOptions();
    if (!mounted) return;
    final config = context.read<WorkspaceConfig>();
    final items = <({int id, String label})>[];
    for (final b in _data?.blocks ?? const <SchBlock>[]) {
      if (items.any((i) => i.id == b.workItemId)) continue;
      items.add((id: b.workItemId, label: dotJoin([b.ref, b.title])));
    }
    items.sort((a, b) => a.label.compareTo(b.label));

    var team = _teamId;
    var type = _typeId;
    var skill = _skillId;
    var item = _itemId;

    final applied = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialog) => AlertDialog(
          title: const Text('Filter the schedule'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int?>(
                  initialValue: team,
                  decoration: const InputDecoration(labelText: 'Team'),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('All teams')),
                    for (final t in _teams) DropdownMenuItem<int?>(value: t.id, child: Text(t.name)),
                  ],
                  onChanged: (v) => setDialog(() => team = v),
                ),
                const SizedBox(height: Sp.md),
                DropdownButtonFormField<int?>(
                  initialValue: type,
                  decoration: const InputDecoration(labelText: 'Work type'),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('All work types')),
                    for (final t in config.activeWorkTypes) DropdownMenuItem<int?>(value: t.id, child: Text(t.name)),
                  ],
                  onChanged: (v) => setDialog(() => type = v),
                ),
                const SizedBox(height: Sp.md),
                DropdownButtonFormField<int?>(
                  initialValue: skill,
                  decoration: const InputDecoration(labelText: 'Skill'),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('Any skill')),
                    for (final s in _skills) DropdownMenuItem<int?>(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (v) => setDialog(() => skill = v),
                ),
                const SizedBox(height: Sp.md),
                DropdownButtonFormField<int?>(
                  initialValue: item,
                  decoration: const InputDecoration(labelText: 'Item'),
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('All items')),
                    for (final i in items) DropdownMenuItem<int?>(value: i.id, child: Text(i.label, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setDialog(() => item = v),
                ),
              ],
            ),
          ),
          actions: [
            SecondaryButton('Clear all', onPressed: () => setDialog(() {
                  team = null;
                  type = null;
                  skill = null;
                  item = null;
                })),
            SecondaryButton('Cancel', onPressed: () => Navigator.of(dialogContext).pop(false)),
            PrimaryButton('Apply', onPressed: () => Navigator.of(dialogContext).pop(true)),
          ],
        ),
      ),
    );
    if (applied != true) return;
    setState(() {
      _teamId = team;
      _typeId = type;
      _skillId = skill;
      _itemId = item;
    });
    _load();
  }

  // --- footer ----------------------------------------------------------------

  Widget _footer(ScheduleData d) {
    final candidates = d.candidates.take(3).toList();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.lg, vertical: Sp.md),
      decoration: BoxDecoration(
        color: context.panelColor,
        borderRadius: DispatchRadius.panelR,
        border: Border.all(color: context.borderColor),
      ),
      child: Wrap(
        spacing: Sp.md,
        runSpacing: Sp.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inbox_outlined, size: 18, color: context.mutedColor),
              const SizedBox(width: Sp.sm),
              Text(
                '${d.unscheduledCount} ${d.unscheduledCount == 1 ? 'item' : 'items'} unscheduled',
                style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          if (candidates.isNotEmpty) ...[
            const SizedBox(width: Sp.md),
            Text('Next candidates by priority:', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
            for (final c in candidates)
              ActionChip(
                label: Text(dotJoin([c.ref, c.title]), maxLines: 1, overflow: TextOverflow.ellipsis),
                avatar: CircleAvatar(backgroundColor: DispatchColors.parseHex(c.typeColour), radius: 5),
                onPressed: () => context.go(Routes.item(c.ref)),
              ),
          ],
          TextButton(onPressed: () => context.go(Routes.pipeline), child: const Text('Open queue')),
        ],
      ),
    );
  }

  // --- phone (MOB-02) --------------------------------------------------------

  Widget _phoneBody(ScheduleData d) {
    final person = d.people.where((p) => p.id == _selectedPersonId).firstOrNull ?? (d.people.isEmpty ? null : d.people.first);
    final blocks = person == null ? <SchBlock>[] : d.blocks.where((b) => b.personId == person.id).toList()
      ..sort((a, b) => a.from.compareTo(b.from));
    final away = person == null ? <SchAway>[] : d.away.where((a) => a.personId == person.id).toList();

    return PageBody(
      onRefresh: () => _load(silent: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Schedule', style: context.text.headlineSmall),
          const SizedBox(height: 2),
          Text(
            dotJoin([
              '$_weeksForZoom weeks from ${fmtShortDate(d.from)}',
              if (d.committedThrough != null) 'committed through ${fmtShortDate(d.committedThrough)}',
            ]),
            style: context.text.bodySmall?.copyWith(color: context.mutedColor),
          ),
          const SizedBox(height: Sp.lg),
          if (d.people.isEmpty)
            const EmptyState(icon: Icons.groups_outlined, title: 'No people in this workspace', message: 'Add people to the team to see a schedule.')
          else ...[
            DropdownButtonFormField<int>(
              initialValue: person?.id,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Person'),
              items: [
                for (final p in d.people)
                  DropdownMenuItem(
                    value: p.id,
                    child: Text('${p.name} · ${p.loadPct.round()}%', maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _selectedPersonId = v),
            ),
            const SizedBox(height: Sp.lg),
            if (person != null)
              Row(
                children: [
                  PersonAvatar(person.initialsOrDerived, colourHex: person.colourHex, seed: person.id, size: 36),
                  const SizedBox(width: Sp.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(person.name, style: context.text.titleMedium),
                        Text(dotJoin([person.roleTitle, '${person.loadPct.round()}% load']),
                            style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
                      ],
                    ),
                  ),
                ],
              ),
            const SizedBox(height: Sp.lg),
            if (blocks.isEmpty && away.isEmpty)
              EmptyState(
                icon: Icons.event_available_outlined,
                title: 'Nothing scheduled',
                message: 'No work is scheduled for ${person?.name ?? 'this person'} in this window.',
              )
            else
              ..._phoneWeeks(d, blocks, away),
          ],
        ],
      ),
    );
  }

  List<Widget> _phoneWeeks(ScheduleData d, List<SchBlock> blocks, List<SchAway> away) {
    final out = <Widget>[];
    for (final w in _weekStarts()) {
      final end = w.add(const Duration(days: 6));
      final inWeek = blocks.where((b) => !b.to.isBefore(w) && !b.from.isAfter(end)).toList();
      final awayWeek = away.where((a) => !a.to.isBefore(w) && !a.from.isAfter(end)).toList();
      if (inWeek.isEmpty && awayWeek.isEmpty) continue;
      out.add(SectionLabel(
        fmtWeekCommencing(w),
        trailing: Text(humanise(_stateFor(d, w)), style: context.text.labelSmall?.copyWith(color: context.mutedColor)),
      ));
      for (final a in awayWeek) {
        out.add(Padding(
          padding: const EdgeInsets.only(bottom: Sp.sm),
          child: SizedBox(height: 40, child: SchBlockCard(away: true, title: dotJoin([a.label, fmtDateRange(a.from, a.to)]))),
        ));
      }
      for (final b in inWeek) {
        out.add(Padding(
          padding: const EdgeInsets.only(bottom: Sp.sm),
          child: IntrinsicHeight(
            child: DispatchCard(
            accent: DispatchColors.parseHex(b.typeColour),
            dashed: b.isIndicative,
            onTap: b.ref == null ? null : () => context.go(Routes.item(b.ref!)),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(dotJoin([b.ref, b.title]), style: context.text.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        dotJoin([fmtDateRange(b.from, b.to), '${b.allocationPct}%', b.roleLabel, if (b.isIndicative) 'indicative']),
                        style: context.text.bodySmall?.copyWith(color: context.mutedColor),
                      ),
                    ],
                  ),
                ),
                if (b.sizeStamp != null) SizeStamp(b.sizeStamp, size: 24),
                if (b.locked) Padding(padding: const EdgeInsets.only(left: Sp.sm), child: Icon(Icons.lock_outline, size: 14, color: context.mutedColor)),
              ],
            ),
            ),
          ),
        ));
      }
    }
    if (out.isEmpty) {
      out.add(const EmptyState(icon: Icons.event_available_outlined, title: 'Nothing scheduled in this window'));
    }
    return out;
  }

  // --- helpers ---------------------------------------------------------------

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? DispatchColors.red : null,
      ),
    );
  }

  List<DateTime> _weekStarts() {
    final out = <DateTime>[];
    final d = _data;
    if (d == null) return out;
    var w = _mondayOf(d.from);
    while (!w.isAfter(d.to)) {
      out.add(w);
      w = w.add(const Duration(days: 7));
    }
    return out;
  }

  String _stateFor(ScheduleData d, DateTime weekStart) {
    final match = d.weeks.where((w) => _sameDay(w.start, weekStart)).firstOrNull;
    if (match != null) return match.state;
    if (d.freezeEnd != null && !weekStart.isAfter(d.freezeEnd!)) return 'committed';
    if (d.plannedEnd != null && !weekStart.isAfter(d.plannedEnd!)) return 'planned';
    return 'indicative';
  }

  int _indexOf(DateTime d) {
    final exact = _dayIndex[_iso(d)];
    if (exact != null) return exact;
    for (var i = 0; i < _days.length; i++) {
      if (!_days[i].isBefore(d)) return i;
    }
    return math.max(0, _days.length - 1);
  }

  /// A date for a working-day index, extending past the visible range when needed.
  DateTime _dateAtIndex(int index) {
    if (_days.isEmpty) return DateTime.now();
    if (index >= 0 && index < _days.length) return _days[index];
    if (index < 0) {
      var d = _days.first;
      for (var i = 0; i > index; i--) {
        d = d.subtract(const Duration(days: 1));
        while (d.weekday > DateTime.friday) {
          d = d.subtract(const Duration(days: 1));
        }
      }
      return d;
    }
    var d = _days.last;
    for (var i = _days.length - 1; i < index; i++) {
      d = d.add(const Duration(days: 1));
      while (d.weekday > DateTime.friday) {
        d = d.add(const Duration(days: 1));
      }
    }
    return d;
  }

  DateTime? _nextWorkingDay(DateTime d) {
    var n = d.add(const Duration(days: 1));
    while (n.weekday > DateTime.friday) {
      n = n.add(const Duration(days: 1));
    }
    return n;
  }
}

// ---------------------------------------------------------------------------

/// A block or an away period placed on the working-day axis of one lane.
class _Placed {
  _Placed({required this.startIdx, required this.endIdx, required this.personId, this.block, this.away, this.ghost = false});
  final int startIdx;
  final int endIdx;
  final int personId;
  final SchBlock? block;
  final SchAway? away;
  final bool ghost;
  int row = 0;
}

/// The lane background: week rules, the committed tint and its lock rule, the
/// indicative hatch and the orange line for today.
class _LanePainter extends CustomPainter {
  _LanePainter({
    required this.days,
    required this.dayWidth,
    required this.zoom,
    required this.today,
    required this.freezeEnd,
    required this.plannedEnd,
    required this.gridColour,
    required this.weekColour,
    required this.committedTint,
    required this.hatchColour,
    required this.todayColour,
  });

  final List<DateTime> days;
  final double dayWidth;
  final SchZoom zoom;
  final DateTime? today;
  final DateTime? freezeEnd;
  final DateTime? plannedEnd;
  final Color gridColour;
  final Color weekColour;
  final Color committedTint;
  final Color hatchColour;
  final Color todayColour;

  int _indexFor(DateTime d) {
    for (var i = 0; i < days.length; i++) {
      if (!days[i].isBefore(d)) return i;
    }
    return days.length;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (days.isEmpty) return;
    // committed region tint
    if (freezeEnd != null) {
      final end = _indexFor(freezeEnd!);
      final x = math.min(size.width, (end + 1) * dayWidth);
      if (x > 0) canvas.drawRect(Rect.fromLTWH(0, 0, x, size.height), Paint()..color = committedTint);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), Paint()..color = gridColour..strokeWidth = 1.6);
    }
    // indicative region hatch
    if (plannedEnd != null) {
      final start = _indexFor(plannedEnd!) + 1;
      final x = start * dayWidth;
      if (x < size.width) {
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(x, 0, size.width - x, size.height));
        SchHatchPainter(colour: hatchColour, spacing: 9).paint(canvas, size);
        canvas.restore();
      }
    }
    // column rules
    final rule = Paint()..strokeWidth = 1;
    for (var i = 0; i < days.length; i++) {
      final isWeekEnd = days[i].weekday == DateTime.friday;
      if (zoom != SchZoom.days && !isWeekEnd) continue;
      rule.color = isWeekEnd ? gridColour : weekColour;
      final x = (i + 1) * dayWidth;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), rule);
    }
    // bottom rule
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), Paint()..color = gridColour..strokeWidth = 1);
    // today
    if (today != null) {
      for (var i = 0; i < days.length; i++) {
        if (days[i].year == today!.year && days[i].month == today!.month && days[i].day == today!.day) {
          final x = i * dayWidth;
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), Paint()..color = todayColour..strokeWidth = 2);
          break;
        }
      }
    }
  }

  @override
  bool shouldRepaint(_LanePainter old) =>
      old.dayWidth != dayWidth || old.days.length != days.length || old.freezeEnd != freezeEnd || old.today != today || old.zoom != zoom;
}

// --- small date helpers -----------------------------------------------------

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _mondayOf(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  return day.subtract(Duration(days: day.weekday - DateTime.monday));
}

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

String _dow(DateTime d) => const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1];

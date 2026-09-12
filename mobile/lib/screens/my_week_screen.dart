import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/json.dart';
import '../services/api.dart';
import '../services/format.dart';
import '../services/my_week_cache.dart';
import '../shell/app_shell.dart';
import '../shell/nav.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/my_week_widgets.dart';
import '../widgets/widgets.dart';

/// My week (section 9.5, MOB-01/03, CHG-06, NOT-01): the day strip, changes
/// that affect you, the selected day's assignments with progress, the incident
/// reserve, what is coming up and your load against the target band.
///
/// Data comes from `overview.php my_week {week_start?, person_id?}`; the last
/// successful payload is cached so the week is readable offline.
class MyWeekScreen extends StatefulWidget {
  const MyWeekScreen({super.key});

  @override
  State<MyWeekScreen> createState() => _MyWeekScreenState();
}

class _MyWeekScreenState extends State<MyWeekScreen> {
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _mine; // changes.php mine — own week only
  String? _error;
  bool _loading = true;
  bool _offline = false;
  bool _busy = false;
  DateTime? _cachedAt;
  DateTime? _weekStart;
  int _selectedDay = 0;

  /// Set when an account with no linked person picks someone to view.
  int? _viewPersonId;
  List<Map<String, dynamic>> _people = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Session get _session => context.read<Session>();

  /// The person whose week we ask for: the chosen person, else the account's own.
  int? get _targetPersonId => _viewPersonId ?? _session.user?.personId;

  /// True when the signed-in account is looking at its own week.
  bool get _ownWeek => _viewPersonId == null && _session.user?.personId != null;

  static String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _bootstrap() async {
    if (!mounted) return;
    context.read<ShellState>().setPageTitle('My week');
    final session = _session;
    if (session.user?.personId == null) {
      if (session.can('team_lead')) {
        await _loadPeople();
      }
      if (mounted) setState(() => _loading = false);
      return;
    }
    await _load();
  }

  Future<void> _loadPeople() async {
    try {
      final r = await Api.post('people.php', 'list');
      if (!mounted) return;
      final people = (r['people'] is List ? r['people'] as List : const [])
          .whereType<Map>()
          .map((p) => Map<String, dynamic>.from(p))
          .where((p) => asBool(p['active'], fallback: true))
          .toList()
        ..sort((a, b) => asStrOr(a['name'], '').compareTo(asStrOr(b['name'], '')));
      setState(() => _people = people);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  Future<void> _load({DateTime? week, bool keepDay = false}) async {
    final target = _targetPersonId;
    if (target == null) return;
    if (mounted) {
      setState(() {
        _loading = _data == null;
        _error = null;
      });
    }
    final requested = week ?? _weekStart;
    final body = <String, dynamic>{
      if (requested != null) 'week_start': _iso(requested),
      if (_viewPersonId != null) 'person_id': _viewPersonId,
    };
    try {
      final r = await Api.post('overview.php', 'my_week', body);
      if (!mounted) return;
      final weekMap = asMap(r['week']);
      final startIso = asStrOr(weekMap['week_start'], requested == null ? '' : _iso(requested));
      final start = parseDate(startIso);
      setState(() {
        _data = r;
        _error = null;
        _offline = false;
        _cachedAt = null;
        _loading = false;
        _weekStart = start ?? _weekStart;
        _selectedDay = keepDay ? _selectedDay.clamp(0, 4) : _todayIndex(weekMap);
      });
      if (startIso.isNotEmpty) await MyWeekCache.save(_viewPersonId, startIso, r);
      if (_ownWeek) _loadMine();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 0) {
        final cached = requested == null
            ? await MyWeekCache.readAny(_viewPersonId)
            : (await MyWeekCache.read(_viewPersonId, _iso(requested)) ?? await MyWeekCache.readAny(_viewPersonId));
        if (!mounted) return;
        if (cached != null) {
          final weekMap = asMap(cached.data['week']);
          setState(() {
            _data = cached.data;
            _cachedAt = cached.savedAt;
            _offline = true;
            _loading = false;
            _error = null;
            _weekStart = parseDate(asStr(weekMap['week_start'])) ?? _weekStart;
            _selectedDay = keepDay ? _selectedDay.clamp(0, 4) : _todayIndex(weekMap);
          });
          return;
        }
      }
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// Pending acknowledgements (CHG-06). Best effort: a failure here must not
  /// disturb the week.
  void _loadMine() {
    Api.post('changes.php', 'mine').then((r) {
      if (mounted) setState(() => _mine = r);
    }).catchError((Object _) {});
  }

  int _todayIndex(Map<String, dynamic> weekMap) {
    final days = (weekMap['days'] is List ? weekMap['days'] as List : const []).whereType<Map>().toList();
    for (var i = 0; i < days.length; i++) {
      if (asBool(days[i]['is_today'])) return i;
    }
    return 0;
  }

  void _shiftWeek(int weeks) {
    final base = _weekStart;
    if (base == null) return;
    _load(week: base.add(Duration(days: 7 * weeks)));
  }

  Future<void> _logProgress(MwAssignment a) async {
    final entry = await showMwLogProgress(context, ref: a.ref, title: a.title, initialPct: a.progressPct);
    if (entry == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await Api.post('work_items.php', 'log_progress', {
        'id': a.workItemId,
        'progress_pct': entry.progressPct,
        if (entry.effortDays != null) 'effort_days': entry.effortDays,
        if (entry.note != null) 'note': entry.note,
      });
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Progress saved for ${a.ref}.')));
      await _load(week: _weekStart, keepDay: true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _acknowledge(int changeId) async {
    setState(() => _busy = true);
    try {
      await Api.post('changes.php', 'acknowledge', {'change_id': changeId});
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Thank you — that change is acknowledged.')));
      _loadMine();
      context.read<ShellState>().refreshCounts();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  // ─── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final unlinked = session.user?.personId == null;

    if (unlinked && !session.can('team_lead')) {
      return PageBody(
        maxWidth: 720,
        child: Column(children: const [
          SizedBox(height: Sp.xxl),
          EmptyState(
            icon: Icons.person_off_outlined,
            title: 'No week to show',
            message: 'Your account is not linked to a team member, so there is no planned week to show. '
                'Ask a delivery lead to link your account, or browse the schedule instead.',
          ),
        ]),
      );
    }

    if (_loading && _data == null) return _skeleton();
    if (_error != null && _data == null) {
      return PageBody(
        maxWidth: 720,
        child: Column(children: [
          if (unlinked) ...[_picker(), const SizedBox(height: Sp.lg)],
          const SizedBox(height: Sp.xl),
          ErrorState(message: _error, onRetry: () => _load(week: _weekStart, keepDay: true)),
        ]),
      );
    }

    if (_data == null) {
      // A lead with no linked person who has not chosen anyone yet.
      return PageBody(
        maxWidth: 720,
        child: Column(children: [
          _picker(),
          const SizedBox(height: Sp.xl),
          const EmptyState(
            icon: Icons.groups_outlined,
            title: 'Choose a team member',
            message: 'Your account is not linked to a team member. Pick someone above to see their week.',
          ),
        ]),
      );
    }

    return PageBody(
      maxWidth: 720,
      onRefresh: () => _load(week: _weekStart, keepDay: true),
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v > 220) _shiftWeek(-1);
          if (v < -220) _shiftWeek(1);
        },
        child: _content(unlinked),
      ),
    );
  }

  Widget _picker() => MwPersonPicker(
        people: _people,
        selected: _viewPersonId,
        onChanged: (id) {
          if (id == null) return;
          setState(() {
            _viewPersonId = id;
            _data = null;
            _weekStart = null;
            _loading = true;
          });
          _load();
        },
      );

  Widget _content(bool unlinked) {
    final data = _data!;
    final person = asMap(data['person']);
    final weekMap = asMap(data['week']);
    final days = (weekMap['days'] is List ? weekMap['days'] as List : const []).whereType<Map>().map((d) => MwDay(Map<String, dynamic>.from(d))).toList();
    final weekStart = parseDate(weekMap['week_start']);
    final weekEnd = parseDate(weekMap['week_end']);
    final firstName = asStrOr(person['first_name'], asStrOr(person['name'], 'This person').split(' ').first);
    final personId = asInt(person['id']);
    final changes = (data['changes_affecting'] is List ? data['changes_affecting'] as List : const []).whereType<Map>().map((c) => Map<String, dynamic>.from(c)).toList();
    final coming = (data['coming_up'] is List ? data['coming_up'] as List : const []).whereType<Map>().map((a) => MwAssignment(Map<String, dynamic>.from(a))).toList();
    final reserve = asMap(data['reserve']);
    final policy = context.read<WorkspaceConfig>().policy;
    final hoursPerDay = context.read<WorkspaceConfig>().workspace?.hoursPerDay ?? 7.5;
    final selected = days.isEmpty ? null : days[_selectedDay.clamp(0, days.length - 1)];
    final showsToday = days.any((d) => d.isToday);

    final pendingAck = ((_mine?['pending_ack'] is List ? _mine!['pending_ack'] as List : const [])).whereType<Map>().map((c) => Map<String, dynamic>.from(c)).toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Header: title, subtitle, avatar.
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('My week', style: context.text.headlineLarge),
            const SizedBox(height: 4),
            Text(dotJoin([firstName, fmtDateRange(weekStart, weekEnd)]), style: context.text.bodyLarge?.copyWith(color: context.mutedColor)),
          ]),
        ),
        if (personId != null) ...[
          const SizedBox(width: Sp.md),
          Semantics(
            button: true,
            label: 'Open ${asStrOr(person['name'], firstName)}',
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => context.push(Routes.person(personId)),
              child: Padding(
                padding: const EdgeInsets.all(Sp.xs),
                child: PersonAvatar(
                  asStrOr(person['initials'], initialsOf(asStr(person['name']))),
                  colourHex: asStr(person['colour']),
                  seed: personId,
                  size: 40,
                ),
              ),
            ),
          ),
        ],
      ]),
      if (unlinked) ...[const SizedBox(height: Sp.lg), _picker()],
      if (_offline) ...[
        const SizedBox(height: Sp.lg),
        MwOfflineBanner(savedAt: _cachedAt, onRetry: () => _load(week: _weekStart, keepDay: true)),
      ],

      const SizedBox(height: Sp.sm),
      MwWeekNav(
        label: fmtWeekCommencing(weekStart ?? DateTime.now()),
        onPrevious: () => _shiftWeek(-1),
        onNext: () => _shiftWeek(1),
        onToday: showsToday ? null : () => _load(),
      ),
      const SizedBox(height: Sp.sm),
      if (days.isNotEmpty)
        MwDayStrip(
          days: days,
          selected: _selectedDay.clamp(0, days.length - 1),
          onSelect: (i) => setState(() => _selectedDay = i),
        ),

      if (changes.isNotEmpty) ...[
        const SizedBox(height: Sp.lg),
        MwChangesBanner(
          count: changes.length,
          headline: asStr(changes.first['headline']),
          onReview: () => context.push(Routes.changes),
        ),
      ],

      for (final c in pendingAck) ...[
        const SizedBox(height: Sp.lg),
        _AckCard(
          headline: asStrOr(c['headline'], 'A committed change affects you'),
          reason: asStr(c['reason']),
          busy: _busy,
          onOpen: () => context.push(Routes.change(asIntOr(c['proposal_id'], 0))),
          onAcknowledge: () => _acknowledge(asIntOr(c['id'], 0)),
        ),
      ],

      // The selected day.
      if (selected != null) ...[
        SectionLabel(selected.sectionLabel),
        if (selected.onLeave)
          MwLeaveCard(label: selected.leaveLabel ?? 'Leave', date: selected.date)
        else if (selected.assignments.isEmpty)
          DispatchCard(
            padding: const EdgeInsets.symmetric(vertical: Sp.lg),
            child: EmptyState(
              compact: true,
              icon: Icons.event_available_outlined,
              title: 'Nothing scheduled',
              message: 'No work is scheduled for $firstName on ${fmtShortDate(selected.date)}. Propose a replan or add work.',
              action: PrimaryButton('Add work', icon: Icons.add_rounded, onPressed: () => context.push(Routes.addWork)),
            ),
          )
        else
          for (final a in selected.assignments) ...[
            MwAssignmentCard(
              assignment: a,
              typeColour: context.read<WorkspaceConfig>().typeColour(id: asInt(a.raw['work_type_id']), name: a.typeName, hex: a.typeColour),
              onTap: a.ref.isEmpty ? null : () => context.push(Routes.item(a.ref)),
              onLogProgress: (_ownWeek && !_offline && context.read<Session>().can('team_member')) ? () => _logProgress(a) : null,
            ),
            const SizedBox(height: Sp.md),
          ],
        if (!selected.onLeave) ...[
          const SizedBox(height: Sp.xs),
          MwReserveCard(
            pct: asDoubleOr(reserve['pct'], 0),
            hoursWeek: asDoubleOr(reserve['hours_week'], 0),
            usedHours: asDoubleOr(reserve['used_hours'], 0),
            onRota: asBool(reserve['on_rota']),
            hoursPerDay: hoursPerDay,
          ),
        ],
      ],

      // Coming up.
      const SectionLabel('Coming up'),
      if (coming.isEmpty)
        DispatchCard(
          padding: const EdgeInsets.all(Sp.lg),
          child: Text('Nothing is planned for $firstName after this week yet.', style: context.text.bodyMedium?.copyWith(color: context.mutedColor)),
        )
      else
        for (final a in coming) ...[
          MwComingUpCard(
            assignment: a,
            typeColour: context.read<WorkspaceConfig>().typeColour(id: asInt(a.raw['work_type_id']), name: a.typeName, hex: a.typeColour),
            onTap: a.ref.isEmpty ? null : () => context.push(Routes.item(a.ref)),
          ),
          const SizedBox(height: Sp.md),
        ],

      const SizedBox(height: Sp.md),
      MwLoadTile(
        loadPct: asIntOr(data['load_pct'], 0),
        targetMin: policy.targetLoadMin,
        targetMax: policy.targetLoadMax,
        hoursAssigned: asDoubleOr(data['hours_assigned'], 0),
        hoursAvailable: asDoubleOr(data['hours_available'], 0),
      ),
    ]);
  }

  Widget _skeleton() {
    return PageBody(
      maxWidth: 720,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
              Skeleton(width: 160, height: 26),
              SizedBox(height: Sp.sm),
              Skeleton(width: 200, height: 15),
            ]),
          ),
          const Skeleton.circle(size: 40),
        ]),
        const SizedBox(height: Sp.lg),
        Row(children: [
          for (var i = 0; i < 5; i++) ...[
            if (i > 0) const SizedBox(width: Sp.sm),
            const Expanded(child: Skeleton(height: 60, radius: DispatchRadius.card)),
          ],
        ]),
        const SizedBox(height: Sp.lg),
        const SkeletonPanel(rows: 2),
        const SizedBox(height: Sp.lg),
        const SkeletonPanel(rows: 3),
      ]),
    );
  }
}

/// A committed change inside the freeze horizon waiting for acknowledgement
/// (CHG-06).
class _AckCard extends StatelessWidget {
  const _AckCard({required this.headline, this.reason, required this.onAcknowledge, required this.onOpen, this.busy = false});
  final String headline;
  final String? reason;
  final VoidCallback onAcknowledge, onOpen;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return DispatchCard(
      accent: DispatchColors.orange,
      padding: const EdgeInsets.all(Sp.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.notification_important_outlined, size: 20, color: DispatchColors.orange),
          const SizedBox(width: Sp.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('Please acknowledge this change', style: context.text.titleMedium),
              const SizedBox(height: 2),
              Text(headline, style: context.text.bodyMedium),
              if (reason != null && reason!.isNotEmpty) ...[const SizedBox(height: 2), Text(reason!, style: context.text.bodySmall)],
            ]),
          ),
        ]),
        const SizedBox(height: Sp.md),
        Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
          PrimaryButton('Acknowledge', busy: busy, onPressed: busy ? null : onAcknowledge),
          SecondaryButton('Open change', onPressed: onOpen),
        ]),
      ]),
    );
  }
}

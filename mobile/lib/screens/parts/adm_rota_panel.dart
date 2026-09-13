import 'package:flutter/material.dart';

import '../../services/api.dart';
import '../../services/format.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/adm_metrics.dart';
import '../../widgets/team_widgets.dart';
import '../../widgets/widgets.dart';

/// One candidate for the incident rota.
class AdmRotaPerson {
  const AdmRotaPerson({required this.id, required this.name, this.initials, this.colourHex, this.active = true});
  final int id;
  final String name;
  final String? initials;
  final String? colourHex;
  final bool active;
}

/// The incident rota, editable (TEAM-08).
///
/// `people.php set_rota` / `clear_rota` both recompute capacity for that person
/// and week, which is what raises their incident reserve from the standard
/// percentage to the rota percentage. The panel says so before the change and
/// confirms it after, because the consequence is invisible otherwise: the only
/// other place it shows is a slightly smaller planning capacity that week.
///
/// A week may hold more than one person — TEAM-08 says "a person or people per
/// week" — so each week takes a list and keeps an add control after the first.
class AdmRotaPanel extends StatefulWidget {
  const AdmRotaPanel({
    super.key,
    required this.people,
    required this.rota,
    required this.today,
    required this.canEdit,
    required this.onChanged,
    this.incidentReservePct = 12,
    this.rotaReservePct = 25,
    this.weeks = 8,
  });

  /// Everyone in the workspace; inactive people are never offered the rota.
  final List<AdmRotaPerson> people;

  /// Rota weeks (Mondays) per person id, as `people.php list` returns them.
  final Map<int, List<DateTime>> rota;

  /// The server's today — the demo clock can differ from the browser's, so the
  /// week list is anchored on what the API reports rather than DateTime.now().
  final DateTime today;

  final bool canEdit;
  final Future<void> Function() onChanged;
  final double incidentReservePct;
  final double rotaReservePct;
  final int weeks;

  @override
  State<AdmRotaPanel> createState() => _AdmRotaPanelState();
}

class _AdmRotaPanelState extends State<AdmRotaPanel> {
  DateTime? _busyWeek;
  String? _error;

  static DateTime _mondayOf(DateTime d) {
    final day = DateTime(d.year, d.month, d.day);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  /// The next [weeks] Mondays, extended so a rota week already set further out
  /// is never hidden.
  List<DateTime> get _weekList {
    final first = _mondayOf(widget.today);
    final list = [for (var i = 0; i < widget.weeks; i++) first.add(Duration(days: 7 * i))];
    var last = list.last;
    for (final weeks in widget.rota.values) {
      for (final w in weeks) {
        final m = _mondayOf(w);
        if (m.isAfter(last)) last = m;
      }
    }
    while (list.last.isBefore(last)) {
      list.add(list.last.add(const Duration(days: 7)));
    }
    return list;
  }

  List<AdmRotaPerson> _onRota(DateTime week) {
    final out = <AdmRotaPerson>[];
    for (final p in widget.people) {
      final weeks = widget.rota[p.id] ?? const <DateTime>[];
      if (weeks.any((w) => _sameDay(_mondayOf(w), week))) out.add(p);
    }
    return out;
  }

  String _weekHint(DateTime week) {
    final thisWeek = _mondayOf(widget.today);
    final diff = week.difference(thisWeek).inDays ~/ 7;
    return switch (diff) {
      0 => 'This week',
      1 => 'Next week',
      _ => 'In $diff weeks',
    };
  }

  Future<void> _post(String action, DateTime week, AdmRotaPerson person) async {
    setState(() {
      _busyWeek = week;
      _error = null;
    });
    try {
      await Api.post('people.php', action, {'person_id': person.id, 'week_start': _iso(week)});
      if (!mounted) return;
      final on = action == 'set_rota';
      tmToast(
        context,
        on
            ? '${person.name} is on the incident rota for ${fmtWeekCommencing(week)} — their incident reserve rises to ${widget.rotaReservePct.round()}% that week, '
                'so they can take less planned work'
            : '${person.name} is off the incident rota for ${fmtWeekCommencing(week)} — their incident reserve returns to ${widget.incidentReservePct.round()}%',
      );
      await widget.onChanged();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busyWeek = null);
    }
  }

  Future<void> _assign(DateTime week, List<AdmRotaPerson> already) async {
    final taken = already.map((p) => p.id).toSet();
    final options = widget.people.where((p) => p.active && !taken.contains(p.id)).toList();
    if (options.isEmpty) {
      tmToast(context, 'Everyone is already on the rota for ${fmtWeekCommencing(week)}');
      return;
    }
    final picked = await showDialog<AdmRotaPerson>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Incident rota · ${fmtWeekCommencing(week)}'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.lg, 0, Sp.lg, Sp.md),
            child: Text(
              'Their incident reserve for that week rises from ${widget.incidentReservePct.round()}% to ${widget.rotaReservePct.round()}%, '
              'and their capacity is recomputed straight away.',
              style: context.text.bodyMedium?.copyWith(color: context.mutedColor),
            ),
          ),
          for (final p in options)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(p),
              child: Row(children: [
                PersonAvatar(p.initials ?? initialsOf(p.name), colourHex: p.colourHex, seed: p.id, size: 26),
                const SizedBox(width: Sp.md),
                Expanded(child: Text(p.name, style: context.text.bodyLarge)),
              ]),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    await _post('set_rota', week, picked);
  }

  @override
  Widget build(BuildContext context) {
    final weeks = _weekList;
    return TmMetricPanel(
      title: 'Incident rota',
      subtitle: 'Next ${weeks.length} weeks',
      definition: AdmMetrics.incidentRota(incidentReservePct: widget.incidentReservePct, rotaReservePct: widget.rotaReservePct),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TmInfoBox(
          'A rota week raises that person’s incident reserve from ${widget.incidentReservePct.round()}% to ${widget.rotaReservePct.round()}% of their capacity. '
          'Capacity is recomputed as soon as the rota changes, so they can take less planned work that week.',
          icon: Icons.shield_outlined,
        ),
        const SizedBox(height: Sp.sm),
        LayoutBuilder(builder: (context, c) {
          final narrow = c.maxWidth < 520;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < weeks.length; i++) ...[
              if (i > 0) Divider(height: 1, thickness: 1, color: context.borderColor),
              _weekRow(context, weeks[i], narrow),
            ],
          ]);
        }),
        if (_error != null) TmInlineError(_error!),
        if (!widget.canEdit) ...[
          const SizedBox(height: Sp.sm),
          Text(
            'A team lead or above assigns the rota.',
            style: context.text.bodySmall?.copyWith(color: context.mutedColor),
          ),
        ],
      ]),
    );
  }

  Widget _weekRow(BuildContext context, DateTime week, bool narrow) {
    final on = _onRota(week);
    final busy = _busyWeek != null && _sameDay(_busyWeek!, week);
    final isThisWeek = _sameDay(week, _mondayOf(widget.today));

    final label = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(fmtWeekCommencing(week), style: isThisWeek ? context.text.titleSmall : context.text.bodyMedium),
      Text(_weekHint(week), style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
    ]);

    final people = on.isEmpty
        ? Text('No one on rota', style: context.text.bodyMedium?.copyWith(color: context.mutedColor))
        : Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
            for (final p in on) _personChip(context, p, week, busy),
          ]);

    final action = busy
        ? const Padding(
            padding: EdgeInsets.symmetric(horizontal: Sp.md),
            child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          )
        : (!widget.canEdit
            ? const SizedBox.shrink()
            : (on.isEmpty
                ? SecondaryButton('Assign', icon: Icons.person_add_alt_1_rounded, onPressed: () => _assign(week, on))
                : IconButton(
                    onPressed: () => _assign(week, on),
                    icon: const Icon(Icons.person_add_alt_1_rounded, size: 17),
                    tooltip: 'Add someone else to ${fmtWeekCommencing(week)}',
                    visualDensity: VisualDensity.compact,
                  )));

    if (narrow) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          label,
          const SizedBox(height: Sp.sm),
          people,
          if (widget.canEdit || busy) ...[const SizedBox(height: Sp.sm), Align(alignment: Alignment.centerLeft, child: action)],
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.md),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(width: 132, child: label),
        const SizedBox(width: Sp.md),
        Expanded(child: people),
        const SizedBox(width: Sp.sm),
        action,
      ]),
    );
  }

  Widget _personChip(BuildContext context, AdmRotaPerson p, DateTime week, bool busy) {
    return Container(
      padding: EdgeInsets.fromLTRB(4, 3, widget.canEdit ? 0 : Sp.md, 3),
      decoration: BoxDecoration(
        color: DispatchColors.tint(DispatchColors.red, opacity: context.isDark ? 0.18 : 0.07),
        borderRadius: DispatchRadius.chipR,
        border: Border.all(color: DispatchColors.tint(DispatchColors.red, opacity: 0.3)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        PersonAvatar(p.initials ?? initialsOf(p.name), colourHex: p.colourHex, seed: p.id, size: 22),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            p.active ? p.name : '${p.name} (deactivated)',
            style: context.text.bodyMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 6),
        Text('${widget.rotaReservePct.round()}% reserve', style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
        if (widget.canEdit)
          IconButton(
            onPressed: busy ? null : () => _post('clear_rota', week, p),
            icon: const Icon(Icons.close_rounded, size: 15),
            tooltip: 'Take ${p.name} off the rota for ${fmtWeekCommencing(week)}',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          ),
      ]),
    );
  }
}

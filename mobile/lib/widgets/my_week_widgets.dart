import 'package:flutter/material.dart';

import '../models/json.dart';
import '../services/format.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'widgets.dart';

/// Widgets for the My week screen (section 9.5, MOB-01/03). Prefix `Mw` so
/// they never collide with the shared shell widgets.

/// Navy surface that reads correctly in both themes (the day strip's selected
/// tile and the "changes affect you" banner).
Color mwNavy(BuildContext context) => context.isDark ? DispatchColors.sidebarActive : DispatchColors.ink;

/// Animation duration that collapses to zero when the platform asks for
/// reduced motion.
Duration mwMotion(BuildContext context) => MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 160);

/// One assignment row from `overview.php my_week` (day lists and coming up).
///
/// The endpoint returns the whole assignment plus convenience fields the API
/// contract does not list (`status_label`, `due_label`, `state_label`,
/// `day_n`/`day_total`, `with`, `range_label`), so this reads the raw map
/// rather than a shared model.
class MwAssignment {
  const MwAssignment(this.raw);
  final Map<String, dynamic> raw;

  int get id => asIntOr(raw['id'], 0);
  int get workItemId => asIntOr(raw['work_item_id'], 0);
  String get ref => asStrOr(raw['ref'], '');
  String get title => asStrOr(raw['title'], '');
  String get typeName => asStrOr(raw['type_name'], '');
  String? get typeColour => asStr(raw['type_colour']);
  String get typePolicy => asStrOr(raw['type_policy'], 'planned');
  String? get sizeStamp => asStr(raw['size_stamp']);
  String? get roleLabel => asStr(raw['role_label']);
  int get allocationPct => asIntOr(raw['allocation_pct'] ?? raw['pct_of_day'], 0);
  double? get hours => asDouble(raw['hours']);
  int get progressPct => asIntOr(raw['progress_pct'], 0);
  int? get dayN => asInt(raw['day_n']);
  int? get dayTotal => asInt(raw['day_total']);
  bool get isReserve => asBool(raw['is_reserve']);
  bool get locked => asBool(raw['locked']);
  String get state => asStrOr(raw['state'], 'planned');
  String? get stateLabel => asStr(raw['state_label']);
  String? get statusLabel => asStr(raw['status_label']);
  String? get dueLabel => asStr(raw['due_label']);
  DateTime? get from => asDate(raw['from_date']);
  DateTime? get to => asDate(raw['to_date']);
  List<String> get withWhom => asStrList(raw['with']);

  /// 'with Jon', 'with Jon and Sam', 'with Jon, Sam and Hana'.
  String? get withLabel {
    final names = withWhom.where((n) => n.trim().isNotEmpty).toList();
    if (names.isEmpty) return null;
    if (names.length == 1) return 'with ${names.first}';
    return 'with ${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }
}

/// One day of the week strip.
class MwDay {
  const MwDay(this.raw);
  final Map<String, dynamic> raw;

  DateTime? get date => asDate(raw['date']);
  String get dow => asStrOr(raw['dow'], '');
  int get dayNum => asIntOr(raw['day_num'], 0);
  bool get isToday => asBool(raw['is_today']);
  bool get onLeave => asBool(raw['leave']);
  String? get leaveLabel => asStr(raw['leave_label']);
  double get hoursAvailable => asDoubleOr(raw['hours_available'], 0);
  double get hoursAssigned => asDoubleOr(raw['hours_assigned'], 0);
  List<MwAssignment> get assignments =>
      (raw['assignments'] is List ? (raw['assignments'] as List) : const []).whereType<Map>().map((a) => MwAssignment(Map<String, dynamic>.from(a))).toList();

  /// 'Today · Tue 8 Sep' / 'Wed 9 Sep'
  String get sectionLabel => isToday ? 'Today · ${fmtShortDate(date)}' : fmtShortDate(date);
}

// ─── Week navigation ──────────────────────────────────────────────────────

/// Previous / next week arrows around the week label.
class MwWeekNav extends StatelessWidget {
  const MwWeekNav({super.key, required this.label, required this.onPrevious, required this.onNext, this.onToday});
  final String label;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback? onToday;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      IconBox(Icons.chevron_left_rounded, tooltip: 'Previous week', onPressed: onPrevious),
      Expanded(
        child: Center(
          child: Text(label, textAlign: TextAlign.center, style: context.text.titleSmall?.copyWith(color: context.mutedColor)),
        ),
      ),
      if (onToday != null) ...[
        TextButton(onPressed: onToday, child: const Text('This week')),
        const SizedBox(width: Sp.xs),
      ],
      IconBox(Icons.chevron_right_rounded, tooltip: 'Next week', onPressed: onNext),
    ]);
  }
}

/// Mon 7 … Fri 11. Selected day filled navy, today outlined orange.
class MwDayStrip extends StatelessWidget {
  const MwDayStrip({super.key, required this.days, required this.selected, required this.onSelect});
  final List<MwDay> days;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < days.length; i++) ...[
          if (i > 0) const SizedBox(width: Sp.sm),
          Expanded(child: _MwDayTile(day: days[i], selected: i == selected, onTap: () => onSelect(i))),
        ],
      ],
    );
  }
}

class _MwDayTile extends StatelessWidget {
  const _MwDayTile({required this.day, required this.selected, required this.onTap});
  final MwDay day;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final navy = mwNavy(context);
    final fg = selected ? Colors.white : context.inkColor;
    final border = selected
        ? navy
        : day.isToday
            ? DispatchColors.orange
            : context.borderColor;
    return Semantics(
      button: true,
      selected: selected,
      label: '${fmtShortDate(day.date)}${day.isToday ? ', today' : ''}${day.onLeave ? ', on leave' : ''}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: DispatchRadius.cardR,
          child: AnimatedContainer(
            duration: mwMotion(context),
            constraints: const BoxConstraints(minHeight: 60),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: Sp.sm),
            decoration: BoxDecoration(
              color: selected ? navy : context.panelColor,
              borderRadius: DispatchRadius.cardR,
              border: Border.all(color: border, width: day.isToday && !selected ? 1.6 : 1),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  day.dow,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.labelMedium?.copyWith(color: selected ? Colors.white70 : context.mutedColor),
                ),
                const SizedBox(height: 2),
                Text('${day.dayNum}', maxLines: 1, style: DispatchTheme.numeric(size: 17, color: fg)),
                if (day.onLeave) ...[
                  const SizedBox(height: 3),
                  Container(width: 5, height: 5, decoration: BoxDecoration(color: selected ? Colors.white70 : context.mutedColor, shape: BoxShape.circle)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Banners ──────────────────────────────────────────────────────────────

/// Navy banner: proposed changes that affect this person (CHG-06, NOT-01).
class MwChangesBanner extends StatelessWidget {
  const MwChangesBanner({super.key, required this.count, this.headline, required this.onReview, this.actionLabel = 'Review', this.title, this.icon = Icons.swap_calls_rounded});
  final int count;
  final String? headline;
  final VoidCallback onReview;
  final String actionLabel;

  /// Overrides the default "N proposed changes affect you" wording, for the
  /// approval queue, which is the same banner about a different queue.
  final String? title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final title = this.title ?? (count == 1 ? '1 proposed change affects you' : '$count proposed changes affect you');
    final button = PrimaryButton(actionLabel, onPressed: onReview);
    final texts = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(title, style: context.text.titleMedium?.copyWith(color: Colors.white)),
      if (headline != null && headline!.isNotEmpty) ...[
        const SizedBox(height: 2),
        Text(headline!, style: context.text.bodySmall?.copyWith(color: Colors.white70)),
      ],
    ]);

    return Container(
      padding: const EdgeInsets.all(Sp.lg),
      decoration: BoxDecoration(color: mwNavy(context), borderRadius: DispatchRadius.panelR),
      child: LayoutBuilder(builder: (context, c) {
        final stacked = c.maxWidth < 380 || MediaQuery.textScalerOf(context).scale(14) > 20;
        final head = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: Colors.white, size: 22),
          const SizedBox(width: Sp.md),
          Expanded(child: texts),
          if (!stacked) ...[const SizedBox(width: Sp.md), button],
        ]);
        if (!stacked) return head;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [head, const SizedBox(height: Sp.md), button]);
      }),
    );
  }
}

/// "Showing your last synced week (offline)" (MOB-03).
class MwOfflineBanner extends StatelessWidget {
  const MwOfflineBanner({super.key, this.savedAt, this.onRetry});
  final DateTime? savedAt;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final when = savedAt == null ? null : 'Last synced ${fmtRelativeDay(savedAt)} at ${fmtTime(savedAt)}.';
    return Container(
      padding: const EdgeInsets.all(Sp.md),
      decoration: BoxDecoration(
        color: DispatchColors.tint(DispatchColors.amber, opacity: context.isDark ? 0.22 : 0.12),
        borderRadius: DispatchRadius.cardR,
        border: Border.all(color: DispatchColors.tint(DispatchColors.amber, opacity: 0.4)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.cloud_off_rounded, size: 20, color: DispatchColors.amber),
        const SizedBox(width: Sp.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('Showing your last synced week (offline)', style: context.text.labelLarge),
            if (when != null) ...[const SizedBox(height: 2), Text(when, style: context.text.bodySmall)],
          ]),
        ),
        if (onRetry != null) ...[
          const SizedBox(width: Sp.sm),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ]),
    );
  }
}

// ─── Cards ────────────────────────────────────────────────────────────────

/// Today's assignment: type rail, title, facts, progress, chips and the log
/// progress action.
class MwAssignmentCard extends StatelessWidget {
  const MwAssignmentCard({super.key, required this.assignment, required this.typeColour, this.onTap, this.onLogProgress});
  final MwAssignment assignment;
  final Color typeColour;
  final VoidCallback? onTap;
  final VoidCallback? onLogProgress;

  @override
  Widget build(BuildContext context) {
    final a = assignment;
    final facts = dotJoin([
      a.ref,
      a.typeName,
      a.allocationPct > 0 ? '${a.allocationPct}% today' : null,
      a.withLabel,
    ]);
    final dayLine = (a.dayN != null && a.dayTotal != null && a.dayTotal! > 0) ? 'Day ${a.dayN} of ${a.dayTotal}' : null;

    return DispatchCard(
      accent: typeColour,
      padding: const EdgeInsets.all(Sp.lg),
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(a.title, style: context.text.titleMedium)),
          if (a.sizeStamp != null) ...[const SizedBox(width: Sp.md), SizeStamp(a.sizeStamp, size: 26)],
        ]),
        const SizedBox(height: 2),
        Text(facts, style: context.text.bodySmall),
        const SizedBox(height: Sp.md),
        ProgressBar(
          a.progressPct / 100,
          colour: typeColour,
          trailing: dayLine == null ? null : Text(dayLine, style: DispatchTheme.numeric(size: 13, weight: FontWeight.w600, color: context.mutedColor)),
        ),
        const SizedBox(height: Sp.md),
        Wrap(spacing: Sp.sm, runSpacing: Sp.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (a.statusLabel != null) StatusChip(a.statusLabel!.toLowerCase(), label: a.statusLabel),
          if (a.dueLabel != null) StatusChip('scheduled', label: a.dueLabel),
          if (a.isReserve || a.typePolicy == 'interrupt') const StatusChip('scheduled', label: 'Reserve', icon: Icons.shield_outlined),
          if (onLogProgress != null)
            TextButton(
              onPressed: onLogProgress,
              style: TextButton.styleFrom(minimumSize: const Size(44, 44), padding: const EdgeInsets.symmetric(horizontal: Sp.sm)),
              child: const Text('Log progress'),
            ),
        ]),
      ]),
    );
  }
}

/// Dashed reserve card. The wording is derived from the reserve figures, not
/// hard-coded.
class MwReserveCard extends StatelessWidget {
  const MwReserveCard({super.key, required this.pct, required this.hoursWeek, required this.usedHours, this.onRota = false, this.hoursPerDay = 7.5});
  final double pct, hoursWeek, usedHours, hoursPerDay;
  final bool onRota;

  static String _days(double days) {
    if (days <= 0) return 'Nothing';
    if ((days - 0.5).abs() < 0.08) return 'Half a day';
    if ((days - 1).abs() < 0.08) return 'One day';
    if ((days - 1.5).abs() < 0.08) return 'A day and a half';
    return fmtDays(double.parse(days.toStringAsFixed(1)));
  }

  @override
  Widget build(BuildContext context) {
    final hpd = hoursPerDay > 0 ? hoursPerDay : 7.5;
    final heldDays = hoursWeek / hpd;
    final usedDays = usedHours / hpd;
    final title = '${onRota ? 'Rota reserve' : 'Incident reserve'} · ${fmtPct(pct)}';

    final held = heldDays <= 0.05 ? 'No time is held back this week.' : '${_days(heldDays)} held back.';
    final String used;
    if (usedHours <= 0.05) {
      used = 'Nothing has used it yet this week.';
    } else if (usedHours >= hoursWeek) {
      used = 'All of it is in use this week (${fmtDays(double.parse(usedDays.toStringAsFixed(1)))}).';
    } else {
      used = '${fmtDays(double.parse(usedDays.toStringAsFixed(1)))} of it is in use this week.';
    }

    return DispatchCard(
      dashed: true,
      tint: Colors.transparent,
      padding: const EdgeInsets.all(Sp.lg),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.shield_outlined, size: 20, color: context.mutedColor),
        const SizedBox(width: Sp.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: context.text.titleMedium),
            const SizedBox(height: 2),
            Text('$held $used', style: context.text.bodySmall),
          ]),
        ),
      ]),
    );
  }
}

/// Hatched grey card shown instead of assignments on a leave day. The label is
/// the availability type only — never a reason (ADM-05).
class MwLeaveCard extends StatelessWidget {
  const MwLeaveCard({super.key, this.label, this.date});
  final String? label;
  final DateTime? date;

  @override
  Widget build(BuildContext context) {
    final hatch = context.isDark ? const Color(0xFF243352) : DispatchColors.surfaceAlt;
    return Container(
      decoration: BoxDecoration(borderRadius: DispatchRadius.cardR, border: Border.all(color: context.borderColor)),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        painter: _MwHatchPainter(colour: hatch, background: context.panelColor),
        child: Padding(
          padding: const EdgeInsets.all(Sp.lg),
          child: Row(children: [
            Icon(Icons.beach_access_outlined, size: 20, color: context.mutedColor),
            const SizedBox(width: Sp.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(label == null || label!.isEmpty ? 'Leave' : label!, style: context.text.titleMedium),
                const SizedBox(height: 2),
                Text('No work is planned${date == null ? '' : ' on ${fmtShortDate(date)}'}.', style: context.text.bodySmall),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _MwHatchPainter extends CustomPainter {
  _MwHatchPainter({required this.colour, required this.background});
  final Color colour, background;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final paint = Paint()
      ..color = colour
      ..strokeWidth = 6;
    const step = 14.0;
    for (double x = -size.height; x < size.width + size.height; x += step) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MwHatchPainter o) => o.colour != colour || o.background != background;
}

/// "Coming up" card: an assignment starting after this week.
class MwComingUpCard extends StatelessWidget {
  const MwComingUpCard({super.key, required this.assignment, required this.typeColour, this.onTap});
  final MwAssignment assignment;
  final Color typeColour;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final a = assignment;
    final committed = a.state == 'committed';
    final label = a.stateLabel ?? (committed ? 'Committed' : 'Planned');
    return DispatchCard(
      accent: typeColour,
      padding: const EdgeInsets.all(Sp.lg),
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(a.title, style: context.text.titleMedium)),
          if (a.sizeStamp != null) ...[const SizedBox(width: Sp.md), SizeStamp(a.sizeStamp, size: 26)],
        ]),
        const SizedBox(height: 2),
        Text(dotJoin([a.ref, a.typeName, fmtDateRange(a.from, a.to)]), style: context.text.bodySmall),
        const SizedBox(height: Sp.md),
        Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
          StatusChip(label.toLowerCase(), label: label, icon: committed ? Icons.lock_outline_rounded : null),
          if (a.allocationPct > 0 && a.allocationPct < 100) StatusChip('scheduled', label: '${a.allocationPct}% of each day'),
        ]),
      ]),
    );
  }
}

/// "Your load this week" against the configured target band.
class MwLoadTile extends StatelessWidget {
  const MwLoadTile({
    super.key,
    required this.loadPct,
    required this.targetMin,
    required this.targetMax,
    required this.hoursAssigned,
    required this.hoursAvailable,
  });
  final int loadPct, targetMin, targetMax;
  final double hoursAssigned, hoursAvailable;

  @override
  Widget build(BuildContext context) {
    final below = loadPct < targetMin;
    final above = loadPct > targetMax;
    final tone = above
        ? DispatchColors.red
        : below
            ? DispatchColors.amber
            : DispatchColors.green;
    final bandLabel = above
        ? 'Above the target band'
        : below
            ? 'Below the target band'
            : 'Within the target band';

    return Panel(
      title: 'Your load this week',
      trailing: LoadPct(loadPct.toDouble()),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth;
          double x(num pct) => (pct.clamp(0, 120) / 120) * w;
          return SizedBox(
            height: 12,
            child: Stack(children: [
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: context.isDark ? const Color(0xFF243352) : DispatchColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
              Positioned(
                left: x(targetMin),
                width: (x(targetMax) - x(targetMin)).clamp(2.0, w),
                top: 0,
                bottom: 0,
                child: Container(color: DispatchColors.tint(DispatchColors.green, opacity: context.isDark ? 0.35 : 0.22)),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: AnimatedContainer(
                  duration: mwMotion(context),
                  width: x(loadPct).clamp(0.0, w),
                  decoration: BoxDecoration(color: tone, borderRadius: BorderRadius.circular(6)),
                ),
              ),
            ]),
          );
        }),
        const SizedBox(height: Sp.sm),
        Text(
          '$bandLabel · target $targetMin–$targetMax% · ${fmtDays(double.parse((hoursAssigned / 7.5).toStringAsFixed(1)))} of work against '
          '${fmtDays(double.parse((hoursAvailable / 7.5).toStringAsFixed(1)))} available',
          style: context.text.bodySmall,
        ),
      ]),
    );
  }
}

/// Person picker for accounts with no linked person (admins, delivery leads).
class MwPersonPicker extends StatelessWidget {
  const MwPersonPicker({super.key, required this.people, required this.selected, required this.onChanged});

  /// Raw `people.php list` rows: {id, name, role_title, initials, colour}.
  final List<Map<String, dynamic>> people;
  final int? selected;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Panel(
      padding: const EdgeInsets.all(Sp.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Viewing', style: context.text.labelMedium?.copyWith(color: context.mutedColor)),
        const SizedBox(height: Sp.sm),
        DropdownButtonFormField<int>(
          initialValue: selected,
          isExpanded: true,
          decoration: const InputDecoration(hintText: 'Choose a team member'),
          items: [
            for (final p in people)
              DropdownMenuItem<int>(
                value: asIntOr(p['id'], 0),
                child: Row(children: [
                  PersonAvatar(asStrOr(p['initials'], initialsOf(asStr(p['name']))), colourHex: asStr(p['colour']), seed: asIntOr(p['id'], 0), size: 26),
                  const SizedBox(width: Sp.sm),
                  Expanded(child: Text(asStrOr(p['name'], 'Unknown'), overflow: TextOverflow.ellipsis)),
                ]),
              ),
          ],
          onChanged: onChanged,
        ),
      ]),
    );
  }
}

// ─── Log progress ─────────────────────────────────────────────────────────

/// What the log progress dialog collects.
class MwProgressEntry {
  const MwProgressEntry({required this.progressPct, this.effortDays, this.note});
  final int progressPct;
  final double? effortDays;
  final String? note;
}

/// Percentage slider, effort days and an optional note. Returns null when the
/// person cancels; the caller posts `work_items.php log_progress`.
Future<MwProgressEntry?> showMwLogProgress(
  BuildContext context, {
  required String ref,
  required String title,
  required int initialPct,
}) {
  return showDialog<MwProgressEntry>(
    context: context,
    builder: (context) => _MwLogProgressDialog(ref: ref, title: title, initialPct: initialPct),
  );
}

class _MwLogProgressDialog extends StatefulWidget {
  const _MwLogProgressDialog({required this.ref, required this.title, required this.initialPct});
  final String ref, title;
  final int initialPct;

  @override
  State<_MwLogProgressDialog> createState() => _MwLogProgressDialogState();
}

class _MwLogProgressDialogState extends State<_MwLogProgressDialog> {
  late double _pct = widget.initialPct.toDouble().clamp(0, 100);
  final _effort = TextEditingController();
  final _note = TextEditingController();
  String? _effortError;

  @override
  void dispose() {
    _effort.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _effort.text.trim();
    double? days;
    if (raw.isNotEmpty) {
      days = double.tryParse(raw);
      if (days == null || days < 0) {
        setState(() => _effortError = 'Enter the effort in days, for example 0.5.');
        return;
      }
    }
    Navigator.of(context).pop(MwProgressEntry(
      progressPct: _pct.round(),
      effortDays: days,
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Log progress'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(dotJoin([widget.ref, widget.title]), style: context.text.bodySmall),
          const SizedBox(height: Sp.lg),
          Row(children: [
            Expanded(child: Text('Progress', style: context.text.labelLarge)),
            Text('${_pct.round()}%', style: DispatchTheme.numeric(size: 15, color: context.inkColor)),
          ]),
          Slider(
            value: _pct,
            max: 100,
            divisions: 20,
            label: '${_pct.round()}%',
            onChanged: (v) => setState(() => _pct = v),
          ),
          const SizedBox(height: Sp.sm),
          TextField(
            controller: _effort,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: 'Effort today (days)', hintText: 'Optional, for example 0.5', errorText: _effortError),
            onChanged: (_) {
              if (_effortError != null) setState(() => _effortError = null);
            },
          ),
          const SizedBox(height: Sp.md),
          TextField(
            controller: _note,
            minLines: 2,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Note', hintText: 'Optional — what moved, what is next'),
          ),
        ]),
      ),
      actions: [
        SecondaryButton('Cancel', onPressed: () => Navigator.of(context).pop()),
        PrimaryButton('Save progress', onPressed: _submit),
      ],
    );
  }
}

/// "Request a person": ask for somebody's time on a work item, with a live
/// preview of what the hours turn into against that person's real capacity.
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/api.dart';
import '../../services/format.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/team_widgets.dart';
import '../../widgets/widgets.dart';

/// Ask for a person on [workItemId]. Returns true when a request was raised.
Future<bool> showRequestPersonDialog(
  BuildContext context, {
  required int workItemId,
  required String itemRef,
  required List<({int id, String name})> people,
  int? personId,
}) async {
  final done = await showDialog<bool>(
    context: context,
    builder: (_) => _RequestPersonDialog(workItemId: workItemId, itemRef: itemRef, people: people, personId: personId),
  );
  return done ?? false;
}

class _RequestPersonDialog extends StatefulWidget {
  const _RequestPersonDialog({required this.workItemId, required this.itemRef, required this.people, this.personId});
  final int workItemId;
  final String itemRef;
  final List<({int id, String name})> people;
  final int? personId;

  @override
  State<_RequestPersonDialog> createState() => _RequestPersonDialogState();
}

class _RequestPersonDialogState extends State<_RequestPersonDialog> {
  int? _personId;
  final _hours = TextEditingController(text: '7.5');
  final _note = TextEditingController();
  DateTime? _from;
  DateTime? _to;
  bool _busy = false;
  bool _previewing = false;
  String? _error;
  String? _previewError;
  RequestSpan? _span;

  /// Guards against an older preview landing after a newer one (the fields change faster
  /// than the round trip).
  int _previewSeq = 0;

  @override
  void initState() {
    super.initState();
    _personId = widget.personId ?? (widget.people.isNotEmpty ? widget.people.first.id : null);
    _from = _nextWorkingDay(DateTime.now());
    WidgetsBinding.instance.addPostFrameCallback((_) => _preview());
  }

  @override
  void dispose() {
    _hours.dispose();
    _note.dispose();
    super.dispose();
  }

  static DateTime _nextWorkingDay(DateTime d) {
    var x = DateTime(d.year, d.month, d.day).add(const Duration(days: 1));
    while (x.weekday == DateTime.saturday || x.weekday == DateTime.sunday) {
      x = x.add(const Duration(days: 1));
    }
    return x;
  }

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  double? get _hoursValue {
    final v = double.tryParse(_hours.text.trim());
    return v != null && v > 0 ? v : null;
  }

  Map<String, dynamic>? _payload() {
    if (_personId == null || _from == null || _hoursValue == null) return null;
    return {
      'work_item_id': widget.workItemId,
      'person_id': _personId,
      'hours': _hoursValue,
      'from_date': _iso(_from!),
      if (_to != null) 'to_date': _iso(_to!),
    };
  }

  Future<void> _pick(bool isFrom) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: (isFrom ? _from : _to) ?? _from ?? now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
    );
    if (d == null) return;
    setState(() {
      if (isFrom) {
        _from = d;
        if (_to != null && _to!.isBefore(d)) _to = d;
      } else {
        _to = d;
      }
    });
    _preview();
  }

  Future<void> _preview() async {
    final body = _payload();
    if (body == null) {
      setState(() {
        _span = null;
        _previewError = null;
      });
      return;
    }
    final seq = ++_previewSeq;
    setState(() => _previewing = true);
    try {
      final r = await Api.post('resource_requests.php', 'preview', body);
      if (!mounted || seq != _previewSeq) return;
      setState(() {
        _span = RequestSpan.fromJson(r);
        _previewError = null;
        _previewing = false;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _previewSeq) return;
      setState(() {
        _span = null;
        _previewError = e.message;
        _previewing = false;
      });
    }
  }

  Future<void> _submit() async {
    final body = _payload();
    if (body == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.post('resource_requests.php', 'create', {
        ...body,
        if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _payload() != null && !_busy;
    return AlertDialog(
      title: Text('Request a person for ${widget.itemRef}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TmField(
              label: 'Person',
              child: DropdownButtonFormField<int>(
                initialValue: _personId,
                items: [for (final p in widget.people) DropdownMenuItem(value: p.id, child: Text(p.name))],
                onChanged: (v) {
                  setState(() => _personId = v);
                  _preview();
                },
              ),
            ),
            const SizedBox(height: Sp.md),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: TmField(
                  label: 'Hours',
                  hint: 'How much of their time you need',
                  child: TextField(
                    controller: _hours,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => _preview(),
                    decoration: const InputDecoration(suffixText: 'h'),
                  ),
                ),
              ),
              const SizedBox(width: Sp.md),
              Expanded(
                child: TmField(
                  label: 'Starting',
                  child: OutlinedButton(onPressed: () => _pick(true), child: Text(fmtShortDate(_from))),
                ),
              ),
            ]),
            const SizedBox(height: Sp.md),
            TmField(
              label: 'Finish by (optional)',
              hint: 'Leave empty and the hours decide how far the booking runs',
              child: Row(children: [
                Expanded(child: OutlinedButton(onPressed: () => _pick(false), child: Text(_to == null ? 'No end date' : fmtShortDate(_to)))),
                if (_to != null)
                  IconButton(
                    tooltip: 'Clear the end date',
                    onPressed: () {
                      setState(() => _to = null);
                      _preview();
                    },
                    icon: const Icon(Icons.close, size: 18),
                  ),
              ]),
            ),
            const SizedBox(height: Sp.md),
            TmField(
              label: 'Why (optional)',
              hint: 'A business reason, recorded on the request and in the audit trail',
              child: TextField(controller: _note, minLines: 2, maxLines: 3),
            ),
            const SizedBox(height: Sp.lg),
            _previewPanel(context),
            if (_error != null) ...[
              const SizedBox(height: Sp.md),
              Text(_error!, style: context.text.bodyMedium?.copyWith(color: DispatchColors.red)),
            ],
          ]),
        ),
      ),
      actions: [
        SecondaryButton('Cancel', onPressed: _busy ? null : () => Navigator.of(context).pop(false)),
        PrimaryButton('Send request', icon: Icons.send_outlined, navy: true, busy: _busy, onPressed: ready ? _submit : null),
      ],
    );
  }

  /// What the hours actually mean: the dates, the share of each day, who decides.
  Widget _previewPanel(BuildContext context) {
    if (_previewError != null) {
      return Container(
        padding: const EdgeInsets.all(Sp.md),
        decoration: BoxDecoration(color: context.panelColor, borderRadius: DispatchRadius.panelR, border: Border.all(color: DispatchColors.red)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.error_outline, size: 16, color: DispatchColors.red),
          const SizedBox(width: Sp.sm),
          Expanded(child: Text(_previewError!, style: context.text.bodyMedium)),
        ]),
      );
    }
    final s = _span;
    if (s == null) {
      return Text(_previewing ? 'Working out the dates…' : 'Choose a person, hours and a start date.',
          style: context.text.bodySmall?.copyWith(color: context.mutedColor));
    }
    return Container(
      padding: const EdgeInsets.all(Sp.md),
      decoration: BoxDecoration(color: context.panelColor, borderRadius: DispatchRadius.panelR, border: Border.all(color: context.borderColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${fmtDateRange(s.from, s.to)} · ${s.allocationPct}% of each day',
            style: context.text.titleSmall),
        const SizedBox(height: 4),
        Text('${fmtDays(s.bookedHours, unit: 'hour')} across ${fmtDays(s.dayCount, unit: 'working day')}',
            style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
        if (!s.fits) ...[
          const SizedBox(height: Sp.sm),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.warning_amber_rounded, size: 16, color: DispatchColors.amber),
            const SizedBox(width: Sp.sm),
            Expanded(
              child: Text(
                s.conflicts.isEmpty
                    ? 'They are already booked for some of that time.'
                    : 'Already booked on ${s.conflicts.take(3).join(', ')} then. Approving this over-books them, and the next planning cycle will move lower-priority work.',
                style: context.text.bodySmall?.copyWith(color: context.mutedColor),
              ),
            ),
          ]),
        ],
        if (s.insideFreeze) ...[
          const SizedBox(height: Sp.sm),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.lock_clock_outlined, size: 16, color: context.mutedColor),
            const SizedBox(width: Sp.sm),
            Expanded(child: Text('Inside the freeze horizon, so whoever approves it must give a reason.',
                style: context.text.bodySmall?.copyWith(color: context.mutedColor))),
          ]),
        ],
        if (s.onLoanTeam != null) ...[
          const SizedBox(height: Sp.sm),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.swap_horiz_rounded, size: 16, color: DispatchColors.amber),
            const SizedBox(width: Sp.sm),
            Expanded(child: Text('On loan to ${s.onLoanTeam} over those dates.',
                style: context.text.bodySmall?.copyWith(color: context.mutedColor))),
          ]),
        ],
        if (s.approverLabel != null) ...[
          const SizedBox(height: Sp.sm),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.how_to_reg_outlined, size: 16, color: context.mutedColor),
            const SizedBox(width: Sp.sm),
            Expanded(child: Text('${s.approverLabel} decides.', style: context.text.bodySmall?.copyWith(color: context.mutedColor))),
          ]),
        ],
      ]),
    );
  }
}

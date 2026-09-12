/// The change card shared by the Changes list and the single-change screen,
/// plus the small dialogs its actions need (a reason, an edit).
library;

import 'package:flutter/material.dart';

import '../../services/format.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/schedule_widgets.dart';
import '../../widgets/widgets.dart';
import 'sch_models.dart';

/// One proposed change: who, what, before and after, why, and its impact
/// (CHG-01..03). Held changes are dimmed and labelled with the guardrail.
class SchChangeCard extends StatelessWidget {
  const SchChangeCard({
    super.key,
    required this.change,
    this.selected = false,
    this.onSelect,
    this.onAccept,
    this.onReject,
    this.onEdit,
    this.onAcknowledge,
    this.onOpen,
    this.stacked = false,
    this.showSelect = true,
  });

  final SchChange change;
  final bool selected;
  final ValueChanged<bool>? onSelect;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;
  final VoidCallback? onEdit;
  final VoidCallback? onAcknowledge;
  final VoidCallback? onOpen;

  /// Phone layout: before over after, full-width buttons.
  final bool stacked;
  final bool showSelect;

  @override
  Widget build(BuildContext context) {
    final c = change;
    final held = c.isHeld;
    final decided = !c.isPending;

    final card = Container(
      padding: const EdgeInsets.all(Sp.lg),
      decoration: BoxDecoration(
        color: context.panelColor,
        borderRadius: DispatchRadius.panelR,
        border: Border.all(color: held ? context.borderColor : context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showSelect)
                SizedBox(
                  width: 34,
                  child: Tooltip(
                    message: held
                        ? 'Held by a guardrail, so it cannot be accepted in bulk'
                        : (decided ? 'Already ${humanise(c.decision).toLowerCase()}' : 'Include in "Accept selected"'),
                    child: Checkbox(
                      value: selected,
                      onChanged: onSelect == null ? null : (v) => onSelect!(v ?? false),
                      semanticLabel: 'Select ${c.headline}',
                    ),
                  ),
                ),
              if (c.person != null) ...[
                PersonAvatar(c.person!.initialsOrDerived, colourHex: c.person!.colourHex, seed: c.person!.id, size: 30),
                const SizedBox(width: Sp.sm),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: Sp.sm,
                      children: [
                        Text(dotJoin([c.person?.name, c.headline]), style: context.text.titleMedium),
                        if (decided) SchChip(humanise(c.decision), tone: c.decision == 'rejected' ? 'bad' : 'ok'),
                        if (stacked && (held || c.needsApproval)) SchChip(c.guardrailLabel, tone: held ? 'bad' : 'warn', icon: Icons.gpp_maybe_outlined),
                      ],
                    ),
                    if (c.workItemRef != null)
                      Text(
                        dotJoin([c.workItemRef, c.workItemTitle, humanise(c.kind)]),
                        style: context.text.bodySmall?.copyWith(color: context.mutedColor),
                      ),
                  ],
                ),
              ),
              if (!stacked && (held || c.needsApproval)) ...[
                const SizedBox(width: Sp.sm),
                Flexible(child: SchChip(c.guardrailLabel, tone: held ? 'bad' : 'warn', icon: Icons.gpp_maybe_outlined)),
              ],
              if (onOpen != null)
                IconButton(
                  onPressed: onOpen,
                  tooltip: 'Open this change',
                  icon: const Icon(Icons.open_in_new, size: 18),
                ),
            ],
          ),
          const SizedBox(height: Sp.md),
          Padding(
            padding: EdgeInsets.only(left: showSelect && !stacked ? 34 : 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SchBeforeAfter(before: c.beforeLabel, after: c.afterLabel, vertical: stacked),
                if (c.reason != null && c.reason!.isNotEmpty) ...[
                  const SizedBox(height: Sp.md),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lightbulb_outline, size: 16, color: context.mutedColor),
                      const SizedBox(width: Sp.sm),
                      Expanded(child: Text(c.reason!, style: context.text.bodyMedium?.copyWith(color: context.mutedColor))),
                    ],
                  ),
                ],
                if (held && c.guardrailReason != null) ...[
                  const SizedBox(height: Sp.sm),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.block, size: 16, color: DispatchColors.red),
                      const SizedBox(width: Sp.sm),
                      Expanded(child: Text(c.guardrailReason!, style: context.text.bodyMedium)),
                    ],
                  ),
                ],
                const SizedBox(height: Sp.md),
                _actions(context),
              ],
            ),
          ),
        ],
      ),
    );

    return Semantics(
      container: true,
      label: held ? '${c.headline}. Held by a guardrail.' : c.headline,
      child: Opacity(opacity: held ? 0.72 : 1, child: card),
    );
  }

  Widget _actions(BuildContext context) {
    final c = change;
    final chips = <Widget>[
      for (final chip in c.chips) SchChip(chip.label, tone: chip.tone),
      if (c.chips.isEmpty && c.stabilityCostDays > 0) SchChip('Stability cost ${fmtDays(c.stabilityCostDays, unit: 'assignment-day')}', tone: 'info'),
    ];
    final buttons = <Widget>[
      if (onEdit != null) SecondaryButton('Edit', icon: Icons.edit_outlined, onPressed: onEdit, expand: stacked),
      if (onReject != null) SecondaryButton('Reject', onPressed: onReject, expand: stacked),
      if (onAccept != null) PrimaryButton('Accept', icon: Icons.check, navy: true, onPressed: onAccept, expand: stacked),
      if (onAcknowledge != null) PrimaryButton('Acknowledge', icon: Icons.check, navy: true, onPressed: onAcknowledge, expand: stacked),
    ];

    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: chips),
          if (buttons.isNotEmpty) ...[
            const SizedBox(height: Sp.md),
            for (final b in buttons) Padding(padding: const EdgeInsets.only(bottom: Sp.sm), child: b),
          ],
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: chips)),
        if (buttons.isNotEmpty) ...[
          const SizedBox(width: Sp.md),
          Wrap(
            spacing: Sp.sm,
            runSpacing: Sp.sm,
            children: buttons,
          ),
        ],
      ],
    );
  }
}

/// Ask for a reason (approving inside the freeze horizon, overriding a
/// guardrail, rejecting). Returns null when cancelled.
Future<String?> schReasonDialog(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = 'Confirm',
  bool required = true,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _ReasonDialog(title: title, message: message, confirmLabel: confirmLabel, reasonRequired: required),
    );

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({required this.title, this.message, required this.confirmLabel, required this.reasonRequired});
  final String title;
  final String? message;
  final String confirmLabel;
  final bool reasonRequired;

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = !widget.reasonRequired || _controller.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.message != null) ...[
                Text(widget.message!, style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: Sp.md),
              ],
              TextField(
                controller: _controller,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: widget.reasonRequired ? 'Reason' : 'Reason (optional)',
                  hintText: 'Recorded on the change and in the audit trail',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        SecondaryButton('Cancel', onPressed: () => Navigator.of(context).pop()),
        PrimaryButton(widget.confirmLabel, onPressed: ready ? () => Navigator.of(context).pop(_controller.text.trim()) : null),
      ],
    );
  }
}

/// Edit a change before accepting it (CHG-02): person, dates and allocation.
/// Returns the `changes.php edit` payload, or null when cancelled.
Future<Map<String, dynamic>?> schEditChangeDialog(
  BuildContext context, {
  required SchChange change,
  required List<SchPersonLite> people,
}) =>
    showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _EditChangeDialog(change: change, people: people),
    );

class _EditChangeDialog extends StatefulWidget {
  const _EditChangeDialog({required this.change, required this.people});
  final SchChange change;
  final List<SchPersonLite> people;

  @override
  State<_EditChangeDialog> createState() => _EditChangeDialogState();
}

class _EditChangeDialogState extends State<_EditChangeDialog> {
  final _reason = TextEditingController();
  late int? _personId = asIntOrNull(widget.change.after['person_id']) ?? widget.change.person?.id;
  late DateTime _from = parseDate(widget.change.after['from']) ?? DateTime.now();
  late DateTime _to = parseDate(widget.change.after['to']) ?? _from;
  late int _allocation = asIntOrNull(widget.change.after['allocation_pct']) ?? 100;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _pick(bool isFrom) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? _from : _to,
      firstDate: DateTime(_from.year - 1),
      lastDate: DateTime(_from.year + 2),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isFrom) {
        _from = picked;
        if (_to.isBefore(_from)) _to = _from;
      } else {
        _to = picked.isBefore(_from) ? _from : picked;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit this change'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.change.headline, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: Sp.lg),
              if (widget.people.isNotEmpty)
                DropdownButtonFormField<int>(
                  initialValue: widget.people.any((p) => p.id == _personId) ? _personId : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Person'),
                  items: [
                    for (final p in widget.people)
                      DropdownMenuItem(value: p.id, child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => _personId = v),
                ),
              const SizedBox(height: Sp.md),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pick(true),
                      icon: const Icon(Icons.calendar_today_outlined, size: 16),
                      label: Text('From ${fmtShortDate(_from)}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  const SizedBox(width: Sp.sm),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pick(false),
                      icon: const Icon(Icons.calendar_today_outlined, size: 16),
                      label: Text('To ${fmtShortDate(_to)}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Sp.md),
              DropdownButtonFormField<int>(
                initialValue: _allocation,
                decoration: const InputDecoration(labelText: 'Allocation'),
                items: [for (final a in const [25, 50, 75, 100]) DropdownMenuItem(value: a, child: Text('$a%'))],
                onChanged: (v) => setState(() => _allocation = v ?? 100),
              ),
              const SizedBox(height: Sp.md),
              TextField(
                controller: _reason,
                minLines: 2,
                maxLines: 3,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Reason for the edit'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        SecondaryButton('Cancel', onPressed: () => Navigator.of(context).pop()),
        PrimaryButton(
          'Save edit',
          onPressed: _reason.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop({
                    'change_id': widget.change.id,
                    'after': {
                      'person_id': ?_personId,
                      'from': _iso(_from),
                      'to': _iso(_to),
                      'allocation_pct': _allocation,
                    },
                    'reason': _reason.text.trim(),
                  }),
        ),
      ],
    );
  }
}

int? asIntOrNull(dynamic v) => v == null ? null : int.tryParse(v.toString());

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

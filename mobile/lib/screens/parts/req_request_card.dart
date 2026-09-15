/// The resource-request card, shared by the Requests list, the single-request
/// screen and the Requests panel on a work item.
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/format.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/widgets.dart';

/// One request for somebody's time: who, how much, when, and where it has got to.
///
/// Approve and Decline appear only when the server said this caller may decide it
/// (`can_approve`), so a lead of another branch never sees a button that would 403.
class ReqRequestCard extends StatelessWidget {
  const ReqRequestCard({
    super.key,
    required this.request,
    this.onApprove,
    this.onDecline,
    this.onWithdraw,
    this.onOpen,
    this.stacked = false,
  });

  final ResourceRequest request;
  final VoidCallback? onApprove;
  final VoidCallback? onDecline;
  final VoidCallback? onWithdraw;
  final VoidCallback? onOpen;

  /// Phone layout: details stacked, full-width buttons.
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final r = request;
    final decided = !r.isPending;

    return Semantics(
      container: true,
      label: '${r.person.name} requested for ${r.workItem.ref}. ${r.statusLabel}.',
      child: Opacity(
        opacity: decided && r.status != 'approved' ? 0.75 : 1,
        child: Container(
          padding: const EdgeInsets.all(Sp.lg),
          decoration: BoxDecoration(
            color: context.panelColor,
            borderRadius: DispatchRadius.panelR,
            border: Border.all(color: context.borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PersonAvatar(r.person.initials ?? initialsOf(r.person.name), colourHex: r.person.colour, seed: r.person.id, size: 30),
                  const SizedBox(width: Sp.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: Sp.sm,
                          runSpacing: Sp.xs,
                          children: [
                            Text('${r.person.name} for ${r.workItem.ref}', style: context.text.titleMedium),
                            ToneChip(r.statusLabel, tone: r.tone),
                          ],
                        ),
                        Text(
                          dotJoin([r.workItem.title, r.person.teamName]),
                          style: context.text.bodySmall?.copyWith(color: context.mutedColor),
                        ),
                      ],
                    ),
                  ),
                  if (onOpen != null)
                    IconButton(onPressed: onOpen, tooltip: 'Open this request', icon: const Icon(Icons.open_in_new, size: 18)),
                ],
              ),
              const SizedBox(height: Sp.md),
              Wrap(
                spacing: Sp.md,
                runSpacing: Sp.sm,
                children: [
                  _fact(context, 'Asked for', fmtDays(r.hours, unit: 'hour')),
                  _fact(context, 'When', fmtDateRange(r.fromDate, r.toDate)),
                  _fact(context, 'Share of each day', '${r.allocationPct}%'),
                  _fact(context, 'Asked by', r.requestedByName),
                ],
              ),
              if (r.note != null && r.note!.isNotEmpty) ...[
                const SizedBox(height: Sp.md),
                _line(context, Icons.lightbulb_outline, r.note!),
              ],
              if (r.isPending && r.approverLabel != null)
                ...[const SizedBox(height: Sp.sm), _line(context, Icons.how_to_reg_outlined, 'Waiting on ${r.approverLabel}')],
              if (decided && r.decidedByName != null)
                ...[
                  const SizedBox(height: Sp.sm),
                  _line(context, r.isApproved ? Icons.check_circle_outline : Icons.cancel_outlined,
                      dotJoin(['${r.statusLabel} by ${r.decidedByName}', r.decisionReason])),
                ],
              if (_buttons(context).isNotEmpty) ...[
                const SizedBox(height: Sp.md),
                if (stacked)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [for (final b in _buttons(context, expand: true)) Padding(padding: const EdgeInsets.only(bottom: Sp.sm), child: b)],
                  )
                else
                  Wrap(alignment: WrapAlignment.end, spacing: Sp.sm, runSpacing: Sp.sm, children: _buttons(context)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buttons(BuildContext context, {bool expand = false}) => [
        if (onWithdraw != null) SecondaryButton('Withdraw', onPressed: onWithdraw, expand: expand),
        if (onDecline != null) SecondaryButton('Decline', onPressed: onDecline, expand: expand),
        if (onApprove != null) PrimaryButton('Approve', icon: Icons.check, navy: true, onPressed: onApprove, expand: expand),
      ];

  Widget _fact(BuildContext context, String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
          Text(value, style: context.text.bodyMedium),
        ],
      );

  Widget _line(BuildContext context, IconData icon, String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: context.mutedColor),
          const SizedBox(width: Sp.sm),
          Expanded(child: Text(text, style: context.text.bodyMedium?.copyWith(color: context.mutedColor))),
        ],
      );
}

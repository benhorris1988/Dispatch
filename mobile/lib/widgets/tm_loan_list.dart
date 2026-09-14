import 'package:flutter/material.dart';

import '../models/person.dart';
import '../services/format.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'buttons.dart';
import 'chips.dart';
import 'person_avatar.dart';

/// Rows of loans (TEAM-09): who went where, for how long, at what share, and
/// why (a business reason — ADM-05 keeps personal detail out). Team leads get
/// *End early* on a running loan and *Cancel* on one that has not started.
/// Used by the Team & skills People tab, the Portfolio screen and the Person
/// screen's Loans panel.
class TmLoanList extends StatelessWidget {
  const TmLoanList({
    super.key,
    required this.loans,
    required this.today,
    this.canEnd = false,
    this.onEnd,
    this.showPerson = true,
    this.dense = false,
  });

  final List<Loan> loans;
  final DateTime today;
  final bool canEnd;
  final void Function(Loan)? onEnd;
  /// Off on a person's own page, where every row is about them.
  final bool showPerson;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final muted = context.text.bodySmall?.copyWith(color: context.mutedColor);
    return Column(children: [
      for (final l in loans)
        Padding(
          padding: EdgeInsets.symmetric(vertical: dense ? 4 : Sp.sm),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (showPerson) ...[
              PersonAvatar(initialsOf(l.personName), seed: l.personId, size: 30),
              const SizedBox(width: Sp.md),
            ] else ...[
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.swap_horiz_rounded, size: 18, color: context.mutedColor),
              ),
              const SizedBox(width: Sp.md),
            ],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Wrap(spacing: Sp.sm, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(
                    showPerson ? (l.personName ?? 'Person ${l.personId}') : '${l.fromTeamName ?? 'Own team'} → ${l.toTeamName ?? 'other team'}',
                    style: context.text.titleSmall,
                  ),
                  loanStateChip(l, today),
                ]),
                const SizedBox(height: 2),
                Text(
                  dotJoin([
                    if (showPerson) '${l.fromTeamName ?? 'Own team'} → ${l.toTeamName ?? 'other team'}',
                    fmtDateRange(l.fromDate, l.toDate),
                    '${l.allocationPct}% of their time',
                  ]),
                  style: muted,
                ),
                if (l.reason != null && l.reason!.isNotEmpty) Text(l.reason!, style: muted, maxLines: 2, overflow: TextOverflow.ellipsis),
              ]),
            ),
            if (canEnd && onEnd != null && !l.endedBefore(today)) ...[
              const SizedBox(width: Sp.sm),
              SecondaryButton(l.startsAfter(today) ? 'Cancel' : 'End early', danger: true, onPressed: () => onEnd!(l)),
            ],
          ]),
        ),
    ]);
  }
}

/// 'Ended' / 'Starts 14 Sep' / 'Active · until 25 Sep'.
Widget loanStateChip(Loan l, DateTime today) {
  if (l.endedBefore(today)) return const ToneChip('Ended', compact: true);
  if (l.startsAfter(today)) return ToneChip('Starts ${fmtDayMonth(l.fromDate)}', tone: 'info', compact: true);
  return ToneChip('Active · until ${fmtDayMonth(l.toDate)}', tone: 'ok', compact: true);
}

import 'package:flutter/material.dart';

import '../models/person.dart';
import '../services/format.dart';
import 'chips.dart';

/// Which side of a loan the viewer is standing on.
enum LoanSide {
  /// The person is borrowed into the team being looked at.
  borrowed,

  /// A home member of the team being looked at has been lent elsewhere.
  lent,
}

/// 'On loan from Integration Platform · until 25 Sep · 50%' or
/// 'Lent to Data Platform until 25 Sep · 50%'. The share is left off when the
/// whole person moves. A loan that has not started yet says 'from' instead of
/// 'until', so the row reads correctly before and during the loan.
String loanChipLabel(Loan loan, LoanSide side, {DateTime? today}) {
  final now = today ?? DateTime.now();
  final notStarted = loan.startsAfter(now);
  final when = notStarted ? '${fmtDayMonth(loan.fromDate)}–${fmtDayMonth(loan.toDate)}' : 'until ${fmtDayMonth(loan.toDate)}';
  final share = loan.allocationPct >= 100 ? null : '${loan.allocationPct}%';
  return switch (side) {
    LoanSide.borrowed => dotJoin(['On loan from ${loan.fromTeamName ?? 'another team'}', when, share]),
    LoanSide.lent => dotJoin(['Lent to ${loan.toTeamName ?? 'another team'} $when', share]),
  };
}

/// Compact chip for a person row: borrowed people in the info tone, home
/// members lent out in the warning tone (their time is not the team's just now).
class TmLoanChip extends StatelessWidget {
  const TmLoanChip(this.loan, {super.key, required this.side, this.today, this.compact = true});
  final Loan loan;
  final LoanSide side;
  final DateTime? today;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final label = loanChipLabel(loan, side, today: today);
    final tip = dotJoin([
      label,
      fmtDateRange(loan.fromDate, loan.toDate),
      if (loan.reason != null && loan.reason!.isNotEmpty) loan.reason,
    ]);
    return Tooltip(
      message: tip,
      child: ToneChip(
        label,
        tone: side == LoanSide.borrowed ? 'info' : 'warn',
        icon: side == LoanSide.borrowed ? Icons.call_received_rounded : Icons.call_made_rounded,
        compact: compact,
      ),
    );
  }
}

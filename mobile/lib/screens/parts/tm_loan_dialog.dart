import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/api.dart';
import '../../services/format.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/team_widgets.dart';
import '../../widgets/tm_scope_picker.dart';
import '../../widgets/widgets.dart';

/// Lend a person to another team for a dated period at a share of their time
/// (TEAM-09, `people.php add_loan`). Returns true when a loan was created.
///
/// The server decides who may lend (delivery lead, or a team lead of either
/// team); the dialog is only offered to team leads and above. A clash with
/// another loan comes back as a 409 whose message names the loan in the way —
/// it is shown verbatim, because it already says what to do about it.
Future<bool> showTmAddLoan(
  BuildContext context, {
  required List<Person> people,
  required List<ScopeTeam> teams,
  int? personId,
  DateTime? today,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (context) => _TmAddLoanDialog(people: people, teams: teams, personId: personId, today: today ?? DateTime.now()),
  );
  return r ?? false;
}

/// End a loan early (or cancel one that has not started), behind a confirm.
/// Returns true when the server accepted it.
Future<bool> confirmTmEndLoan(BuildContext context, Loan loan, {DateTime? today}) async {
  final now = today ?? DateTime.now();
  final notStarted = loan.startsAfter(now);
  final who = loan.personName ?? 'This person';
  final ok = await showTmConfirm(
    context,
    title: notStarted ? 'Cancel this loan?' : 'End this loan early?',
    message: notStarted
        ? '$who will not go to ${loan.toTeamName ?? 'the other team'} on ${fmtShortDate(loan.fromDate)}. The loan is cancelled outright because it has not started.'
        : '$who comes back to ${loan.fromTeamName ?? 'their own team'} from tomorrow. The loan is kept as history to today, and a replan trigger is raised so any work planned on the borrowed time can be moved.',
    confirmLabel: notStarted ? 'Cancel loan' : 'End today',
    danger: true,
  );
  if (!ok || !context.mounted) return false;
  try {
    await Api.post('people.php', 'end_loan', {
      'id': loan.id,
      // A loan that has started ends today; one that has not is cancelled outright,
      // which the API does when to_date is omitted.
      if (!notStarted) 'to_date': _iso(now),
    });
    if (context.mounted) tmToast(context, notStarted ? 'Loan cancelled' : 'Loan ends today');
    return true;
  } on ApiException catch (e) {
    if (context.mounted) tmToast(context, e.message, bad: true);
    return false;
  }
}

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class _TmAddLoanDialog extends StatefulWidget {
  const _TmAddLoanDialog({required this.people, required this.teams, required this.today, this.personId});
  final List<Person> people;
  final List<ScopeTeam> teams;
  final DateTime today;
  final int? personId;

  @override
  State<_TmAddLoanDialog> createState() => _TmAddLoanDialogState();
}

class _TmAddLoanDialogState extends State<_TmAddLoanDialog> {
  int? _personId;
  int? _toTeamId;
  DateTime? _from;
  DateTime? _to;
  final TextEditingController _share = TextEditingController(text: '100');
  final TextEditingController _reason = TextEditingController();
  bool _busy = false;
  String? _error;

  Person? get _person => widget.people.where((p) => p.id == _personId).firstOrNull;

  /// Teams the chosen person can be lent to: everyone's but their own.
  List<ScopeTeam> get _targets => widget.teams.where((t) => t.id != _person?.teamId).toList();

  @override
  void initState() {
    super.initState();
    _personId = widget.personId ?? (widget.people.isNotEmpty ? widget.people.first.id : null);
    _toTeamId = _targets.isNotEmpty ? _targets.first.id : null;
  }

  @override
  void dispose() {
    _share.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _pick(bool isFrom) async {
    final base = widget.today;
    final d = await showDatePicker(
      context: context,
      initialDate: (isFrom ? _from : _to) ?? _from ?? base,
      firstDate: DateTime(base.year - 1),
      lastDate: DateTime(base.year + 3),
    );
    if (d == null) return;
    setState(() {
      if (isFrom) {
        _from = d;
        if (_to == null || _to!.isBefore(d)) _to = d;
      } else {
        _to = d;
      }
    });
  }

  static String _label(DateTime? d) => d == null ? 'Choose a date' : '${fmtDayMonth(d)} ${d.year}';

  int? get _sharePct {
    final v = int.tryParse(_share.text.trim());
    if (v == null || v < 1 || v > 100) return null;
    return v;
  }

  bool get _ready => _personId != null && _toTeamId != null && _from != null && _to != null && _sharePct != null;

  Future<void> _save() async {
    if (!_ready) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.post('people.php', 'add_loan', {
        'person_id': _personId,
        'to_team_id': _toTeamId,
        'from_date': _iso(_from!),
        'to_date': _iso(_to!),
        'allocation_pct': _sharePct,
        if (_reason.text.trim().isNotEmpty) 'reason': _reason.text.trim(),
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          // Shown as the server wrote it: a 409 names the overlapping loan and
          // says to end that one first.
          _error = e.message;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final targets = _targets;
    if (_toTeamId != null && !targets.any((t) => t.id == _toTeamId)) _toTeamId = targets.isNotEmpty ? targets.first.id : null;
    final person = _person;
    return AlertDialog(
      title: const Text('Lend to another team'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TmField(
              label: 'Person',
              hint: person?.teamName == null ? null : 'Lent by ${person!.teamName}, their own team.',
              child: DropdownButtonFormField<int>(
                initialValue: _personId,
                isExpanded: true,
                items: [
                  for (final p in widget.people)
                    DropdownMenuItem(value: p.id, child: Text(dotJoin([p.name, p.teamName]), overflow: TextOverflow.ellipsis)),
                ],
                onChanged: widget.personId != null ? null : (v) => setState(() => _personId = v),
              ),
            ),
            const SizedBox(height: Sp.md),
            TmField(
              label: 'To team',
              child: targets.isEmpty
                  ? Text('There is no other team to lend to.', style: context.text.bodyMedium?.copyWith(color: context.mutedColor))
                  : DropdownButtonFormField<int>(
                      initialValue: _toTeamId,
                      isExpanded: true,
                      items: [
                        for (final t in targets) DropdownMenuItem(value: t.id, child: Text(dotJoin([t.name, t.parentName]), overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: (v) => setState(() => _toTeamId = v),
                    ),
            ),
            const SizedBox(height: Sp.md),
            Row(children: [
              Expanded(
                child: TmField(
                  label: 'From',
                  child: SecondaryButton(_label(_from), icon: Icons.calendar_today_outlined, expand: true, onPressed: () => _pick(true)),
                ),
              ),
              const SizedBox(width: Sp.md),
              Expanded(
                child: TmField(
                  label: 'To',
                  child: SecondaryButton(_label(_to), icon: Icons.calendar_today_outlined, expand: true, onPressed: () => _pick(false)),
                ),
              ),
            ]),
            const SizedBox(height: Sp.md),
            TmField(
              label: 'Share of their time',
              hint: 'Percent, 1–100. A 50% loan counts half for each team.',
              child: TextField(
                controller: _share,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(suffixText: '%'),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(height: Sp.md),
            TmField(
              label: 'Reason',
              hint: 'A business reason, such as the item they are needed for — never personal detail.',
              child: TextField(controller: _reason, maxLines: 2),
            ),
            if (_error != null) TmInlineError(_error!),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        PrimaryButton('Add loan', busy: _busy, onPressed: _ready ? _save : null),
      ],
    );
  }
}

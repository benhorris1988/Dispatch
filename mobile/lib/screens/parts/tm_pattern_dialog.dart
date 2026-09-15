/// Edit a person's working pattern: hours per weekday, Monday to Sunday.
///
/// The pattern is what the scheduler books against, and until now nothing in the client could
/// change it — a part-timer's week could only be fixed in the database. Saturday and Sunday are
/// offered because the API has always accepted them and capacity is derived for any weekday a
/// pattern gives hours to.
library;

import 'package:flutter/material.dart';

import '../../services/api.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/team_widgets.dart';
import '../../widgets/widgets.dart';

const List<String> kWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Returns true when the pattern was saved.
Future<bool> showTmPatternDialog(
  BuildContext context, {
  required int personId,
  required String personName,
  required Map<String, double> pattern,
  String? patternLabel,
  double hoursPerDay = 7.5,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _PatternDialog(
      personId: personId,
      personName: personName,
      pattern: pattern,
      patternLabel: patternLabel,
      hoursPerDay: hoursPerDay <= 0 ? 7.5 : hoursPerDay,
    ),
  );
  return saved ?? false;
}

class _PatternDialog extends StatefulWidget {
  const _PatternDialog({
    required this.personId,
    required this.personName,
    required this.pattern,
    required this.patternLabel,
    required this.hoursPerDay,
  });
  final int personId;
  final String personName;
  final Map<String, double> pattern;
  final String? patternLabel;
  final double hoursPerDay;

  @override
  State<_PatternDialog> createState() => _PatternDialogState();
}

class _PatternDialogState extends State<_PatternDialog> {
  late final Map<String, TextEditingController> _hours;
  late final TextEditingController _label;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _hours = {
      for (final d in kWeekdays) d: TextEditingController(text: _fmt(widget.pattern[d] ?? 0)),
    };
    _label = TextEditingController(text: widget.patternLabel ?? '');
  }

  @override
  void dispose() {
    for (final c in _hours.values) {
      c.dispose();
    }
    _label.dispose();
    super.dispose();
  }

  static String _fmt(double v) => v <= 0 ? '' : (v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(2));

  Map<String, double> get _current {
    final out = <String, double>{};
    for (final d in kWeekdays) {
      final v = double.tryParse(_hours[d]!.text.trim().replaceAll(',', '.')) ?? 0;
      if (v > 0) out[d] = v;
    }
    return out;
  }

  double get _weekHours => _current.values.fold(0.0, (a, b) => a + b);
  double get _daysPerWeek => widget.hoursPerDay > 0 ? (_weekHours / widget.hoursPerDay) : 0;

  void _preset(Map<String, double> p) {
    setState(() {
      for (final d in kWeekdays) {
        _hours[d]!.text = _fmt(p[d] ?? 0);
      }
    });
  }

  Future<void> _save() async {
    final pattern = _current;
    if (pattern.isEmpty) {
      setState(() => _error = 'Give at least one day some hours.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.post('people.php', 'save', {
        'id': widget.personId,
        'working_pattern': pattern,
        'days_per_week': double.parse(_daysPerWeek.toStringAsFixed(1)),
        'pattern_label': _label.text.trim().isEmpty ? null : _label.text.trim(),
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
    final full = widget.hoursPerDay;
    return AlertDialog(
      title: Text('Working pattern · ${widget.personName}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Hours this person works on each weekday. The scheduler never books beyond them, '
                'and leave and public holidays come off the top.',
                style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
            const SizedBox(height: Sp.md),
            Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
              SecondaryButton('Full time', onPressed: () => _preset({for (final d in kWeekdays.take(5)) d: full})),
              SecondaryButton('Mon–Thu', onPressed: () => _preset({for (final d in kWeekdays.take(4)) d: full})),
              SecondaryButton('Half-day Friday', onPressed: () => _preset({
                    for (final d in kWeekdays.take(4)) d: full,
                    'Fri': full / 2,
                  })),
            ]),
            const SizedBox(height: Sp.md),
            Wrap(
              spacing: Sp.sm,
              runSpacing: Sp.sm,
              children: [
                for (final d in kWeekdays)
                  SizedBox(
                    width: 96,
                    child: TmField(
                      label: d,
                      child: TextField(
                        controller: _hours[d],
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(hintText: '0', suffixText: 'h', isDense: true),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Sp.md),
            Container(
              padding: const EdgeInsets.all(Sp.md),
              decoration: BoxDecoration(color: context.panelColor, borderRadius: DispatchRadius.panelR, border: Border.all(color: context.borderColor)),
              child: Text(
                '${_weekHours % 1 == 0 ? _weekHours.toStringAsFixed(0) : _weekHours.toStringAsFixed(2)} hours a week '
                '· ${_daysPerWeek.toStringAsFixed(1)} days at ${full % 1 == 0 ? full.toStringAsFixed(0) : full.toStringAsFixed(2)}h',
                style: context.text.titleSmall,
              ),
            ),
            const SizedBox(height: Sp.md),
            TmField(
              label: 'Label (optional)',
              hint: 'How this reads on the person page, e.g. "Mon–Thu full, Fri half day"',
              child: TextField(controller: _label),
            ),
            if (_error != null) ...[
              const SizedBox(height: Sp.md),
              Text(_error!, style: context.text.bodyMedium?.copyWith(color: DispatchColors.red)),
            ],
          ]),
        ),
      ),
      actions: [
        SecondaryButton('Cancel', onPressed: _busy ? null : () => Navigator.of(context).pop(false)),
        PrimaryButton('Save pattern', navy: true, busy: _busy, onPressed: _busy ? null : _save),
      ],
    );
  }
}

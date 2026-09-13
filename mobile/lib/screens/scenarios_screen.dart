import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/models.dart';
import '../services/api.dart';
import '../services/format.dart';
import '../shell/app_shell.dart';
import '../shell/breaks.dart';
import '../shell/nav.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/schedule_widgets.dart';
import '../widgets/widgets.dart';
import 'parts/sch_plan_models.dart';

/// What-if scenarios (SCH-11). Compose hypothetical edits — add a contractor,
/// drop an item, put someone on leave — run them through the engine without
/// persisting anything, and compare the result with the committed plan. A
/// what-if worth keeping is saved as a named scenario; a delivery lead can
/// adopt one, which re-runs it against today's data as a proposal for review.
class ScenariosScreen extends StatefulWidget {
  const ScenariosScreen({super.key});

  /// Linkable: `/schedule/scenarios`.
  static const String route = '/schedule/scenarios';

  @override
  State<ScenariosScreen> createState() => _ScenariosScreenState();
}

class _ScenariosScreenState extends State<ScenariosScreen> {
  final List<SchEdit> _edits = [];
  SchPreview? _preview;
  List<SchScenario> _scenarios = const [];
  List<SchItemOption> _items = const [];
  List<({int id, String name})> _people = const [];
  List<({int id, String name})> _skills = const [];

  bool _loading = true;
  bool _running = false;
  bool _busy = false;
  String? _error;
  String? _previewError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final raw = await Api.post('replan.php', 'scenarios');
      if (!mounted) return;
      setState(() {
        _scenarios = asList(raw['scenarios'], SchScenario.fromJson);
        _loading = false;
        _error = null;
      });
      await _loadOptions();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// The pickers the composer needs. Each one degrades on its own: a failure
  /// here removes one kind of edit, it does not break the screen.
  Future<void> _loadOptions() async {
    if (_items.isEmpty) {
      try {
        final r = await Api.post('work_items.php', 'list', {'limit': 200});
        final items = asList(r['items'], SchItemOption.fromJson)..sort((a, b) => a.ref.compareTo(b.ref));
        if (mounted) setState(() => _items = items);
      } catch (_) {/* item edits stay unavailable */}
    }
    if (_people.isEmpty) {
      try {
        final r = await Api.post('people.php', 'list');
        final people = (r['people'] is List ? r['people'] as List : const [])
            .whereType<Map>()
            .map((m) => (id: asIntOr(m['id'], 0), name: asStrOr(m['name'], 'Unknown')))
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        if (mounted) setState(() => _people = people);
      } catch (_) {/* person edits stay unavailable */}
    }
    if (_skills.isEmpty) {
      try {
        final r = await Api.post('skills.php', 'list');
        final skills = (r['skills'] is List ? r['skills'] as List : const [])
            .whereType<Map>()
            .map((m) => (id: asIntOr(m['id'], 0), name: asStrOr(m['name'], '')))
            .where((s) => s.name.isNotEmpty)
            .toList();
        if (mounted) setState(() => _skills = skills);
      } catch (_) {/* a contractor can still be added with no skills */}
    }
  }

  Map<int, String> get _itemNames => {for (final i in _items) i.id: i.label};
  Map<int, String> get _peopleNames => {for (final p in _people) p.id: p.name};

  // ---------------------------------------------------------------------------
  // Composing and running a what-if
  // ---------------------------------------------------------------------------

  Future<void> _runPreview() async {
    if (_edits.isEmpty) return;
    setState(() {
      _running = true;
      _previewError = null;
    });
    try {
      final raw = await Api.post('replan.php', 'preview', {'changes': [for (final e in _edits) e.toJson()]});
      if (!mounted) return;
      setState(() {
        _preview = SchPreview.fromJson(raw);
        _running = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _previewError = e.message;
        _running = false;
      });
    }
  }

  void _discard() {
    setState(() {
      _edits.clear();
      _preview = null;
      _previewError = null;
    });
    _snack('What-if discarded. The committed plan is untouched.');
  }

  Future<void> _save() async {
    final name = await _nameDialog();
    if (name == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await Api.post('replan.php', 'scenario_save', {
        'name': name,
        'changes': [for (final e in _edits) e.toJson()],
      });
      if (!mounted) return;
      _snack('Saved as "$name"');
      await _load(silent: true);
    } on ApiException catch (e) {
      if (mounted) _snack(e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _adopt(SchScenario s) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Adopt "${s.name}"?'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Adopting re-runs this scenario against today\'s data and records the result as a proposal. '
                'Nothing is committed: the changes go to the Changes screen for review, guardrails and all.',
                style: context.text.bodyMedium,
              ),
              const SizedBox(height: Sp.md),
              for (final e in s.edits)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('· ${schEditLabel(e, items: _itemNames, people: _peopleNames)}', style: context.text.bodyMedium),
                ),
            ],
          ),
        ),
        actions: [
          SecondaryButton('Cancel', onPressed: () => Navigator.of(dialogContext).pop(false)),
          PrimaryButton('Adopt as a proposal', onPressed: () => Navigator.of(dialogContext).pop(true)),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await Api.post('replan.php', 'scenario_adopt', {'id': s.id});
      if (!mounted) return;
      final changes = asIntOr(r['changes'] is List ? (r['changes'] as List).length : r['changes'], 0);
      context.read<ShellState>().refreshCounts();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(changes == 0
              ? '"${s.name}" adopted — the engine found nothing worth changing'
              : '"${s.name}" adopted as a proposal with $changes ${changes == 1 ? 'change' : 'changes'} to review'),
          action: SnackBarAction(label: 'Review', onPressed: () => context.go(Routes.changes)),
        ),
      );
    } on ApiException catch (e) {
      if (mounted) _snack(e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Edit composer dialogs
  // ---------------------------------------------------------------------------

  Future<void> _addEdit() async {
    final kind = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Add a hypothetical edit'),
        children: [
          _option(dialogContext, 'add_item', Icons.playlist_add, 'Bring an item into the plan', 'Schedule something that is not planned yet.'),
          _option(dialogContext, 'remove_item', Icons.playlist_remove, 'Drop an item', 'Take an item out and see what the time buys.'),
          _option(dialogContext, 'person_away', Icons.event_busy_outlined, 'Mark someone away', 'Leave, training or a secondment for a date range.'),
          _option(dialogContext, 'add_person', Icons.person_add_alt, 'Add a contractor', 'An extra pair of hands with the skills you choose.'),
        ],
      ),
    );
    if (kind == null || !mounted) return;
    final edit = switch (kind) {
      'add_item' => await _itemDialog(add: true),
      'remove_item' => await _itemDialog(add: false),
      'person_away' => await _awayDialog(),
      'add_person' => await _contractorDialog(),
      _ => null,
    };
    if (edit == null || !mounted) return;
    setState(() {
      _edits.add(edit);
      _preview = null; // the previous result no longer describes these edits
    });
  }

  Widget _option(BuildContext dialogContext, String value, IconData icon, String title, String detail) => SimpleDialogOption(
        onPressed: () => Navigator.of(dialogContext).pop(value),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: context.mutedColor),
            const SizedBox(width: Sp.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: context.text.titleSmall),
                  Text(detail, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
                ],
              ),
            ),
          ],
        ),
      );

  Future<SchEdit?> _itemDialog({required bool add}) async {
    if (_items.isEmpty) {
      _snack('The work item list could not be loaded, so item edits are not available.', error: true);
      return null;
    }
    int? chosen;
    return showDialog<SchEdit>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialog) => AlertDialog(
          title: Text(add ? 'Bring an item into the plan' : 'Drop an item'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  add
                      ? 'The engine will try to fit this item in alongside everything else.'
                      : 'The item comes out of the plan and its people are free for other work.',
                  style: context.text.bodyMedium,
                ),
                const SizedBox(height: Sp.md),
                DropdownButtonFormField<int>(
                  initialValue: chosen,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Work item'),
                  items: [
                    for (final i in _items)
                      DropdownMenuItem(
                        value: i.id,
                        child: Text(dotJoin([i.label, i.sizeStamp]), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setDialog(() => chosen = v),
                ),
              ],
            ),
          ),
          actions: [
            SecondaryButton('Cancel', onPressed: () => Navigator.of(dialogContext).pop()),
            PrimaryButton(
              'Add to the what-if',
              onPressed: chosen == null
                  ? null
                  : () {
                      final item = _items.firstWhere((i) => i.id == chosen);
                      Navigator.of(dialogContext).pop(add ? SchEdit.addItem(item.id, item.label) : SchEdit.removeItem(item.id, item.label));
                    },
            ),
          ],
        ),
      ),
    );
  }

  Future<SchEdit?> _awayDialog() async {
    if (_people.isEmpty) {
      _snack('The people list could not be loaded, so availability edits are not available.', error: true);
      return null;
    }
    int? personId;
    final today = DateTime.now();
    DateTime from = DateTime(today.year, today.month, today.day);
    DateTime to = from.add(const Duration(days: 4));
    return showDialog<SchEdit>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialog) {
          Future<void> pick({required bool isFrom}) async {
            final picked = await showDatePicker(
              context: dialogContext,
              initialDate: isFrom ? from : to,
              firstDate: DateTime(today.year - 1),
              lastDate: DateTime(today.year + 3),
            );
            if (picked == null) return;
            setDialog(() {
              if (isFrom) {
                from = picked;
                if (to.isBefore(from)) to = from;
              } else {
                to = picked.isBefore(from) ? from : picked;
              }
            });
          }

          return AlertDialog(
            title: const Text('Mark someone away'),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Their capacity drops to nothing for these dates and the engine replans around it. '
                    'Nothing is written to their real availability.',
                    style: context.text.bodyMedium,
                  ),
                  const SizedBox(height: Sp.md),
                  DropdownButtonFormField<int>(
                    initialValue: personId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Person'),
                    items: [for (final p in _people) DropdownMenuItem(value: p.id, child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis))],
                    onChanged: (v) => setDialog(() => personId = v),
                  ),
                  const SizedBox(height: Sp.md),
                  Row(
                    children: [
                      Expanded(child: SecondaryButton('From ${fmtShortDate(from)}', icon: Icons.event, expand: true, onPressed: () => pick(isFrom: true))),
                      const SizedBox(width: Sp.sm),
                      Expanded(child: SecondaryButton('To ${fmtShortDate(to)}', icon: Icons.event, expand: true, onPressed: () => pick(isFrom: false))),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              SecondaryButton('Cancel', onPressed: () => Navigator.of(dialogContext).pop()),
              PrimaryButton(
                'Add to the what-if',
                onPressed: personId == null
                    ? null
                    : () {
                        final person = _people.firstWhere((p) => p.id == personId);
                        Navigator.of(dialogContext).pop(SchEdit.personAway(person.id, person.name, from, to));
                      },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<SchEdit?> _contractorDialog() async {
    final controller = TextEditingController(text: 'Contractor');
    final chosen = <int>{};
    final edit = await showDialog<SchEdit>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialog) => AlertDialog(
          title: const Text('Add a contractor'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'A full-time extra person for the what-if only, qualified at level 3 in the skills you tick. '
                    'Nobody is added to the team.',
                    style: context.text.bodyMedium,
                  ),
                  const SizedBox(height: Sp.md),
                  TextField(
                    controller: controller,
                    onChanged: (_) => setDialog(() {}),
                    decoration: const InputDecoration(labelText: 'Name', hintText: 'Shown on the lane in the what-if'),
                  ),
                  const SizedBox(height: Sp.lg),
                  if (_skills.isEmpty)
                    Text('No skills catalogue is available, so the contractor will be added without skills.',
                        style: context.text.bodySmall?.copyWith(color: context.mutedColor))
                  else ...[
                    const SectionLabel('Skills at level 3', padding: EdgeInsets.only(bottom: Sp.sm)),
                    Wrap(
                      spacing: Sp.sm,
                      runSpacing: Sp.sm,
                      children: [
                        for (final s in _skills)
                          FilterChip(
                            label: Text(s.name),
                            selected: chosen.contains(s.id),
                            onSelected: (v) => setDialog(() => v ? chosen.add(s.id) : chosen.remove(s.id)),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            SecondaryButton('Cancel', onPressed: () => Navigator.of(dialogContext).pop()),
            PrimaryButton(
              'Add to the what-if',
              onPressed: controller.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(dialogContext).pop(SchEdit.addPerson(
                        controller.text.trim(),
                        [for (final s in _skills.where((s) => chosen.contains(s.id))) (id: s.id, name: s.name, proficiency: 3)],
                      )),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return edit;
  }

  Future<String?> _nameDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialog) => AlertDialog(
          title: const Text('Save this what-if'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Saved scenarios keep their edits and their before-and-after summary. They change nothing until one is adopted.',
                    style: context.text.bodyMedium),
                const SizedBox(height: Sp.md),
                TextField(
                  controller: controller,
                  autofocus: true,
                  onChanged: (_) => setDialog(() {}),
                  decoration: const InputDecoration(labelText: 'Name', hintText: 'Contractor from October'),
                ),
              ],
            ),
          ),
          actions: [
            SecondaryButton('Cancel', onPressed: () => Navigator.of(dialogContext).pop()),
            PrimaryButton(
              'Save scenario',
              onPressed: controller.text.trim().isEmpty ? null : () => Navigator.of(dialogContext).pop(controller.text.trim()),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return name;
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: error ? DispatchColors.red : null),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const PageBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Skeleton(width: 240, height: 28),
            SizedBox(height: Sp.sm),
            Skeleton(width: 420, height: 14),
            SizedBox(height: Sp.xl),
            SkeletonPanel(rows: 3),
            SizedBox(height: Sp.lg),
            SkeletonPanel(rows: 3),
          ],
        ),
      );
    }
    if (_error != null) {
      return PageBody(child: ErrorState(title: 'Scenarios could not be loaded', message: _error, onRetry: _load));
    }
    final phone = Breaks.isPhone(context);
    return PageBody(
      onRefresh: () => _load(silent: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(),
          const SizedBox(height: Sp.xl),
          if (phone) ...[
            _composer(),
            const SizedBox(height: Sp.lg),
            if (_preview != null || _previewError != null) ...[_result(), const SizedBox(height: Sp.lg)],
            _savedPanel(),
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _composer(),
                      if (_preview != null || _previewError != null) ...[const SizedBox(height: Sp.lg), _result()],
                    ],
                  ),
                ),
                const SizedBox(width: Sp.xl),
                SizedBox(width: Breaks.isDesktop(context) ? 380 : 300, child: _savedPanel()),
              ],
            ),
        ],
      ),
    );
  }

  Widget _header() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final title = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('What-if scenarios', style: Breaks.isPhone(context) ? context.text.headlineSmall : context.text.headlineMedium),
            const SizedBox(height: 2),
            Text(
              'Try a change against the committed plan without touching it. Nothing here is saved until you save it, and nothing is planned until a scenario is adopted.',
              style: context.text.bodyMedium?.copyWith(color: context.mutedColor),
            ),
          ],
        );
        final back = SecondaryButton('Back to schedule', icon: Icons.calendar_month_outlined, onPressed: () => context.go(Routes.schedule));
        if (constraints.maxWidth < 720) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, const SizedBox(height: Sp.md), back]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Expanded(child: title), const SizedBox(width: Sp.md), back],
        );
      },
    );
  }

  // --- composer ---------------------------------------------------------------

  Widget _composer() {
    final session = context.watch<Session>();
    return Panel(
      title: 'Compose a what-if',
      subtitle: _edits.isEmpty ? 'No edits yet' : '${_edits.length} ${_edits.length == 1 ? 'edit' : 'edits'} against the committed plan',
      trailing: SecondaryButton('Add an edit', icon: Icons.add, onPressed: _busy ? null : _addEdit),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_edits.isEmpty)
            const EmptyState(
              icon: Icons.alt_route_outlined,
              compact: true,
              title: 'Nothing to try yet',
              message: 'Add an edit — a contractor, a dropped item, someone away — then run the preview.',
            )
          else
            for (var i = 0; i < _edits.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: Sp.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(_editIcon(_edits[i].op), size: 18, color: context.mutedColor),
                    const SizedBox(width: Sp.md),
                    Expanded(child: Text(_edits[i].label, style: context.text.bodyMedium)),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: 'Remove this edit',
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _edits.removeAt(i);
                                _preview = null;
                              }),
                    ),
                  ],
                ),
              ),
          const SizedBox(height: Sp.md),
          Wrap(
            spacing: Sp.sm,
            runSpacing: Sp.sm,
            children: [
              PrimaryButton(
                'Run the preview',
                icon: Icons.play_arrow_rounded,
                busy: _running,
                onPressed: _edits.isEmpty || _running ? null : _runPreview,
              ),
              if (session.can('team_lead'))
                SecondaryButton(
                  'Save as a scenario',
                  icon: Icons.bookmark_add_outlined,
                  busy: _busy,
                  onPressed: _edits.isEmpty || _busy ? null : _save,
                ),
              if (_edits.isNotEmpty) SecondaryButton('Discard', danger: true, onPressed: _busy ? null : _discard),
            ],
          ),
          if (!session.can('team_lead'))
            Padding(
              padding: const EdgeInsets.only(top: Sp.sm),
              child: Text('Only a team lead or above can save a scenario.', style: context.text.labelMedium?.copyWith(color: context.mutedColor)),
            ),
        ],
      ),
    );
  }

  IconData _editIcon(String op) => switch (op) {
        'add_item' => Icons.playlist_add,
        'remove_item' => Icons.playlist_remove,
        'person_away' => Icons.event_busy_outlined,
        'add_person' => Icons.person_add_alt,
        _ => Icons.tune,
      };

  // --- preview result ---------------------------------------------------------

  Widget _result() {
    if (_previewError != null) {
      return Panel(
        title: 'The what-if',
        child: ErrorState(title: 'The preview could not be produced', message: _previewError, compact: true, onRetry: _runPreview),
      );
    }
    final p = _preview!;
    final changes = p.allChanges;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Panel(
          title: 'The committed plan and this what-if',
          subtitle: p.editsApplied.isEmpty ? null : p.editsApplied.join(' · '),
          trailing: p.solveSeconds == null ? null : SchChip('Solved in ${p.solveSeconds!.toStringAsFixed(2)}s', tone: 'info'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SchSummaryTable(before: p.summaryBefore, after: p.summaryAfter, beforeLabel: 'Committed', afterLabel: 'What-if'),
              if (p.improvementPct != null) ...[
                const Divider(height: Sp.xl),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      p.improvementPct! > 0 ? Icons.trending_up : Icons.trending_down,
                      size: 18,
                      color: p.improvementPct! > 0 ? DispatchColors.green : DispatchColors.orange,
                    ),
                    const SizedBox(width: Sp.sm),
                    Expanded(
                      child: Text(
                        p.improvementPct! > 0
                            ? 'This what-if scores ${fmtPct(p.improvementPct)} better than the committed plan.'
                            : 'This what-if scores ${fmtPct(p.improvementPct!.abs())} worse than the committed plan.',
                        style: context.text.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ],
              if (p.unscheduled.isNotEmpty) ...[
                const SizedBox(height: Sp.md),
                SectionLabel('Left unscheduled (${p.unscheduled.length})'),
                for (final u in p.unscheduled.take(6))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      dotJoin([u.ref, u.detail ?? u.title, u.suggestion]),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodySmall?.copyWith(color: context.mutedColor),
                    ),
                  ),
                if (p.unscheduled.length > 6)
                  Text('…and ${p.unscheduled.length - 6} more', style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
              ],
            ],
          ),
        ),
        const SizedBox(height: Sp.lg),
        Panel(
          title: 'What it would take',
          subtitle: changes.isEmpty
              ? 'No assignment would move'
              : '${changes.length} ${changes.length == 1 ? 'change' : 'changes'}'
                  '${p.held.isEmpty ? '' : ', ${p.held.length} held by guardrails'}',
          child: changes.isEmpty
              ? const EmptyState(
                  icon: Icons.check_circle_outline,
                  compact: true,
                  title: 'Nothing would move',
                  message: 'The engine reaches this what-if without changing any assignment.',
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final c in changes.take(12))
                      Padding(
                        padding: const EdgeInsets.only(bottom: Sp.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: Text(c.headline, style: context.text.titleSmall)),
                                const SizedBox(width: Sp.sm),
                                if (c.isHeld) const SchChip('Held', tone: 'warn') else SchChip(humanise(c.kind), tone: 'info'),
                              ],
                            ),
                            if (c.reason != null && c.reason!.isNotEmpty)
                              Text(c.reason!, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
                            const SizedBox(height: Sp.xs),
                            Wrap(
                              spacing: Sp.sm,
                              runSpacing: Sp.xs,
                              children: [
                                if (c.personName != null) SchChip(c.personName!, tone: 'info'),
                                SchChip('Stability ${fmtDays(c.stabilityCostDays, unit: 'assignment-day')}',
                                    tone: c.stabilityCostDays > 0 ? 'warn' : 'ok'),
                                if (c.insideFreeze) const SchChip('Inside freeze horizon', tone: 'warn'),
                              ],
                            ),
                          ],
                        ),
                      ),
                    if (changes.length > 12)
                      Text('…and ${changes.length - 12} more', style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
                    if (p.belowThreshold) ...[
                      const Divider(height: Sp.xl),
                      Text(
                        'Every change here is below the minimum improvement threshold, so a replan would show them and apply none of them automatically.',
                        style: context.text.bodyMedium?.copyWith(color: context.mutedColor),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  // --- saved scenarios --------------------------------------------------------

  Widget _savedPanel() {
    final session = context.watch<Session>();
    return Panel(
      title: 'Saved scenarios',
      subtitle: _scenarios.isEmpty ? null : '${_scenarios.length} saved',
      child: _scenarios.isEmpty
          ? const EmptyState(
              icon: Icons.bookmark_border,
              compact: true,
              title: 'No saved scenarios',
              message: 'Compose a what-if and save it to compare it again later.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final s in _scenarios)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Sp.md),
                    child: DispatchCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: Text(s.name, style: context.text.titleSmall)),
                              const SizedBox(width: Sp.sm),
                              if (s.improvementPct != null)
                                SchChip(
                                  '${s.improvementPct! > 0 ? '+' : ''}${fmtPct(s.improvementPct)}',
                                  tone: (s.improvementPct ?? 0) > 0 ? 'ok' : 'warn',
                                ),
                            ],
                          ),
                          Text(
                            dotJoin([
                              if (s.generatedAt != null) 'saved ${fmtShortDate(s.generatedAt)}',
                              if (s.objectiveScore != null) 'objective ${s.objectiveScore!.toStringAsFixed(1)}',
                            ]),
                            style: context.text.labelSmall?.copyWith(color: context.mutedColor),
                          ),
                          const SizedBox(height: Sp.sm),
                          for (final e in s.edits)
                            Text('· ${schEditLabel(e, items: _itemNames, people: _peopleNames)}',
                                maxLines: 2, overflow: TextOverflow.ellipsis, style: context.text.bodySmall),
                          const SizedBox(height: Sp.sm),
                          Wrap(
                            spacing: Sp.sm,
                            runSpacing: Sp.sm,
                            children: [
                              SecondaryButton('Load into the composer', icon: Icons.north_east, onPressed: _busy ? null : () => _loadScenario(s)),
                              if (session.isDeliveryLead)
                                PrimaryButton('Adopt', icon: Icons.done_all, busy: _busy, onPressed: _busy ? null : () => _adopt(s)),
                            ],
                          ),
                          if (!session.isDeliveryLead)
                            Padding(
                              padding: const EdgeInsets.only(top: Sp.xs),
                              child: Text('Only a delivery lead can adopt a scenario.',
                                  style: context.text.labelSmall?.copyWith(color: context.mutedColor)),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  void _loadScenario(SchScenario s) {
    setState(() {
      _edits
        ..clear()
        ..addAll([
          for (final e in s.edits)
            SchEdit(
              op: asStrOr(e['op'] ?? e['type'] ?? e['kind'], ''),
              label: schEditLabel(e, items: _itemNames, people: _peopleNames),
              payload: {for (final entry in e.entries) if (entry.key != 'op' && entry.key != 'type' && entry.key != 'kind') entry.key: entry.value},
            ),
        ]);
      _preview = null;
      _previewError = null;
    });
    _snack('"${s.name}" loaded into the composer');
  }
}

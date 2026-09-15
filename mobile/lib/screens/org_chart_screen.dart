import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/org.dart';
import '../services/api.dart';
import '../services/format.dart';
import '../shell/breaks.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/team_widgets.dart';
import '../widgets/widgets.dart';
import 'parts/org_canvas.dart';
import 'parts/org_details_panel.dart';
import 'parts/org_dialogs.dart';
import 'parts/org_tree_list.dart';

/// The organisation (ORG-01..05): teams within teams, who leads them, who
/// reports to whom, and who may change it.
///
/// Two views of the same tree. The chart is a pannable canvas with drag and
/// drop, which is how you reorganise something; the list is the same structure
/// indented, which is how you read it on a phone. Everything either one can do
/// goes through the same handlers here, so a drag and a menu item mean exactly
/// the same thing to the server.
class OrgChartScreen extends StatefulWidget {
  const OrgChartScreen({super.key});

  @override
  State<OrgChartScreen> createState() => _OrgChartScreenState();
}

class _OrgChartScreenState extends State<OrgChartScreen> {
  final GlobalKey<OrgCanvasState> _canvasKey = GlobalKey<OrgCanvasState>();

  bool _loading = true;
  String? _error;
  OrgTree? _tree;

  int _view = 0; // 0 chart, 1 list
  bool _showPeople = true;
  int? _roleFamilyFilter;
  final Set<int> _collapsed = {};
  int? _selectedTeamId;
  int? _selectedPersonId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await Api.post('org.php', 'tree');
      if (!mounted) return;
      setState(() {
        _tree = OrgTree.fromJson(r);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not reach the server.';
        _loading = false;
      });
    }
  }

  // ─── mutations ────────────────────────────────────────────────────────────

  Future<void> _call(String action, Map<String, dynamic> body, String done) async {
    try {
      await Api.post('org.php', action, body);
      if (!mounted) return;
      tmToast(context, done);
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      tmToast(context, e.message, bad: true);
    }
  }

  Future<void> _moveTeam(OrgTeam team, int? parentId) async {
    final where = parentId == null ? 'the top of the organisation' : (_tree?.team(parentId)?.name ?? 'there');
    await _call('move_team', {'team_id': team.id, 'parent_team_id': parentId}, '${team.name} now sits under $where');
  }

  Future<void> _movePerson(OrgPerson person, int? teamId, {bool confirmed = false}) async {
    final to = teamId == null ? 'no team' : (_tree?.team(teamId)?.name ?? 'another team');
    if (!confirmed) {
      final ok = await confirmOrgMovePerson(context, person: person, from: _tree?.homeTeamOf(person.id)?.name, to: to);
      if (!ok || !mounted) return;
    }
    try {
      await Api.post('org.php', 'move_person', {'person_id': person.id, 'team_id': teamId});
      if (!mounted) return;
      tmToast(context, '${person.firstName} is now in $to');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      // A running loan says this person's time already belongs somewhere else.
      // The server will end it, but only if somebody says so out loud.
      if (e.code == 409) {
        final again = await showTmConfirm(
          context,
          title: 'There is a loan in the way',
          message: '${e.message}\n\nMoving them anyway ends that loan.',
          confirmLabel: 'Move anyway',
          danger: true,
        );
        if (!again || !mounted) return;
        await _call('move_person', {'person_id': person.id, 'team_id': teamId, 'force': true},
            '${person.firstName} is now in $to, and the loan has ended');
        return;
      }
      tmToast(context, e.message, bad: true);
    }
  }

  Future<void> _setManager(OrgPerson person, int? managerId) async {
    final name = managerId == null ? 'nobody' : (_tree?.person(managerId)?.name ?? 'them');
    await _call('set_manager', {'person_id': person.id, 'manager_person_id': managerId}, '${person.firstName} now reports to $name');
  }

  Future<void> _deleteTeam(OrgTeam team) async {
    final ok = await confirmOrgDeleteTeam(context, team);
    if (!ok || !mounted) return;
    if (_selectedTeamId == team.id) setState(() => _selectedTeamId = null);
    await _call('delete_team', {'team_id': team.id}, '${team.name} deleted');
  }

  Future<void> _editTeam({OrgTeam? team, int? parentId}) async {
    final tree = _tree;
    if (tree == null) return;
    final changed = await showOrgTeamDialog(context, tree: tree, team: team, parentId: parentId);
    if (changed) await _load();
  }

  Future<void> _visibility(OrgTeam team) async {
    final changed = await showOrgVisibilityDialog(context, team);
    if (changed) await _load();
  }

  Future<void> _pickTeamForTeam(OrgTeam team) async {
    final tree = _tree;
    if (tree == null) return;
    final pick = await showOrgTeamPicker(
      context,
      tree: tree,
      title: 'Where should ${team.name} sit?',
      exclude: tree.descendantsOf(team.id),
      allowNone: tree.canEditAll,
      noneLabel: 'Top of the organisation',
    );
    if (pick == null || !mounted) return;
    await _moveTeam(team, pick.id);
  }

  Future<void> _pickTeamForPerson(OrgPerson person) async {
    final tree = _tree;
    if (tree == null) return;
    final pick = await showOrgTeamPicker(
      context,
      tree: tree,
      title: 'Which team does ${person.firstName} join?',
      exclude: {if (person.teamId != null) person.teamId!},
      allowNone: true,
      noneLabel: 'No team',
    );
    if (pick == null || !mounted) return;
    await _movePerson(person, pick.id);
  }

  Future<void> _pickManager(OrgPerson person) async {
    final tree = _tree;
    if (tree == null) return;
    final people = orgPeopleOf(tree).where((p) => p.id != person.id).toList();
    final chosen = await showDialog<int?>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Who does ${person.firstName} report to?'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.of(context).pop(-1), child: const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Nobody'))),
          for (final p in people)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(p.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  PersonAvatar(p.initialsOrDerived, colourHex: p.colourHex, seed: p.id, size: 22),
                  const SizedBox(width: Sp.sm),
                  Flexible(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                ]),
              ),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    await _setManager(person, chosen == -1 ? null : chosen);
  }

  // ─── selection ────────────────────────────────────────────────────────────

  void _selectTeam(OrgTeam t) {
    setState(() {
      _selectedTeamId = t.id;
      _selectedPersonId = null;
    });
    _maybeSheet();
  }

  void _selectPerson(OrgPerson p) {
    setState(() {
      _selectedPersonId = p.id;
      _selectedTeamId = null;
    });
    _maybeSheet();
  }

  void _clearSelection() => setState(() {
        _selectedTeamId = null;
        _selectedPersonId = null;
      });

  /// A side panel needs room. Below that, the details arrive as a sheet.
  void _maybeSheet() {
    if (Breaks.isDesktop(context)) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: _details(sheet: true),
      ),
    ).whenComplete(() {
      if (mounted) _clearSelection();
    });
  }

  Widget _details({bool sheet = false}) {
    final tree = _tree!;
    return OrgDetailsPanel(
      tree: tree,
      team: tree.team(_selectedTeamId),
      person: tree.person(_selectedPersonId),
      sheet: sheet,
      onClose: () {
        if (sheet) {
          Navigator.of(context).maybePop();
        } else {
          _clearSelection();
        }
      },
      onSelectTeam: _selectTeam,
      onSelectPerson: _selectPerson,
      onEditTeam: (t) => _editTeam(team: t),
      onAddSubTeam: (t) => _editTeam(parentId: t.id),
      onDeleteTeam: _deleteTeam,
      onVisibility: _visibility,
      onSetManager: _setManager,
      onMovePerson: _pickTeamForPerson,
    );
  }

  // ─── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final phone = Breaks.isPhone(context);
    final tree = _tree;
    final view = phone ? 1 : _view;

    return Padding(
      padding: EdgeInsets.fromLTRB(Breaks.gutter(context), Sp.lg, Breaks.gutter(context), Sp.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(
          title: 'Organisation',
          subtitle: tree == null
              ? 'Teams, sub-teams and who reports to whom'
              : dotJoin([
                  '${tree.teamCount} ${tree.teamCount == 1 ? 'team' : 'teams'}',
                  '${tree.peopleCount} people',
                  '${tree.roleFamilies.length} role families',
                ]),
          actions: [
            if (!phone)
              SegmentedTabs(labels: const ['Chart', 'List'], selected: _view, onChanged: (i) => setState(() => _view = i)),
            if (tree != null && tree.roleFamilies.isNotEmpty) _RoleFamilyFilter(
              families: tree.roleFamilies,
              value: _roleFamilyFilter,
              onChanged: (v) => setState(() => _roleFamilyFilter = v),
            ),
            InfoPill(
              _showPeople ? 'People shown' : 'People hidden',
              icon: _showPeople ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              onTap: () => setState(() => _showPeople = !_showPeople),
            ),
            if (tree != null && tree.canEditAll)
              PrimaryButton('Add team', icon: Icons.add_rounded, onPressed: () => _editTeam()),
          ],
        ),
        const SizedBox(height: Sp.lg),
        Expanded(
          child: _loading
              ? const _OrgSkeleton()
              : _error != null
                  ? ErrorState(title: 'We could not load the organisation', message: _error, onRetry: _load)
                  : tree == null || tree.roots.isEmpty
                      ? EmptyState(
                          icon: Icons.account_tree_outlined,
                          title: 'No teams yet',
                          message: 'Add a team to start building the organisation.',
                          action: (tree?.canEditAll ?? false) ? PrimaryButton('Add team', icon: Icons.add_rounded, onPressed: () => _editTeam()) : null,
                        )
                      : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                color: view == 0 ? context.panelColor : Colors.transparent,
                                borderRadius: DispatchRadius.panelR,
                                border: view == 0 ? Border.all(color: context.borderColor) : null,
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: view == 0
                                  ? OrgCanvas(
                                      key: _canvasKey,
                                      tree: tree,
                                      collapsed: _collapsed,
                                      showPeople: _showPeople,
                                      roleFamilyFilter: _roleFamilyFilter,
                                      selectedTeamId: _selectedTeamId,
                                      selectedPersonId: _selectedPersonId,
                                      callbacks: OrgCanvasCallbacks(
                                        onSelectTeam: _selectTeam,
                                        onSelectPerson: _selectPerson,
                                        onToggleCollapse: (id) => setState(() => _collapsed.contains(id) ? _collapsed.remove(id) : _collapsed.add(id)),
                                        onMoveTeam: _moveTeam,
                                        onMovePerson: (p, t) => _movePerson(p, t),
                                        onAddSubTeam: (t) => _editTeam(parentId: t.id),
                                      ),
                                    )
                                  : OrgTreeList(
                                      tree: tree,
                                      collapsed: _collapsed,
                                      showPeople: _showPeople,
                                      roleFamilyFilter: _roleFamilyFilter,
                                      selectedTeamId: _selectedTeamId,
                                      selectedPersonId: _selectedPersonId,
                                      onToggleCollapse: (id) => setState(() => _collapsed.contains(id) ? _collapsed.remove(id) : _collapsed.add(id)),
                                      onSelectTeam: _selectTeam,
                                      onSelectPerson: _selectPerson,
                                      onEditTeam: (t) => _editTeam(team: t),
                                      onAddSubTeam: (t) => _editTeam(parentId: t.id),
                                      onDeleteTeam: _deleteTeam,
                                      onVisibility: _visibility,
                                      onMoveTeamTo: _pickTeamForTeam,
                                      onMovePersonTo: _pickTeamForPerson,
                                      onSetManagerFor: _pickManager,
                                    ),
                            ),
                          ),
                          if (Breaks.isDesktop(context) && (_selectedTeamId != null || _selectedPersonId != null)) _details(),
                        ]),
        ),
        if (tree != null && !tree.canEditAnything && !_loading && _error == null) ...[
          const SizedBox(height: Sp.sm),
          Text(
            session.can('team_lead')
                ? 'You can change the team you lead and the teams beneath it.'
                : 'Reorganising is for team leads and above.',
            style: context.text.bodySmall?.copyWith(color: context.mutedColor),
          ),
        ],
      ]),
    );
  }
}

/// Highlight one discipline across the whole chart.
class _RoleFamilyFilter extends StatelessWidget {
  const _RoleFamilyFilter({required this.families, required this.value, required this.onChanged});
  final List<RoleFamily> families;
  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final name = families.where((f) => f.id == value).map((f) => f.name).firstOrNull;
    return PopupMenuButton<int>(
      tooltip: 'Pick out one role family',
      onSelected: (v) => onChanged(v == -1 ? null : v),
      itemBuilder: (context) => [
        const PopupMenuItem(value: -1, child: Text('Everybody')),
        const PopupMenuDivider(),
        for (final f in families) PopupMenuItem(value: f.id, child: Text(f.name)),
      ],
      child: InfoPill(name ?? 'All role families', icon: Icons.badge_outlined),
    );
  }
}

class _OrgSkeleton extends StatelessWidget {
  const _OrgSkeleton();

  @override
  Widget build(BuildContext context) {
    // A root and two children, at whatever width there is: two 240px cards side
    // by side do not fit a phone, and a skeleton that overflows is still an overflow.
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth < 520 ? c.maxWidth : 240.0;
      final side = c.maxWidth < 520;
      return Column(children: [
        Center(child: Skeleton(width: w, height: 110, radius: DispatchRadius.card)),
        const SizedBox(height: Sp.xxl),
        if (side)
          Skeleton(width: w, height: 150, radius: DispatchRadius.card)
        else
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Skeleton(width: w, height: 150, radius: DispatchRadius.card),
            const SizedBox(width: Sp.xl),
            Skeleton(width: w, height: 150, radius: DispatchRadius.card),
          ]),
      ]);
    });
  }
}

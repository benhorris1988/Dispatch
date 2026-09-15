import 'package:flutter/material.dart';

import '../models/json.dart';
import '../models/org.dart';
import '../services/api.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// A planning or viewing scope (TEAM-09, SCH-13, ORG-01/02): the whole
/// workspace, one role family, or one team.
///
/// A team scope means that team **and every team beneath it** — planning
/// 'Data Platform' plans its sub-teams too. A role family is a discipline that
/// spans the tree, so it is a set of people rather than of teams. Sent to the
/// API as `team_id` or `role_family_id`, never both, through [params].
class PlanScope {
  const PlanScope._(this.kind, this.id, this.name, {this.parentName});

  const PlanScope.workspace()
      : kind = 'workspace',
        id = null,
        name = 'Whole workspace',
        parentName = null;
  const PlanScope.roleFamily(int id, String name) : this._('role_family', id, name);
  const PlanScope.team(int id, String name, {String? parentName}) : this._('team', id, name, parentName: parentName);

  final String kind; // workspace | role_family | team
  final int? id;
  final String name;

  /// For a team: the team it sits under, if any.
  final String? parentName;

  bool get isWorkspace => kind == 'workspace';
  bool get isRoleFamily => kind == 'role_family';
  bool get isTeam => kind == 'team';

  /// Stable key for dropdowns and persistence: 'w', 'f1', 't2'.
  String get key => switch (kind) { 'role_family' => 'f$id', 'team' => 't$id', _ => 'w' };

  /// Request parameters for `people.php list`, `skills.php matrix`,
  /// `replan.php propose / preview` and friends.
  Map<String, dynamic> get params => switch (kind) {
        'role_family' => {'role_family_id': id},
        'team' => {'team_id': id},
        _ => const {},
      };

  /// 'the whole workspace' / 'the Data engineering role family' / 'the Data
  /// Platform team' — reads naturally after 'planned for'.
  String get phrase => switch (kind) {
        'role_family' => 'the $name role family',
        'team' => 'the $name team',
        _ => 'the whole workspace',
      };

  /// Short label for chips and buttons.
  String get label => isWorkspace ? 'Whole workspace' : name;

  @override
  bool operator ==(Object other) => other is PlanScope && other.key == key;
  @override
  int get hashCode => key.hashCode;
}

/// One team as the scope picker and the person dialogs need it.
class ScopeTeam {
  const ScopeTeam({required this.id, required this.name, this.parentTeamId, this.parentName, this.depth = 0, this.path = '', this.leadPersonId});
  final int id;
  final String name;
  final int? parentTeamId;
  final String? parentName;

  /// How far down the tree, so a menu or a dropdown can indent it.
  final int depth;
  final String path;
  final int? leadPersonId;

  PlanScope get scope => PlanScope.team(id, name, parentName: parentName);
}

/// The role families and teams a picker offers. `people.php list` returns both,
/// the teams already in tree order.
class PlanScopeOptions {
  const PlanScopeOptions({this.roleFamilies = const [], this.teams = const []});

  final List<RoleFamily> roleFamilies;
  final List<ScopeTeam> teams;

  static const empty = PlanScopeOptions();

  /// Every scope in menu order: workspace, role families, then teams.
  List<PlanScope> get all => [const PlanScope.workspace(), for (final f in roleFamilies) PlanScope.roleFamily(f.id, f.name), for (final t in teams) t.scope];

  /// True when there is anything to choose between beyond the workspace.
  bool get hasChoices => roleFamilies.isNotEmpty || teams.length > 1;

  PlanScope? byKey(String key) => all.where((s) => s.key == key).firstOrNull;

  ScopeTeam? team(int? id) => id == null ? null : teams.where((t) => t.id == id).firstOrNull;

  static Future<PlanScopeOptions> load() async {
    // Two calls, caught separately: a missing role family should not cost the
    // picker its teams, and the other way round.
    List<ScopeTeam> teams = const [];
    List<RoleFamily> families = const [];
    try {
      final r = await Api.post('people.php', 'list');
      teams = [
        for (final raw in (r['teams'] as List? ?? const []))
          if (raw is Map)
            ScopeTeam(
              id: asIntOr(raw['id'], 0),
              name: asStrOr(raw['name'], ''),
              parentTeamId: asInt(raw['parent_team_id']),
              parentName: asStr(raw['parent_team_name']),
              depth: asIntOr(raw['depth'], 0),
              path: asStrOr(raw['path'], ''),
              leadPersonId: asInt(raw['lead_person_id']),
            ),
      ];
    } on ApiException {
      teams = const [];
    }
    try {
      final r = await Api.post('role_families.php', 'list');
      families = listOf(r['role_families'], RoleFamily.fromJson);
    } on ApiException {
      families = const [];
    }
    return PlanScopeOptions(roleFamilies: families, teams: teams);
  }
}

/// Scope selector: *Whole workspace* / each role family / each team. A popup menu
/// behind a pill, so it sits in a [Wrap] of header actions at any width without
/// needing a fixed width the way a dropdown would.
class TmScopePicker extends StatelessWidget {
  const TmScopePicker({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.icon = Icons.filter_center_focus_rounded,
    this.prefix,
    this.enabled = true,
  });

  final PlanScopeOptions options;
  final PlanScope value;
  final ValueChanged<PlanScope> onChanged;
  final IconData icon;

  /// Optional lead-in on the pill, e.g. 'Plan' → 'Plan · Data Platform'.
  final String? prefix;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final muted = context.text.bodySmall?.copyWith(color: context.mutedColor);
    final label = prefix == null ? value.label : '$prefix · ${value.label}';
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: context.panelColor, borderRadius: BorderRadius.circular(999), border: Border.all(color: context.borderColor)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: context.mutedColor),
        const SizedBox(width: 6),
        Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.labelLarge?.copyWith(fontWeight: FontWeight.w500))),
        const SizedBox(width: 2),
        Icon(Icons.arrow_drop_down_rounded, size: 20, color: context.mutedColor),
      ]),
    );
    if (!enabled) return Opacity(opacity: 0.6, child: pill);

    PopupMenuItem<String> header(String text) => PopupMenuItem<String>(
          enabled: false,
          height: 30,
          child: Text(text.toUpperCase(), style: context.text.labelSmall?.copyWith(color: context.mutedColor, letterSpacing: 0.6)),
        );
    PopupMenuItem<String> entry(PlanScope s, {String? note, int indent = 0}) => PopupMenuItem<String>(
          value: s.key,
          child: Row(children: [
            if (indent > 0) SizedBox(width: Sp.md * indent),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(s.label, style: context.text.bodyMedium?.copyWith(fontWeight: s == value ? FontWeight.w700 : FontWeight.w400)),
                if (note != null) Text(note, style: muted),
              ]),
            ),
            if (s == value) const Icon(Icons.check_rounded, size: 18, color: DispatchColors.green),
          ]),
        );

    return Tooltip(
      message: 'Choose the workspace, a role family or a team',
      child: PopupMenuButton<String>(
        tooltip: '',
        onSelected: (k) {
          final s = options.byKey(k);
          if (s != null) onChanged(s);
        },
        itemBuilder: (context) => [
          entry(const PlanScope.workspace()),
          if (options.roleFamilies.isNotEmpty) ...[
            const PopupMenuDivider(),
            header('Role families'),
            for (final f in options.roleFamilies)
              entry(PlanScope.roleFamily(f.id, f.name),
                  note: '${f.headcount} ${f.headcount == 1 ? 'person' : 'people'}${f.leadName == null ? '' : ' · ${f.leadName}'}'),
          ],
          if (options.teams.isNotEmpty) ...[
            const PopupMenuDivider(),
            header('Teams'),
            // Indented by depth: a sub-team plans as part of its parent, and the
            // shape of the menu should say so before the note does.
            for (final t in options.teams) entry(t.scope, note: t.parentName, indent: t.depth),
          ],
        ],
        child: pill,
      ),
    );
  }
}

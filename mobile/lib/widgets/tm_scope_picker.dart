import 'package:flutter/material.dart';

import '../models/json.dart';
import '../services/api.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// A planning or viewing scope (TEAM-09, SCH-13): the whole workspace, one
/// portfolio's teams together, or a single team. Sent to the API as
/// `portfolio_id` or `team_id` — never both — through [params].
class PlanScope {
  const PlanScope._(this.kind, this.id, this.name, {this.portfolioName});

  const PlanScope.workspace()
      : kind = 'workspace',
        id = null,
        name = 'Whole workspace',
        portfolioName = null;
  const PlanScope.portfolio(int id, String name) : this._('portfolio', id, name);
  const PlanScope.team(int id, String name, {String? portfolioName}) : this._('team', id, name, portfolioName: portfolioName);

  final String kind; // workspace | portfolio | team
  final int? id;
  final String name;
  /// For a team: the portfolio it sits in, if any.
  final String? portfolioName;

  bool get isWorkspace => kind == 'workspace';
  bool get isPortfolio => kind == 'portfolio';
  bool get isTeam => kind == 'team';

  /// Stable key for dropdowns and persistence: 'w', 'p1', 't2'.
  String get key => switch (kind) { 'portfolio' => 'p$id', 'team' => 't$id', _ => 'w' };

  /// Request parameters for `people.php list`, `skills.php matrix`,
  /// `replan.php propose / preview` and friends.
  Map<String, dynamic> get params => switch (kind) {
        'portfolio' => {'portfolio_id': id},
        'team' => {'team_id': id},
        _ => const {},
      };

  /// 'the whole workspace' / 'the Data & Integration portfolio' / 'the Data
  /// Platform team' — reads naturally after 'planned for'.
  String get phrase => switch (kind) {
        'portfolio' => 'the $name portfolio',
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

/// One team as the scope picker and portfolio dialogs need it.
class ScopeTeam {
  const ScopeTeam({required this.id, required this.name, this.portfolioId, this.portfolioName, this.leadPersonId});
  final int id;
  final String name;
  final int? portfolioId;
  final String? portfolioName;
  final int? leadPersonId;

  PlanScope get scope => PlanScope.team(id, name, portfolioName: portfolioName);
}

/// One portfolio with its member teams.
class ScopePortfolio {
  const ScopePortfolio({required this.id, required this.name, this.description, this.leadName, this.teams = const []});
  final int id;
  final String name;
  final String? description;
  final String? leadName;
  final List<ScopeTeam> teams;

  PlanScope get scope => PlanScope.portfolio(id, name);
}

/// The portfolios and teams a picker offers, from `portfolios.php list`
/// (which also lists the teams in no portfolio).
class PlanScopeOptions {
  const PlanScopeOptions({this.portfolios = const [], this.unassignedTeams = const []});

  final List<ScopePortfolio> portfolios;
  final List<ScopeTeam> unassignedTeams;

  static const empty = PlanScopeOptions();

  List<ScopeTeam> get teams => [for (final p in portfolios) ...p.teams, ...unassignedTeams];

  /// Every scope in menu order: workspace, portfolios, then teams.
  List<PlanScope> get all => [const PlanScope.workspace(), for (final p in portfolios) p.scope, for (final t in teams) t.scope];

  /// True when there is anything to choose between beyond the workspace.
  bool get hasChoices => portfolios.isNotEmpty || teams.length > 1;

  PlanScope? byKey(String key) => all.where((s) => s.key == key).firstOrNull;

  static Future<PlanScopeOptions> load() async {
    final r = await Api.post('portfolios.php', 'list');
    ScopeTeam team(Map<String, dynamic> m, {int? portfolioId, String? portfolioName}) => ScopeTeam(
          id: asIntOr(m['id'], 0),
          name: asStrOr(m['name'], ''),
          portfolioId: portfolioId ?? asInt(m['portfolio_id']),
          portfolioName: portfolioName ?? asStr(m['portfolio_name']),
          leadPersonId: asInt(m['lead_person_id']),
        );
    final portfolios = <ScopePortfolio>[];
    for (final raw in (r['portfolios'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final id = asIntOr(m['id'], 0);
      final name = asStrOr(m['name'], '');
      portfolios.add(ScopePortfolio(
        id: id,
        name: name,
        description: asStr(m['description']),
        leadName: asStr(m['lead_name']),
        teams: [
          for (final t in (m['teams'] as List? ?? const []))
            if (t is Map) team(Map<String, dynamic>.from(t), portfolioId: id, portfolioName: name),
        ],
      ));
    }
    final unassigned = [
      for (final t in (r['unassigned_teams'] as List? ?? const []))
        if (t is Map) team(Map<String, dynamic>.from(t)),
    ];
    return PlanScopeOptions(portfolios: portfolios, unassignedTeams: unassigned);
  }
}

/// Scope selector: *Whole workspace* / each portfolio / each team. A popup menu
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
    PopupMenuItem<String> entry(PlanScope s, {String? note, bool indent = false}) => PopupMenuItem<String>(
          value: s.key,
          child: Row(children: [
            if (indent) const SizedBox(width: Sp.md),
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
      message: 'Choose the workspace, a portfolio or a team',
      child: PopupMenuButton<String>(
        tooltip: '',
        onSelected: (k) {
          final s = options.byKey(k);
          if (s != null) onChanged(s);
        },
        itemBuilder: (context) => [
          entry(const PlanScope.workspace()),
          if (options.portfolios.isNotEmpty) ...[
            const PopupMenuDivider(),
            header('Portfolios'),
            for (final p in options.portfolios)
              entry(p.scope, note: '${p.teams.length} ${p.teams.length == 1 ? 'team' : 'teams'}${p.leadName == null ? '' : ' · ${p.leadName}'}'),
          ],
          if (options.teams.isNotEmpty) ...[
            const PopupMenuDivider(),
            header('Teams'),
            for (final t in options.teams) entry(t.scope, note: t.portfolioName, indent: true),
          ],
        ],
        child: pill,
      ),
    );
  }
}

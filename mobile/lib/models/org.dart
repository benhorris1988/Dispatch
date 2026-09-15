import 'package:flutter/material.dart' show Color;

import '../theme/tokens.dart';
import 'json.dart';
import 'person.dart';

/// The organisation chart (ORG-01..05), as `org.php tree` returns it.
///
/// Teams nest under teams; people sit in exactly one team and report to one
/// person. A team the viewer may not see comes back as a stub — its name and
/// its place in the tree and nothing else — so the chart shows a closed door
/// rather than a hole.

/// The lead of a team, as the tree carries them.
class OrgLead {
  const OrgLead({required this.id, required this.name, this.initials, this.colourHex, this.roleTitle});
  final int id;
  final String name;
  final String? initials;
  final String? colourHex;
  final String? roleTitle;

  Color get colour => DispatchColors.parseHex(colourHex, fallback: DispatchColors.forSeed(id));
  String get initialsOrDerived => _initialsFor(initials, name);

  static OrgLead? maybe(dynamic v) {
    final m = asMap(v);
    if (m.isEmpty || m['id'] == null) return null;
    return OrgLead(
      id: asIntOr(m['id'], 0),
      name: asStrOr(m['name'], ''),
      initials: asStr(m['initials']),
      colourHex: asStr(m['colour']),
      roleTitle: asStr(m['role_title']),
    );
  }
}

/// Somebody on the chart.
class OrgPerson {
  const OrgPerson({
    required this.id,
    required this.name,
    this.initials,
    this.colourHex,
    this.roleTitle,
    this.teamId,
    this.managerPersonId,
    this.managerName,
    this.roleFamilyId,
    this.roleFamilyName,
    this.loadPct = 0,
    this.isLead = false,
    this.active = true,
    this.onLoanTo,
  });

  final int id;
  final String name;
  final String? initials;
  final String? colourHex;
  final String? roleTitle;
  final int? teamId;
  final int? managerPersonId;
  final String? managerName;
  final int? roleFamilyId;
  final String? roleFamilyName;
  final int loadPct;
  final bool isLead;
  final bool active;

  /// Where this person's time has gone today, if a loan is running.
  final OrgLoanChip? onLoanTo;

  Color get colour => DispatchColors.parseHex(colourHex, fallback: DispatchColors.forSeed(id));
  String get initialsOrDerived => _initialsFor(initials, name);
  String get firstName => name.trim().split(RegExp(r'\s+')).first;

  factory OrgPerson.fromJson(Map<String, dynamic> j) => OrgPerson(
        id: asIntOr(j['id'], 0),
        name: asStrOr(j['name'], ''),
        initials: asStr(j['initials']),
        colourHex: asStr(j['colour']),
        roleTitle: asStr(j['role_title']),
        teamId: asInt(j['team_id']),
        managerPersonId: asInt(j['manager_person_id']),
        managerName: asStr(j['manager_name']),
        roleFamilyId: asInt(j['role_family_id']),
        roleFamilyName: asStr(j['role_family_name']),
        loadPct: asIntOr(j['load_pct'], 0),
        isLead: asBool(j['is_lead']),
        active: asBool(j['active'], fallback: true),
        onLoanTo: OrgLoanChip.maybe(j['on_loan_to']),
      );
}

/// The short form of a running loan the chart shows on a person row.
class OrgLoanChip {
  const OrgLoanChip({required this.toTeamId, required this.toTeamName, this.toDate, this.allocationPct = 100});
  final int toTeamId;
  final String toTeamName;
  final String? toDate;
  final int allocationPct;

  static OrgLoanChip? maybe(dynamic v) {
    final m = asMap(v);
    if (m.isEmpty || m['to_team_id'] == null) return null;
    return OrgLoanChip(
      toTeamId: asIntOr(m['to_team_id'], 0),
      toTeamName: asStrOr(m['to_team_name'], ''),
      toDate: asStr(m['to_date']),
      allocationPct: asIntOr(m['allocation_pct'], 100),
    );
  }
}

/// A team and everything beneath it.
class OrgTeam {
  const OrgTeam({
    required this.id,
    required this.name,
    this.parentTeamId,
    this.sortOrder = 0,
    this.description,
    this.visibility = 'everyone',
    this.visibilityReason,
    this.restricted = false,
    this.leadPersonId,
    this.lead,
    this.headcount = 0,
    this.headcountAll = 0,
    this.loadPct = 0,
    this.availableHours = 0,
    this.assignedHours = 0,
    this.canEdit = false,
    this.people = const [],
    this.children = const [],
  });

  final int id;
  final String name;
  final int? parentTeamId;
  final int sortOrder;
  final String? description;

  /// 'everyone' or 'restricted' (ORG-04).
  final String visibility;
  final String? visibilityReason;

  /// True when this viewer gets the stub: the team exists and sits here, and
  /// that is all they are told.
  final bool restricted;

  final int? leadPersonId;
  final OrgLead? lead;

  /// People whose home team is this one.
  final int headcount;

  /// …and everyone in the teams beneath it as well.
  final int headcountAll;

  final int loadPct;
  final double availableHours;
  final double assignedHours;
  final bool canEdit;
  final List<OrgPerson> people;
  final List<OrgTeam> children;

  bool get isRestricted => visibility == 'restricted';

  factory OrgTeam.fromJson(Map<String, dynamic> j) => OrgTeam(
        id: asIntOr(j['id'], 0),
        name: asStrOr(j['name'], ''),
        parentTeamId: asInt(j['parent_team_id']),
        sortOrder: asIntOr(j['sort_order'], 0),
        description: asStr(j['description']),
        visibility: asStrOr(j['visibility'], 'everyone'),
        visibilityReason: asStr(j['visibility_reason']),
        restricted: asBool(j['restricted']),
        leadPersonId: asInt(j['lead_person_id']),
        lead: OrgLead.maybe(j['lead']),
        headcount: asIntOr(j['headcount'], 0),
        headcountAll: asIntOr(j['headcount_all'], 0),
        loadPct: asIntOr(j['load_pct'], 0),
        availableHours: asDoubleOr(j['available_hours'], 0),
        assignedHours: asDoubleOr(j['assigned_hours'], 0),
        canEdit: asBool(j['can_edit']),
        people: asList(j['people'], OrgPerson.fromJson),
        children: asList(j['children'], OrgTeam.fromJson),
      );
}

/// A discipline people belong to, across teams (ORG-02).
class RoleFamily {
  const RoleFamily({
    required this.id,
    required this.name,
    this.description,
    this.leadName,
    this.leadPersonId,
    this.headcount = 0,
    this.loadPct = 0,
    this.teamsSpanned = const [],
  });

  final int id;
  final String name;
  final String? description;
  final String? leadName;
  final int? leadPersonId;
  final int headcount;
  final int loadPct;

  /// Which teams the discipline reaches into, and how many of its people sit in
  /// each — the thing a grouping of whole teams could never say.
  final List<RoleFamilyTeam> teamsSpanned;

  Color get colour => DispatchColors.forSeed(id + 17);

  factory RoleFamily.fromJson(Map<String, dynamic> j) => RoleFamily(
        id: asIntOr(j['id'], 0),
        name: asStrOr(j['name'], ''),
        description: asStr(j['description']),
        leadName: asStr(j['lead_name']),
        leadPersonId: asInt(j['lead_person_id']),
        headcount: asIntOr(j['headcount'], 0),
        loadPct: asIntOr(j['load_pct'], 0),
        teamsSpanned: asList(j['teams_spanned'], RoleFamilyTeam.fromJson),
      );
}

class RoleFamilyTeam {
  const RoleFamilyTeam({this.id, required this.name, this.count = 0});
  final int? id;
  final String name;
  final int count;

  factory RoleFamilyTeam.fromJson(Map<String, dynamic> j) =>
      RoleFamilyTeam(id: asInt(j['id']), name: asStrOr(j['name'], ''), count: asIntOr(j['count'], 0));
}

/// The whole chart, with the lookups the screen needs computed once.
class OrgTree {
  OrgTree({
    this.roots = const [],
    this.unassigned = const [],
    this.roleFamilies = const [],
    Set<int>? canEditTeamIds,
    this.canEditAll = false,
  }) : canEditTeamIds = canEditTeamIds ?? const {} {
    void walk(OrgTeam t, int? parent, int depth) {
      _byId[t.id] = t;
      _parentOf[t.id] = parent;
      _depthOf[t.id] = depth;
      _flat.add(t);
      for (final p in t.people) {
        _peopleById[p.id] = p;
      }
      for (final c in t.children) {
        walk(c, t.id, depth + 1);
      }
    }

    for (final r in roots) {
      walk(r, null, 0);
    }
    for (final p in unassigned) {
      _peopleById[p.id] = p;
    }
  }

  final List<OrgTeam> roots;

  /// People with no home team. They are real and they have to go somewhere, so
  /// the chart shows them rather than quietly dropping them.
  final List<OrgPerson> unassigned;

  final List<RoleFamily> roleFamilies;

  /// Which teams this viewer may reorganise (ORG-05). The client hides controls
  /// it is not entitled to rather than letting the server 403 them.
  final Set<int> canEditTeamIds;
  final bool canEditAll;

  final Map<int, OrgTeam> _byId = {};
  final Map<int, int?> _parentOf = {};
  final Map<int, int> _depthOf = {};
  final List<OrgTeam> _flat = [];
  final Map<int, OrgPerson> _peopleById = {};

  /// Every team in pre-order, which is the order an indented list wants.
  List<OrgTeam> get flat => List.unmodifiable(_flat);

  int get teamCount => _flat.length;
  int get peopleCount => _peopleById.length;

  OrgTeam? team(int? id) => id == null ? null : _byId[id];
  OrgPerson? person(int? id) => id == null ? null : _peopleById[id];
  int? parentOf(int id) => _parentOf[id];
  int depthOf(int id) => _depthOf[id] ?? 0;
  OrgTeam? homeTeamOf(int personId) => team(person(personId)?.teamId);

  /// 'Digital & Data › Data Platform › Platform engineering'.
  String pathOf(int id) {
    final names = <String>[];
    int? at = id;
    while (at != null) {
      final t = _byId[at];
      if (t == null) break;
      names.insert(0, t.name);
      at = _parentOf[at];
    }
    return names.join(' › ');
  }

  /// A team and everything beneath it. The drag guard: a team may not be
  /// dropped onto one of its own descendants, or the tree stops being a tree.
  Set<int> descendantsOf(int id) {
    final out = <int>{};
    void walk(OrgTeam t) {
      out.add(t.id);
      for (final c in t.children) {
        walk(c);
      }
    }

    final t = _byId[id];
    if (t != null) walk(t);
    return out;
  }

  bool canEdit(int? teamId) => canEditAll || (teamId != null && canEditTeamIds.contains(teamId));

  /// True when this viewer may reorganise anything at all, so the screen knows
  /// whether to offer its editing controls.
  bool get canEditAnything => canEditAll || canEditTeamIds.isNotEmpty;

  factory OrgTree.fromJson(Map<String, dynamic> r) {
    final raw = r['can_edit_team_ids'];
    return OrgTree(
      roots: asList(r['teams'], OrgTeam.fromJson),
      unassigned: asList(r['unassigned_people'], OrgPerson.fromJson),
      roleFamilies: asList(r['role_families'], RoleFamily.fromJson),
      canEditAll: raw == '*',
      canEditTeamIds: raw is List ? raw.map(asInt).whereType<int>().toSet() : <int>{},
    );
  }
}

/// One team as a picker offers it: the tree flattened, with the depth to indent by.
class OrgTeamOption {
  const OrgTeamOption({required this.id, required this.name, this.parentTeamId, this.parentName, this.depth = 0, this.path = '', this.leadPersonId, this.visibility = 'everyone'});
  final int id;
  final String name;
  final int? parentTeamId;
  final String? parentName;
  final int depth;
  final String path;
  final int? leadPersonId;
  final String visibility;

  factory OrgTeamOption.fromJson(Map<String, dynamic> j) => OrgTeamOption(
        id: asIntOr(j['id'], 0),
        name: asStrOr(j['name'], ''),
        parentTeamId: asInt(j['parent_team_id']),
        parentName: asStr(j['parent_team_name']),
        depth: asIntOr(j['depth'], 0),
        path: asStrOr(j['path'], ''),
        leadPersonId: asInt(j['lead_person_id']),
        visibility: asStrOr(j['visibility'], 'everyone'),
      );

  /// 'Data Platform · in Digital & Data' — for the closed state of a dropdown,
  /// where the indent that carries the same meaning is not available.
  String get subtitle => parentName ?? '';
}

/// The teams a picker should offer, in tree order. `people.php list` already
/// returns them this way; this rebuilds the order from a flat list that has not
/// been sorted, so a caller can use either.
List<OrgTeamOption> orderTeamsByHierarchy(List<OrgTeamOption> teams) {
  final byParent = <int?, List<OrgTeamOption>>{};
  for (final t in teams) {
    byParent.putIfAbsent(t.parentTeamId, () => []).add(t);
  }
  final known = teams.map((t) => t.id).toSet();
  final out = <OrgTeamOption>[];
  final seen = <int>{};
  void walk(int? parent, int depth) {
    final kids = [...?byParent[parent]]..sort((a, b) => a.name.compareTo(b.name));
    for (final t in kids) {
      if (!seen.add(t.id)) continue; // a cycle cannot happen through the API, but never hang on one
      out.add(OrgTeamOption(id: t.id, name: t.name, parentTeamId: t.parentTeamId, parentName: t.parentName, depth: depth, path: t.path, leadPersonId: t.leadPersonId, visibility: t.visibility));
      walk(t.id, depth + 1);
    }
  }

  walk(null, 0);
  // A team whose parent is not in the list (a restricted branch, say) would
  // otherwise vanish: hang it off the top rather than lose it.
  for (final t in teams) {
    if (seen.contains(t.id)) continue;
    if (t.parentTeamId != null && known.contains(t.parentTeamId)) continue;
    seen.add(t.id);
    out.add(OrgTeamOption(id: t.id, name: t.name, parentTeamId: t.parentTeamId, parentName: t.parentName, depth: 0, path: t.path, leadPersonId: t.leadPersonId, visibility: t.visibility));
  }
  return out;
}

String _initialsFor(String? initials, String name) {
  if (initials != null && initials.trim().isNotEmpty) return initials.trim().toUpperCase();
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, parts.first.length.clamp(0, 2)).toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

/// The Person shape the org endpoints return, for screens that already speak Person.
Person personFromOrg(OrgPerson p) => Person(
      id: p.id,
      teamId: p.teamId,
      name: p.name,
      initials: p.initials,
      roleTitle: p.roleTitle,
      managerPersonId: p.managerPersonId,
      managerName: p.managerName,
      roleFamilyId: p.roleFamilyId,
      roleFamilyName: p.roleFamilyName,
      colourHex: p.colourHex,
      active: p.active,
      loadPct: p.loadPct.toDouble(),
    );

import 'package:flutter/material.dart' show Color;

import '../theme/tokens.dart';
import 'json.dart';

/// A team member.
class Person {
  Person({
    required this.id,
    this.teamId,
    this.teamName,
    required this.name,
    this.initials,
    this.email,
    this.roleTitle,
    this.tagline,
    this.daysPerWeek = 5,
    this.workingPattern = const {},
    this.patternLabel,
    this.maxConcurrent,
    this.minFocusDays,
    this.prefers,
    this.avoid,
    this.lineManager,
    this.managerPersonId,
    this.managerName,
    this.roleFamilyId,
    this.roleFamilyName,
    this.colourHex,
    this.active = true,
    this.protectedUntil,
    this.loadPct,
    this.skills = const [],
    this.loans = const [],
    this.onLoanTo,
    this.loanedFrom,
  });

  final int id;
  final int? teamId;
  final String? teamName;
  final String name;
  final String? initials;
  final String? email;
  final String? roleTitle;
  final String? tagline;
  final double daysPerWeek;
  final Map<String, double> workingPattern; // {'Mon': 7.5, ...}
  final String? patternLabel;
  final int? maxConcurrent;
  final int? minFocusDays;
  final String? prefers;
  final String? avoid;
  /// ORG-02 made the reporting line a real person; this is that person's name,
  /// kept under the old field name so nothing that already reads it breaks.
  final String? lineManager;
  final int? managerPersonId;
  final String? managerName;
  /// The discipline this person practises (Data engineering, Analytics), which
  /// spans teams rather than sitting under one.
  final int? roleFamilyId;
  final String? roleFamilyName;
  final String? colourHex;
  final bool active;
  final DateTime? protectedUntil;
  final double? loadPct; // when the endpoint supplies it
  final List<PersonSkill> skills;

  // TEAM-09. `people.php list` and `get` supply these; other endpoints leave
  // them empty.
  /// Every loan touching the window the endpoint reported (today to the horizon
  /// for `list`, 90 days back for `get`).
  final List<Loan> loans;
  /// The loan that moves this person to another team today, or null.
  final Loan? onLoanTo;
  /// In a team- or role-family-scoped list: the loan that brings this person into
  /// the scope from their home team, or null for a home member.
  final Loan? loanedFrom;

  /// True when this person is borrowed into the scope the list was built for.
  bool get isBorrowed => loanedFrom != null;

  Color get colour => colourHex == null ? DispatchColors.forSeed(id) : DispatchColors.parseHex(colourHex, fallback: DispatchColors.forSeed(id));

  String get initialsOrDerived {
    if (initials != null && initials!.trim().isNotEmpty) return initials!.trim().toUpperCase();
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, parts.first.length.clamp(0, 2)).toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  String get firstName => name.trim().split(RegExp(r'\s+')).first;

  factory Person.fromJson(Map<String, dynamic> j) => Person(
        id: asIntOr(j['id'], 0),
        teamId: asInt(j['team_id']),
        teamName: asStr(j['team_name']),
        name: asStrOr(j['name'], ''),
        initials: asStr(j['initials']),
        email: asStr(j['email']),
        roleTitle: asStr(j['role_title']),
        tagline: asStr(j['tagline']),
        daysPerWeek: asDoubleOr(j['days_per_week'], 5),
        workingPattern: _pattern(j['working_pattern']),
        patternLabel: asStr(j['pattern_label']),
        maxConcurrent: asInt(j['max_concurrent']),
        minFocusDays: asInt(j['min_focus_days']),
        prefers: asStr(j['prefers']),
        avoid: asStr(j['avoid']),
        lineManager: asStr(j['manager_name'] ?? j['line_manager']),
        managerPersonId: asInt(j['manager_person_id']),
        managerName: asStr(j['manager_name']),
        roleFamilyId: asInt(j['role_family_id'] ?? (j['role_family'] is Map ? j['role_family']['id'] : null)),
        roleFamilyName: asStr(j['role_family_name'] ?? (j['role_family'] is Map ? j['role_family']['name'] : null)),
        colourHex: asStr(j['colour']),
        active: asBool(j['active'], fallback: true),
        protectedUntil: asDate(j['protected_until']),
        loadPct: asDouble(j['load_pct'] ?? j['load']),
        skills: asList(j['skills'], PersonSkill.fromJson),
        loans: asList(j['loans'], Loan.fromJson),
        onLoanTo: Loan.maybe(j['on_loan_to']),
        loanedFrom: Loan.maybe(j['loaned_from']),
      );

  static Map<String, double> _pattern(dynamic v) {
    if (v is Map) {
      return {for (final e in v.entries) e.key.toString(): asDoubleOr(e.value, 0)};
    }
    return const {};
  }
}

/// A skill in the workspace catalogue.
class Skill {
  Skill({required this.id, required this.name, this.category, this.description, this.sortOrder = 0, this.retired = false});
  final int id;
  final String name;
  final String? category;
  final String? description;
  final int sortOrder;
  final bool retired;

  factory Skill.fromJson(Map<String, dynamic> j) => Skill(
        id: asIntOr(j['id'], 0),
        name: asStrOr(j['name'], ''),
        category: asStr(j['category']),
        description: asStr(j['description']),
        sortOrder: asIntOr(j['sort_order'], 0),
        retired: asBool(j['retired']),
      );
}

/// Proficiency level labels, index = level 0..4.
const List<String> kProficiencyLabels = ['None', 'Aware', 'Practitioner', 'Independent', 'Expert'];

/// One person's level in one skill.
class PersonSkill {
  PersonSkill({
    required this.personId,
    required this.skillId,
    this.skillName,
    this.category,
    this.proficiency = 0,
    this.endorsedBy = const [],
    this.certified = false,
    this.developmentTarget,
    this.pairingEnabled = false,
    this.updatedAt,
  });

  final int personId;
  final int skillId;
  final String? skillName;
  final String? category;
  final int proficiency; // 0..4
  final List<int> endorsedBy;
  final bool certified;
  final int? developmentTarget;
  final bool pairingEnabled;
  final DateTime? updatedAt;

  String get levelLabel => kProficiencyLabels[proficiency.clamp(0, 4)];

  factory PersonSkill.fromJson(Map<String, dynamic> j) => PersonSkill(
        personId: asIntOr(j['person_id'], 0),
        skillId: asIntOr(j['skill_id'], 0),
        skillName: asStr(j['skill_name'] ?? j['name']),
        category: asStr(j['category']),
        proficiency: asIntOr(j['proficiency'], 0).clamp(0, 4),
        endorsedBy: asIntList(j['endorsed_by']),
        certified: asBool(j['certified']),
        developmentTarget: asInt(j['development_target']),
        pairingEnabled: asBool(j['pairing_enabled']),
        updatedAt: asDate(j['updated_at']),
      );
}

/// A dated loan of a person to another team at a share of their time (TEAM-09).
/// The shape `people.php add_loan / loans / list / get` and
/// `portfolios.php overview` return; `plan.php schedule` sends a cut-down
/// version on each person row (`loaned_in` / `on_loan_to`), which parses the
/// same way with the missing fields left null.
class Loan {
  const Loan({
    required this.id,
    required this.personId,
    this.personName,
    this.fromTeamId,
    this.fromTeamName,
    this.toTeamId,
    this.toTeamName,
    required this.fromDate,
    required this.toDate,
    this.allocationPct = 100,
    this.reason,
  });

  final int id;
  final int personId;
  final String? personName;
  final int? fromTeamId;
  final String? fromTeamName;
  final int? toTeamId;
  final String? toTeamName;
  final DateTime fromDate;
  /// Inclusive.
  final DateTime toDate;
  final int allocationPct;
  /// A business reason — never personal data (ADM-05).
  final String? reason;

  double get share => allocationPct / 100;

  /// True while [day] falls inside the loan's dates.
  bool coversDay(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return !d.isBefore(fromDate) && !d.isAfter(toDate);
  }

  bool startsAfter(DateTime day) => fromDate.isAfter(DateTime(day.year, day.month, day.day));
  bool endedBefore(DateTime day) => toDate.isBefore(DateTime(day.year, day.month, day.day));

  static Loan? maybe(dynamic v) {
    if (v is! Map || v.isEmpty) return null;
    final m = Map<String, dynamic>.from(v);
    if (asDate(m['from_date']) == null) return null;
    return Loan.fromJson(m);
  }

  factory Loan.fromJson(Map<String, dynamic> j) {
    final from = asDate(j['from_date']) ?? DateTime.now();
    return Loan(
      id: asIntOr(j['id'], 0),
      personId: asIntOr(j['person_id'], 0),
      personName: asStr(j['person_name']),
      fromTeamId: asInt(j['from_team_id']),
      fromTeamName: asStr(j['from_team_name']),
      toTeamId: asInt(j['to_team_id']),
      toTeamName: asStr(j['to_team_name']),
      fromDate: from,
      toDate: asDate(j['to_date']) ?? from,
      allocationPct: asIntOr(j['allocation_pct'], 100),
      reason: asStr(j['reason']),
    );
  }
}

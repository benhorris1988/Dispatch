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
    this.colourHex,
    this.active = true,
    this.protectedUntil,
    this.loadPct,
    this.skills = const [],
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
  final String? lineManager;
  final String? colourHex;
  final bool active;
  final DateTime? protectedUntil;
  final double? loadPct; // when the endpoint supplies it
  final List<PersonSkill> skills;

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
        lineManager: asStr(j['line_manager']),
        colourHex: asStr(j['colour']),
        active: asBool(j['active'], fallback: true),
        protectedUntil: asDate(j['protected_until']),
        loadPct: asDouble(j['load_pct'] ?? j['load']),
        skills: asList(j['skills'], PersonSkill.fromJson),
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

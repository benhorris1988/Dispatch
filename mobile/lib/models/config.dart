import 'package:flutter/material.dart' show Color;

import '../theme/tokens.dart';
import 'json.dart';

/// A configurable work type (Project, Small change, Incident, Service request…).
class WorkType {
  WorkType({
    required this.id,
    required this.name,
    required this.plural,
    required this.prefix,
    required this.colourHex,
    this.policy = 'planned',
    this.requiresEstimate = true,
    this.requiresBenefit = false,
    this.defaultSizeStamp,
    this.allowedSizes = const [],
    this.sizeUnit = 'days',
    this.description,
    this.requirementsTemplate,
    this.sortOrder = 0,
    this.retired = false,
  });

  final int id;
  final String name;
  final String plural;
  final String prefix;
  final String colourHex;
  final String policy; // planned | interrupt
  final bool requiresEstimate;
  final bool requiresBenefit;
  final String? defaultSizeStamp;
  final List<String> allowedSizes; // empty = all
  final String sizeUnit; // days | hours
  final String? description;
  final String? requirementsTemplate;
  final int sortOrder;
  final bool retired;

  Color get colour => DispatchColors.parseHex(colourHex);
  bool get isInterrupt => policy == 'interrupt';

  factory WorkType.fromJson(Map<String, dynamic> j) => WorkType(
        id: asIntOr(j['id'], 0),
        name: asStrOr(j['name'], ''),
        plural: asStrOr(j['plural'], asStrOr(j['name'], '')),
        prefix: asStrOr(j['prefix'], 'WI'),
        colourHex: asStrOr(j['colour'], '#3B6BD6'),
        policy: asStrOr(j['policy'], 'planned'),
        requiresEstimate: asBool(j['requires_estimate'], fallback: true),
        requiresBenefit: asBool(j['requires_benefit']),
        defaultSizeStamp: asStr(j['default_size_stamp']),
        allowedSizes: asStrList(j['allowed_sizes']),
        sizeUnit: asStrOr(j['size_unit'], 'days'),
        description: asStr(j['description']),
        requirementsTemplate: asStr(j['requirements_template']),
        sortOrder: asIntOr(j['sort_order'], 0),
        retired: asBool(j['retired']),
      );
}

/// A size class (S / M / L / C…) with its planning defaults.
class SizeClass {
  SizeClass({
    required this.id,
    this.workTypeId,
    required this.name,
    required this.stamp,
    this.minDays,
    this.maxDays,
    this.planningDays,
    this.defaultEstimateClass = 3,
    this.granularity = 'day',
    this.countsForWip = true,
    this.isCustom = false,
    this.sortOrder = 0,
  });

  final int id;
  final int? workTypeId; // null = workspace default scope
  final String name;
  final String stamp;
  final double? minDays;
  final double? maxDays;
  final double? planningDays;
  final int defaultEstimateClass;
  final String granularity; // halfDay | day | week
  final bool countsForWip;
  final bool isCustom;
  final int sortOrder;

  factory SizeClass.fromJson(Map<String, dynamic> j) => SizeClass(
        id: asIntOr(j['id'], 0),
        workTypeId: asInt(j['work_type_id']),
        name: asStrOr(j['name'], ''),
        stamp: asStrOr(j['stamp'], '?'),
        minDays: asDouble(j['min_days']),
        maxDays: asDouble(j['max_days']),
        planningDays: asDouble(j['planning_days']),
        defaultEstimateClass: asIntOr(j['default_estimate_class'], 3),
        granularity: asStrOr(j['granularity'], 'day'),
        countsForWip: asBool(j['counts_for_wip'], fallback: true),
        isCustom: asBool(j['is_custom']),
        sortOrder: asIntOr(j['sort_order'], 0),
      );

  /// '3–10 days', '10+ days', 'up to 3 days'
  String get rangeLabel {
    if (minDays == null && maxDays == null) return '';
    String n(double d) => d == d.roundToDouble() ? d.toInt().toString() : d.toStringAsFixed(1);
    if (maxDays == null) return '${n(minDays!)}+ days';
    if (minDays == null || minDays == 0) return 'up to ${n(maxDays!)} days';
    return '${n(minDays!)}–${n(maxDays!)} days';
  }
}

/// Current scheduling policy.
class Policy {
  Policy({
    this.id,
    this.version = 1,
    this.freezeHorizonDays = 10,
    this.planningHorizonWeeks = 4,
    this.modelHorizonWeeks = 26,
    this.changeBudgetDays = 5,
    this.minImprovementPct = 5,
    this.incidentReservePct = 12,
    this.rotaReservePct = 25,
    this.proposeCadence = 'daily 02:00',
    this.commitCadence = 'weekly Mon 09:00',
    this.maxConcurrentItems = 2,
    this.minFocusDays = 2,
    this.planAt = 'mostLikely',
    this.solverBudgetSeconds = 60,
    this.smallFillThresholdDays = 3,
    this.targetLoadMin = 80,
    this.targetLoadMax = 90,
    this.autoApplyOutsideHorizon = false,
    this.requireAckInsideHorizon = true,
    this.reestimateClassThreshold,
    this.objectiveWeights = const {},
    this.priorityWeights = const {},
  });

  final int? id;
  final int version;
  final int freezeHorizonDays;
  final int planningHorizonWeeks;
  final int modelHorizonWeeks;
  final int changeBudgetDays;
  final double minImprovementPct;
  final double incidentReservePct;
  final double rotaReservePct;
  final String proposeCadence;
  final String commitCadence;
  final int maxConcurrentItems;
  final int minFocusDays;
  final String planAt; // mostLikely | p80
  final int solverBudgetSeconds;
  final double smallFillThresholdDays;
  final int targetLoadMin;
  final int targetLoadMax;
  final bool autoApplyOutsideHorizon;
  final bool requireAckInsideHorizon;
  final int? reestimateClassThreshold;
  final Map<String, dynamic> objectiveWeights;
  final Map<String, dynamic> priorityWeights;

  factory Policy.fromJson(Map<String, dynamic> j) => Policy(
        id: asInt(j['id']),
        version: asIntOr(j['version'], 1),
        freezeHorizonDays: asIntOr(j['freeze_horizon_days'], 10),
        planningHorizonWeeks: asIntOr(j['planning_horizon_weeks'], 4),
        modelHorizonWeeks: asIntOr(j['model_horizon_weeks'], 26),
        changeBudgetDays: asIntOr(j['change_budget_days'], 5),
        minImprovementPct: asDoubleOr(j['min_improvement_pct'], 5),
        incidentReservePct: asDoubleOr(j['incident_reserve_pct'], 12),
        rotaReservePct: asDoubleOr(j['rota_reserve_pct'], 25),
        proposeCadence: asStrOr(j['propose_cadence'], 'daily 02:00'),
        commitCadence: asStrOr(j['commit_cadence'], 'weekly Mon 09:00'),
        maxConcurrentItems: asIntOr(j['max_concurrent_items'], 2),
        minFocusDays: asIntOr(j['min_focus_days'], 2),
        planAt: asStrOr(j['plan_at'], 'mostLikely'),
        solverBudgetSeconds: asIntOr(j['solver_budget_seconds'], 60),
        smallFillThresholdDays: asDoubleOr(j['small_fill_threshold_days'], 3),
        targetLoadMin: asIntOr(j['target_load_min'], 80),
        targetLoadMax: asIntOr(j['target_load_max'], 90),
        autoApplyOutsideHorizon: asBool(j['auto_apply_outside_horizon']),
        requireAckInsideHorizon: asBool(j['require_ack_inside_horizon'], fallback: true),
        reestimateClassThreshold: asInt(j['reestimate_class_threshold']),
        objectiveWeights: _jsonMap(j['objective_weights']),
        priorityWeights: _jsonMap(j['priority_weights']),
      );

  static Map<String, dynamic> _jsonMap(dynamic v) {
    if (v is Map) return Map<String, dynamic>.from(v);
    return const {};
  }
}

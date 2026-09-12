import 'json.dart';

/// Work item statuses as stored by the API.
class WorkStatus {
  WorkStatus._();
  static const draft = 'draft';
  static const needsEstimate = 'needs_estimate';
  static const needsBenefit = 'needs_benefit';
  static const ready = 'ready';
  static const scheduled = 'scheduled';
  static const inProgress = 'in_progress';
  static const blocked = 'blocked';
  static const delivered = 'delivered';
  static const cancelled = 'cancelled';
}

/// Derived health flags.
class Health {
  Health._();
  static const onTrack = 'on_track';
  static const atRisk = 'at_risk';
  static const late = 'late';
  static const blocked = 'blocked';
}

/// A required skill on a work item.
class SkillRequirement {
  SkillRequirement({required this.skillId, this.skillName, this.minLevel = 2, this.days});
  final int skillId;
  final String? skillName;
  final int minLevel;
  final double? days;

  factory SkillRequirement.fromJson(Map<String, dynamic> j) => SkillRequirement(
        skillId: asIntOr(j['skill_id'] ?? j['id'], 0),
        skillName: asStr(j['skill_name'] ?? j['name']),
        minLevel: asIntOr(j['min_level'] ?? j['level'], 2),
        days: asDouble(j['days']),
      );
}

/// A piece of work: project, small change, incident, service request…
class WorkItem {
  WorkItem({
    required this.id,
    required this.ref,
    required this.title,
    this.summary,
    this.workTypeId,
    this.typeName,
    this.typeColour,
    this.sizeClassId,
    this.sizeStamp,
    this.customEffortDays,
    this.status = WorkStatus.draft,
    this.health,
    this.priorityScore,
    this.priorityTerms = const {},
    this.priorityOverridePoints,
    this.priorityPinnedScore,
    this.riskWeight,
    this.severity,
    this.requestedBy,
    this.sponsor,
    this.ownerPersonId,
    this.ownerName,
    this.benefitValue,
    this.benefitConfidence,
    this.romLow,
    this.romHigh,
    this.estimateClass,
    this.skills = const [],
    this.tags = const [],
    this.neededBy,
    this.earliestStart,
    this.plannedFrom,
    this.plannedTo,
    this.startedAt,
    this.deliveredAt,
    this.progressPct = 0,
    this.assigneeIds = const [],
    this.assigneeNames = const [],
    this.externalUrl,
    this.externalRef,
    this.protectedUntil,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final String ref; // WI-1042
  final String title;
  final String? summary;
  final int? workTypeId;
  final String? typeName; // joined from work_types when the endpoint provides it
  final String? typeColour;
  final int? sizeClassId;
  final String? sizeStamp; // S / M / L / C
  final double? customEffortDays;
  final String status;
  final String? health;
  final double? priorityScore; // 0..100
  final Map<String, dynamic> priorityTerms;
  final int? priorityOverridePoints;
  final double? priorityPinnedScore;
  final double? riskWeight;
  final String? severity; // P1..P4
  final String? requestedBy;
  final String? sponsor;
  final int? ownerPersonId;
  final String? ownerName;
  final double? benefitValue; // annual, in workspace currency
  final String? benefitConfidence;
  final double? romLow;
  final double? romHigh;
  final int? estimateClass;
  final List<SkillRequirement> skills;
  final List<String> tags;
  final DateTime? neededBy;
  final DateTime? earliestStart;
  final DateTime? plannedFrom;
  final DateTime? plannedTo;
  final DateTime? startedAt;
  final DateTime? deliveredAt;
  final int progressPct;
  final List<int> assigneeIds;
  final List<String> assigneeNames;
  final String? externalUrl;
  final String? externalRef;
  final DateTime? protectedUntil;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isDelivered => status == WorkStatus.delivered;
  bool get isOpen => status != WorkStatus.delivered && status != WorkStatus.cancelled;
  bool get needsEstimate => status == WorkStatus.needsEstimate || (romLow == null && romHigh == null && status == WorkStatus.draft);
  bool get hasRom => romLow != null || romHigh != null;

  /// Status string most useful for a chip: health wins when the item is live.
  String get displayStatus {
    if ((status == WorkStatus.scheduled || status == WorkStatus.inProgress) && health != null && health != Health.onTrack) return health!;
    return status;
  }

  factory WorkItem.fromJson(Map<String, dynamic> j) => WorkItem(
        id: asIntOr(j['id'], 0),
        ref: asStrOr(j['ref'], ''),
        title: asStrOr(j['title'], ''),
        summary: asStr(j['summary']),
        workTypeId: asInt(j['work_type_id']),
        typeName: asStr(j['type_name'] ?? j['work_type'] ?? j['type']),
        typeColour: asStr(j['type_colour'] ?? j['colour']),
        sizeClassId: asInt(j['size_class_id']),
        sizeStamp: asStr(j['size_stamp'] ?? j['stamp']),
        customEffortDays: asDouble(j['custom_effort_days']),
        status: asStrOr(j['status'], WorkStatus.draft),
        health: asStr(j['health']),
        priorityScore: asDouble(j['priority_score']),
        priorityTerms: _mapOrEmpty(j['priority_terms']),
        priorityOverridePoints: asInt(j['priority_override_points']),
        priorityPinnedScore: asDouble(j['priority_pinned_score']),
        riskWeight: asDouble(j['risk_weight']),
        severity: asStr(j['severity']),
        requestedBy: asStr(j['requested_by']),
        sponsor: asStr(j['sponsor']),
        ownerPersonId: asInt(j['owner_person_id']),
        ownerName: asStr(j['owner_name']),
        benefitValue: asDouble(j['benefit_value'] ?? j['annual_value']),
        benefitConfidence: asStr(j['benefit_confidence'] ?? j['confidence']),
        romLow: asDouble(j['rom_low']),
        romHigh: asDouble(j['rom_high']),
        estimateClass: asInt(j['estimate_class']),
        skills: asList(j['skills'], SkillRequirement.fromJson),
        tags: asStrList(j['tags']),
        neededBy: asDate(j['needed_by']),
        earliestStart: asDate(j['earliest_start']),
        plannedFrom: asDate(j['planned_from']),
        plannedTo: asDate(j['planned_to']),
        startedAt: asDate(j['started_at']),
        deliveredAt: asDate(j['delivered_at']),
        progressPct: asIntOr(j['progress_pct'], 0),
        assigneeIds: asIntList(j['assignee_ids'] ?? j['assignees']),
        assigneeNames: asStrList(j['assignee_names']),
        externalUrl: asStr(j['external_url']),
        externalRef: asStr(j['external_ref']),
        protectedUntil: asDate(j['protected_until']),
        createdAt: asDate(j['created_at']),
        updatedAt: asDate(j['updated_at']),
      );

  static Map<String, dynamic> _mapOrEmpty(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : const {};
}

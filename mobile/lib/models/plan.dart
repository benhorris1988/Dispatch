import 'json.dart';

/// A person × work item × date-range allocation within a plan version.
class Assignment {
  Assignment({
    required this.id,
    required this.planVersionId,
    required this.workItemId,
    required this.personId,
    required this.fromDate,
    required this.toDate,
    this.allocationPct = 100,
    this.state = 'planned',
    this.roleLabel,
    this.lockedUntil,
    this.fixedPerson = false,
    this.fixedDates = false,
    this.isReserve = false,
    this.note,
    this.ref,
    this.title,
    this.sizeStamp,
    this.typeName,
    this.typeColour,
    this.personName,
  });

  final int id;
  final int planVersionId;
  final int workItemId;
  final int personId;
  final DateTime fromDate;
  final DateTime toDate;
  final int allocationPct;
  final String state; // committed | planned | indicative
  final String? roleLabel;
  final DateTime? lockedUntil;
  final bool fixedPerson;
  final bool fixedDates;
  final bool isReserve;
  final String? note;
  // Denormalised extras when the endpoint joins them:
  final String? ref;
  final String? title;
  final String? sizeStamp;
  final String? typeName;
  final String? typeColour;
  final String? personName;

  bool get isCommitted => state == 'committed';
  bool get isIndicative => state == 'indicative';
  int get days => toDate.difference(fromDate).inDays + 1;

  factory Assignment.fromJson(Map<String, dynamic> j) {
    final from = asDate(j['from_date'] ?? j['from']) ?? DateTime.now();
    return Assignment(
      id: asIntOr(j['id'], 0),
      planVersionId: asIntOr(j['plan_version_id'], 0),
      workItemId: asIntOr(j['work_item_id'], 0),
      personId: asIntOr(j['person_id'], 0),
      fromDate: from,
      toDate: asDate(j['to_date'] ?? j['to']) ?? from,
      allocationPct: asIntOr(j['allocation_pct'], 100),
      state: asStrOr(j['state'], 'planned'),
      roleLabel: asStr(j['role_label']),
      lockedUntil: asDate(j['locked_until']),
      fixedPerson: asBool(j['fixed_person']),
      fixedDates: asBool(j['fixed_dates']),
      isReserve: asBool(j['is_reserve']),
      note: asStr(j['note']),
      ref: asStr(j['ref']),
      title: asStr(j['title']),
      sizeStamp: asStr(j['size_stamp'] ?? j['stamp']),
      typeName: asStr(j['type_name']),
      typeColour: asStr(j['type_colour']),
      personName: asStr(j['person_name']),
    );
  }
}

/// A generated or committed plan.
class PlanVersion {
  PlanVersion({
    required this.id,
    required this.versionNo,
    this.status = 'proposed',
    this.engine = 'heuristic',
    this.generatedAt,
    this.generatedBy,
    this.committedAt,
    this.committedBy,
    this.committedThrough,
    this.policyVersion,
    this.objectiveScore,
    this.objectiveTerms = const {},
    this.stabilityCostDays,
    this.solverStats = const {},
    this.scenarioName,
    this.notes,
  });

  final int id;
  final int versionNo;
  final String status; // proposed | committed | superseded | discarded | scenario
  final String engine; // heuristic | cpsat | manual | import
  final DateTime? generatedAt;
  final int? generatedBy;
  final DateTime? committedAt;
  final int? committedBy;
  final DateTime? committedThrough;
  final int? policyVersion;
  final double? objectiveScore;
  final Map<String, dynamic> objectiveTerms;
  final double? stabilityCostDays;
  final Map<String, dynamic> solverStats;
  final String? scenarioName;
  final String? notes;

  bool get isCommitted => status == 'committed';

  factory PlanVersion.fromJson(Map<String, dynamic> j) => PlanVersion(
        id: asIntOr(j['id'], 0),
        versionNo: asIntOr(j['version_no'], 0),
        status: asStrOr(j['status'], 'proposed'),
        engine: asStrOr(j['engine'], 'heuristic'),
        generatedAt: asDate(j['generated_at']),
        generatedBy: asInt(j['generated_by']),
        committedAt: asDate(j['committed_at']),
        committedBy: asInt(j['committed_by']),
        committedThrough: asDate(j['committed_through']),
        policyVersion: asInt(j['policy_version']),
        objectiveScore: asDouble(j['objective_score']),
        objectiveTerms: _map(j['objective_terms']),
        stabilityCostDays: asDouble(j['stability_cost_days']),
        solverStats: _map(j['solver_stats']),
        scenarioName: asStr(j['scenario_name']),
        notes: asStr(j['notes']),
      );

  static Map<String, dynamic> _map(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : const {};
}

/// A replan cycle (nightly / urgent / manual) grouping change proposals.
class Proposal {
  Proposal({
    required this.id,
    this.candidatePlanVersionId,
    this.basePlanVersionId,
    this.kind = 'nightly',
    this.status = 'open',
    this.generatedAt,
    this.improvementPct,
    this.belowThreshold = false,
    this.summaryBefore = const {},
    this.summaryAfter = const {},
    this.triggers = const [],
    this.carriedOverNote,
    this.engine = 'heuristic',
    this.decidedAt,
    this.changes = const [],
    this.pendingCount,
  });

  final int id;
  final int? candidatePlanVersionId;
  final int? basePlanVersionId;
  final String kind; // nightly | urgent | manual | preview
  final String status; // open | decided | expired | superseded
  final DateTime? generatedAt;
  final double? improvementPct;
  final bool belowThreshold;
  final Map<String, dynamic> summaryBefore;
  final Map<String, dynamic> summaryAfter;
  final List<Map<String, dynamic>> triggers; // [{type,label,occurredAt}]
  final String? carriedOverNote;
  final String engine;
  final DateTime? decidedAt;
  final List<ChangeProposal> changes;
  final int? pendingCount;

  bool get isOpen => status == 'open';

  factory Proposal.fromJson(Map<String, dynamic> j) => Proposal(
        id: asIntOr(j['id'], 0),
        candidatePlanVersionId: asInt(j['candidate_plan_version_id']),
        basePlanVersionId: asInt(j['base_plan_version_id']),
        kind: asStrOr(j['kind'], 'nightly'),
        status: asStrOr(j['status'], 'open'),
        generatedAt: asDate(j['generated_at']),
        improvementPct: asDouble(j['improvement_pct']),
        belowThreshold: asBool(j['below_threshold']),
        summaryBefore: _map(j['summary_before']),
        summaryAfter: _map(j['summary_after']),
        triggers: _mapList(j['triggers']),
        carriedOverNote: asStr(j['carried_over_note']),
        engine: asStrOr(j['engine'], 'heuristic'),
        decidedAt: asDate(j['decided_at']),
        changes: asList(j['changes'], ChangeProposal.fromJson),
        pendingCount: asInt(j['pending_count']),
      );

  static Map<String, dynamic> _map(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : const {};
  static List<Map<String, dynamic>> _mapList(dynamic v) =>
      v is List ? v.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList() : const [];
}

/// A chip on a change card: {label, tone: ok|warn|info|bad}.
class ImpactChip {
  ImpactChip({required this.label, this.tone = 'info'});
  final String label;
  final String tone;
  factory ImpactChip.fromJson(Map<String, dynamic> j) => ImpactChip(label: asStrOr(j['label'], ''), tone: asStrOr(j['tone'], 'info'));
}

/// One proposed change to the plan, reviewable on its own.
class ChangeProposal {
  ChangeProposal({
    required this.id,
    required this.proposalId,
    this.personId,
    this.personName,
    this.personInitials,
    this.personColour,
    this.workItemId,
    this.workItemRef,
    this.workItemTitle,
    this.kind = 'move',
    required this.headline,
    this.before = const {},
    this.after = const {},
    this.reason,
    this.objectiveDelta = const {},
    this.stabilityCostDays = 0,
    this.insideFreeze = false,
    this.impactChips = const [],
    this.affectedPersonIds = const [],
    this.guardrailStatus = 'ok',
    this.guardrailReason,
    this.decision = 'pending',
    this.decidedBy,
    this.decidedAt,
    this.decisionReason,
    this.acknowledgedAt,
    this.sortOrder = 0,
  });

  final int id;
  final int proposalId;
  final int? personId;
  final String? personName;
  final String? personInitials;
  final String? personColour;
  final int? workItemId;
  final String? workItemRef;
  final String? workItemTitle;
  final String kind; // move | extend | reassign | add | remove | split | pair
  final String headline;
  final Map<String, dynamic> before; // {label, personId, from, to, allocationPct}
  final Map<String, dynamic> after;
  final String? reason;
  final Map<String, dynamic> objectiveDelta;
  final double stabilityCostDays;
  final bool insideFreeze;
  final List<ImpactChip> impactChips;
  final List<int> affectedPersonIds;
  final String guardrailStatus; // ok | needs_approval | held_budget | held_threshold
  final String? guardrailReason;
  final String decision; // pending | accepted | rejected | edited
  final int? decidedBy;
  final DateTime? decidedAt;
  final String? decisionReason;
  final DateTime? acknowledgedAt;
  final int sortOrder;

  bool get isPending => decision == 'pending';
  bool get needsApproval => guardrailStatus == 'needs_approval';
  String? get beforeLabel => asStr(before['label']);
  String? get afterLabel => asStr(after['label']);

  factory ChangeProposal.fromJson(Map<String, dynamic> j) => ChangeProposal(
        id: asIntOr(j['id'], 0),
        proposalId: asIntOr(j['proposal_id'], 0),
        personId: asInt(j['person_id']),
        personName: asStr(j['person_name']),
        personInitials: asStr(j['person_initials'] ?? j['initials']),
        personColour: asStr(j['person_colour']),
        workItemId: asInt(j['work_item_id']),
        workItemRef: asStr(j['ref'] ?? j['work_item_ref']),
        workItemTitle: asStr(j['title'] ?? j['work_item_title']),
        kind: asStrOr(j['kind'], 'move'),
        headline: asStrOr(j['headline'], ''),
        before: _map(j['before'] ?? j['before_json']),
        after: _map(j['after'] ?? j['after_json']),
        reason: asStr(j['reason']),
        objectiveDelta: _map(j['objective_delta']),
        stabilityCostDays: asDoubleOr(j['stability_cost_days'], 0),
        insideFreeze: asBool(j['inside_freeze']),
        impactChips: asList(j['impact_chips'], ImpactChip.fromJson),
        affectedPersonIds: asIntList(j['affected_person_ids']),
        guardrailStatus: asStrOr(j['guardrail_status'], 'ok'),
        guardrailReason: asStr(j['guardrail_reason']),
        decision: asStrOr(j['decision'], 'pending'),
        decidedBy: asInt(j['decided_by']),
        decidedAt: asDate(j['decided_at']),
        decisionReason: asStr(j['decision_reason']),
        acknowledgedAt: asDate(j['acknowledged_at']),
        sortOrder: asIntOr(j['sort_order'], 0),
      );

  static Map<String, dynamic> _map(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : const {};
}

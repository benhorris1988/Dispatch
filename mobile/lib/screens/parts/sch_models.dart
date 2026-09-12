/// Parsing for the schedule and changes payloads (`plan.php schedule`,
/// `changes.php current`). These shapes are nested in ways the shared models
/// do not cover (`person:{...}`, `work_item:{...}`, `windows`, `overlay`), so
/// the Schedule and Changes screens read them here rather than editing the
/// shared model files.
library;

import '../../models/models.dart';
import '../../services/format.dart';

// ---------------------------------------------------------------------------
// Schedule (plan.php schedule)
// ---------------------------------------------------------------------------

/// One week column: `{week_start, label, state, is_current}`.
class SchWeek {
  SchWeek({required this.start, required this.label, required this.state, this.isCurrent = false});
  final DateTime start;
  final String label; // 'w/c 7 Sep'
  final String state; // committed | planned | indicative
  final bool isCurrent;

  factory SchWeek.fromJson(Map<String, dynamic> j) => SchWeek(
        start: asDate(j['week_start']) ?? DateTime.now(),
        label: asStrOr(j['label'], ''),
        state: asStrOr(j['state'], 'planned'),
        isCurrent: asBool(j['is_current']),
      );
}

/// A lane header person, with the load percentage for the visible horizon.
class SchPerson {
  SchPerson({
    required this.id,
    required this.name,
    this.initials,
    this.colourHex,
    this.roleTitle,
    this.teamId,
    this.teamName,
    this.daysPerWeek = 5,
    this.loadPct = 0,
    this.assignedHours = 0,
    this.availableHours = 0,
  });

  final int id;
  final String name;
  final String? initials;
  final String? colourHex;
  final String? roleTitle;
  final int? teamId;
  final String? teamName;
  final double daysPerWeek;
  final double loadPct;
  final double assignedHours;
  final double availableHours;

  String get initialsOrDerived {
    final i = initials;
    if (i != null && i.trim().isNotEmpty) return i.trim();
    return initialsOf(name);
  }

  factory SchPerson.fromJson(Map<String, dynamic> j) => SchPerson(
        id: asIntOr(j['id'], 0),
        name: asStrOr(j['name'], 'Unknown'),
        initials: asStr(j['initials']),
        colourHex: asStr(j['colour']),
        roleTitle: asStr(j['role_title']),
        teamId: asInt(j['team_id']),
        teamName: asStr(j['team_name']),
        daysPerWeek: asDoubleOr(j['days_per_week'], 5),
        loadPct: asDoubleOr(j['load_pct'], 0),
        assignedHours: asDoubleOr(j['assigned_hours'], 0),
        availableHours: asDoubleOr(j['available_hours'], 0),
      );
}

/// One assignment block in a lane.
class SchBlock {
  SchBlock({
    required this.id,
    required this.workItemId,
    required this.personId,
    required this.from,
    required this.to,
    this.ref,
    this.title,
    this.typeColour,
    this.typeName,
    this.sizeStamp,
    this.allocationPct = 100,
    this.state = 'planned',
    this.roleLabel,
    this.locked = false,
    this.fixedPerson = false,
    this.fixedDates = false,
    this.isReserve = false,
    this.note,
    this.progressPct,
    this.proposed = false,
    this.changed = false,
  });

  final int id;
  final int workItemId;
  final int personId;
  final DateTime from;
  final DateTime to;
  final String? ref;
  final String? title;
  final String? typeColour;
  final String? typeName;
  final String? sizeStamp;
  final int allocationPct;
  final String state; // committed | planned | indicative
  final String? roleLabel;
  final bool locked;
  final bool fixedPerson;
  final bool fixedDates;
  final bool isReserve;
  final String? note;
  final int? progressPct;
  final bool proposed; // from the overlay candidate plan
  final bool changed; // moved relative to the committed plan

  bool get isIndicative => state == 'indicative';
  bool get isCommitted => state == 'committed';
  String get label => '${ref ?? ''} ${title ?? ''}'.trim();

  /// 'phase 2 · L' — role label then size stamp.
  String get subLabel => dotJoin([roleLabel, sizeStamp, if (allocationPct != 100) '$allocationPct%', if (isIndicative) 'indicative']);

  SchBlock copyWith({DateTime? from, DateTime? to, int? personId}) => SchBlock(
        id: id,
        workItemId: workItemId,
        personId: personId ?? this.personId,
        from: from ?? this.from,
        to: to ?? this.to,
        ref: ref,
        title: title,
        typeColour: typeColour,
        typeName: typeName,
        sizeStamp: sizeStamp,
        allocationPct: allocationPct,
        state: state,
        roleLabel: roleLabel,
        locked: locked,
        fixedPerson: fixedPerson,
        fixedDates: fixedDates,
        isReserve: isReserve,
        note: note,
        progressPct: progressPct,
        proposed: proposed,
        changed: changed,
      );

  factory SchBlock.fromJson(Map<String, dynamic> j) {
    final from = asDate(j['from_date'] ?? j['from']) ?? DateTime.now();
    return SchBlock(
      id: asIntOr(j['id'], 0),
      workItemId: asIntOr(j['work_item_id'], 0),
      personId: asIntOr(j['person_id'], 0),
      from: from,
      to: asDate(j['to_date'] ?? j['to']) ?? from,
      ref: asStr(j['ref']),
      title: asStr(j['title']),
      typeColour: asStr(j['type_colour']),
      typeName: asStr(j['type_name']),
      sizeStamp: asStr(j['size_stamp']),
      allocationPct: asIntOr(j['allocation_pct'], 100),
      state: asStrOr(j['state'], 'planned'),
      roleLabel: asStr(j['role_label']),
      locked: asBool(j['locked']),
      fixedPerson: asBool(j['fixed_person']),
      fixedDates: asBool(j['fixed_dates']),
      isReserve: asBool(j['is_reserve']),
      note: asStr(j['note']),
      progressPct: asInt(j['progress_pct']),
      proposed: asBool(j['proposed']),
      changed: asBool(j['changed']),
    );
  }
}

/// Leave, training, a pattern gap or a rota week — drawn hatched.
class SchAway {
  SchAway({required this.personId, required this.from, required this.to, required this.type, required this.label, this.fraction = 1});
  final int personId;
  final DateTime from;
  final DateTime to;
  final String type; // leave | training | pattern | other
  final String label;
  final double fraction;

  factory SchAway.fromJson(Map<String, dynamic> j) {
    final from = asDate(j['from_date']) ?? DateTime.now();
    final type = asStrOr(j['type'], 'leave');
    return SchAway(
      personId: asIntOr(j['person_id'], 0),
      from: from,
      to: asDate(j['to_date']) ?? from,
      type: type,
      label: asStrOr(j['label'], humanise(type)),
      fraction: asDoubleOr(j['fraction'], 1),
    );
  }
}

/// A queue candidate shown in the schedule footer.
class SchCandidate {
  SchCandidate({required this.id, required this.ref, required this.title, this.typeColour, this.sizeStamp, this.priorityScore, this.neededBy});
  final int id;
  final String ref;
  final String title;
  final String? typeColour;
  final String? sizeStamp;
  final double? priorityScore;
  final DateTime? neededBy;

  factory SchCandidate.fromJson(Map<String, dynamic> j) => SchCandidate(
        id: asIntOr(j['id'], 0),
        ref: asStrOr(j['ref'], ''),
        title: asStrOr(j['title'], ''),
        typeColour: asStr(j['type_colour']),
        sizeStamp: asStr(j['size_stamp']),
        priorityScore: asDouble(j['priority_score']),
        neededBy: asDate(j['needed_by']),
      );
}

/// The whole `plan.php schedule` payload.
class ScheduleData {
  ScheduleData({
    required this.weeks,
    required this.people,
    required this.blocks,
    required this.away,
    required this.rota,
    required this.candidates,
    required this.unscheduledCount,
    required this.from,
    required this.to,
    this.today,
    this.freezeEnd,
    this.plannedEnd,
    this.indicativeEnd,
    this.planVersion,
    this.committedThrough,
    this.overlayBlocks = const [],
    this.overlayProposalId,
    this.removedAssignmentIds = const [],
    this.movedAssignmentIds = const [],
  });

  final List<SchWeek> weeks;
  final List<SchPerson> people;
  final List<SchBlock> blocks;
  final List<SchAway> away;
  final List<({int personId, DateTime weekStart})> rota;
  final List<SchCandidate> candidates;
  final int unscheduledCount;
  final DateTime from;
  final DateTime to;
  final DateTime? today;
  final DateTime? freezeEnd;
  final DateTime? plannedEnd;
  final DateTime? indicativeEnd;
  final PlanVersion? planVersion;
  final DateTime? committedThrough;
  final List<SchBlock> overlayBlocks;
  final int? overlayProposalId;
  final List<int> removedAssignmentIds;
  final List<int> movedAssignmentIds;

  bool get hasOverlay => overlayBlocks.isNotEmpty;

  double get daysPerWeekTotal => people.fold(0.0, (t, p) => t + p.daysPerWeek);

  factory ScheduleData.fromJson(Map<String, dynamic> j) {
    final w = asMap(j['windows']);
    final r = asMap(j['range']);
    final overlay = asMap(j['overlay']);
    final pv = asMap(j['plan_version']);
    return ScheduleData(
      weeks: asList(j['weeks'], SchWeek.fromJson),
      people: asList(j['people'], SchPerson.fromJson),
      blocks: asList(j['assignments'], SchBlock.fromJson),
      away: asList(j['availability'], SchAway.fromJson),
      rota: (j['rota'] is List ? j['rota'] as List : const [])
          .whereType<Map>()
          .map((m) => (personId: asIntOr(m['person_id'], 0), weekStart: asDate(m['week_start']) ?? DateTime.now()))
          .toList(),
      candidates: asList(j['unscheduled'], SchCandidate.fromJson),
      unscheduledCount: asIntOr(j['unscheduled_count'], 0),
      from: asDate(r['from']) ?? DateTime.now(),
      to: asDate(r['to']) ?? DateTime.now(),
      today: asDate(w['today']),
      freezeEnd: asDate(w['freeze_end']),
      plannedEnd: asDate(w['planned_end']),
      indicativeEnd: asDate(w['indicative_end']),
      planVersion: pv.isEmpty ? null : PlanVersion.fromJson(pv),
      committedThrough: asDate(pv['committed_through']),
      overlayBlocks: asList(overlay['assignments'], SchBlock.fromJson),
      overlayProposalId: asInt(overlay['proposal_id']),
      removedAssignmentIds: asIntList(overlay['removed_assignment_ids']),
      movedAssignmentIds: asIntList(j['moved_assignment_ids']),
    );
  }
}

/// The result of `plan.php move_assignment` with `preview:true`.
class MovePreview {
  MovePreview({
    required this.headline,
    required this.knockOn,
    required this.stabilityCostDays,
    required this.insideFreeze,
    required this.warnings,
    this.summaryAfter = const {},
  });

  final String headline;
  final List<KnockOn> knockOn;
  final double stabilityCostDays;
  final bool insideFreeze;
  final List<String> warnings;
  final Map<String, dynamic> summaryAfter;

  factory MovePreview.fromJson(Map<String, dynamic> j) => MovePreview(
        headline: asStrOr(j['headline'], 'Move this assignment'),
        knockOn: asList(j['knock_on'], KnockOn.fromJson),
        stabilityCostDays: asDoubleOr(j['stability_cost_days'], 0),
        insideFreeze: asBool(j['inside_freeze']),
        warnings: asStrList(j['warnings']),
        summaryAfter: asMap(j['summary_after']),
      );
}

/// One downstream effect of a previewed move.
class KnockOn {
  KnockOn({required this.ref, required this.title, this.person, this.effect, this.from, this.to, this.stabilityCostDays = 0});
  final String ref;
  final String title;
  final String? person;
  final String? effect;
  final DateTime? from;
  final DateTime? to;
  final double stabilityCostDays;

  factory KnockOn.fromJson(Map<String, dynamic> j) => KnockOn(
        ref: asStrOr(j['ref'], ''),
        title: asStrOr(j['title'], ''),
        person: asStr(j['person']),
        effect: asStr(j['effect']),
        from: asDate(j['from']),
        to: asDate(j['to']),
        stabilityCostDays: asDoubleOr(j['stability_cost_days'], 0),
      );
}

// ---------------------------------------------------------------------------
// Changes (changes.php current / get / mine)
// ---------------------------------------------------------------------------

/// A person as the change payload carries them: `{id, name, initials, colour}`.
class SchPersonLite {
  SchPersonLite({required this.id, required this.name, this.initials, this.colourHex});
  final int id;
  final String name;
  final String? initials;
  final String? colourHex;

  String get initialsOrDerived => (initials != null && initials!.trim().isNotEmpty) ? initials!.trim() : initialsOf(name);

  static SchPersonLite? maybe(dynamic v) {
    final m = asMap(v);
    if (m.isEmpty) return null;
    return SchPersonLite(
      id: asIntOr(m['id'], 0),
      name: asStrOr(m['name'], 'Unknown'),
      initials: asStr(m['initials']),
      colourHex: asStr(m['colour']),
    );
  }
}

/// One reviewable change (`change_proposals` row, explained).
class SchChange {
  SchChange({
    required this.id,
    required this.proposalId,
    this.person,
    this.workItemId,
    this.workItemRef,
    this.workItemTitle,
    this.typeColour,
    this.kind = 'move',
    required this.headline,
    this.before = const {},
    this.after = const {},
    this.reason,
    this.stabilityCostDays = 0,
    this.insideFreeze = false,
    this.chips = const [],
    this.affectedPeople = const [],
    this.guardrailStatus = 'ok',
    this.guardrailReason,
    this.decision = 'pending',
    this.decidedByName,
    this.decidedAt,
    this.decisionReason,
    this.acknowledgedAt,
    this.objectiveDelta = const {},
    this.proposalStatus,
    this.proposalKind,
    this.generatedAt,
  });

  final int id;
  final int proposalId;
  final SchPersonLite? person;
  final int? workItemId;
  final String? workItemRef;
  final String? workItemTitle;
  final String? typeColour;
  final String kind;
  final String headline;
  final Map<String, dynamic> before;
  final Map<String, dynamic> after;
  final String? reason;
  final double stabilityCostDays;
  final bool insideFreeze;
  final List<ImpactChip> chips;
  final List<SchPersonLite> affectedPeople;
  final String guardrailStatus; // ok | needs_approval | held_budget | held_threshold
  final String? guardrailReason;
  final String decision; // pending | accepted | rejected | edited
  final String? decidedByName;
  final DateTime? decidedAt;
  final String? decisionReason;
  final DateTime? acknowledgedAt;
  final Map<String, dynamic> objectiveDelta;
  final String? proposalStatus;
  final String? proposalKind;
  final DateTime? generatedAt;

  bool get isPending => decision == 'pending';
  bool get isHeld => guardrailStatus == 'held_budget' || guardrailStatus == 'held_threshold';
  bool get needsApproval => guardrailStatus == 'needs_approval';

  /// True when this change can be ticked for "Accept N selected".
  bool get selectable => isPending && !isHeld;

  String get beforeLabel => asStrOr(before['label'], _range(before));
  String get afterLabel => asStrOr(after['label'], _range(after));

  String _range(Map<String, dynamic> m) {
    if (m.isEmpty) return '—';
    final f = asDate(m['from']);
    final t = asDate(m['to']);
    return dotJoin([workItemRef, fmtDateRange(f, t)]);
  }

  String get guardrailLabel => switch (guardrailStatus) {
        'held_budget' => 'Blocked by guardrail',
        'held_threshold' => 'Not applied automatically',
        'needs_approval' => 'Needs your approval',
        _ => '',
      };

  factory SchChange.fromJson(Map<String, dynamic> j) {
    final item = asMap(j['work_item']);
    return SchChange(
      id: asIntOr(j['id'], 0),
      proposalId: asIntOr(j['proposal_id'], 0),
      person: SchPersonLite.maybe(j['person']),
      workItemId: asInt(item['id'] ?? j['work_item_id']),
      workItemRef: asStr(item['ref'] ?? j['ref']),
      workItemTitle: asStr(item['title'] ?? j['title']),
      typeColour: asStr(item['type_colour']),
      kind: asStrOr(j['kind'], 'move'),
      headline: asStrOr(j['headline'], ''),
      before: asMap(j['before']),
      after: asMap(j['after']),
      reason: asStr(j['reason']),
      stabilityCostDays: asDoubleOr(j['stability_cost_days'], 0),
      insideFreeze: asBool(j['inside_freeze']),
      chips: asList(j['impact_chips'], ImpactChip.fromJson),
      affectedPeople: (j['affected_people'] is List ? j['affected_people'] as List : const [])
          .map(SchPersonLite.maybe)
          .whereType<SchPersonLite>()
          .toList(),
      guardrailStatus: asStrOr(j['guardrail_status'], 'ok'),
      guardrailReason: asStr(j['guardrail_reason']),
      decision: asStrOr(j['decision'], 'pending'),
      decidedByName: asStr(j['decided_by_name']),
      decidedAt: asDate(j['decided_at']),
      decisionReason: asStr(j['decision_reason']),
      acknowledgedAt: asDate(j['acknowledged_at']),
      objectiveDelta: asMap(j['objective_delta']),
      proposalStatus: asStr(j['proposal_status']),
      proposalKind: asStr(j['proposal_kind']),
      generatedAt: asDate(j['generated_at']),
    );
  }
}

/// Header facts about a replan cycle.
class SchProposal {
  SchProposal({
    required this.id,
    this.kind = 'nightly',
    this.status = 'open',
    this.generatedAt,
    this.generatedByName,
    this.decidedAt,
    this.triggers = const [],
    this.summaryBefore = const {},
    this.summaryAfter = const {},
    this.improvementPct,
    this.belowThreshold = false,
    this.carriedOverNote,
    this.budgetUsed = 0,
    this.budgetLimit = 0,
    this.counts = const {},
  });

  final int id;
  final String kind;
  final String status;
  final DateTime? generatedAt;
  final String? generatedByName;
  final DateTime? decidedAt;
  final List<({String type, String label})> triggers;
  final Map<String, dynamic> summaryBefore;
  final Map<String, dynamic> summaryAfter;
  final double? improvementPct;
  final bool belowThreshold;
  final String? carriedOverNote;
  final double budgetUsed;
  final double budgetLimit;
  final Map<String, int> counts;

  bool get isOpen => status == 'open';
  int count(String key) => counts[key] ?? 0;

  String get kindLabel => switch (kind) {
        'nightly' => 'Nightly replan',
        'urgent' => 'Urgent replan',
        'manual' => 'Manual replan',
        _ => humanise(kind),
      };

  factory SchProposal.fromJson(Map<String, dynamic> j) {
    final b = asMap(j['budget']);
    final c = asMap(j['counts']);
    return SchProposal(
      id: asIntOr(j['id'], 0),
      kind: asStrOr(j['kind'], 'nightly'),
      status: asStrOr(j['status'], 'open'),
      generatedAt: asDate(j['generated_at']),
      generatedByName: asStr(j['generated_by_name']),
      decidedAt: asDate(j['decided_at']),
      triggers: (j['triggers'] is List ? j['triggers'] as List : const [])
          .whereType<Map>()
          .map((m) => (type: asStrOr(m['type'], 'trigger'), label: asStrOr(m['label'], '')))
          .where((t) => t.label.isNotEmpty)
          .toList(),
      summaryBefore: asMap(j['summary_before']),
      summaryAfter: asMap(j['summary_after']),
      improvementPct: asDouble(j['improvement_pct']),
      belowThreshold: asBool(j['below_threshold']),
      carriedOverNote: asStr(j['carried_over_note']),
      budgetUsed: asDoubleOr(b['used'], 0),
      budgetLimit: asDoubleOr(b['limit'], 0),
      counts: {for (final e in c.entries) e.key: asIntOr(e.value, 0)},
    );
  }
}

/// A guardrail row for the right-hand panel.
class SchGuardrail {
  SchGuardrail({required this.key, required this.label, this.detail, this.enabled = true});
  final String key; // freeze | budget | threshold | reserve
  final String label;
  final String? detail;
  final bool enabled;

  factory SchGuardrail.fromJson(Map<String, dynamic> j) => SchGuardrail(
        key: asStrOr(j['key'], ''),
        label: asStrOr(j['label'], ''),
        detail: asStr(j['detail']),
        enabled: asBool(j['enabled'], fallback: true),
      );
}

/// A comment on a change.
class SchComment {
  SchComment({required this.id, required this.changeId, required this.author, required this.body, this.createdAt});
  final int id;
  final int changeId;
  final String author;
  final String body;
  final DateTime? createdAt;

  factory SchComment.fromJson(Map<String, dynamic> j) => SchComment(
        id: asIntOr(j['id'], 0),
        changeId: asIntOr(j['change_proposal_id'], 0),
        author: asStrOr(j['author_name'], 'Someone'),
        body: asStrOr(j['body'], ''),
        createdAt: asDate(j['created_at']),
      );
}

/// The whole `changes.php current` payload.
class ChangesData {
  ChangesData({
    this.proposal,
    this.changes = const [],
    this.held = const [],
    this.guardrails = const [],
    this.comments = const [],
  });

  final SchProposal? proposal;
  final List<SchChange> changes;
  final List<SchChange> held;
  final List<SchGuardrail> guardrails;
  final List<SchComment> comments;

  bool get hasOpenProposal => proposal != null && proposal!.isOpen && (changes.isNotEmpty || held.isNotEmpty);

  factory ChangesData.fromJson(Map<String, dynamic> j) {
    final p = asMap(j['proposal']);
    return ChangesData(
      proposal: p.isEmpty ? null : SchProposal.fromJson(p),
      changes: asList(j['changes'], SchChange.fromJson),
      held: asList(j['held'], SchChange.fromJson),
      guardrails: asList(j['guardrails'], SchGuardrail.fromJson),
      comments: asList(j['comments'], SchComment.fromJson),
    );
  }
}

/// Rows of the "Before and after" panel (CHG-04). `improvementIsDown` says
/// which direction counts as better, so the panel can colour honestly.
class BeforeAfterRow {
  BeforeAfterRow(this.label, this.before, this.after, {this.improvementIsDown = true, this.footnote});
  final String label;
  final String before;
  final String after;
  final bool improvementIsDown;
  final String? footnote;
}

/// Summary maps arrive in either `snake_case` (engine/summary.php) or
/// `camelCase` (the seeded demo proposals) — read both.
dynamic schSummary(Map<String, dynamic> summary, String snakeKey) {
  if (summary.containsKey(snakeKey)) return summary[snakeKey];
  final parts = snakeKey.split('_');
  final camel = parts.first + parts.skip(1).map((p) => p.isEmpty ? '' : p[0].toUpperCase() + p.substring(1)).join();
  return summary[camel];
}

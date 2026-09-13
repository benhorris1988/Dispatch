/// Parsing for the plan-version and what-if payloads (`plan.php versions`,
/// `plan.php version`, `replan.php preview`, `scenario_save`, `scenarios`).
///
/// These shapes carry fields the shared `PlanVersion` model does not
/// (`committed_by_name`, `assignment_count`, `change_count`, a scenario's
/// stored edits and its before/after summaries), so the Version history and
/// Scenarios screens read them here rather than editing the shared models.
library;

import '../../models/models.dart';
import '../../services/format.dart';
import 'sch_models.dart';

// ---------------------------------------------------------------------------
// Plan versions (CHG-05)
// ---------------------------------------------------------------------------

/// One row of `plan.php versions`.
class SchPlanVersion {
  SchPlanVersion({
    required this.id,
    required this.versionNo,
    this.status = 'proposed',
    this.engine = 'heuristic',
    this.generatedAt,
    this.committedAt,
    this.committedThrough,
    this.committedByName,
    this.policyVersion,
    this.objectiveScore,
    this.objectiveTerms = const {},
    this.stabilityCostDays,
    this.solverStats = const {},
    this.scenarioName,
    this.notes,
    this.inputsHash,
    this.assignmentCount,
    this.changeCount,
  });

  final int id;
  final int versionNo;
  final String status; // proposed | committed | superseded | discarded | scenario
  final String engine; // heuristic | cpsat | manual | import
  final DateTime? generatedAt;
  final DateTime? committedAt;
  final DateTime? committedThrough;
  final String? committedByName;
  final int? policyVersion;
  final double? objectiveScore;
  final Map<String, dynamic> objectiveTerms;
  final double? stabilityCostDays;
  final Map<String, dynamic> solverStats;
  final String? scenarioName;
  final String? notes;
  final String? inputsHash;
  final int? assignmentCount;
  final int? changeCount;

  bool get isCommitted => status == 'committed';
  bool get isSuperseded => status == 'superseded';
  bool get isProposed => status == 'proposed';

  /// Only a superseded version can be restored: the committed one is already
  /// in force and a proposal has to be reviewed on the Changes screen.
  bool get canRestore => isSuperseded;

  String get statusLabel => humanise(status);

  String get statusTone => switch (status) {
        'committed' => 'ok',
        'proposed' => 'accent',
        'superseded' => 'info',
        'discarded' => 'bad',
        _ => 'info',
      };

  /// 'Committed 7 Sep by Ben Stevenson' / 'Generated 8 Sep'.
  String whenLabel() {
    if (committedAt != null) {
      return dotJoin(['Committed ${fmtShortDate(committedAt)}', if (committedByName != null) 'by $committedByName']);
    }
    return generatedAt == null ? 'Not yet generated' : 'Generated ${fmtShortDate(generatedAt)}';
  }

  double? get solveSeconds => asDouble(solverStats['solveSeconds'] ?? solverStats['solve_seconds']);
  bool get provedOptimal => asBool(solverStats['provedOptimal'] ?? solverStats['proved_optimal']);

  factory SchPlanVersion.fromJson(Map<String, dynamic> j) => SchPlanVersion(
        id: asIntOr(j['id'], 0),
        versionNo: asIntOr(j['version_no'], 0),
        status: asStrOr(j['status'], 'proposed'),
        engine: asStrOr(j['engine'], 'heuristic'),
        generatedAt: asDate(j['generated_at']),
        committedAt: asDate(j['committed_at']),
        committedThrough: asDate(j['committed_through']),
        committedByName: asStr(j['committed_by_name']),
        policyVersion: asInt(j['policy_version']),
        objectiveScore: asDouble(j['objective_score']),
        objectiveTerms: asMap(j['objective_terms']),
        stabilityCostDays: asDouble(j['stability_cost_days']),
        solverStats: asMap(j['solver_stats']),
        scenarioName: asStr(j['scenario_name']),
        notes: asStr(j['notes']),
        inputsHash: asStr(j['inputs_hash']),
        assignmentCount: asInt(j['assignment_count']),
        changeCount: asInt(j['change_count']),
      );
}

/// `plan.php version{id}` — one version and the assignments it holds.
class SchVersionDetail {
  SchVersionDetail({required this.version, this.assignments = const []});
  final SchPlanVersion version;
  final List<SchBlock> assignments;

  factory SchVersionDetail.fromJson(Map<String, dynamic> j) => SchVersionDetail(
        version: SchPlanVersion.fromJson(asMap(j['version'])),
        assignments: asList(j['assignments'], SchBlock.fromJson),
      );
}

// ---------------------------------------------------------------------------
// What-if scenarios (SCH-11)
// ---------------------------------------------------------------------------

/// One hypothetical edit, as `replan.php preview` and `scenario_save` accept
/// it: `{op, ...}` where op is add_item, remove_item, person_away or
/// add_person (see `apply_edits_to_model()` in `api/replan.php`).
class SchEdit {
  SchEdit({required this.op, required this.label, required this.payload});

  final String op;
  final String label;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => {'op': op, ...payload};

  static SchEdit addItem(int workItemId, String label) =>
      SchEdit(op: 'add_item', label: 'Add $label to the plan', payload: {'work_item_id': workItemId});

  static SchEdit removeItem(int workItemId, String label) =>
      SchEdit(op: 'remove_item', label: 'Drop $label from the plan', payload: {'work_item_id': workItemId});

  static SchEdit personAway(int personId, String name, DateTime from, DateTime to) => SchEdit(
        op: 'person_away',
        label: '$name away ${fmtDateRange(from, to)}',
        payload: {'person_id': personId, 'from': schIso(from), 'to': schIso(to)},
      );

  static SchEdit addPerson(String name, List<({int id, String name, int proficiency})> skills) => SchEdit(
        op: 'add_person',
        label: skills.isEmpty
            ? 'Add $name as an extra pair of hands'
            : 'Add $name (${skills.map((s) => '${s.name} L${s.proficiency}').join(', ')})',
        payload: {
          'name': name,
          'skills': [for (final s in skills) {'skill_id': s.id, 'proficiency': s.proficiency}],
        },
      );
}

/// 'YYYY-MM-DD' for the API.
String schIso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// A stored edit read back from a saved scenario, described in plain English.
/// Names are resolved where the caller can supply them and fall back to the id.
String schEditLabel(Map<String, dynamic> edit, {Map<int, String> items = const {}, Map<int, String> people = const {}}) {
  final op = asStrOr(edit['op'] ?? edit['type'] ?? edit['kind'], '');
  final itemId = asInt(edit['work_item_id']);
  final personId = asInt(edit['person_id']);
  final item = itemId == null ? null : (items[itemId] ?? 'item $itemId');
  final person = personId == null ? null : (people[personId] ?? 'person $personId');
  return switch (op) {
    'add_item' => 'Add $item to the plan',
    'remove_item' => 'Drop $item from the plan',
    'set_effort' => '$item at ${fmtDays(asDouble(edit['remaining_days']))} remaining',
    'person_away' => '$person away ${fmtDateRange(asDate(edit['from']), asDate(edit['to']))}',
    'add_person' => 'Add ${asStrOr(edit['name'], 'a contractor')}',
    'move' => 'Move assignment ${asIntOr(edit['assignment_id'], 0)}',
    _ => humanise(op),
  };
}

/// One change in a preview, as `change_lite()` returns it.
class SchPreviewChange {
  SchPreviewChange({
    required this.headline,
    this.personName,
    this.ref,
    this.kind = 'move',
    this.reason,
    this.stabilityCostDays = 0,
    this.insideFreeze = false,
    this.chips = const [],
    this.guardrailStatus = 'ok',
  });

  final String headline;
  final String? personName;
  final String? ref;
  final String kind;
  final String? reason;
  final double stabilityCostDays;
  final bool insideFreeze;
  final List<ImpactChip> chips;
  final String guardrailStatus;

  bool get isHeld => guardrailStatus == 'held_budget' || guardrailStatus == 'held_threshold';

  factory SchPreviewChange.fromJson(Map<String, dynamic> j) => SchPreviewChange(
        headline: asStrOr(j['headline'], ''),
        personName: asStr(j['person_name']),
        ref: asStr(j['ref']),
        kind: asStrOr(j['kind'], 'move'),
        reason: asStr(j['reason']),
        stabilityCostDays: asDoubleOr(j['stability_cost_days'], 0),
        insideFreeze: asBool(j['inside_freeze']),
        chips: asList(j['impact_chips'], ImpactChip.fromJson),
        guardrailStatus: asStrOr(j['guardrail_status'], 'ok'),
      );
}

/// An item the what-if could not schedule, with the engine's suggestion.
class SchUnscheduled {
  SchUnscheduled({required this.ref, required this.title, this.detail, this.suggestion});
  final String ref;
  final String title;
  final String? detail;
  final String? suggestion;

  factory SchUnscheduled.fromJson(Map<String, dynamic> j) => SchUnscheduled(
        ref: asStrOr(j['ref'], ''),
        title: asStrOr(j['title'], ''),
        detail: asStr(j['detail']),
        suggestion: asStr(j['suggestion']),
      );
}

/// The `replan.php preview` result: the committed plan and the what-if side by
/// side, with the changes the engine would need to get there.
class SchPreview {
  SchPreview({
    this.summaryBefore = const {},
    this.summaryAfter = const {},
    this.changes = const [],
    this.held = const [],
    this.improvementPct,
    this.belowThreshold = false,
    this.unscheduled = const [],
    this.editsApplied = const [],
    this.solverStats = const {},
  });

  final Map<String, dynamic> summaryBefore;
  final Map<String, dynamic> summaryAfter;
  final List<SchPreviewChange> changes;
  final List<SchPreviewChange> held;
  final double? improvementPct;
  final bool belowThreshold;
  final List<SchUnscheduled> unscheduled;
  final List<String> editsApplied;
  final Map<String, dynamic> solverStats;

  List<SchPreviewChange> get allChanges => [...changes, ...held];
  double? get solveSeconds => asDouble(solverStats['total_seconds'] ?? solverStats['solve_seconds']);

  factory SchPreview.fromJson(Map<String, dynamic> j) => SchPreview(
        summaryBefore: asMap(j['summary_before']),
        summaryAfter: asMap(j['summary_after']),
        changes: asList(j['changes'], SchPreviewChange.fromJson),
        held: asList(j['held'], SchPreviewChange.fromJson),
        improvementPct: asDouble(j['improvement_pct']),
        belowThreshold: asBool(j['below_threshold']),
        unscheduled: asList(j['unscheduled'], SchUnscheduled.fromJson),
        editsApplied: asStrList(j['edits_applied']),
        solverStats: asMap(j['solver_stats']),
      );
}

/// A saved what-if (`plan_versions` with status `scenario`).
class SchScenario {
  SchScenario({
    required this.id,
    required this.name,
    this.versionNo = 0,
    this.generatedAt,
    this.objectiveScore,
    this.stabilityCostDays,
    this.edits = const [],
    this.summaryBefore = const {},
    this.summaryAfter = const {},
    this.improvementPct,
    this.notes,
  });

  final int id;
  final String name;
  final int versionNo;
  final DateTime? generatedAt;
  final double? objectiveScore;
  final double? stabilityCostDays;
  final List<Map<String, dynamic>> edits;
  final Map<String, dynamic> summaryBefore;
  final Map<String, dynamic> summaryAfter;
  final double? improvementPct;
  final String? notes;

  factory SchScenario.fromJson(Map<String, dynamic> j) => SchScenario(
        id: asIntOr(j['id'], 0),
        name: asStrOr(j['name'], 'Untitled scenario'),
        versionNo: asIntOr(j['version_no'], 0),
        generatedAt: asDate(j['generated_at']),
        objectiveScore: asDouble(j['objective_score']),
        stabilityCostDays: asDouble(j['stability_cost_days']),
        edits: (j['edits'] is List ? j['edits'] as List : const [])
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList(),
        summaryBefore: asMap(j['summary_before']),
        summaryAfter: asMap(j['summary_after']),
        improvementPct: asDouble(j['improvement_pct']),
        notes: asStr(j['notes']),
      );
}

/// A pickable work item for the what-if composer.
class SchItemOption {
  SchItemOption({required this.id, required this.ref, required this.title, this.status, this.sizeStamp, this.typeName});
  final int id;
  final String ref;
  final String title;
  final String? status;
  final String? sizeStamp;
  final String? typeName;

  String get label => dotJoin([ref, title]);

  factory SchItemOption.fromJson(Map<String, dynamic> j) => SchItemOption(
        id: asIntOr(j['id'], 0),
        ref: asStrOr(j['ref'], ''),
        title: asStrOr(j['title'], ''),
        status: asStr(j['status']),
        sizeStamp: asStr(j['size_stamp']),
        typeName: asStr(j['type_name']),
      );
}

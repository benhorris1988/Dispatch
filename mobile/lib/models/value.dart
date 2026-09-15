import 'json.dart';

/// A benefit attached to a work item.
class Benefit {
  Benefit({
    required this.id,
    required this.workItemId,
    this.workItemRef,
    this.workItemTitle,
    this.type = 'other',
    this.annualValue = 0,
    this.currency = 'GBP',
    this.confidence = 'medium',
    this.isFinancial = true,
    this.qualitativeScale,
    this.qualitativeLabel,
    this.proxyValue,
    this.realisationFrom,
    this.ownerPersonId,
    this.ownerName,
    this.narrative,
    this.status = 'planned',
    this.realisedValue,
    this.createdAt,
  });

  final int id;
  final int workItemId;
  final String? workItemRef;
  final String? workItemTitle;
  final String type; // cost_avoidance | productivity | revenue | risk_reduction | compliance | other
  final double annualValue;
  final String currency;
  final String confidence; // low | medium | high

  /// BEN-02. A non-financial benefit carries a 1–5 [qualitativeScale] (label from
  /// `benefits.php list.qualitative_scales`) and an optional currency-equivalent
  /// [proxyValue]; its [annualValue] is 0 and never counts in money totals.
  final bool isFinancial;
  final int? qualitativeScale; // 1..5
  final String? qualitativeLabel;
  final double? proxyValue;
  final DateTime? realisationFrom;
  final int? ownerPersonId;
  final String? ownerName;
  final String? narrative;
  final String status; // planned | in_flight | realising | realised | at_risk
  final double? realisedValue;
  final DateTime? createdAt;

  factory Benefit.fromJson(Map<String, dynamic> j) => Benefit(
        id: asIntOr(j['id'], 0),
        workItemId: asIntOr(j['work_item_id'], 0),
        workItemRef: asStr(j['ref'] ?? j['work_item_ref']),
        workItemTitle: asStr(j['title'] ?? j['work_item_title']),
        type: asStrOr(j['type'], 'other'),
        annualValue: asDoubleOr(j['annual_value'], 0),
        currency: asStrOr(j['currency'], 'GBP'),
        confidence: asStrOr(j['confidence'], 'medium'),
        isFinancial: asBool(j['is_financial'], fallback: true),
        qualitativeScale: asInt(j['qualitative_scale']),
        qualitativeLabel: asStr(j['qualitative_label']),
        proxyValue: asDouble(j['proxy_value']),
        realisationFrom: asDate(j['realisation_from']),
        ownerPersonId: asInt(j['owner_person_id']),
        ownerName: asStr(j['owner_name']),
        narrative: asStr(j['narrative']),
        status: asStrOr(j['status'], 'planned'),
        realisedValue: asDouble(j['realised_value']),
        createdAt: asDate(j['created_at']),
      );
}

/// One point on the qualitative scale (BEN-02), as published by
/// `benefits.php list.qualitative_scales`: 1 minor … 5 transformational. The
/// labels are the server's; the client never invents them.
class QualitativeScale {
  const QualitativeScale({required this.scale, required this.label});
  final int scale;
  final String label;
  factory QualitativeScale.fromJson(Map<String, dynamic> j) => QualitativeScale(scale: asIntOr(j['scale'], 0), label: asStrOr(j['label'], ''));
}

/// One row of an estimate's skill split.
class SkillSplit {
  SkillSplit({this.skillId, required this.label, required this.days});
  final int? skillId;
  final String label;
  final double days;
  factory SkillSplit.fromJson(Map<String, dynamic> j) =>
      SkillSplit(skillId: asInt(j['skill_id']), label: asStrOr(j['label'], ''), days: asDoubleOr(j['days'], 0));
}

/// Estimate class → ± tolerance label.
String estimateClassLabel(int? c) => switch (c) {
      1 => 'Class 1 · ±5%',
      2 => 'Class 2 · ±10%',
      3 => 'Class 3 · ±20%',
      4 => 'Class 4 · ±30%',
      5 => 'Class 5 · ±50%',
      _ => 'Unclassified',
    };

/// A versioned estimate for a work item.
class Estimate {
  Estimate({
    required this.id,
    required this.workItemId,
    this.workItemRef,
    this.workItemTitle,
    this.version = 1,
    this.method = 'three_point',
    this.optimistic,
    this.likely,
    this.pessimistic,
    this.estimateClass = 3,
    this.dayRate,
    this.assumptions,
    this.reason,
    this.skillSplit = const [],
    this.authorUserId,
    this.authorName,
    this.createdAt,
  });

  final int id;
  final int workItemId;
  final String? workItemRef;
  final String? workItemTitle;
  final int version;
  final String method; // size | three_point | rollup
  final double? optimistic;
  final double? likely;
  final double? pessimistic;
  final int estimateClass; // 5 (±50) … 1 (±5)
  final double? dayRate;
  final String? assumptions;
  final String? reason;
  final List<SkillSplit> skillSplit;
  final int? authorUserId;
  final String? authorName;
  final DateTime? createdAt;

  /// PERT expected value (O + 4M + P) / 6, or likely when incomplete.
  double? get expected {
    if (optimistic != null && likely != null && pessimistic != null) return (optimistic! + 4 * likely! + pessimistic!) / 6;
    return likely;
  }

  double? get costLikely => (likely != null && dayRate != null) ? likely! * dayRate! : null;

  factory Estimate.fromJson(Map<String, dynamic> j) => Estimate(
        id: asIntOr(j['id'], 0),
        workItemId: asIntOr(j['work_item_id'], 0),
        workItemRef: asStr(j['ref'] ?? j['work_item_ref']),
        workItemTitle: asStr(j['title'] ?? j['work_item_title']),
        version: asIntOr(j['version'], 1),
        method: asStrOr(j['method'], 'three_point'),
        optimistic: asDouble(j['optimistic']),
        likely: asDouble(j['likely']),
        pessimistic: asDouble(j['pessimistic']),
        estimateClass: asIntOr(j['estimate_class'], 3),
        dayRate: asDouble(j['day_rate']),
        assumptions: asStr(j['assumptions']),
        reason: asStr(j['reason']),
        skillSplit: asList(j['skill_split'], SkillSplit.fromJson),
        authorUserId: asInt(j['author_user_id']),
        authorName: asStr(j['author_name']),
        createdAt: asDate(j['created_at']),
      );
}

/// In-app notification.
class AppNotification {
  AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    this.body,
    this.link,
    this.urgent = false,
    this.channel = 'in_app',
    this.createdAt,
    this.readAt,
  });

  final int id;
  final String kind; // change_proposed | change_committed | approval_requested | item_assigned | estimate_requested | realisation_due | watch_list | request_decided | digest
  final String title;
  final String? body;
  final String? link; // app route, e.g. /changes/12
  final bool urgent;
  final String channel;
  final DateTime? createdAt;
  final DateTime? readAt;

  bool get isRead => readAt != null;

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: asIntOr(j['id'], 0),
        kind: asStrOr(j['kind'], ''),
        title: asStrOr(j['title'], ''),
        body: asStr(j['body']),
        link: asStr(j['link']),
        urgent: asBool(j['urgent']),
        channel: asStrOr(j['channel'], 'in_app'),
        createdAt: asDate(j['created_at']),
        readAt: asDate(j['read_at']),
      );
}

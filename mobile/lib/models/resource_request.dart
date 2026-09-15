import 'json.dart';

/// A request for somebody's time on a work item, and where it has got to.
///
/// Hours are what was asked for; [fromDate], [toDate] and [allocationPct] are what the server
/// worked that out to against the person's own capacity — a part-time Friday is not a whole day,
/// so the client never computes a span itself.
class ResourceRequest {
  ResourceRequest({
    required this.id,
    required this.workItem,
    required this.person,
    required this.requestedByName,
    required this.hours,
    required this.fromDate,
    required this.toDate,
    required this.allocationPct,
    required this.status,
    this.note,
    this.decidedByName,
    this.decidedAt,
    this.decisionReason,
    this.planVersionId,
    this.createdAt,
    this.canApprove = false,
    this.canWithdraw = false,
    this.approverLabel,
  });

  final int id;
  final RequestItemRef workItem;
  final RequestPersonRef person;
  final String requestedByName;
  final double hours;
  final DateTime? fromDate;
  final DateTime? toDate;
  final int allocationPct;

  /// pending | approved | declined | withdrawn | expired
  final String status;
  final String? note;
  final String? decidedByName;
  final DateTime? decidedAt;
  final String? decisionReason;
  final int? planVersionId;
  final DateTime? createdAt;

  /// True when *this* caller may decide it — the server works out the lead chain, so the client
  /// hides buttons instead of discovering a 403 (ADM-02).
  final bool canApprove;
  final bool canWithdraw;

  /// "Lena Torres, Priya Kaur or a delivery lead" — who the asker is waiting on.
  final String? approverLabel;

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';

  /// Colour tone for the status chip, matching the tones used on change cards.
  String get tone => switch (status) {
        'approved' => 'ok',
        'declined' => 'bad',
        'pending' => 'warn',
        _ => 'info',
      };

  String get statusLabel => switch (status) {
        'pending' => 'Awaiting approval',
        'approved' => 'Approved',
        'declined' => 'Declined',
        'withdrawn' => 'Withdrawn',
        'expired' => 'Expired',
        _ => status,
      };

  factory ResourceRequest.fromJson(Map<String, dynamic> j) => ResourceRequest(
        id: asIntOr(j['id'], 0),
        workItem: RequestItemRef.fromJson(Map<String, dynamic>.from(j['work_item'] as Map? ?? const {})),
        person: RequestPersonRef.fromJson(Map<String, dynamic>.from(j['person'] as Map? ?? const {})),
        requestedByName: asStrOr((j['requested_by'] as Map?)?['name'], 'Somebody'),
        hours: asDoubleOr(j['hours'], 0),
        fromDate: asDate(j['from_date']),
        toDate: asDate(j['to_date']),
        allocationPct: asIntOr(j['allocation_pct'], 100),
        status: asStrOr(j['status'], 'pending'),
        note: asStr(j['note']),
        decidedByName: asStr(j['decided_by_name']),
        decidedAt: asDate(j['decided_at']),
        decisionReason: asStr(j['decision_reason']),
        planVersionId: asInt(j['plan_version_id']),
        createdAt: asDate(j['created_at']),
        canApprove: asBool(j['can_approve']),
        canWithdraw: asBool(j['can_withdraw']),
        approverLabel: asStr(j['approver_label']),
      );
}

class RequestItemRef {
  RequestItemRef({required this.id, required this.ref, required this.title, this.status, this.typeColour, this.typeName});
  final int id;
  final String ref;
  final String title;
  final String? status;
  final String? typeColour;
  final String? typeName;

  factory RequestItemRef.fromJson(Map<String, dynamic> j) => RequestItemRef(
        id: asIntOr(j['id'], 0),
        ref: asStrOr(j['ref'], '—'),
        title: asStrOr(j['title'], ''),
        status: asStr(j['status']),
        typeColour: asStr(j['type_colour']),
        typeName: asStr(j['type_name']),
      );
}

class RequestPersonRef {
  RequestPersonRef({required this.id, required this.name, this.initials, this.colour, this.teamName});
  final int id;
  final String name;
  final String? initials;
  final String? colour;
  final String? teamName;

  factory RequestPersonRef.fromJson(Map<String, dynamic> j) => RequestPersonRef(
        id: asIntOr(j['id'], 0),
        name: asStrOr(j['name'], 'Somebody'),
        initials: asStr(j['initials']),
        colour: asStr(j['colour']),
        teamName: asStr(j['team_name']),
      );
}

/// What `preview` answers with: the dates the hours turn into, and what they collide with.
class RequestSpan {
  RequestSpan({
    required this.from,
    required this.to,
    required this.allocationPct,
    required this.schedulableHours,
    required this.bookedHours,
    required this.dayCount,
    required this.fits,
    required this.shortHours,
    required this.conflicts,
    required this.insideFreeze,
    this.approverLabel,
    this.onLoanTeam,
  });

  final DateTime? from;
  final DateTime? to;
  final int allocationPct;
  final double schedulableHours;
  final double bookedHours;
  final int dayCount;
  final bool fits;
  final double shortHours;
  final List<String> conflicts;
  final bool insideFreeze;
  final String? approverLabel;
  final String? onLoanTeam;

  factory RequestSpan.fromJson(Map<String, dynamic> j) {
    final span = Map<String, dynamic>.from(j['span'] as Map? ?? const {});
    final fit = Map<String, dynamic>.from(j['fit'] as Map? ?? const {});
    final days = (span['days'] as List?) ?? const [];
    final conflicts = ((fit['conflicts'] as List?) ?? const [])
        .map((c) => asStrOr((c as Map)['ref'], '—'))
        .toList(growable: false);
    return RequestSpan(
      from: asDate(span['from']),
      to: asDate(span['to']),
      allocationPct: asIntOr(span['allocation_pct'], 100),
      schedulableHours: asDoubleOr(span['schedulable_hours'], 0),
      bookedHours: asDoubleOr(span['booked_hours'], 0),
      dayCount: days.length,
      fits: asBool(fit['fits'], fallback: true),
      shortHours: asDoubleOr(fit['short_hours'], 0),
      conflicts: conflicts,
      insideFreeze: asBool(j['inside_freeze']),
      approverLabel: asStr(j['approver_label']),
      onLoanTeam: asStr((j['on_loan'] as Map?)?['to_team_name']),
    );
  }
}

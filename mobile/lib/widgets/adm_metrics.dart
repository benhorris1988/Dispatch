/// In-app metric definitions (REP-04) for the Team & skills and Person screens.
///
/// `reports.php` returns definitions for its own four metrics; everything the
/// team and person screens show had none. The wording here is taken from the
/// requirement text (sections 6.4, 6.8, 6.9 and 8.5 of
/// `docs/requirements-v0.1.md`) and from the formulas the API actually
/// implements, rather than being invented at the widget. Each definition says
/// what the figure is, what it includes and what it excludes, which is what
/// REP-04 asks for.
///
/// Reached through `TmMetricTitle`'s info icon (`widgets/team_widgets.dart`).
library;

class AdmMetrics {
  AdmMetrics._();

  /// Load percentage on a person, a lane header or the matrix (TEAM-10).
  static String load({num targetMin = 80, num targetMax = 90, String window = 'the next four weeks'}) =>
      'Load = hours assigned in the committed plan ÷ hours available, across $window. '
      'Available hours come from the person’s working pattern less leave, training and sickness; '
      'capacity per person per day is derived nightly as available hours minus the incident reserve. '
      'The target band is ${targetMin.round()}–${targetMax.round()}%: at or below it is healthy, above it is flagged amber, and over 100% is red. '
      'Includes committed assignments only. Excludes proposed changes that have not been committed, the incident reserve itself, and inactive people.';

  /// Coverage and single points of failure (REQ-02, TEAM-03, TEAM-04).
  static const String coverage =
      'Proficiency runs 0 to 4 — None, Aware, Practitioner, Independent, Expert. '
      'Coverage for a required skill is the number of people who meet or exceed the minimum proficiency that piece of work asks for. '
      'A skill with exactly one person at Independent or above is a single point of failure and is flagged; two is shown as a warning. '
      'Includes active people with a recorded level. Excludes retired skills and people who have been deactivated.';

  /// Skills matrix, its footers and the gap highlighting (TEAM-04).
  static const String skillsMatrix =
      'The matrix shows every person against every tracked skill at proficiency 0 to 4 (None, Aware, Practitioner, Independent, Expert). '
      '“People at L3 or above” counts everyone at Independent or better in that skill — one is a single point of failure, two is a warning. '
      '“Items needing skill, next 6 weeks” counts the open work items that require the skill inside that window. '
      'A green dot on a square means the level is certified. Excludes retired skills and inactive people.';

  /// Demand against supply per skill (TEAM-04).
  static const String demandVsSupply =
      'Demand = the planned assignment days over the next six weeks on open items that require the skill — that is, the remaining effort attributable to it inside the window. '
      'Supply = the capacity days over the same six weeks of the people qualified for it, meaning those at or above the minimum proficiency the work asks for. '
      'Both are person-days. Where demand exceeds supply the skill is marked with an exclamation mark as well as colour. '
      'Excludes delivered and cancelled items, retired skills and inactive people.';

  /// Availability records (TEAM-06, ADM-05).
  static const String availability =
      'Availability records cover leave, training, sickness and rota duties, and reduce the person’s capacity on every day they span; '
      'half-day records reduce it by half. The scheduler never books work on a day with no capacity. '
      'Only the type and the dates are stored — never a reason, a medical detail or a note (ADM-05). '
      'Imported records are marked with their source and can be corrected but not deleted locally.';

  /// Development targets and pairing (TEAM-05, SCH-12).
  static const String development =
      'A development target is a skill and the level the person is growing towards. '
      'With pairing switched on, the scheduler prefers to add that person to matching work as a second at 25% allocation, '
      'but only when the pair is exactly one level short and the extra effort stays under the pairing cost threshold in policy. '
      'Excludes people with no recorded target.';

  /// The incident rota and the reserve uplift it causes (TEAM-08).
  static String incidentRota({num incidentReservePct = 12, num rotaReservePct = 25}) =>
      'The incident rota assigns a person to a whole week. For that week their incident reserve rises from '
      '${incidentReservePct.round()}% to ${rotaReservePct.round()}% of their capacity, and their capacity is recomputed as soon as the rota changes. '
      'Reserved hours are held back for interrupt-driven work and are not offered to planned work, so assigning the rota lowers how much planned work that person can take that week. '
      'Everyone not on the rota keeps the standard ${incidentReservePct.round()}%. Weeks run Monday to Sunday.';

  /// Concurrent items against the person's own limit (SCH-01, TEAM-02).
  static const String concurrentItems =
      'Concurrent items = the distinct work items with a committed assignment covering today. '
      'The limit is the person’s own maximum concurrent items, or the workspace policy’s maximum when they have none set. '
      'The scheduler holds to the same limit when it plans. Excludes the incident reserve, and excludes size classes marked as not counting toward the WIP limit.';

  /// Per-person change history over eight weeks (STAB-07).
  static const String personChanges =
      'Changes affecting this person = entries in the plan change log for them, grouped by week commencing, over the last eight weeks. '
      'Changes made inside the freeze horizon are counted separately because they needed an approver and a reason. '
      'Assignment-days moved is the stability cost of those changes: the assignment-days that moved inside the committed and planned windows. '
      'The team median is the same count across their team over the same eight weeks. '
      'Excludes indicative assignments beyond the planning horizon, whose moves cost nothing (STAB-06).';

  /// Plan stability index (STAB-08) — same formula the Reports screen states.
  static const String stabilityIndex =
      'Plan stability index = 1 − (assignment-days changed inside the committed and planned windows ÷ total assignment-days in those windows), rolling four weeks. '
      'Includes committed and planned assignments in the current plan. '
      'Excludes indicative assignments beyond the planning horizon and changes to them.';

  /// The incident reserve line on a person's assignments (CFG-08, SCH-10).
  static String incidentReserve({num incidentReservePct = 12, num rotaReservePct = 25}) =>
      'The incident reserve holds back ${incidentReservePct.round()}% of each person’s capacity for interrupt-driven work, '
      'rising to ${rotaReservePct.round()}% in a week they are on the incident rota. '
      'Planned work is never scheduled into it. An incident consumes the reserve first and only displaces that person’s lowest-priority planned work if the reserve is not enough. '
      'It is capacity, not an assignment, so it never appears as a work item.';

  /// The blended day rate behind the estimate screen's cost range (EST-05).
  static const String dayRate =
      'Rates are versioned by effective date: the rate in force is the most recent one whose effective-from date has passed, with blended rates preferred over per-role rates. '
      'The estimate screen multiplies the planning effort by the blended rate in force today to show an indicative cost range. '
      'Saving a rate never changes a cost already recorded against an older estimate version.';
}

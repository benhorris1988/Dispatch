Dispatch
Delivery planning and resource management
Requirements and design
Figure 1: The schedule view: people as lanes, work as blocks, and a locked committed window that the scheduler may not disturb.
Attribute
Value
Version
0.1 (draft for review)
Date
8 September 2026
Author
Ben, Data & Platform Engineering
Status
Draft
Pilot team
Data Platform team (8 people)
# Document control
Version
Date
Author
Change
0.1
8 Sep 2026
Ben
First complete draft: requirements, scheduling engine design, UX design with screen mockups, architecture, roadmap.
Review and approval
Role
Name
Decision
Date
Product owner
Head of AIDEX
Architecture
Security
Pilot team representative
How to read this document. Sections 1 to 5 set out the problem, scope, users and vocabulary. Sections 6 and 7 are the requirements, numbered for traceability and prioritised Must, Should, Could, with a target release. Section 8 is the design of the scheduling engine, including the stability mechanisms that stop the plan thrashing. Section 9 is the user experience design with rendered screen mockups. Sections 10 to 13 cover architecture, roadmap, risks and acceptance. Appendices hold the glossary, configuration examples and the priority score worked example.
# Contents
If the contents list is empty when opened, right-click it and choose Update Field, or press F9.
# 1	Executive summary
Dispatch is a resource management and delivery planning application for teams whose work arrives as a mix of projects, small changes, incidents and requests. It holds the pipeline of work, the team's skills and availability, rough-order-of-magnitude estimates and the business benefits that justify each item, and it schedules the work automatically. Its defining feature is that it treats stability as a first-class objective: a plan that people can rely on for the next two weeks is worth more than a marginally better plan that changes every morning.
The product runs in the browser for planning at scale and as native iOS and Android apps for the moments away from a desk: seeing your week, acknowledging a change, approving a proposal or capturing a request. All three share one design language, themed around delivery: a board of what is landing, lanes per person, parcel-style size stamps, and a committed window that is visibly locked.
The scheduling engine is a constraint solver (Google OR-Tools CP-SAT) with a fast heuristic for previews. It respects skills and proficiency, capacity, leave, dependencies and work-in-progress limits, and optimises for value landing early, due dates met, balanced load and minimal change. Four guardrails make change deliberate: a freeze horizon, a per-person change budget, a minimum improvement threshold and a replan cadence of propose nightly, commit weekly. Every change is proposed with its reason and its cost, and nothing changes silently.
Work types and sizes are configurable. A team can call its work Projects, Small changes and Incidents or anything else, choose colours and prefixes, and define size bands for Small, Medium and Large in days, plus a Custom size where effort is entered directly. Incidents can have their own bands in hours.
This document proposes a phased delivery: a discovery phase with the pilot team, an MVP on the web with configuration, pipeline, team and skills, heuristic scheduling and the stability guardrails, then the full optimiser, estimates, benefits, reporting and the mobile apps, followed by integrations and multi-team planning. Success is measured by plan stability inside the committed window, time spent on weekly planning, completeness of estimates and benefit cases, and adoption.
## 1.1	Key design decisions
- Proposals, not changes. The engine never edits the committed plan directly. It proposes; a person commits.
- Three windows of certainty. Committed (locked), planned (adjustable within guardrails) and indicative (approximate). The interface shows which is which at a glance.
- Stability in the objective. Moving an assignment-day costs something. The solver has to earn the right to change the plan.
- Configurable vocabulary. Work types and size classes are data, not code.
- Estimates are ranges with a confidence class, and the team's calibration history is fed back into planning.
- Benefits drive priority, scaled by confidence, alongside urgency, risk, dependency leverage and age.
- One codebase for mobile (React Native) and shared TypeScript packages with the web app, behind one REST API.
# 2	Background, problem statement and objectives
## 2.1	The problem
Delivery teams that own platforms and services rarely have one kind of work. A data and platform engineering team, for instance, runs multi-month projects, absorbs a steady stream of small changes and service requests, and responds to incidents that cannot wait. Allocation is usually held in a spreadsheet or in someone's head, the estimates live in a different spreadsheet, the benefits case lives in a slide deck, and skills are known informally.
The result is familiar. The plan is re-cut whenever something new arrives, so engineers find their week rearranged daily and lose the focus that finishes things. Scarce skills become single points of failure that nobody sees until a person is on leave. Small work is squeezed in wherever there is a gap and pushes larger commitments right. Requesters cannot see when their item will land or why it has moved. Planning consumes a disproportionate share of the delivery lead's week.
## 2.2	What the product must change
Today
With Dispatch
Allocation in spreadsheets; several versions of the truth.
One pipeline, one plan, versioned, with an audit trail.
Plans change daily in response to each new request.
Changes are proposed on a cadence, costed for disruption, and committed deliberately.
Skills known informally; gaps discovered late.
Skills matrix with proficiency, coverage per item and demand versus supply six weeks out.
Estimates are point figures, rarely revisited.
Three-point estimates with a confidence class and a calibration history.
Benefits documented once, then forgotten.
Benefits drive priority and are tracked through to realisation.
Engineers hear about changes second hand.
Every affected person sees the change and its reason before it takes effect.
## 2.3	Objectives and success measures
Objective
Measure
Target (pilot team, 3 months after go-live)
Stable plans people can rely on
Plan stability index (STAB-08)
At least 90% inside the committed window; changes inside the freeze horizon at most 3 per week for the team
Less time planning
Delivery lead time on weekly planning
Reduced by half against the baseline measured in discovery
Work is estimated before it is scheduled
Share of scheduled items with an estimate of class 3 or better
100% of Projects and Small changes
Value is visible
Share of Projects with a benefit case
100%; value in plan and realised reported quarterly
Skills risk is visible early
Single-skill dependencies flagged before the planned window
100% flagged at least 4 weeks ahead
People use it
Weekly active use of My week
100% of the team in any given week
Estimates improve
Median actual ÷ most-likely by size class
Within 0.9 to 1.15 for Small and Medium after 6 months
# 3	Scope
## 3.1	In scope
- Configurable work types and size classes, including a Custom size and per-type overrides.
- Pipeline and intake, including requirements, tasks, dependencies and readiness rules.
- Team, skills catalogue, proficiency, availability, incident rota and derived capacity.
- Rough-order-of-magnitude estimation with three-point estimates, estimate classes, cost conversion and calibration.
- Business benefits, priority scoring and realisation tracking.
- Automated scheduling with hard constraints, weighted objectives and a stability penalty; what-if scenarios.
- Stability guardrails: freeze horizon, change budget, minimum improvement, cadence, indicative window.
- Change proposals with review, approval, notification and acknowledgement.
- Schedule, overview, item, person, benefits, estimates and reporting views on the web; native iOS and Android apps.
- Integrations with Jira or Azure DevOps, ServiceNow, HR leave, Microsoft 365 calendar, Teams and timesheets.
- Administration, role-based access, audit and data retention.
## 3.2	Out of scope
- Detailed task tracking and engineering workflow (remains in Jira or Azure DevOps; Dispatch links and syncs).
- Being the system of record for HR data, leave approval or timesheets.
- Financial budgeting and cost management beyond indicative cost ranges derived from day rates.
- Document management for requirements beyond linked pages and attachments.
- Cross-organisation or supplier resource pools in the first releases.
## 3.3	Assumptions
- A single team of about eight people pilots the product; the design scales to a portfolio of teams.
- Users sign in with the organisation's Microsoft Entra ID; mobile devices are managed through Intune.
- Working days and hours follow a configurable working week; the default is Monday to Friday, 7.5 hours.
- Effort is estimated in person-days; hours are supported for small work and incidents.
# 4	Users and journeys
## 4.1	Personas
Persona
Needs from Dispatch
Primary surfaces
Delivery lead
A plan the team can commit to; to see the effect of new work before accepting it; to approve or reject proposed changes quickly; to spot skills risk early; to report value delivered.
Web: Overview, Schedule, Proposed changes, Reports. Mobile: Changes for approvals.
Team member (engineer, analyst, modeller)
To know what they are doing this week and next; to be told why anything changed; to keep their skills and availability up to date; to log progress.
Mobile: My week, item view. Web: person page, schedule.
Team lead or skills owner
To endorse proficiency, plan development pairing, manage the rota, keep the skills catalogue honest.
Web: Team & skills, person pages.
Requester or sponsor
To submit work with the right size and benefit case; to see where it is in the pipeline and when it is planned; to be told when it moves.
Mobile and web: Add work, item view, notifications.
Benefit owner
To own the benefit case, confirm realised value, and see the register.
Web: Benefits.
Portfolio or PMO
Cross-team view of load, stability, value and skills; exports to Power BI.
Web: Overview (portfolio), Reports, dataset.
Workspace administrator
To configure work types, sizes, policy, skills, roles and integrations; to read the audit log.
Web: Settings.
## 4.2	Core journeys
### 4.2.1	Work arrives and is made ready
- A requester adds an item on their phone: title, type (Project), size (Medium), needed-by date, required skills and the annual benefit. The item enters the pipeline as Needs estimate.
- The delivery lead or an engineer adds a three-point estimate with effort by skill; the estimate class defaults to 3 (±30%). The item becomes Needs benefit case if a case is required and missing, otherwise Ready.
- The priority score is computed and shown with its formula. The item appears in the unscheduled queue in priority order.
### 4.2.2	The nightly proposal and the weekly commit
- Overnight the engine builds a model from the pipeline, the team's capacity and the current committed plan, solves it, and diffs the result against the committed plan.
- Each difference becomes a proposed change with a reason, a stability cost and the people affected. Guardrails hold changes inside the freeze horizon, over the change budget or below the improvement threshold.
- On Monday morning the delivery lead reviews the proposal in twenty minutes: accepts most, edits one, rejects one. A new plan version is committed. Affected people are notified with the reason.
### 4.2.3	An incident arrives mid-week
- ServiceNow assigns a P2 incident to the team. Dispatch creates INC-4471 as an Incident item with priority from severity.
- The engine runs an immediate cycle limited to the rota person. The incident consumes the reserve first; the remainder displaces the person's lowest-priority planned work, proposed as a change for the lead to accept from their phone.
- The displaced item's requester is notified with the new date and the reason. The stability index records the change.
### 4.2.4	Someone adds leave
- An engineer adds two days' leave for the week after next. Capacity for those days drops to zero.
- The change is a non-urgent trigger and is batched into the nightly proposal. Overnight the engine extends the affected assignment by two days if the needed-by date still holds; otherwise it proposes the smallest displacement.
# 5	Key concepts
The vocabulary below is used throughout the requirements and the interface. Where a workspace renames a work type or size, the interface uses the configured name; this document uses the defaults.
Concept
Definition
Work item
A unit of work in the pipeline with a work type, size, status, priority score and (optionally) tasks, estimate and benefits. References are prefixed by type: WI-1042, INC-4471, SR-0212.
Work type
A configurable category of work with its own name, colour, prefix and scheduling policy (planned or interrupt-driven). Defaults: Project, Small change, Incident, Service request.
Size class
A configurable effort band with a one-character stamp. Defaults: S up to 3 days, M 4 to 15 days, L 16 to 60 days, C (Custom) entered directly.
Task
A part of a work item with its own effort and optional skill; effort can roll up to the item.
Skill and proficiency
A catalogued capability and a person's level in it: 0 None, 1 Aware, 2 Practitioner, 3 Independent, 4 Expert. Items require skills at a minimum level.
Capacity
A person's available effort per day after working pattern, leave and reserve. Load is assigned effort divided by capacity over a period.
Incident reserve
A percentage of each person's capacity held back for interrupt-driven work (default 12%, 25% on rota). Planned work never fills it.
Assignment
A person allocated to a work item for a date range at a percentage.
Plan version
A complete set of assignments produced by a cycle; either proposed, committed or superseded.
Committed, planned, indicative windows
Committed: inside the freeze horizon, locked. Planned: inside the planning horizon, adjustable with guardrails. Indicative: beyond, approximate and free to change.
Freeze horizon
The number of working days ahead within which assignments are locked (default 10).
Change budget
The maximum assignment-days that may be moved per person per week by proposals (default 5).
Stability cost
The number of assignment-days a change moves inside the committed and planned windows. Penalised in the objective.
Plan stability index
One minus the share of assignment-days changed in the committed and planned windows over a rolling four weeks.
ROM and estimate class
A rough-order-of-magnitude estimate expressed as a range (three-point or size band) with a class from 5 (±50%) to 1 (±5%).
Benefit
A quantified reason to do the work: type, annual value, confidence, realisation start and owner.
Priority score
A 0 to 100 score combining benefit value and confidence, urgency, risk or compliance weight, dependency leverage and age. Drives scheduling order.
Trigger
An event that may warrant replanning: intake, estimate change, incident, leave, dependency cleared, item delivered.
Proposal and change
The output of a cycle: a set of changes, each shown before and after with reason, cost and impact, awaiting review.
Guardrail
A configured rule that holds a change from being applied automatically: freeze horizon, change budget, minimum improvement, override permission.
Watch list
Things the engine cannot fix on its own and that need a human decision: skills gaps, missing estimates, people over capacity.
# 6	Functional requirements
Requirements are grouped by capability. Each has an identifier, a priority (Must, Should, Could) and a target release: R1 is the MVP, R2 the second release, R3 later. Priorities reflect the pilot team's needs; a portfolio deployment may promote Should items.
## 6.1	Workspace configuration: work types and size classes
The vocabulary of the pipeline must be the team's own. Work types and size classes are configured per workspace, and every screen, report and export uses the configured names.
ID
Requirement
Priority
Release
CFG-01
An administrator can create, rename, recolour, reorder and retire work types (for example Project, Small change, Incident, Service request). Renaming applies everywhere immediately; existing references keep their prefix.
Must
R1
CFG-02
Each work type has: display name, plural, reference prefix, colour, scheduling policy (planned or interrupt-driven), whether an estimate is required before scheduling, whether a benefit case is required before scheduling, and a default size class.
Must
R1
CFG-03
Retiring a work type is blocked while open items use it; the administrator is offered a bulk re-type.
Must
R1
CFG-04
An administrator can define size classes with a name, a one-character stamp, an effort band in days (min, max), a planning value used until an estimate exists, a default estimate class, a planning granularity (half day, day, week) and whether the size counts towards a person's concurrent-work limit.
Must
R1
CFG-05
The default size classes are Small (up to 3 days), Medium (4 to 15 days), Large (16 to 60 days) and Custom. Bands must not overlap; the system validates this on save.
Must
R1
CFG-06
A Custom size lets the user enter effort directly (days or hours) or build it from a task roll-up. Items above the largest band must be split or entered as Custom.
Must
R1
CFG-07
Size classes can be overridden per work type (for example Incidents measured in hours: S up to 4 h, M up to 2 days, L longer).
Should
R2
CFG-08
Each workspace has a scheduling policy: freeze horizon, change budget, minimum improvement threshold, incident reserve percentage, replan cadence, default maximum concurrent items, minimum focus block, and the planning horizon after which assignments are indicative.
Must
R1
CFG-09
Configuration changes are versioned and audited; the schedule shows which policy version produced each plan version.
Should
R2
CFG-10
Configuration can be exported and imported as JSON to seed new workspaces.
Could
R3
## 6.2	Pipeline and intake
The pipeline is the single list of everything the team might do. It is where work is sized, prioritised and made ready for the scheduler.
ID
Requirement
Priority
Release
PIP-01
Users can add a work item with a title, work type, size class (or custom effort), summary, tags, requested-by, sponsor, needed-by date and earliest-start date.
Must
R1
PIP-02
Each item receives a reference built from the work type prefix and a sequence (WI-1042, INC-4471, SR-0212).
Must
R1
PIP-03
The pipeline view lists items with type, size stamp, priority score, benefit value, estimate range, required skills, status and planned window, with filtering by type, size, skill, team, status and free text, and sorting by any column.
Must
R1
PIP-04
Statuses are: Draft, Needs estimate, Needs benefit case, Ready, Scheduled, In progress, Blocked, Delivered, Cancelled. Transitions are validated against work type policy (for example a Project cannot be Ready without an estimate).
Must
R1
PIP-05
Users can record dependencies between items (finish-to-start and soft) and see them on the item and in the schedule.
Must
R1
PIP-06
Users can split an item into tasks, each with its own size or effort and optional skill; the item's effort can be rolled up from its tasks.
Must
R1
PIP-07
Items can be imported from Jira or Azure DevOps by query, with field mapping to work type, size and skills, and kept in sync on a schedule.
Should
R3
PIP-08
A queue-health strip shows items waiting for an estimate, missing a benefit case, or with a skills gap, and how long the oldest has waited.
Should
R1
PIP-09
Items support a discussion thread with @mentions and file attachments.
Should
R2
PIP-10
Bulk actions: re-type, re-size, tag, cancel and assign owner.
Should
R2
PIP-11
Every change to an item is recorded in a history tab with who, when and before/after values.
Must
R1
## 6.3	Work item requirements and readiness
Each item carries enough definition for the scheduler to place it well: what skills it needs, at what level, and what has to happen first.
ID
Requirement
Priority
Release
REQ-01
An item declares required skills, each with a minimum proficiency (1 to 4) and optionally the effort attributable to that skill.
Must
R1
REQ-02
The item shows team coverage for each required skill (how many people meet the minimum in the planned window) and flags single points of failure.
Must
R1
REQ-03
An item has a free-text requirements tab supporting headings, lists, links and acceptance criteria; a template per work type can pre-populate it.
Should
R1
REQ-04
A readiness checklist per work type (for example estimate present, benefit case present, skills declared, sponsor named) must be complete before an item can be Ready.
Must
R1
REQ-05
Items can be linked to external records (Jira epic, ServiceNow incident, SharePoint page) by URL with a live status badge where an integration exists.
Could
R3
## 6.4	Team, skills and availability
The scheduler is only as good as its knowledge of people. Skills, proficiency and availability are first-class data, owned by the people they describe and confirmed by their lead.
ID
Requirement
Priority
Release
TEAM-01
Administrators maintain a skills catalogue (name, category, description). Skills can be merged and retired.
Must
R1
TEAM-02
Each person has a profile: role, team, days per week, working pattern, maximum concurrent items, minimum focus block, preferences and things to avoid.
Must
R1
TEAM-03
Each person records proficiency 0 to 4 per skill (None, Aware, Practitioner, Independent, Expert); the team lead can endorse levels; certifications can be attached.
Must
R1
TEAM-04
A skills matrix shows people against skills with proficiency, people at Independent or above per skill, and demand for each skill over the planning horizon, highlighting gaps.
Must
R1
TEAM-05
People can set development targets (skill and target level). The scheduler can be configured to prefer pairing that person on matching work as a second.
Should
R2
TEAM-06
Availability records cover leave, training, rota duties and recurring patterns; they reduce capacity for the scheduler on the affected days.
Must
R1
TEAM-07
Leave can be imported from the HR system and calendar out-of-office; imported records are marked with their source and can be corrected but not deleted locally.
Should
R2
TEAM-08
An incident rota assigns a person or people per week; the incident reserve for that person rises to the rota reserve percentage.
Must
R1
TEAM-09
Teams can be grouped into a portfolio for cross-team views; a person belongs to one team but can be loaned to another for a dated period.
Should
R3
TEAM-10
Capacity per person per day is derived nightly (available hours minus reserve) and visible on the profile and in the schedule lane header as a load percentage.
Must
R1
## 6.5	Estimation (rough order of magnitude)
Estimates are ranges, not points. The system records how the estimate was made, how confident it is and how it later compared with reality, so that the team's calibration improves.
ID
Requirement
Priority
Release
EST-01
An item can be estimated by size class only (using the planning value), by three-point (optimistic, most likely, pessimistic) or by task roll-up.
Must
R1
EST-02
For three-point estimates the system calculates the PERT expected value, standard deviation and P80, and shows the size class the estimate implies.
Must
R1
EST-03
Each estimate carries an estimate class (5: ±50% down to 1: ±5%) with a description of what each class means; the class defaults from the size class and can be changed.
Must
R1
EST-04
Effort can be split by skill; the split drives the skills the scheduler must match and the effort it allocates to each.
Must
R1
EST-05
A blended or per-role day rate converts effort to an indicative cost range; rates are configured per workspace and versioned.
Should
R2
EST-06
Estimates are versioned; each version records author, date and reason. The schedule uses the latest version and shows when the estimate changed.
Must
R1
EST-07
The system shows calibration data: actual effort divided by most-likely estimate, by size class and work type, over the last 12 months, and recommends whether to plan at most-likely or P80.
Should
R2
EST-08
Users can find similar delivered items (same skills, same size) and copy their estimate as a starting point.
Should
R2
EST-09
The policy can require a re-estimate before an item enters the committed window if its estimate class is worse than a configured threshold.
Should
R2
EST-10
Assumptions and exclusions are recorded with the estimate and shown wherever the estimate is shown.
Must
R1
## 6.6	Business benefits and prioritisation
Benefits explain why work is worth doing and feed the priority score that decides what the scheduler places first. Realisation is tracked after delivery.
ID
Requirement
Priority
Release
BEN-01
An item can hold one or more benefits, each with a type (cost avoidance, productivity, revenue, risk reduction, compliance, other), annual value, currency, confidence (low, medium, high), realisation start, owner and narrative.
Must
R1
BEN-02
Non-financial benefits can be recorded with a qualitative scale and an optional proxy value so they still influence priority.
Should
R2
BEN-03
The priority score combines benefit value scaled by confidence, urgency against the needed-by date, risk or compliance weight, dependency leverage (how much other work an item unblocks) and age in the pipeline. Weights are configurable per workspace and the formula is shown on the item.
Must
R1
BEN-04
Interrupt-driven items (incidents) take a priority from their severity and bypass the benefit case.
Must
R1
BEN-05
A benefits register lists all benefits with filters by type, owner, status and quarter, and totals value in plan, realised to date and at risk.
Must
R1
BEN-06
After delivery, the benefit owner records realised value at the configured cadence; the register shows planned against realised by quarter.
Should
R2
BEN-07
A delivery lead can pin or manually override an item's priority with a reason; the override is visible and expires on a date.
Must
R1
BEN-08
The benefits register can be exported to CSV and to Power BI via a read-only dataset.
Should
R2
## 6.7	Automated scheduling
The scheduler turns a prioritised pipeline and a team's capacity into a plan of who does what, when. It respects hard constraints and balances competing goals, and it always explains itself.
ID
Requirement
Priority
Release
SCH-01
The scheduler produces a plan assigning people to work items over working days, honouring: required skills and minimum proficiency, per-person capacity and reserve, leave and availability, dependencies, earliest-start dates, maximum concurrent items and minimum focus blocks.
Must
R1
SCH-02
The scheduler optimises for: value-weighted early completion, meeting needed-by dates, balanced load within the target band, minimal context switching, and minimal change from the current committed plan. Objective weights are configurable and shown.
Must
R1
SCH-03
The scheduler produces a proposal, never a silent change. Proposals are reviewed and committed by an authorised user (see STAB and CHG).
Must
R1
SCH-04
A person can be assigned at a percentage allocation (25% steps by default) to allow pairing and part-time involvement; allocation granularity follows the size class.
Must
R1
SCH-05
Where no feasible assignment exists (skills gap, capacity, dependency), the item is placed on the watch list with the reason and the smallest change that would make it schedulable.
Must
R1
SCH-06
Users can fix an assignment (person, dates or both) and the scheduler plans around it.
Must
R1
SCH-07
Users can drag an assignment in the schedule view; the system shows the knock-on effect before the change is saved and records it as a manual change.
Must
R1
SCH-08
A quick preview (heuristic) returns within 2 seconds for what-if questions; the full optimisation runs as a background job with a configurable time budget.
Must
R1
SCH-09
The scheduler supports three windows: committed (locked), planned (adjustable with guardrails) and indicative (shown as approximate, changes freely).
Must
R1
SCH-10
Incidents consume the affected person's reserve first; if more is needed the scheduler displaces the lowest-priority planned work of that person and proposes the displacement as a change.
Must
R1
SCH-11
Scenarios: a user can create a named what-if scenario (for example add a contractor, drop an item) and compare it with the committed plan before adopting it.
Should
R2
SCH-12
The scheduler can prefer pairing a person with a development target on matching work when the cost to the objective is below a configured threshold.
Should
R2
SCH-13
Multi-team scheduling: items requiring skills from more than one team can be planned across teams within a portfolio.
Could
R3
SCH-14
The scheduler records for each plan version: inputs hash, policy version, objective score, solve time and whether the optimum was proved.
Should
R2
## 6.8	Schedule stability (reducing thrashing)
People cannot deliver if their plan changes every day. These requirements make change deliberate, budgeted, visible and worth it.
ID
Requirement
Priority
Release
STAB-01
A freeze horizon (default 10 working days) locks committed assignments; the scheduler may not move them, and manual changes inside the horizon require a named approver and a reason.
Must
R1
STAB-02
Each moved assignment-day carries a stability cost. The objective function penalises stability cost so that a change is only proposed when the improvement outweighs the disruption.
Must
R1
STAB-03
A change budget limits changes per person per week (default 5 assignment-days). Proposals that exceed the budget are held and shown with the reason.
Must
R1
STAB-04
A minimum improvement threshold (default 5% of objective) applies: proposals below it are shown as information but never applied automatically.
Must
R1
STAB-05
Replanning runs on a cadence (default: propose nightly, commit weekly). Triggers classed as urgent (incident, sickness) can start an immediate cycle limited to the affected people.
Must
R1
STAB-06
Assignments beyond the planning horizon are indicative and displayed as such; changes to them do not count as stability cost or against the change budget.
Must
R1
STAB-07
Each person sees a stability view: changes affecting them in the last 8 weeks and the reasons. Team and workspace views show the stability index trend.
Must
R1
STAB-08
Plan stability index = 1 − (assignment-days changed inside the committed and planned windows ÷ total assignment-days in those windows), rolling four weeks. It is shown on the overview and in reports.
Must
R1
STAB-09
When an item is re-estimated upwards, the default behaviour extends the same assignment rather than re-allocating, unless the extension breaks a needed-by date.
Must
R1
STAB-10
Small incoming work (below a configurable size) is placed into existing gaps within the planned window before any displacement is considered.
Must
R1
STAB-11
The system batches non-urgent triggers until the next scheduled proposal rather than replanning on every edit.
Must
R1
STAB-12
Users can mark an item or a person as "protected" for a period, raising the stability cost of changes involving them.
Should
R2
## 6.9	Change proposals, review and approval
Every proposed change is a small, explainable decision. Reviewers see what moves, why, what it costs and who it affects.
ID
Requirement
Priority
Release
CHG-01
A proposal lists each change as before and after (person, item, dates, allocation), the trigger that caused it, the objective terms it improves, the stability cost and the other people affected.
Must
R1
CHG-02
Reviewers can accept, reject or edit each change individually, or accept all changes that pass guardrails.
Must
R1
CHG-03
Changes held by a guardrail are shown with the guardrail and cannot be accepted without an override permission and a reason.
Must
R1
CHG-04
The proposal shows a before-and-after summary: late items, value landing in the quarter, people over 100%, single-skill dependencies, assignment-days changed and the resulting stability index.
Must
R1
CHG-05
Accepting changes creates a new committed plan version; the previous version remains viewable and restorable.
Must
R1
CHG-06
Affected people are notified before a change takes effect, with the reason, and can comment; the policy can require acknowledgement for changes inside the freeze horizon.
Must
R1
CHG-07
Approval roles are configurable: who may approve changes inside the horizon, who may override guardrails, and whether auto-apply is allowed outside the horizon.
Must
R1
CHG-08
A proposal expires if not reviewed before the next cycle; the next proposal supersedes it and notes what was carried over.
Should
R1
## 6.10	Schedule and overview views
The schedule is the product's centrepiece. It shows people as lanes over time, with certainty encoded visually.
ID
Requirement
Priority
Release
VIEW-01
A schedule view shows a lane per person across a selectable horizon (days, weeks, months) with assignments as blocks coloured by work type, sized by duration and labelled with reference, title and size stamp.
Must
R1
VIEW-02
The committed window is visually distinct and marked with a lock; today is marked; leave and rota appear as hatched blocks; indicative assignments use a dashed style.
Must
R1
VIEW-03
Lane headers show name, role and load percentage for the visible horizon, colour-coded against the target band.
Must
R1
VIEW-04
The view can be filtered by team, work type, skill and item, and grouped by person, item or work type.
Must
R1
VIEW-05
Proposed changes can be overlaid on the schedule with the moved blocks highlighted.
Should
R1
VIEW-06
An overview page shows committed deliveries (items landing in the committed window), team load, stability index, reserve use, pending proposals and a watch list.
Must
R1
VIEW-07
A person page shows current and upcoming assignments, skills, availability, preferences and their personal stability history.
Must
R1
VIEW-08
An item page shows summary, requirements, skills coverage, dependencies, plan facts, estimate, benefits, tasks, schedule and history in tabs.
Must
R1
VIEW-09
Users can export the schedule to PDF and to calendar (iCalendar per person).
Should
R2
## 6.11	Notifications and collaboration
ID
Requirement
Priority
Release
NOT-01
Users receive notifications for: a change proposed that affects them, a change committed, an approval requested, an item assigned, an estimate requested, a benefit realisation due, and a watch-list item they own.
Must
R1
NOT-02
Notification channels are in-app, push (iOS and Android), email digest and Microsoft Teams; each user chooses channels and digest cadence per notification kind.
Must
R2
NOT-03
Urgent notifications (incident displacement, change inside the freeze horizon) bypass digests.
Must
R2
NOT-04
A weekly digest per person summarises next week's plan and any changes since the last digest.
Should
R2
NOT-05
Comments on items and proposals support @mentions and link to the exact change.
Should
R2
## 6.12	Reporting and analytics
ID
Requirement
Priority
Release
REP-01
Reports: plan stability trend, load and utilisation (planned vs actual where timesheets are integrated), estimate accuracy by size and type, delivered items by type per month, cycle time, benefit realisation by quarter, skills demand vs supply.
Must
R2
REP-02
Reports can be filtered by team, period and work type, exported to CSV and PDF, and scheduled by email.
Should
R2
REP-03
A read-only analytics dataset (views) is exposed for Power BI with row-level security matching app permissions.
Should
R3
REP-04
Every metric has an in-app definition (formula, inclusions, exclusions).
Must
R2
## 6.13	Administration, security and audit
ID
Requirement
Priority
Release
ADM-01
Sign-in is through the organisation's identity provider (Microsoft Entra ID) using OpenID Connect; no local passwords.
Must
R1
ADM-02
Roles: Workspace administrator, Delivery lead (approver), Team lead, Team member, Requester, Benefit owner, Viewer. Permissions are documented and enforced server-side.
Must
R1
ADM-03
Users and groups can be provisioned from the directory (SCIM or group sync); leavers are deactivated automatically and their future assignments flagged.
Should
R2
ADM-04
Every create, update, delete, approval and configuration change is audited with actor, time, entity and before/after values; the audit log is searchable and exportable.
Must
R1
ADM-05
Personal data held is limited to name, work email, role, skills, working pattern and availability type (not reason); leave reasons are never stored. A data retention policy removes plan history after a configurable period.
Must
R1
ADM-06
Administrators can manage day rates, skills catalogue, teams, integrations and notification defaults.
Must
R1
ADM-07
Multiple workspaces can exist in one tenancy with separate configuration and data; a user may belong to more than one.
Should
R3
## 6.14	Integrations
Dispatch is the planning layer, not the system of record for tickets, HR or time. Integrations keep it honest without duplicating those systems.
ID
Requirement
Priority
Release
INT-01
Jira and Azure DevOps: import and sync work items by query; map fields to type, size, skills and status; write back planned dates and assignee when configured.
Should
R3
INT-02
ServiceNow: create Incident items automatically from assigned incidents above a severity threshold, with severity mapped to priority.
Should
R3
INT-03
HR or leave system: import approved leave as availability records nightly.
Should
R2
INT-04
Microsoft 365: read out-of-office and all-day events as availability; publish each person's committed assignments to their calendar as an iCalendar feed.
Should
R2
INT-05
Timesheets: import actual effort per item per person to drive estimate accuracy and planned-vs-actual reports.
Could
R3
INT-06
Microsoft Teams: post proposals, approvals and digests to channels and chats; support accept and reject from the card.
Should
R2
INT-07
A public REST API (OpenAPI 3.1) and outbound webhooks for plan committed, change proposed, item status changed.
Should
R2
## 6.15	Mobile (iOS and Android)
Mobile is for the moments away from a desk: seeing your week, acknowledging a change, approving a proposal, capturing a request. Planning at scale stays on the web.
ID
Requirement
Priority
Release
MOB-01
Native apps for iOS (16 and later) and Android (11 and later) with feature parity for: My week, item view, proposal review and approval, add work, notifications, skills and availability self-service.
Must
R2
MOB-02
The schedule lane view is available read-only on tablets and in a simplified per-person form on phones.
Should
R2
MOB-03
Offline: the last synced My week, items and proposals are readable offline; actions taken offline are queued and confirmed on reconnect.
Should
R2
MOB-04
Push notifications through APNs and FCM with deep links into the relevant item or proposal.
Must
R2
MOB-05
Biometric unlock after the identity provider session is established; sessions follow the organisation's conditional access policy.
Must
R2
MOB-06
Platform conventions are respected (navigation, back behaviour, share sheets, dynamic type, dark mode) while keeping one visual identity.
Must
R2
MOB-07
Apps are distributed through the organisation's mobile device management (Intune) as well as the public stores if required.
Must
R2
# 7	Non-functional requirements
ID
Area
Requirement
Priority
NFR-PERF-01
Performance
Pages render the first meaningful content within 1.5 s on the web at the 95th percentile on the corporate network; API reads complete within 300 ms at p95.
Must
NFR-PERF-02
Performance
Heuristic preview completes within 2 s for a workspace of 50 people and 500 open items; full optimisation completes within its configured budget (default 60 s) and always returns the best plan found.
Must
NFR-PERF-03
Performance
The schedule view renders 50 lanes over 26 weeks without visible lag when scrolling or zooming.
Must
NFR-SCAL-01
Scale
A workspace supports at least 200 people, 5,000 open items and 24 months of plan history; a tenancy supports at least 20 workspaces.
Should
NFR-AVAIL-01
Availability
99.5% monthly availability for the web app and API during business hours; scheduled maintenance outside 07:00 to 19:00 UK time.
Must
NFR-AVAIL-02
Recovery
Recovery point objective 1 hour, recovery time objective 4 hours, with geo-redundant backups in a second UK region.
Must
NFR-SEC-01
Security
Single sign-on through Entra ID with conditional access; all traffic TLS 1.2 or later; data encrypted at rest with platform-managed keys, customer-managed keys as an option.
Must
NFR-SEC-02
Security
Role-based access enforced in the API; row-level tenancy by workspace; OWASP ASVS level 2 verified before go-live; dependency and container scanning in the pipeline.
Must
NFR-SEC-03
Security
Secrets in Azure Key Vault; no secrets in code or configuration files; managed identities between services.
Must
NFR-DATA-01
Data
All data stored and processed in the UK. Personal data minimised as set out in ADM-05; a data protection impact assessment is completed before pilot.
Must
NFR-DATA-02
Data
Full audit trail retained for 7 years; plan versions retained for 24 months by default and configurable.
Must
NFR-ACC-01
Accessibility
WCAG 2.2 AA on web and mobile: keyboard operable schedule, visible focus, colour never the only carrier of meaning (stamps and labels accompany colour), text scales to 200%, reduced motion respected.
Must
NFR-USE-01
Usability
A new team member can find their week and acknowledge a change without training; a delivery lead can complete the weekly review in under 20 minutes for a team of 10.
Must
NFR-OBS-01
Operability
Structured logs, traces and metrics for every service; dashboards for solver duration, proposal acceptance rate, sync failures; alerts on error budgets.
Must
NFR-OBS-02
Operability
Every plan version is reproducible from its stored inputs and policy version.
Should
NFR-MAINT-01
Maintainability
Infrastructure defined in Terraform; environments (dev, test, pilot, production) created from the same definitions; blue-green deployment with automatic rollback on health-check failure.
Must
NFR-COMP-01
Compatibility
Web: current and previous major versions of Edge, Chrome, Firefox and Safari. Mobile: iOS 16+, Android 11+.
Must
NFR-I18N-01
Localisation
British English by default; dates, currency and working week configurable per workspace; the UI is translation-ready.
Should
# 8	Scheduling engine design
## 8.1	Overview
The engine has two planners behind one interface. A constraint solver (Google OR-Tools CP-SAT) produces the nightly proposal and any full replan, with a time budget of 60 seconds by default and a warm start from the current committed plan. A greedy heuristic answers interactive questions in under two seconds: what happens if this item is added, if this person is away, if this assignment is dragged. Both share the same model, constraints and objective so that a preview is a faithful approximation of what the solver will do.
The engine never edits the committed plan. It produces a candidate plan, diffs it against the committed plan, and emits a proposal of changes. Guardrails then decide which changes may be applied automatically, which need approval and which are merely shown.
Figure 2: The scheduling and replan cycle. Inputs feed a model, the solver proposes, the diff is costed, guardrails filter, a person commits.
## 8.2	Time model
- Time is divided into working days from the workspace working week. Each person has capacity per day in hours, derived nightly from working pattern minus availability records minus reserve.
- Assignments are placed at the granularity of the item's size class: half days for Small, days for Medium, weeks for Large and Custom. This keeps the model small and stops the solver fragmenting large work into slivers.
- The horizon is split into three windows from today: committed (freeze horizon, default 10 working days), planned (to the planning horizon, default 4 weeks) and indicative (to the end of the modelled horizon, default 26 weeks).
## 8.3	Inputs
Input
Source
Used for
Open work items with type, size or effort, status, needed-by, earliest-start, dependencies
Work service
What to schedule and in what order
Required skills with minimum proficiency and effort split
Work service
Who is eligible and how much of each skill is needed
Latest estimate (P80 or most likely per policy) and remaining effort from progress
Work service
How much work is left
Priority score and manual overrides
Work service
Objective weights per item
People, proficiency, working pattern, maximum concurrent items, minimum focus block, preferences
People service
Eligibility and soft preferences
Capacity per person per day including reserve and rota
People service (derived)
Hard capacity constraint
Current committed plan with locks and progress
Plan service
Baseline for stability cost and warm start
Scheduling policy and objective weights
Workspace configuration
Guardrails and objective
Triggers since the last cycle
Event bus
Scope of an urgent cycle; explanation of changes
## 8.4	Priority score
Every planned item has a score from 0 to 100, recomputed nightly and on edit. The weights are configurable per workspace; the defaults are below. The score is shown on the item with each term so that it can be challenged.
Term
Default weight
Definition
Value
40
Sum of benefit annual values scaled by confidence (High 1.0, Medium 0.7, Low 0.4), normalised against the 90th percentile of values in the workspace, capped at 1.
Urgency
25
Rises as the needed-by date approaches, relative to the remaining effort: 0 when slack is more than eight weeks, 1 when the item is already late.
Risk and compliance
15
A stated risk or compliance weight (0 to 1) on the item, defaulting from the benefit type.
Dependency leverage
10
Share of the total value of items this item unblocks, normalised as for Value.
Age
10
Time since the item was Ready, saturating at 12 weeks, so that old small work eventually surfaces.
Override
Additive
A delivery lead can pin a score or add or subtract up to 20 points with a reason and expiry.
Interrupt-driven items (Incidents by default) take a score from severity (P1 100, P2 90, P3 70, P4 50) and skip the benefit case.
## 8.5	Hard constraints
- Skills. A person may only be assigned to an item if they meet the minimum proficiency for each skill they will spend effort on; when effort is split by skill, at least one assigned person must meet each skill.
- Capacity. Assigned effort per person per day may not exceed capacity minus reserve. Reserve may only be consumed by interrupt-driven items.
- Availability. No assignment on days with zero capacity (leave, training, non-working days).
- Dependencies. A finish-to-start dependency prevents work starting before its predecessor's planned finish; soft dependencies are a penalty.
- Earliest start and locks. No assignment before the earliest-start date; locked assignments (fixed by a user or inside the freeze horizon) are kept exactly.
- Concurrency. No more than the person's maximum concurrent items on any day (sizes below the WIP threshold do not count).
- Focus blocks. When an item is worked on, it is worked on for at least the minimum consecutive days (default 2) unless the remaining effort is smaller.
- Completeness. An item is either fully scheduled to completion or left unscheduled and reported; partial plans are not silently truncated.
## 8.6	Objective
The solver minimises a weighted sum. Weights are configurable; the defaults reflect the pilot team's priorities and can be tuned during discovery.
Term
Default weight
Meaning
Value-weighted completion
1.0
Sum over items of priority score × completion week; earlier completion of high-score items is better.
Lateness
3.0
Sum over items of working days finished after the needed-by date, weighted by priority score.
Unscheduled value
5.0
Priority score of items left unscheduled inside the planning horizon.
Load imbalance
0.5
Deviation of each person's weekly load from the target band (80 to 90%).
Context switching
0.5
Number of item switches per person per week beyond one.
Stability
2.0 planned, locked committed
Assignment-days moved relative to the committed plan, inside the planned window. Committed-window moves are hard-locked unless a user unlocks them. Indicative moves cost nothing.
Preferences
0.2
Assignments against a person's stated avoid list; bonus for development pairing.
## 8.7	Stability model
Stability is enforced in three places so that no single mechanism has to carry it.
- Inside the solver. The stability term charges 2.0 (default) per assignment-day moved inside the planned window and locks the committed window. The solver therefore only moves planned work when the improvement elsewhere is larger than the disruption.
- In the guardrails. After the diff, each change is checked: inside the freeze horizon requires an approver; changes exceeding the per-person change budget are held; a proposal whose total improvement is below the minimum threshold is shown but not applied. Guardrails are evaluated per change and per proposal.
- In the cadence. Non-urgent triggers are batched to the nightly proposal; commits happen weekly by default. Only incidents and sickness start an immediate cycle, and that cycle is scoped to the affected people so that the rest of the team's plan is untouched.
Three behaviours reduce the need for change in the first place. Small work is filled into existing gaps before anything is displaced (STAB-10). An upward re-estimate extends the same assignment rather than re-allocating (STAB-09). Work beyond the planning horizon is indicative and is not shown to people as a commitment (STAB-06), so the solver is free to optimise the far future without anyone experiencing it as churn.
## 8.8	Solver formulation (sketch)
The CP-SAT model uses integer variables for allocation in quarter-days: a[i,p,t] is the effort of person p on item i in bucket t (a day or a week according to the item's granularity). Boolean w[i,p,t] indicates any work, s[i] and f[i] are start and finish buckets, and u[i] marks an unscheduled item.
- Effort: Σ_p,t a[i,p,t] = remaining[i] × (1 − u[i]) for each item.
- Capacity: Σ_i a[i,p,t] ≤ capacity[p,t] − reserve[p,t] for planned items; incidents may use reserve.
- Skills: a[i,p,t] = 0 where p does not meet the minimum for i.
- Concurrency: Σ_i w[i,p,t] ≤ maxConcurrent[p] for counted sizes.
- Dependencies: s[j] ≥ f[i] + 1 for finish-to-start pairs.
- Locks: a[i,p,t] = committed[i,p,t] for buckets inside the freeze horizon or fixed by a user.
- Focus: w[i,p,t] − w[i,p,t−1] ≤ w[i,p,t+1] for minimum two-day blocks (generalised for longer minima).
- Stability: m[i,p,t] ≥ |a[i,p,t] − committed[i,p,t]| in the planned window; the objective adds weight × Σ m.
The solver is warm-started from the committed plan so that the first feasible solution is the current plan and every improvement found is a genuine improvement. The solve runs with a time budget and returns the best solution found, flagged as optimal or not. Model size is kept manageable by only creating variables for eligible person-item pairs, by using weekly buckets for Large items, and by excluding items whose earliest start is beyond the planning horizon (they are placed heuristically in the indicative window).
## 8.9	Heuristic planner
The heuristic is list scheduling: items in descending priority score, each placed at the earliest feasible slot with the best-fit eligible person (highest proficiency, lowest load, preference match), respecting the same hard constraints. It fills gaps before extending the horizon and never moves committed work. It is used for interactive previews, for the indicative window and as a fallback if the solver finds no solution within budget. Its result is always reported as a preview.
## 8.10	Replan cycle and triggers
Trigger
Class
Behaviour
New item made Ready
Batched
Included in the next nightly proposal; Small items may fill gaps in the planned window.
Estimate changed
Batched
Extend the same assignment if the needed-by date holds; otherwise propose the smallest displacement.
Leave or availability added
Batched (urgent if within the freeze horizon)
Recompute capacity; extend or move affected assignments.
Incident raised
Urgent
Immediate cycle scoped to the rota person; consume reserve, then displace lowest-priority planned work.
Sickness
Urgent
Immediate cycle scoped to the person; propose cover for committed work only.
Dependency cleared early
Batched
May pull dependent work forward if no one else is affected.
Item delivered
Batched
Release remaining effort; fill the freed capacity from the queue.
Policy or weights changed
Manual
Administrator chooses whether to run a full replan.
## 8.11	Explainability
Every change in a proposal carries: the trigger or triggers that caused it, the objective terms that improved and by how much, the stability cost in assignment-days, the people and items affected downstream, and the guardrail status. The explainer renders this in plain language, for example: "Amira starts WI-1033 two days later. Frees capacity for INC-4471 handover while Ravi is at 104%. Stability cost 2 days; due date unchanged; inside the freeze horizon so needs your approval." The before-and-after summary shows late items, value landing in the quarter, people over 100%, single-skill dependencies, assignment-days changed and the resulting stability index.
## 8.12	Worked example
Sunday 6 September: a P2 incident (INC-4471) is assigned to the team. Ravi is on the incident rota with a 25% reserve, about 1.25 days for the week. The incident is sized Medium (3 to 6 days).
- The urgent cycle runs for Ravi only. The reserve covers 1.25 days; the rest of the most-likely estimate (about 3 days) must come from planned work.
- Ravi's lowest-priority planned item in the planned window is WI-1052 Monitoring alerts (score 41). The engine proposes moving it back four days. Stability cost: 4 assignment-days, inside the planned window, so it needs approval.
- The engine also notices that Amira, who has SQL at level 4, could take the handover on Wednesday if WI-1033 starts two days later, and that Lena can cover WI-1033 on those days. It proposes this as a second change because it reduces the risk of WI-1042 slipping (score 78) at a stability cost of 2 days.
- Monday morning the lead sees two changes with reasons, accepts both from the phone, and both people see the change and the reason before 09:00. The plan stability index for the week records 6 moved assignment-days out of 365.
## 8.13	Edge cases and policies
Situation
Behaviour
No eligible person for a skill
Item goes on the watch list with the skill, the level and the closest people; the engine suggests pairing a level-2 person with the single level-3 person as development.
Item cannot finish by needed-by even with all capacity
Item is scheduled at earliest possible finish, flagged late, and the lead is shown the options: add capacity, descope, or move the date.
Person over 100% after an incident
Shown on the watch list; planned work is displaced only through an accepted proposal, never silently.
Two items competing for the same scarce skill
Priority score decides; the loser is shown with the score gap so the decision can be challenged.
Estimate class too poor near the horizon
Policy can require re-estimation before the item enters the committed window (EST-09).
Solver time-out
Best solution found is used and marked not proved optimal; the heuristic result is offered for comparison.
Conflicting manual edits
Manual edits are changes like any other, recorded, costed and included in the next diff; the last committed version wins and can be restored.
# 9	User experience design
## 9.1	Design principles
- The plan is a promise. Committed work looks committed: locked, solid, labelled. Planned work looks adjustable. Indicative work looks approximate (dashed, hatched). Certainty is encoded visually, not explained in a tooltip.
- Nothing changes silently. Every change is shown as before and after, with its reason and its cost, to the person it affects, before it takes effect.
- Show the cost of change. Stability cost, change budget and the stability index are on the surface, not buried in a report.
- Size is a stamp. Size classes are shown as parcel-style stamps (S, M, L, C) that read at a glance in tables, lanes and on a phone.
- Delivery vocabulary, plain words. What is landing, lanes per person, load, reserve. No jargon that a requester would not understand.
- One identity, three surfaces. Web for planning at scale; iOS and Android for the moments away from a desk. Same colours, type, stamps and language; platform conventions respected.
## 9.2	Visual identity: themed around delivery
The look draws on the world of delivery and logistics without pastiche: the delivery board listing what is being delivered, lanes that work travels along, a loading bay where committed consignments are locked, parcel stamps for size, and a signal orange used sparingly for the one action that matters on each screen.
Token
Value
Use
Ink navy
#16284D
Navigation, headings, primary text, committed markers, size stamps
Navy 2
#1F3A5F
Secondary headings, active navigation
Surface
#F3F5F9 / #FFFFFF
Application background / panels and cards
Dispatch orange
#F28C28
Primary action on each screen, in-progress state, today marker, changed blocks
Delivered green
#1F9D6B
On track, covered, realised
Amber
#D99A00
At risk, needs attention, held changes
Signal red
#C8102E
Incidents, blocked, demand exceeds supply
Work type colours
Blue #3B6BD6, Teal #178F8A, Red #C8102E, Violet #6D5BD0
Project, Small change, Incident, Service request (configurable)
Type
Manrope for headings and numbers; Inter for interface text; system fonts on mobile as a fallback
Manrope gives figures and titles a confident, geometric voice; Inter keeps dense tables legible
Shape
Panels 14 px, cards 10 px, buttons 8 px, chips 6 px radius; 1 px borders, shadows only on floating elements
Hierarchy through radius and border, not shadow
Colour is never the only carrier of meaning: every coloured chip has a label, every lane block has a text label and a size stamp, and every status has an icon or word. Contrast meets WCAG 2.2 AA on all foreground and background pairs above.
## 9.3	Information architecture
Area
Web navigation
Mobile tab
Purpose
Overview
Overview
My week (personal)
Committed deliveries, load, stability, reserve, pending proposals, watch list
Pipeline
Pipeline
Pipeline
All work; intake; estimates and benefits per item
Schedule
Schedule
More › Schedule (read-only)
Lanes per person; drag to adjust; overlay proposals
Changes
Changes
Changes
Review and commit proposals; personal change history
Team & skills
Team & skills
More › My profile
Matrix, people, availability, rota, development
Estimates
Estimates
Within item
Three-point estimation, calibration, similar work
Benefits
Benefits
Within item
Register, realisation, value by type
Reports
Reports
More › Reports (summary)
Stability, utilisation, accuracy, delivered, benefits
Settings
Settings
More › Notifications
Work types, sizes, policy, skills, roles, integrations
## 9.4	Web screens
### 9.4.1	Overview
Figure 3: Overview: committed deliveries for the committed window, four headline measures, pending proposals and the watch list.
The overview opens on what is landing. The committed deliveries list shows items due in the next ten working days with type, size stamp, people, due date and status. Four measures sit above it: committed deliveries, team load against the target band, the plan stability index and how much of the incident reserve has been used. The right column holds the proposals waiting for review and the watch list of things the scheduler cannot fix alone, each with a concrete suggestion. The primary action, in orange, is to propose a replan now; the pill in the header shows when the next proposal will run.
### 9.4.2	Pipeline
Figure 4: Pipeline: every item with type, size stamp, priority score, benefit, estimate range, required skills and status.
The pipeline is a dense, sortable table with filters for status, type, size, skill and team. The priority score is a bar and a number so that ordering is visible without reading. Required skills are chips, truncated with a count. Items with a Custom size show the C stamp with a dashed border; a footer explains it. Import from Jira, column choice and Add work are the toolbar actions.
### 9.4.3	Work item
Figure 5: Work item: summary, required skills with team coverage, dependencies, plan facts, three-point estimate and benefit breakdown.
The item page answers the questions a requester and an engineer both have: what is it, who can do it, what does it depend on, when is it planned, how big is it and why is it worth doing. Skills coverage is computed over the planned window and flags a single point of failure with an amber chip. The estimate card shows optimistic, most likely and pessimistic with the PERT expected value and cost; the benefit card shows annual value, payback and the breakdown by type.
### 9.4.4	Schedule
Figure 6: Schedule: lanes per person over six weeks, committed window locked, today marked, indicative work hatched, leave shaded.
The schedule is the centrepiece. Each person is a lane; each assignment is a block with a coloured rail for work type, a title and a size. The committed window is tinted and edged with a lock; today is an orange line; leave is hatched grey; work beyond the planning horizon is dashed and hatched to read as indicative. Lane headers carry load for the visible horizon, red when over 100%. Blocks can be dragged; the knock-on effect is previewed before saving and recorded as a manual change. A footer shows the next unscheduled candidates by priority.
### 9.4.5	Proposed changes
Figure 7: Proposed changes: each change as before and after with reason, stability cost and impact; guardrails and a before-and-after summary on the right.
Each change is a card: who, what, before and after, why, and its impact as chips (stability cost, due date effect, skills risk, approval needed). Accept, reject or edit per change; accept all that pass guardrails from the header, where the change budget is shown as a meter. A change held by a guardrail is dimmed and explains which guardrail held it. The right column explains why the plan changed (the triggers), summarises before and after, and lists the guardrails in force.
### 9.4.6	Team and skills
Figure 8: Team and skills: proficiency matrix, people at Independent or above per skill, demand for each skill, availability and development plans.
The matrix uses a five-step proficiency scale with a consistent square glyph so the pattern of strength and gaps is visible from across the room. Footer rows count people at level 3 or above per skill and show demand over the next six weeks, colouring skills that rely on one person in red. Below are the next four weeks of availability, development targets that the scheduler can use for pairing, and demand against qualified supply.
### 9.4.7	Person
Figure 9: Person: load, concurrency, personal change history and rota; assignments, skills, working pattern and preferences.
A person's page shows their load and concurrency against their own limits, their plan changes over eight weeks against the team median, their current and upcoming assignments with the incident reserve shown explicitly, their skills with endorsements and any single-point flags, and the working pattern and preferences the scheduler respects.
### 9.4.8	Estimate
Figure 10: Estimate: three-point method with PERT and P80, effort by skill, estimate class and cost, calibration from delivered work, similar items and version history.
The estimate screen supports size-class-only, three-point and task roll-up methods. Three-point inputs produce the expected value, standard deviation, P80 and the implied size class. Effort by skill is a stacked bar that drives the skills the scheduler must match. The class selector explains what each class means; cost is derived from a versioned day rate. Calibration shows how the team's estimates have landed by size and recommends planning at P80 where Large work has run over. Similar delivered items can be copied as a starting point.
### 9.4.9	Benefits
Figure 11: Benefits: register with type, value, confidence, realisation start and status; realisation by quarter and value by type.
The register totals value in plan, realised to date and at risk, and lists benefits with confidence as three dots. Realisation by quarter compares planned with owner-confirmed realised value. A note explains how benefit value feeds the priority score and how confidence scales it.
### 9.4.10	Settings: work types and size classes
Figure 12: Settings: rename, recolour and reorder work types; set per-type policy; define size bands, planning values and granularity; add a size.
Work types are a reorderable list with colour, prefix, count and policy. Renaming is a form with display name, plural, prefix and colour, plus toggles for whether an estimate or a benefit case is required and whether the type is interrupt-driven. Size classes are a table of bands in days with planning value, default estimate class, granularity and whether the size counts towards the WIP limit; bands are validated not to overlap; incidents can override the bands in hours.
### 9.4.11	Reports
Figure 13: Reports: plan stability trend, load and utilisation against the target band, estimate accuracy by size, delivered items by type.
Reports are deliberately few and each has an in-app definition. The stability trend annotates when the freeze horizon was introduced. Utilisation compares planned with actual where timesheets are integrated. Estimate accuracy plots estimated against actual days with the parity line; Large and Custom items are coloured separately because they behave differently.
## 9.5	Mobile screens
The mobile apps are built for four moments: seeing your week, reading an item, deciding on a change and capturing a request. A bottom tab bar (My week, Pipeline, Changes, More) keeps them one tap away. Cards, stamps and chips are the same as the web; type sizes and touch targets follow iOS Human Interface Guidelines and Material 3 respectively, with dynamic type and dark mode supported.
Figure 14: My week: day strip, a change that affects you, today's assignments with progress, the incident reserve, what is coming up and your load.
Figure 15: Work item on mobile: status chips, plan facts, required skills with coverage, dependencies, and actions.
Figure 16: Changes on mobile: change budget and stability at the top; each change as before and after with reason, chips and accept or reject.
Figure 17: Add work: type and size pickers using the configured names and stamps, needed-by, benefit, required skills and a readiness note.
### 9.5.1	Platform behaviour
- Navigation: native stack navigation with system back behaviour; the tab bar is hidden on deep forms.
- Offline: My week, items and proposals are cached; Accept, Reject, Acknowledge and Add work are queued when offline and confirmed with a toast on reconnect.
- Push: deep links open the exact item or proposal; urgent notifications use a distinct sound category that users can control.
- Security: sign-in through the identity provider in a system browser; biometric unlock for the app session; no personal data stored beyond the cache, which is encrypted at rest.
- Tablets: the schedule lane view is available read-only in landscape.
## 9.6	Accessibility and inclusive design
- WCAG 2.2 AA throughout. Every interactive element is keyboard reachable with a visible focus ring; the schedule supports arrow-key movement between blocks and keyboard drag with announced results.
- Colour never carries meaning alone: stamps, labels and icons accompany colour; work-type colours are chosen to remain distinguishable under common colour vision deficiencies.
- Text scales to 200% without loss of function; tables become stacked cards below 800 px on the web.
- Motion is limited to responses to a person's action (opening, confirming) and respects reduced-motion settings.
- Copy is plain British English in sentence case; actions say what they do (Accept, Reject, Add to pipeline) and keep the same name through a flow.
## 9.7	Copy and empty states
Interface copy is part of the design. Empty screens invite action ("No work is scheduled for Priya this week. Propose a replan or add work."). Errors say what went wrong and what to do ("This size band overlaps Medium. Change the start of Large to 16 days or the end of Medium to 15."). Guardrail messages name the rule and the way through ("Inside the freeze horizon. Ask a delivery lead to approve, or move the start to Monday 21 September.").
# 10	Technical architecture
## 10.1	Overview
Figure 18: System architecture: three clients over one API; core services; a separate scheduling engine; PostgreSQL, Redis and Service Bus; integrations at the edge.
Dispatch is a set of small services behind one API, deployed to the organisation's Azure tenancy in the UK. Clients are a React web app (installable as a progressive web app) and a single React Native codebase for iOS and Android, sharing TypeScript packages for domain types, the generated API client, validation and design tokens. The scheduling engine is a separate Python service so that the solver can scale and be tuned independently. PostgreSQL is the system of record. Events flow over Service Bus for solver jobs, notifications and outbound sync.
## 10.2	Clients
Concern
Decision
Rationale
Web framework
React 19 with TypeScript, Vite, TanStack Query and Router, Zustand for local state
Mature, well known in the team, excellent tooling; server state cached and invalidated by query keys
Schedule rendering
Virtualised lanes with CSS grid for day columns; canvas fallback above 100 lanes
Smooth at 50 lanes × 26 weeks; accessible DOM for the common case
Mobile
React Native with Expo (managed workflow), Expo Router, React Native Reanimated
One codebase for iOS and Android; shares domain and API packages with the web; over-the-air updates for non-native changes
Shared packages
pnpm monorepo: @dispatch/domain, @dispatch/api-client (generated from OpenAPI), @dispatch/tokens, @dispatch/validation
Single source of truth for types and rules; design tokens exported to CSS variables and to React Native styles
Offline
Persisted query cache and an outbox of mutations replayed with idempotency keys
Read anywhere; safe replay of approvals and intake
Authentication
MSAL (web) and Expo AuthSession with PKCE (mobile) against Entra ID; tokens held in secure storage
Organisation standard; conditional access honoured
Accessibility
Radix primitives on web; React Native Accessibility API; automated axe checks in CI
AA compliance verified continuously
## 10.3	Backend services
Service
Responsibilities
Notes
Work service
Work types, size classes, work items, tasks, dependencies, skill requirements, estimates, benefits, priority scoring
.NET 9 minimal API or NestJS (team choice at discovery); EF Core or Prisma; owns the WorkItem aggregate
People service
People, teams, skills catalogue, proficiency, availability, rota, working patterns, derived capacity
Nightly capacity derivation job; HR and calendar imports land here
Plan service
Plan versions, assignments, proposals, changes, guardrails, approvals, locks, stability metrics
Orchestrates solver jobs; owns the diff and guardrail logic so the solver stays pure
Scheduling engine
Model building, CP-SAT solve, heuristic preview, explanation
Python 3.12, OR-Tools, FastAPI; horizontally scaled workers consume jobs from Service Bus; 60 s default budget
Reporting service
Read models for reports and the Power BI dataset
Materialised views refreshed nightly and on plan commit
Integration service
Connectors, field mapping, sync schedules, webhooks
One adapter per system; sync state and error queues visible to administrators
Notification service
Notification rules, digests, channels (in-app, push, email, Teams)
Azure Notification Hubs for APNs and FCM; Graph API for Teams
API gateway
Routing, authentication, rate limits, OpenAPI publication
Azure API Management; one versioned API (v1) for all clients
## 10.4	Scheduling engine service
- A solve job is created by the Plan service with a snapshot of inputs and the policy version. Workers pick jobs from Service Bus; a job is idempotent by inputs hash.
- The worker builds the CP-SAT model, warm-starts from the committed plan, solves within budget, and returns the candidate plan plus solver statistics. The Plan service performs the diff and guardrail evaluation and stores the proposal.
- The heuristic runs in the same service behind a synchronous endpoint with a 2-second budget for previews.
- Solver parameters (workers, time budget, weights) are configuration; every proposal records them for reproducibility.
- Golden datasets with known-good plans run in CI to catch regressions in constraints or objective behaviour.
## 10.5	Data model
Figure 19: Logical data model grouped by configuration, work, people and capacity, and planning.
Entity
Key fields
Notes
Workspace
id, name, timeZone, workingWeek, policy defaults
Tenancy boundary; all entities carry workspaceId
WorkType
name, plural, prefix, colour, policy (planned | interrupt), requiresEstimate, requiresBenefit, sortOrder
Configurable vocabulary
SizeClass
name, stamp, minDays, maxDays, planningDays, defaultEstimateClass, granularity, countsForWip, isCustom, workTypeId (optional override)
Bands validated not to overlap per scope
SchedulingPolicy
freezeHorizonDays, planningHorizonWeeks, changeBudget, minImprovementPct, incidentReservePct, rotaReservePct, cadence, maxConcurrent, minFocusDays, objective weights
Versioned; plan versions reference the version used
WorkItem
ref, workTypeId, sizeClassId, customEffortDays, title, summary, tags, status, priorityScore, priorityOverride, requestedBy, sponsor, neededBy, earliestStart
Aggregate root for tasks, requirements, estimates, benefits
Task
workItemId, title, sizeClassId, effortDays, sequence, status
Roll-up to item
Dependency
fromWorkItemId, toWorkItemId, type (finishStart | soft)
Cycle detection on save
SkillRequirement
workItemId, skillId, minProficiency, effortDays
Drives eligibility and effort by skill
Estimate
workItemId, version, method, optimistic, likely, pessimistic, estimateClass, dayRate, assumptions, authorId
Latest version used for planning
Benefit
workItemId, type, annualValue, currency, confidence, realisationFrom, ownerId, status, realisedValue
Feeds priority score and register
Team, Person
name, role, teamId, daysPerWeek, pattern, maxConcurrent, minFocusDays, preferences
Person links to directory object id
Skill, PersonSkill
name, category; proficiency, endorsedBy, certified, developmentTarget
Catalogue and matrix
Availability, CapacityDay
personId, from, to, type, source; personId, date, availableHours, reserveHours
CapacityDay derived nightly
PlanVersion
status, generatedAt, generatedBy, policyVersion, inputsHash, objectiveScore, stabilityCost, solverStats
Immutable once committed
Assignment
planVersionId, workItemId, personId, from, to, allocationPct, state (committed | planned | indicative), lockedUntil, fixedBy
Unit of the plan
ChangeProposal
planVersionId, personId, workItemId, before, after, reason, triggerIds, stabilityCostDays, guardrailStatus, decision, decidedBy, decidedAt
Reviewed individually
ReplanTrigger, AuditEvent, Notification
type, occurredAt, sourceId; actorId, action, entity, before, after; personId, kind, payload, channel, readAt
Operational records
## 10.6	API design
- REST over HTTPS, JSON, OpenAPI 3.1 published from code; version in the path (/v1). Resources: /work-types, /size-classes, /work-items, /tasks, /dependencies, /estimates, /benefits, /people, /skills, /availability, /plans, /proposals, /changes, /reports, /settings.
- Cursor pagination, field filtering and sparse fieldsets for list endpoints; ETags for optimistic concurrency on edits.
- Idempotency keys on all mutating requests so that offline replays are safe.
- Long-running operations (solve, import) return a job resource with status and result links; clients poll or subscribe over a server-sent events stream.
- Webhooks: plan.committed, proposal.created, change.decided, workitem.statusChanged; signed with a shared secret and retried with back-off.
- Errors follow RFC 9457 problem details with a stable code, a human message in British English and a link to help.
## 10.7	Security
Role
Can
Viewer
Read schedule, pipeline, team and reports for their workspace
Requester
Viewer plus add work, edit own items while Draft, comment
Team member
Requester plus edit own profile, skills and availability; log progress; acknowledge changes
Benefit owner
Team member plus create and update benefits they own; confirm realised value
Team lead
Team member plus endorse skills, manage rota and availability for the team, estimate items
Delivery lead (approver)
Team lead plus review and commit proposals, approve changes inside the freeze horizon, fix assignments, override priority with reason
Workspace administrator
Delivery lead plus configure work types, sizes, policy, weights, roles, integrations; read audit log; override guardrails with reason
- Authentication through Entra ID (OIDC, PKCE); group claims map to roles; SCIM or group sync deactivates leavers.
- Authorisation enforced in the API on every request; row-level tenancy by workspaceId; no client-side-only checks.
- Data in transit TLS 1.2 or later; at rest AES-256 with platform-managed keys, customer-managed keys optional. Secrets in Key Vault; services use managed identities.
- Personal data is minimised (ADM-05): availability records carry a type, never a reason; leave imports strip descriptions. A data protection impact assessment precedes the pilot.
- Audit of every mutation with before and after; audit events are append-only and exported to the organisation's log platform.
- Security testing: dependency and container scanning in CI, static analysis, OWASP ASVS level 2 assessment before go-live, annual penetration test.
## 10.8	Hosting, environments and operations
- Azure UK South with UK West for recovery; Azure Container Apps for services, Azure Database for PostgreSQL Flexible Server (zone-redundant, geo-backup), Azure Cache for Redis, Service Bus, Notification Hubs, API Management, Static Web Apps for the web client.
- Environments: development, test, pilot and production, created from the same Terraform; per-environment configuration through Key Vault and App Configuration.
- CI/CD with GitHub Actions or Azure Pipelines: build, test, scan, deploy blue-green with health checks and automatic rollback. Mobile builds through Expo Application Services, distributed via Intune and, if required, the public stores.
- Observability with OpenTelemetry to Application Insights and Log Analytics: traces across gateway, services and solver; dashboards for solver duration, proposal acceptance rate, sync failures, error budgets.
- Backups: point-in-time restore for 35 days, geo-redundant; quarterly restore test. RPO 1 hour, RTO 4 hours.
## 10.9	Integrations
System
Direction
Data
Mechanism
Cadence
Jira / Azure DevOps
Both
Items by query; planned dates and assignee written back
REST APIs, field mapping, sync rules
15 minutes; on demand
ServiceNow
Inbound
Assigned incidents above severity threshold
Webhook or polling of the assignment group
Real time
HR / leave
Inbound
Approved leave as availability (type only)
Scheduled export or API
Nightly
Microsoft 365
Both
Out-of-office and all-day events in; committed assignments out as iCalendar
Microsoft Graph
Hourly; feed on demand
Microsoft Teams
Outbound with actions
Proposals, approvals, digests; accept or reject from cards
Graph and adaptive cards
Real time
Timesheets
Inbound
Actual effort per item per person
CSV or API
Weekly
Power BI
Outbound
Read-only analytics views with row-level security
PostgreSQL views or dataset export
Nightly
# 11	Delivery roadmap
Delivery is phased so that the pilot team gets value early and the riskiest element, the optimiser and its stability behaviour, is tuned against real data before it is trusted. Estimates below follow the product's own approach: ranges with an estimate class, to be refined in discovery.
Phase
Scope
Duration (optimistic / likely / pessimistic)
Exit criteria
0 · Discovery
Baseline planning time and stability with the pilot team; agree work types, size bands, policy defaults, objective weights, skills catalogue; DPIA; architecture decisions; design validation with click-through prototype.
3 / 4 / 6 weeks
Signed-off requirements and policy defaults; team can describe the plan windows and guardrails in their own words
1 · MVP (R1, web)
Configuration (CFG), pipeline and intake (PIP, REQ), team and skills (TEAM), estimates and benefits capture (EST, BEN core), heuristic scheduling and manual planning (SCH core), stability guardrails (STAB), proposals and approval (CHG), schedule and overview (VIEW), admin and audit (ADM).
10 / 12 / 16 weeks
Pilot team plans weekly in Dispatch; spreadsheets retired; stability index measured
2 · Optimiser, value and mobile (R2)
CP-SAT solver with tuned weights, scenarios, calibration and P80 planning, benefit realisation, reports (REP), notifications (NOT), iOS and Android apps (MOB), HR leave and calendar integrations.
8 / 10 / 14 weeks
Proposal acceptance rate above 70%; stability index above 90%; apps in use by all team members
3 · Integrations and portfolio (R3)
Jira or Azure DevOps and ServiceNow connectors, Teams actions, timesheets, Power BI dataset, multi-team and portfolio views, multiple workspaces.
8 / 10 / 14 weeks
Second team onboarded without engineering involvement
4 · Continuous
Tuning, additional connectors, forecasting, capacity scenarios for hiring decisions.
Ongoing
Quarterly review of objectives and measures
## 11.1	Team shape
- Product owner (delivery lead of the pilot team, part time), one designer (phases 0 to 2), one tech lead, two full-stack engineers (TypeScript), one Python engineer for the solver (phases 1 to 2), one mobile engineer (phase 2), one platform engineer part time for Azure, and QA embedded.
- Indicative build effort for phases 0 to 2: 540 / 680 / 920 person-days (estimate class 4, ±40%), to be re-estimated at the end of discovery with a task roll-up.
## 11.2	Pilot approach
- Run Dispatch alongside the existing spreadsheet for two weeks, importing the current plan as the first committed version.
- Switch to Dispatch as the single plan; measure stability, planning time and acceptance rate weekly.
- Tune objective weights and guardrail defaults with the team at each weekly review for six weeks; freeze the configuration; measure for a further six weeks against the objectives in section 2.
# 12	Risks, assumptions and dependencies
Risk
Likelihood
Impact
Mitigation
The optimiser produces plans that look wrong to people and loses trust
Medium
High
Explainability on every change; proposals not changes; heuristic first in R1 so people learn the model before the solver is trusted; weights tuned with the team
Stability guardrails make the plan too rigid and incidents are handled outside the tool
Medium
Medium
Incident reserve and urgent scoped cycles; per-workspace tuning; measure both stability and lateness
Skills data is stale or inflated
High
Medium
Self-declared with lead endorsement; coverage shown per item; nudges when skills have not been reviewed for six months
Estimates are not entered because they feel like commitments
Medium
High
Ranges and classes rather than points; size-class-only path for intake; calibration shown without blame
Benefit values are invented to win priority
Medium
Medium
Owner named; confidence scaling; realisation tracked and visible in the register
Solver performance at portfolio scale
Low
Medium
Eligible-pair sparsity, weekly buckets for Large items, warm start, time budget; horizontal workers
Mobile distribution and device policy delays
Medium
Low
Intune distribution planned from phase 0; web app is installable as a fallback
Integration APIs change or are rate limited
Medium
Low
Adapters isolated in the integration service; error queues visible; manual import as a fallback
Personal data concerns from availability and utilisation reporting
Medium
High
Data minimisation; no leave reasons; DPIA before pilot; reports aggregated for portfolio views
## 12.1	Dependencies
- Entra ID application registration and group design for roles.
- Azure subscription and landing zone with the required services approved.
- Access to Jira or Azure DevOps, ServiceNow and HR exports for the pilot team, with data owners agreed.
- Intune policy for distributing the mobile apps.
- A pilot team committed to a twelve-week measured trial.
# 13	Acceptance criteria and testing
## 13.1	Acceptance scenarios
Scenario
Given
When
Then
Configurable vocabulary
A workspace with work type "Project"
An administrator renames it to "Programme" and saves
Every screen, report and export shows "Programme"; existing references keep their prefix; the change is audited
Custom size
Size classes S, M, L and Custom
A user enters a Custom item of 95 days with a task roll-up
The item is scheduled at weekly granularity; its stamp is C; it counts towards the WIP limit
Freeze horizon
A committed assignment starting in 5 working days
The nightly cycle finds a better plan that moves it
The change is proposed but held as needing approval; the committed plan is unchanged until a delivery lead approves
Change budget
Change budget 5 per person per week; a proposal moves 7 assignment-days for one person
The proposal is generated
Changes beyond the budget are held and labelled; the reviewer can override with a reason
Minimum improvement
A candidate plan improves the objective by 2%
The diff is evaluated
The proposal is shown as information and nothing is applied automatically
Incident handling
A person on rota with 25% reserve; a P2 incident sized Medium arrives
The urgent cycle runs
The reserve is consumed first; the remainder displaces the lowest-priority planned item; one change is proposed for that person only; the requester of the displaced item is notified with the reason on commit
Skills gap
An item requires Terraform level 3; one person qualifies and is on leave in the window
The cycle runs
The item appears on the watch list with the skill, the level and the smallest change that would make it schedulable
Stability index
Four weeks of plan history
The overview loads
The index equals 1 minus moved assignment-days over total assignment-days in the committed and planned windows, and its definition is one click away
Mobile approval offline
A delivery lead opens Changes on a phone then loses connectivity
They accept a change
The decision is queued and confirmed on reconnect; the change is committed once and audited with the original decision time
## 13.2	Test approach
- Unit tests for scoring, capacity derivation, guardrail evaluation and diffing; property-based tests for the constraint model (no plan may violate a hard constraint).
- Golden datasets: anonymised snapshots of the pilot team's pipeline with expected proposals, run in CI to catch behavioural regressions in the solver.
- Contract tests between clients and API from the OpenAPI specification; consumer-driven tests for integrations.
- End-to-end tests for the core journeys on web and both mobile platforms; accessibility checks with axe and manual screen-reader passes.
- Performance tests at 50 people × 500 items and 200 people × 5,000 items for the schedule view, the heuristic and the solver.
- User acceptance with the pilot team against the scenarios above; usability sessions for My week and Changes before the mobile release.
# 14	Open questions and decisions needed
- Backend language: .NET 9 or Node (NestJS) for the core services. Both are viable; the choice should follow the team's strengths and platform standards.
- Whether planning uses most-likely or P80 by default for Large items from the start, or switches once calibration data exists.
- Whether benefit realisation is confirmed in Dispatch or imported from a finance system of record.
- Whether requesters outside the team should have direct access or submit through Teams and email only in R1.
- Objective weight defaults and the freeze horizon length for the pilot: proposed 10 working days, 5 change budget, 5% threshold, 12% reserve.
- Whether write-back to Jira or Azure DevOps of planned dates is wanted, or whether Dispatch stays read-only against those systems.
# 15	Appendix A: Configuration example
A workspace's configuration as JSON, as exported by CFG-10. Names, colours, bands and policy values are all data.
{
  "workspace": {
    "name": "Data Platform",
    "timeZone": "Europe/London",
    "workingWeek": [
      "Mon",
      "Tue",
      "Wed",
      "Thu",
      "Fri"
    ],
    "hoursPerDay": 7.5
  },
  "workTypes": [
    {
      "name": "Project",
      "plural": "Projects",
      "prefix": "WI",
      "colour": "#3B6BD6",
      "policy": "planned",
      "requiresEstimate": true,
      "requiresBenefit": true,
      "defaultSize": "L"
    },
    {
      "name": "Small change",
      "plural": "Small changes",
      "prefix": "WI",
      "colour": "#178F8A",
      "policy": "planned",
      "requiresEstimate": true,
      "requiresBenefit": false,
      "defaultSize": "S"
    },
    {
      "name": "Incident",
      "plural": "Incidents",
      "prefix": "INC",
      "colour": "#C8102E",
      "policy": "interrupt",
      "requiresEstimate": false,
      "requiresBenefit": false,
      "sizeOverride": "incidentSizes"
    },
    {
      "name": "Service request",
      "plural": "Service requests",
      "prefix": "SR",
      "colour": "#6D5BD0",
      "policy": "planned",
      "requiresEstimate": false,
      "requiresBenefit": false,
      "allowedSizes": [
        "S"
      ]
    }
  ],
  "sizeClasses": [
    {
      "stamp": "S",
      "name": "Small",
      "minDays": 0,
      "maxDays": 3,
      "planningDays": 2,
      "defaultEstimateClass": 4,
      "granularity": "halfDay",
      "countsForWip": false
    },
    {
      "stamp": "M",
      "name": "Medium",
      "minDays": 4,
      "maxDays": 15,
      "planningDays": 9,
      "defaultEstimateClass": 3,
      "granularity": "day",
      "countsForWip": true
    },
    {
      "stamp": "L",
      "name": "Large",
      "minDays": 16,
      "maxDays": 60,
      "planningDays": 30,
      "defaultEstimateClass": 3,
      "granularity": "week",
      "countsForWip": true
    },
    {
      "stamp": "C",
      "name": "Custom",
      "isCustom": true,
      "granularity": "week",
      "countsForWip": true
    }
  ],
  "incidentSizes": [
    {
      "stamp": "S",
      "maxHours": 4
    },
    {
      "stamp": "M",
      "maxHours": 15
    },
    {
      "stamp": "L",
      "maxHours": null
    }
  ],
  "policy": {
    "freezeHorizonDays": 10,
    "planningHorizonWeeks": 4,
    "modelHorizonWeeks": 26,
    "changeBudgetDaysPerPersonPerWeek": 5,
    "minImprovementPct": 5,
    "incidentReservePct": 12,
    "rotaReservePct": 25,
    "cadence": {
      "propose": "daily 02:00",
      "commit": "weekly Mon 09:00"
    },
    "maxConcurrentItems": 2,
    "minFocusDays": 2,
    "planAt": "mostLikely",
    "solverBudgetSeconds": 60
  },
  "objectiveWeights": {
    "valueCompletion": 1,
    "lateness": 3,
    "unscheduledValue": 5,
    "loadImbalance": 0.5,
    "contextSwitching": 0.5,
    "stabilityPlanned": 2,
    "preferences": 0.2
  },
  "priorityWeights": {
    "value": 40,
    "urgency": 25,
    "riskCompliance": 15,
    "dependencyLeverage": 10,
    "age": 10,
    "confidenceScale": {
      "high": 1,
      "medium": 0.7,
      "low": 0.4
    }
  }
}
# 16	Appendix B: Priority score worked example
WI-1042 Supplier master data pipeline, scored on 8 September 2026 with the default weights.
Term
Input
Normalised
Weight
Contribution
Value
£210k at Medium confidence → £147k; 90th percentile in workspace £400k
0.37
40
14.7
Urgency
Needed by 27 Nov; remaining effort 36 days; slack about 2 weeks
0.80
25
20.0
Risk and compliance
Duplicate vendor payments risk stated as 0.6
0.60
15
9.0
Dependency leverage
Unblocks WI-1068 (£95k at Low → £38k) → 0.10 of normalised value
0.10
10
1.0
Age
Ready for 3 weeks of 12
0.25
10
2.5
Override
None
0
Total
47.2 → shown as 78 after workspace scaling to the current distribution
Scores are rescaled nightly so that the highest-scoring planned item is near 100 and ordering is stable across the pipeline; the raw contributions are visible on the item.
# 17	Appendix C: Screen index
Screen
Surface
Primary user
Requirements illustrated
Overview
Web
Delivery lead
VIEW-06, STAB-07, STAB-08, CHG-01, SCH-05
Pipeline
Web
Delivery lead, requester
PIP-01 to PIP-04, PIP-08, CFG-06
Work item
Web, mobile
All
REQ-01, REQ-02, PIP-05, EST-02, BEN-01, VIEW-08
Schedule
Web (tablet read-only)
Delivery lead
VIEW-01 to VIEW-05, SCH-06, SCH-07, SCH-09, STAB-01, STAB-06
Proposed changes
Web, mobile
Delivery lead
CHG-01 to CHG-07, STAB-02 to STAB-04
Team & skills
Web
Team lead
TEAM-01 to TEAM-06, TEAM-08, TEAM-10
Person
Web, mobile (own profile)
Team member, lead
TEAM-02, TEAM-03, STAB-07, VIEW-07
Estimate
Web
Estimator
EST-01 to EST-08, EST-10
Benefits
Web
Benefit owner, PMO
BEN-01, BEN-03, BEN-05, BEN-06
Settings
Web
Administrator
CFG-01 to CFG-08
Reports
Web
Delivery lead, PMO
REP-01, REP-04, STAB-08, EST-07
My week
Mobile
Team member
VIEW-07, STAB-07, CHG-06, NOT-01, MOB-01
Add work
Mobile, web
Requester
PIP-01, REQ-01, BEN-01, CFG-04, MOB-01
Requirements summary: 127 functional requirements (85 Must, 38 Should, 4 Could) and 18 non-functional requirements. Release 1 carries 80 functional requirements.
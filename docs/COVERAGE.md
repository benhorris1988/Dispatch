# Coverage audit — Dispatch against requirements v0.1

What this repository actually implements, checked requirement by requirement against
*Dispatch — Requirements and Design v0.1* (`docs/requirements-v0.1.md`, 8 September 2026).

Audited 13 September 2026 against the working tree at commit `dbbec9c`, with the API running on
`http://localhost:8090` and the demo seeded. Every verdict below comes from reading the code that
does the work — and, where the requirement implies a person does something, from finding the control
in `mobile/lib/screens/` that reaches it. An endpoint no screen calls is recorded as such. Schema
columns that nothing reads are recorded as such. The status column is deliberately unkind.

## 1 Summary

| Scope | Done | Partial | Not done | Not applicable here | Total |
|---|---|---|---|---|---|
| All functional requirements | 65 | 43 | 10 | 9 | 127 |
| R1 (the MVP) | 61 | 19 | 0 | 0 | 80 |
| Must priority | 58 | 23 | 3 | 1 | 85 |
| Must **and** R1 | 58 | 18 | 0 | 0 | 76 |
| Should priority | 6 | 20 | 5 | 7 | 38 |
| Could priority | 1 | 0 | 2 | 1 | 4 |

Non-functional: of the 18 NFRs, three are structurally met, seven are partly met, and eight are
hosting or operations claims that a local implementation cannot make. Section 3 sets them out.

**How complete is this, plainly.** The MVP is substantially built and the hard part of it — the
scheduling engine — is the most complete part of the system. Every R1 requirement has something real
behind it: not one of the eighty is absent. The model builder, heuristic planner, diff, stability
costing, guardrails, explainer, priority scorer and watch list are faithful implementations of
sections 8.4 to 8.11, they are wired to a client that renders all fifteen screens, and the five PHP
suites plus the CP-SAT hard-constraint checks pass. Where the product is weaker is not the engine
but the last mile of the client and the edges of the administrative surface. Twenty-three R1
requirements are Partial, and the great majority of those follow one pattern: the API implements the
requirement completely and no screen calls it. Dependencies cannot be created, bulk actions cannot
be run, previous plan versions cannot be viewed or restored, scenarios cannot be saved, the rota
cannot be assigned, day rates cannot be edited. A code-only pass over `api/` would score this system
several points higher than it deserves; a user sitting in front of the app would score it lower.

Outside R1 the picture is thinner and honestly so. Notifications now generate all seven kinds and
`notify()` honours the preference table, but in-app is still the only delivery route there is: no
push, email or Teams sender exists, so `channel` records the route a user chose rather than one
anything acted on. Reporting exists but has no work-type dimension, no PDF, and definitions on
four metrics out of a dozen. There are no integrations at all: the `integrations` table is seeded and
never read by a single line of PHP, and the Settings panel that appears to configure them is a
hardcoded list of cards with disabled switches. There are no native mobile apps; the phone
experience is a responsive layout in the same Flutter web build, which covers the MOB-01 feature
list but is not what MOB-01 asks for. The four policy switches that were stored, versioned, audited
and never read — `auto_apply_outside_horizon`, `require_ack_inside_horizon`,
`reestimate_class_threshold` and `small_fill_threshold_days` — now each do what their label says;
only `reestimate_class_threshold` still has no Settings control to set it.

Three places where the mockups and the specification contradict each other are already recorded in
`README.md` (WI-1042's priority score, the benefits register totals, and the changes screen header
counts). They are not re-reported here as defects.

## 2 Functional requirements

Status values: **Done** (implemented and reachable by a user, server-side where the requirement
implies it), **Partial** (the substance is there, with the specific gap named), **Not done**,
**N/A** (cannot apply to a local implementation; what exists instead is named).

### 2.1 Workspace configuration (CFG)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| CFG-01 | Create, rename, recolour, reorder, retire work types | Must | R1 | Done | `workspace_config.php` `save_work_type` / `reorder_work_types` / `retire_work_type`; Settings → Work types with a reorderable list and retire action |
| CFG-02 | Work type attributes | Must | R1 | Partial | Name, plural, prefix, colour, policy, requires-estimate and requires-benefit all save. **`default_size_stamp` and `size_unit` are never shown or editable** in `settings_screen.dart`, though the API and the JSON export carry them |
| CFG-03 | Retiring blocked while open items use it; bulk re-type offered | Must | R1 | Done | Server returns 409 with the open-item list (verified live: "18 open items use Project"); the Settings retire flow catches it and shows a real re-type picker, then reposts with `retype_to_id` |
| CFG-04 | Size classes with band, planning value, class, granularity, WIP flag | Must | R1 | Done | `save_size_class` plus the size-class dialog; all eight fields editable |
| CFG-05 | Default bands S/M/L/Custom, non-overlapping, validated on save | Must | R1 | Done | Overlap check in `workspace_config.php` returns a 409 naming the fix; live config shows S 0–3, M 4–15, L 16–60, C |
| CFG-06 | Custom size entered directly (days or hours) or rolled up from tasks | Must | R1 | Partial | Custom stamp, `custom_effort_days` and `rollup_tasks` all work. **The add form offers days only — no hours entry — and nothing enforces that items above the largest band be split or made Custom** |
| CFG-07 | Size classes overridable per work type | Should | R2 | Partial | `size_classes.work_type_id` and the fallback to workspace scope are real, and the seeded Incident hour-based override is editable. **The UI exposes only that one hardcoded override; there is no way to add an override for another type** |
| CFG-08 | Workspace scheduling policy | Must | R1 | Done | `save_policy` versions every field; Settings → Policy edits freeze horizon, planning horizon, change budget, minimum improvement, reserve, max concurrent, min focus and both cadences |
| CFG-09 | Configuration versioned and audited; schedule shows the policy version behind each plan | Should | R2 | Partial | Versioning and auditing are real — `save_policy` writes a new row with `is_current`, and `plan_versions.policy_version` is stored on every version (verified live). **No screen shows it: `PlanVersion.policyVersion` is parsed in `models/plan.dart` and never rendered** |
| CFG-10 | Configuration export and import as JSON | Could | R3 | Done | `export` / `import`; reachable from Settings as "Export JSON" and an admin-only paste dialog. Live export returns the Appendix A shape |

### 2.2 Pipeline and intake (PIP)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| PIP-01 | Add an item with title, type, size, summary, tags, requester, sponsor, needed-by, earliest-start | Must | R1 | Partial | `work_items.php` `create` accepts every field. **The add form has no tags field (tags appear only in the later edit dialog) and `earliest_start` has no control anywhere in the client** — it is stored and used by the scheduler but can only be set by seed data or a direct API call |
| PIP-02 | Reference from prefix and sequence | Must | R1 | Done | `allocate_ref()` against `ref_sequences`, atomic per prefix |
| PIP-03 | Pipeline list with filtering and sorting by any column | Must | R1 | Partial | Filters by type, size, skill, team, status and free text all work, and the API sorts on about eighteen columns. **The UI sort is a five-option dropdown with no direction toggle, so "sorting by any column" is not available; the planned window is returned but never shown as a column** |
| PIP-04 | Nine statuses, transitions validated against work-type policy | Must | R1 | Done | `set_status` holds an explicit transition matrix and calls `readiness_for()`; 409 with the missing items |
| PIP-05 | Record dependencies and see them on the item and in the schedule | Must | R1 | Partial | `add_dependency` (finish-to-start and soft, with cycle detection) and `remove_dependency` are complete and the planner honours them. **The client is read-only: `_dependenciesPanel` lists them and its empty state invites "Add a dependency", but no screen calls either action. Dependencies are not drawn in the schedule** |
| PIP-06 | Split into tasks with their own effort and skill; roll up | Must | R1 | Done | `add_task` / `update_task` / `delete_task` / `rollup_tasks`; Tasks tab with an add form and a roll-up button |
| PIP-07 | Import from Jira or Azure DevOps by query, with field mapping, kept in sync | Should | R3 | N/A | Needs a Jira or Azure DevOps instance. In its place: nothing functional. There is no adapter, query importer, field mapper or sync job, and the Pipeline's "Import from Jira" button opens a dialog explaining that the import "is configured in Settings → Integrations", which is itself an inert list. This is the one stub in the repository that reads as the feature |
| PIP-08 | Queue-health strip with oldest wait | Should | R1 | Done | `list` returns `queue_health` with `oldest_days` per bucket; rendered by `_queueStrip()` |
| PIP-09 | Discussion thread with @mentions and attachments | Should | R2 | Partial | Thread and @mentions are real — `add_comment` matches person names and calls `notify_person`. **Attachments do not exist at all: no table in `db/01_schema.sql`, no upload endpoint, no file picker** |
| PIP-10 | Bulk re-type, re-size, tag, cancel, assign owner | Should | R2 | Partial | `work_items.php` `bulk` implements all five with per-item audit. **No UI: the pipeline has no multi-select and no Dart file calls the action** |
| PIP-11 | History of every change with who, when, before and after | Must | R1 | Done | `history` stitches `audit_events` across item, estimate, benefit, dependency, task, comment, progress and override; shown as a History sheet rather than a literal tab |

### 2.3 Work item requirements and readiness (REQ)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| REQ-01 | Required skills with minimum proficiency and optional effort | Must | R1 | Done | `set_skill_requirement`; effort per skill is written by the estimate screen's skill split, which upserts `skill_requirements.effort_days` |
| REQ-02 | Coverage per required skill; single points of failure flagged | Must | R1 | Done | `qualified_people()` produces `coverage_count`, `coverage_label` and `single_point`; the skills panel renders "No one qualifies" and "Only <name>" chips |
| REQ-03 | Free-text requirements tab with headings, lists, links and acceptance criteria; per-type template | Should | R1 | Partial | The template is genuinely applied on create (`work_items.php` falls back to `work_types.requirements_template`) and is seeded. **The tab renders a plain `Text()` — no markdown, headings, lists or links; it is read-only, with no editor anywhere; and the Settings work-type dialog omits `requirements_template`, so no administrator can change it** |
| REQ-04 | Readiness checklist per work type, enforced before Ready | Must | R1 | Done | `items_lib.php` `readiness_for()` drives the checks from `requires_estimate` / `requires_benefit`; enforced server-side with a 409 listing what is missing; shown on the Requirements tab |
| REQ-05 | Link to external records by URL with a live status badge | Could | R3 | Not done | `external_url` and `external_ref` are in the schema and in the `update` whitelist. **Nothing in `mobile/lib/` renders, edits or opens them, and there is no status badge.** The URL half needs no integration and is still absent |

### 2.4 Team, skills and availability (TEAM)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| TEAM-01 | Skills catalogue; merge and retire | Must | R1 | Done | `skills.php` `save` / `merge` / `retire`; Team & skills → Skills tab, admin-gated |
| TEAM-02 | Person profile: role, team, days per week, pattern, max concurrent, min focus, preferences, avoid | Must | R1 | Partial | Schema and `people.php` `save` accept the whole profile. **The edit dialog covers only name, role, tagline, days per week, prefers and avoid — there is no UI for `working_pattern`, `max_concurrent`, `min_focus_days`, `pattern_label` or moving someone between teams** |
| TEAM-03 | Proficiency 0–4, lead endorsement, certifications attached | Must | R1 | Partial | Levels and endorsement are real (`set_skill`, `endorse_skill`, and the endorse control on the person page). **Certification is a single boolean rendered as a read-only chip; nothing in the client writes it and there is no attachment mechanism** |
| TEAM-04 | Skills matrix with proficiency, people at L3+, demand over the horizon, gaps highlighted | Must | R1 | Done | `skills.php` `matrix` returns cells, a single-point/two-person summary and `demand_vs_supply`; rendered as the matrix table, summary strip and demand panel |
| TEAM-05 | Development targets; scheduler prefers pairing that person as a second | Should | R2 | Partial | The scheduler half is genuinely implemented: `planner.php` `pl_try_pairing()` adds a 25% second when the extra effort stays under `pairing_cost_threshold_days`, and the pairing toggle is on the development panel. **No UI sets a development target — the toggle re-sends the existing level and the level controls send proficiency only, so targets exist only in seed data** |
| TEAM-06 | Availability covers leave, training, rota and recurring patterns | Must | R1 | Partial | Leave, training, sickness and rota all reduce capacity through `engine/capacity.php` `derive_capacity()`. **There are no recurring availability patterns: every record is a single date range, with no recurrence field anywhere in the API, schema or client** |
| TEAM-07 | Leave imported from HR and calendar, source-marked, correctable but not deletable | Should | R2 | N/A | Needs an HR system and an M365 tenant. In its place: `availability.source` accepts `hr` and `calendar`, the person page shows the source, and `delete_availability` refuses non-manual rows. **But there is no importer, and no `update_availability` action either — so the local half of the rule is "not deletable, not correctable"** |
| TEAM-08 | Incident rota per week; that person's reserve rises to the rota percentage | Must | R1 | Partial | The reserve uplift is real and tested: `capacity.php` applies `rota_reserve_pct` instead of `incident_reserve_pct` on rota weeks, and the engine suite asserts it. The rota is shown on the person page and in the schedule. **`set_rota` and `clear_rota` exist and no screen calls them — a team lead cannot assign the rota in the app; the demo rota comes from the seed** |
| TEAM-09 | Teams grouped into a portfolio; a person loanable to another team for a dated period | Should | R3 | Not done | No portfolio concept exists anywhere in the repository, and there is no loan mechanism. Only a flat `teams` table and a `team_id` filter on the schedule |
| TEAM-10 | Capacity derived nightly; load percentage on the profile and in the lane header | Must | R1 | Done | `cron.php` → `run_nightly` calls `derive_capacity`, which also re-runs on availability, rota and pattern changes; `load_pct_map` feeds "Load, next 4 weeks" on the profile and the colour-banded lane header |

### 2.5 Estimation (EST)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| EST-01 | Estimate by size class, three-point or task roll-up | Must | R1 | Done | `estimates.php` `save` handles all three methods; the estimate screen exposes them as tabs with their own panels |
| EST-02 | PERT expected, standard deviation, P80, implied size class | Must | R1 | Done | `items_lib.php` `estimate_derive()`; all four shown on the estimate screen |
| EST-03 | Estimate class 5 to 1 with descriptions, defaulted from the size class | Must | R1 | Done | Class list and tolerances in `items_lib.php`; segmented picker with the ±tolerance label; default from `size_classes.default_estimate_class` |
| EST-04 | Effort split by skill, driving what the scheduler matches and allocates | Must | R1 | Done | `save` upserts `skill_requirements.effort_days` from `skill_split`, which the model turns into `skill_effort` and the planner uses for split placement |
| EST-05 | Blended or per-role day rate converting effort to a cost range; rates configured and versioned | Should | R2 | Partial | The cost range is shown, and `blended_day_rate()` picks a rate by `effective_from`, so versioning works in principle. **Only one rate exists; no per-role rate is ever applied (the skill split ignores rates); and Settings renders rates read-only — nothing in the client calls `save_day_rate`, so an administrator cannot add or version one** |
| EST-06 | Estimates versioned with author, date and reason; latest used; changes visible | Must | R1 | Done | New row per save with author and reason; every read takes the top version; the estimate screen has a versions sheet and a history panel |
| EST-07 | Calibration: actual ÷ most-likely by size class and work type over 12 months, with a plan-at recommendation | Should | R2 | Partial | Twelve-month medians by size stamp and the most-likely/P80 recommendation are both real and shown on the estimate and estimates screens. **The work-type dimension is absent — grouping is by size stamp only** |
| EST-08 | Find similar delivered items and copy their estimate | Should | R2 | Done | `similar_for()` matches size stamp and overlapping skills; the "Copy from similar" sheet and its "Use" button populate the three-point form for a new version |
| EST-09 | Policy can require a re-estimate before an item enters the committed window when the class is worse than a threshold | Should | R2 | Done | `engine/commit.php` `reestimate_blocked_changes()` gates the commit: an accepted change that would move an item whose latest estimate class is worse than the threshold into the freeze window makes `changes.php commit` return 409 naming the item and its class, and the nightly auto-apply skips it. `replan.php watch_list` reports the same items with a `reestimate` entry. Asserted on and off by `tests/policy_notifications_test.php`. **Still no Settings field to set the threshold** — it is API-only |
| EST-10 | Assumptions and exclusions recorded and shown wherever the estimate is shown | Must | R1 | Done | Stored per version, edited on the estimate screen, displayed on the item's ROM panel and estimate detail |

### 2.6 Business benefits and prioritisation (BEN)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| BEN-01 | Benefits with type, value, currency, confidence, realisation start, owner, narrative | Must | R1 | Done | `benefits.php` `save` validates and stores all of them; the add/edit dialog covers each. Currency is fixed to GBP in the dialog |
| BEN-02 | Non-financial benefits on a qualitative scale with an optional proxy value, still influencing priority | Should | R2 | Not done | `qualitative_scale` exists as a column and the API will store it, but no UI control sets it, the seed always writes null, and `engine/priority.php` scales `annual_value` alone — so a qualitative benefit cannot influence priority. There is no proxy-value concept at all |
| BEN-03 | Priority score from value × confidence, urgency, risk, leverage and age; weights configurable; formula shown on the item | Must | R1 | Partial | The formula is a faithful implementation of section 8.4, including P90 normalisation, confidence scaling and the nightly rescale, and the weights are genuinely editable in Settings with a "must total 100" check. **The item shows each term's contribution as a bar and a number plus one prose sentence — not the weights or the normalised inputs — so a reader cannot reproduce the score from the item page.** The incident case is fixed: `priority.php` republishes the severity contribution as the `urgency` term (flagged `alias_of`), so an interrupt's breakdown now sums to its score instead of drawing five empty bars |
| BEN-04 | Interrupt items take priority from severity and bypass the benefit case | Must | R1 | Done | `priority.php` scores interrupts from `severityScores` and marks the other terms "skipped: interrupt policy"; severity is set at intake. The breakdown is now readable too: the severity contribution is also published as the `urgency` term with `alias_of: 'severity'`, asserted by `tests/policy_notifications_test.php` to sum to the item's score |
| BEN-05 | Benefits register with filters by type, owner, status and quarter, and totals in plan, realised and at risk | Must | R1 | Partial | The register, the three totals, and the by-type and by-owner views are all real. **The filters are API-only — the client calls `list` with no parameters and the Register tab has no type, owner, status or quarter control** |
| BEN-06 | Benefit owner records realised value at the configured cadence; planned against realised by quarter | Should | R2 | Partial | `record_realisation`, the "Record realisation" dialog and the planned-versus-realised quarterly chart all exist. **There is no configured cadence anywhere — no column, no setting — quarters are hardcoded, and nothing prompts an owner when a period falls due** |
| BEN-07 | Delivery lead can pin or override priority with a reason and an expiry | Must | R1 | Done | `override_priority` / `clear_override` with a mandatory reason and expiry, honoured and expired by `priority.php`; dialog, in-force note and Clear on the item page |
| BEN-08 | Register exportable to CSV and to Power BI via a read-only dataset | Should | R2 | Partial | CSV is done (`export_csv` and an Export button). **Power BI is not: the only views are `vw_assignments_committed` and `vw_estimate_accuracy`, neither of which covers benefits; there is no benefits dataset, no read-only grant and no Power BI entry in Settings** |

### 2.7 Automated scheduling (SCH)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| SCH-01 | Plan honouring skills, capacity and reserve, availability, dependencies, earliest start, max concurrent, focus blocks | Must | R1 | Done | `planner.php` enforces every one: `pl_meets` for skills, `pl_try_run` for capacity minus reserve and for `max_concurrent`, zero-capacity days skipped, `earliest_start` and finish-to-start dependencies in `pl_place_item`. Focus blocks hold by construction — every run is contiguous at one allocation — and `solver.py` enforces `min_focus_days` explicitly |
| SCH-02 | Optimises for value-weighted early completion, due dates, balanced load, low context switching and minimal change; weights configurable and shown | Must | R1 | Partial | All the terms are implemented and weighted in `plan_objective()` / `pl_item_cost()`, the weights live in `scheduling_policies.objective_weights`, and Settings shows them. **Settings shows them read-only: only the priority weights have an editor, so an administrator cannot change what the engine optimises from the app** |
| SCH-03 | Proposal, never a silent change | Must | R1 | Done | The engine writes a `proposed` plan version and change rows; only `changes.php commit` (or an explicit manual move) creates a committed version |
| SCH-04 | Percentage allocation in 25% steps; granularity follows the size class | Must | R1 | Done | `pl_allocs()` returns 100/75/50/25 for day granularity and 100/50 for half-day and week; `granularity` comes from the item's size class |
| SCH-05 | Infeasible items on the watch list with the reason and the smallest change that would help | Must | R1 | Done | `pl_unsched()` and `pl_skills_gap()` produce a reason and a suggestion per item; `watchlist.php` turns them into the Overview watch list. Verified live: skills gaps, missing estimates, over-capacity and late items, each with a suggestion |
| SCH-06 | Fix an assignment (person, dates or both) and the scheduler plans around it | Must | R1 | Done | `plan.php` `fix_assignment` / `unfix`; the schedule's block dialog has both switches; pass 1 of the planner pre-loads locked rows |
| SCH-07 | Drag an assignment, see the knock-on before saving, recorded as a manual change | Must | R1 | Done | `move_assignment` with `preview: true` then `false`; the schedule drags a block, shows the knock-on and stability cost, and records a decided manual proposal |
| SCH-08 | Heuristic preview within 2 s; full optimisation as a background job with a configurable budget | Must | R1 | Done | Measured live at 0.47 s end-to-end for a person-away what-if on the demo (8 people, 42 items). `solver_budget_seconds` is configurable and passed to the CP-SAT service; `cron.php` is the background job. Note the in-app "Propose replan now" runs synchronously, and the richer `replan.php preview` endpoint has no UI — the client's only what-if is the drag preview |
| SCH-09 | Committed, planned and indicative windows | Must | R1 | Done | `model_state_for()` labels every assignment; the schedule tints committed weeks, locks them and draws indicative blocks with a dashed border and hatching |
| SCH-10 | Incidents consume reserve first, then displace the person's lowest-priority planned work as a proposed change | Must | R1 | Done | `pl_place_item` allows reserve for interrupt items and, if the run still misses the response window, calls `pl_lowest_priority_on()` and `pl_displace()`; the displaced item re-enters the queue and the diff surfaces it as a change |
| SCH-11 | Named what-if scenarios, compared with the committed plan before adopting | Should | R2 | Partial | Fully implemented server-side: `scenario_save`, `scenarios` and `scenario_adopt`, stored as `plan_versions` with status `scenario` carrying their edits and before/after summaries. **No screen calls any of the three, so a user cannot create, compare or adopt a scenario** |
| SCH-12 | Prefer pairing a person with a development target when the objective cost is below a threshold | Should | R2 | Partial | `pl_try_pairing()` is a real implementation, gated on `pairing_cost_threshold_days` and on the pair being exactly one level short. **It can only ever fire on seeded data, because no UI creates a development target (see TEAM-05)** |
| SCH-13 | Multi-team scheduling across a portfolio | Could | R3 | Not done | No portfolio exists; the model builds one workspace's people as a single pool |
| SCH-14 | Record inputs hash, policy version, objective score, solve time and whether the optimum was proved | Should | R2 | Done | All five stored on every `plan_versions` row. Verified live: `policy_version: 1`, a SHA-256 `inputs_hash`, `objective_score`, and `solver_stats {solveSeconds, provedOptimal, assignments}` |

### 2.8 Schedule stability (STAB)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| STAB-01 | Freeze horizon locks committed assignments; manual changes inside need an approver and a reason | Must | R1 | Done | The planner never moves locked or frozen rows; `move_assignment` returns 409 without a reason inside the horizon; `apply_guardrails` marks such changes `needs_approval` and `decide_change` refuses acceptance without a reason |
| STAB-02 | Each moved assignment-day carries a stability cost, penalised in the objective | Must | R1 | Done | `diff_change()` costs moved allocation-days inside committed and planned windows; `pl_item_cost()` charges `stabilityPlanned × moved` when choosing a placement |
| STAB-03 | Change budget per person per week; proposals over it held with the reason | Must | R1 | Done | `apply_guardrails` accumulates per person-week (including prior usage from committed changes), holds the excess as `held_budget` and returns a sentence naming the person, the days and the week. Asserted by the engine suite |
| STAB-04 | Minimum improvement threshold; proposals below it shown but never applied automatically | Must | R1 | Done | `below_threshold` from `improvement_pct`; every change becomes `held_threshold`; the Changes screen says so in the header. Verified live on a negative-improvement preview: 23 of 23 held |
| STAB-05 | Cadence of propose nightly, commit weekly; urgent triggers start an immediate cycle limited to the affected people | Must | R1 | Done | The cadence is configured and `cron.php` runs the nightly cycle. `lib.php start_urgent_cycle()` runs the scoped cycle synchronously wherever an urgent trigger is raised — an incident arriving (`work_items.php create`), sickness or leave inside the freeze horizon and a leaver's flagged work (`people.php`) — after the originating change is committed, and never fails that request (a `dp_soft_fail` guard turns `fail()` into an exception it swallows). A dry run decides whether to persist, so an empty cycle cannot supersede the standing proposal. Asserted end-to-end by `tests/policy_notifications_test.php`. **The commit cadence is still a stored string that nothing enforces**, and the client's own call sites still post `kind: 'manual'` |
| STAB-06 | Assignments beyond the planning horizon are indicative and cost nothing | Must | R1 | Done | `diff_change()` and `summary_total_days()` both clamp at `planned_end`, so indicative days score zero stability cost and zero budget |
| STAB-07 | Per-person stability view over 8 weeks with reasons; team and workspace stability trend | Must | R1 | Done | `people.php get` returns `change_history` and a stability note; the person page renders "Plan changes affecting …" and "Plan changes by week"; `changes.php mine` feeds My week; the trend is on Overview and Reports |
| STAB-08 | Plan stability index, rolling four weeks, on the overview and in reports | Must | R1 | Done | `stability_index()` in `summary.php` implements the formula against `stability_weeks`; shown on Overview with its definition and as the Reports trend |
| STAB-09 | Upward re-estimate extends the same assignment unless it breaks the needed-by date | Must | R1 | Done | `pl_try_keep()` reproduces the committed slot and extends it; `pl_breaks_needed_by()` is the only thing that abandons it — and inside the freeze horizon not even that |
| STAB-10 | Small incoming work fills existing gaps in the planned window before displacement is considered | Must | R1 | Done | New items are queued after kept committed ones and `pl_find_run()` places them in the earliest feasible gap, and nothing except an incident ever displaces. The threshold now drives the order: `planner.php`'s queue sort puts incoming items flagged `small` by `model.php` (remaining effort ≤ `small_fill_threshold_days`) ahead of larger incoming work. `tests/engine_test.php` asserts the flag tracks the policy value and that inverting it inverts the placement order. **The CP-SAT solver still ignores `small`**, so a `cpsat` run does not honour the threshold |
| STAB-11 | Non-urgent triggers batched until the next scheduled proposal | Must | R1 | Done | Every mutation writes a `replan_triggers` row with a class; nothing replans on edit; the nightly cycle consumes them |
| STAB-12 | Mark an item or a person protected for a period, raising the stability cost | Should | R2 | Partial | The engine half is complete: `protected_until` becomes `protected` in the model, doubles the cost in both `diff.php` and `pl_item_cost()`, and produces a "Protected · stability cost doubled" chip. **No screen sets it or shows it — `protectedUntil` is parsed into the Dart models and rendered nowhere** |

### 2.9 Change proposals, review and approval (CHG)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| CHG-01 | Each change as before and after, with trigger, objective terms, stability cost and people affected | Must | R1 | Done | `diff.php` produces before/after envelopes, cost, `inside_freeze` and `affected_person_ids`; `explain.php` adds the headline, plain-English reason and impact chips; the proposal carries its triggers |
| CHG-02 | Accept, reject or edit each change, or accept all that pass guardrails | Must | R1 | Done | `decide`, `edit` and `commit`; the Changes screen preselects every guardrail-passing change and offers "Accept N selected", then commits |
| CHG-03 | Held changes cannot be accepted without an override permission and a reason | Must | R1 | Done | `decide_change()` refuses `held_budget` and `held_threshold` without the admin role *and* a reason, returning the guardrail sentence; the client shows an override confirmation |
| CHG-04 | Before-and-after summary of late items, quarterly value, people over 100%, single-skill dependencies, days changed and stability index | Must | R1 | Done | `plan_summary()` computes all six; stored on the proposal and rendered on the Changes screen. Verified live |
| CHG-05 | Accepting creates a new committed version; the previous remains viewable and restorable | Must | R1 | Partial | The commit half is done — a new committed version is written and the previous is marked superseded and kept. **`plan.php` `versions`, `version` and `restore` are all implemented and no screen calls any of them, so from the app a previous version can be neither viewed nor restored** |
| CHG-06 | Affected people notified before the change takes effect, with the reason, and can comment; policy can require acknowledgement inside the horizon | Must | R1 | Done | Notification happens at propose time with the reason, comments work, and `acknowledge` exists. `require_ack_inside_horizon` is now read at commit time and recorded per change as `change_proposals.ack_required`, so turning it off stops asking rather than hiding the ask; `changes.php current`/`get` expose `awaiting_ack` and `counts.awaiting_ack`, and `mine` drives My week's `pending_ack` from the same flag. Tested on and off in `tests/policy_notifications_test.php` |
| CHG-07 | Approval roles configurable: who approves inside the horizon, who overrides guardrails, whether auto-apply is allowed outside it | Must | R1 | Partial | The approval rules are enforced but hardcoded: `require_role('delivery_lead')` to approve and `has_role('admin')` to override, **neither configurable**. The auto-apply clause is done: `auto_apply_outside_horizon` is read by `run_nightly`, which accepts and commits every pending change that passes all guardrails and falls wholly outside the freeze horizon, audits each as `auto_apply`, refuses when the proposal is below `min_improvement_pct` (STAB-04), and re-proposes whatever is left so it still reaches a reviewer |
| CHG-08 | A proposal expires at the next cycle, which notes what was carried over | Should | R1 | Done | `run_propose` supersedes every open proposal, collects the undecided headlines and writes `carried_over_note`; the candidate version is discarded |

### 2.10 Schedule and overview views (VIEW)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| VIEW-01 | Lane per person across a selectable horizon, blocks coloured by type and labelled | Must | R1 | Done | `schedule_screen.dart` with a Weeks / Days / Months zoom (6, 2 and 26 weeks); blocks carry reference, title and size stamp |
| VIEW-02 | Committed window distinct and locked, today marked, leave and rota hatched, indicative dashed | Must | R1 | Done | `SchHatchPainter` and `SchDashedBorderPainter` in `schedule_widgets.dart`; committed weeks tinted with a lock glyph, today an orange marker |
| VIEW-03 | Lane headers with name, role and load percentage, colour-coded against the target band | Must | R1 | Done | Lane header renders load from `plan.php schedule`, banded against `target_load_min` / `max`. Asserted by the HTTP smoke suite |
| VIEW-04 | Filter by team, work type, skill and item; group by person, item or work type | Must | R1 | Partial | All four filters work and are passed to the API. **There is no grouping at all — lanes are always per person; nothing in `mobile/lib` implements a group-by** |
| VIEW-05 | Proposed changes overlaid with the moved blocks highlighted | Should | R1 | Done | `overlay_proposal_id` on `schedule`; the overlay toggle draws the proposed plan with a ghost at each moved block's committed position |
| VIEW-06 | Overview with committed deliveries, load, stability, reserve use, pending proposals and watch list | Must | R1 | Done | `overview.php get` returns every section; all six are rendered. Covered by the overview suite |
| VIEW-07 | Person page with assignments, skills, availability, preferences and personal stability history | Must | R1 | Done | `person_screen.dart` has all five panels plus the rota and the weekly change history |
| VIEW-08 | Item page with summary, requirements, skills, dependencies, plan facts, estimate, benefits, tasks, schedule and history in tabs | Must | R1 | Done | Seven tabs (Overview, Requirements, Estimate, Benefits, Tasks, Schedule, Discussion). Skills coverage, dependencies and plan facts are panels on the Overview tab and history is a sheet rather than tabs of their own, which reads as the mockup intends |
| VIEW-09 | Export the schedule to PDF and to iCalendar per person | Should | R2 | Not done | Nothing anywhere: no PDF generator, no `VCALENDAR` output, no `.ics` route, no client control. The whole requirement is absent |

### 2.11 Notifications and collaboration (NOT)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| NOT-01 | Notifications for seven events | Must | R1 | Done | All seven are generated: `change_proposed` and `approval_requested` by `run_propose`; `change_committed` and `item_assigned` by `engine/commit.php` (a commit that gives someone work they did not hold); `estimate_requested` by `work_items.php` `request_estimate{id, note?}` and by any move into `needs_estimate`; `realisation_due` and `watch_list` by `run_nightly`, deduplicated once per benefit and once per watch-list entry per week. Covered by `tests/policy_notifications_test.php`. **A manual assignment change in `plan.php move_assignment` still raises no `item_assigned`** — that file was out of this change's remit |
| NOT-02 | Channels in-app, push, email digest and Teams, chosen per kind with a cadence | Must | R2 | Partial | `notification_prefs` persists all four switches and the cadence per kind, the Notifications screen edits them, and `notify()` now reads the table: in-app off for a kind writes no row at all, and `channel` is set to `digest`, `teams` or `in_app` from the user's own choices. **There is still no push, email or Teams sender**, so `channel` records the route chosen rather than a delivery that happened; push is deliberately never claimed |
| NOT-03 | Urgent notifications bypass digests | Must | R2 | Partial | The `urgent` flag is set correctly for inside-freeze changes, rendered as a red chip, and `notify()` now branches on it: an urgent notification is never given `channel = 'digest'` even when the recipient has a daily or weekly digest configured for that kind (asserted in `tests/policy_notifications_test.php`). **There is still no digest job to bypass** (NOT-04) |
| NOT-04 | Weekly digest of next week's plan and changes since the last one | Should | R2 | Not done | No digest job, no mail transport in the repository; `cron.php` runs only the replan cycle. The stored `digest` preference is never consumed |
| NOT-05 | Comments on items and proposals support @mentions and link to the exact change | Should | R2 | Partial | @mentions are parsed on **work-item** comments only, and link to the item, not to a change. **Change-proposal comments do not parse mentions — they notify everyone affected — and `mention` is not a notification kind, so it has no preferences** |

### 2.12 Reporting and analytics (REP)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| REP-01 | Seven reports | Must | R2 | Partial | Five are there: stability trend, load planned against actual, estimate accuracy, delivered by type per month, and cycle time (`reports.php`). Benefit realisation by quarter and skills demand against supply exist but on the Benefits and Team screens, not in Reports. **Accuracy has no work-type dimension** |
| REP-02 | Filter by team, period and work type; export to CSV and PDF; schedule by email | Should | R2 | Partial | Period only (4w / 12w / 12m) and CSV for four reports. **No team or work-type filter, no PDF, and the "Schedule email" dialog is an admitted stub — "Scheduled email is not wired up in this build."** |
| REP-03 | Read-only analytics dataset for Power BI with row-level security matching app permissions | Should | R3 | Partial | Two views exist, `vw_assignments_committed` and `vw_estimate_accuracy`. **No row-level security of any kind — no security policy, no filter predicate, no reporting login — and no benefits or stability dataset** |
| REP-04 | Every metric has an in-app definition | Must | R2 | Partial | Four definitions are returned by `reports.php` and surfaced through the info icon on `TmMetricTitle`. **`TmMetricTitle` is used only on the Reports screen: benefit realisation, skills demand and supply, reserve use and team load all have none** |

### 2.13 Administration, security and audit (ADM)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| ADM-01 | Sign-in through Entra ID by OpenID Connect; no local passwords | Must | R1 | Partial | The verification path is real, not a placeholder: `auth.php` `oidc_login` fetches the tenant JWKS, checks the RS256 signature, `kid`, audience, issuer and expiry, and maps group claims to roles. No password is stored anywhere. **It is unreachable: no tenant is configured, there is no MSAL or PKCE client flow, the sign-in button is disabled, and the only working path is `dev_login`, which takes a user id and would be a severe hole if it reached production** |
| ADM-02 | Seven roles, documented, enforced server-side | Must | R1 | Done | `DP_ROLE_RANK` in `lib.php`, roughly forty `require_role()` calls across the endpoints, re-read from the database on every request so a role change applies without re-login, and documented in Settings → Teams and roles |
| ADM-03 | Users provisioned from the directory; leavers deactivated automatically with future assignments flagged | Should | R2 | Partial | The flagging half is genuinely done: `people.php deactivate` deactivates person and user, notes every future assignment as needing reassignment and raises an urgent replan trigger. **It is manual and admin-initiated — there is no SCIM endpoint and no group-sync job — and no screen calls it, so even the manual path is API-only** |
| ADM-04 | Every create, update, delete, approval and configuration change audited; searchable and exportable | Must | R1 | Done | `audit()` records actor, time, entity, label, before and after JSON and reason, from roughly sixty-five call sites including config changes, approvals and commits; `audit.php` gives search, paging and CSV, exposed in Settings |
| ADM-05 | Personal data minimised; leave reasons never stored; retention policy removes plan history after a configurable period | Must | R1 | Partial | Data minimisation is honoured properly and deliberately: `availability` holds a type and nothing else, and `add_availability` drops any reason present in the request. **There is no retention policy at all — no configurable period and nothing that purges `plan_versions`, `assignments` or `audit_events`** |
| ADM-06 | Administrators manage day rates, skills catalogue, teams, integrations and notification defaults | Must | R1 | Partial | Skills, work types, size classes and policy all save. **Day rates are read-only in the client (see EST-05); there is no team CRUD endpoint at all; integrations are inert (see 2.14); and the Settings "notification defaults" table is a read-only view of the signed-in user's own preferences, not editable workspace defaults** |
| ADM-07 | Multiple workspaces in one tenancy, a user able to belong to more than one | Should | R3 | Partial | The tenancy model is sound — every table carries `workspace_id` and every query filters on it, which is the hard part. **`users.workspace_id` is a single foreign key, the JWT carries one workspace, there is no switcher in the client and the seed creates one workspace, so a user cannot belong to two** |

### 2.14 Integrations (INT)

Nothing in this section is implemented. The `integrations` table is seeded with six disabled rows and
**no PHP file ever reads it**. Settings → Integrations is a hardcoded Dart `const` list of six cards
with `onChanged: null`; it does not query the table, does not save anything, and mislabels HR leave
and Timesheets as "Connected". The five entries below are marked N/A because they genuinely need an
external system this box does not have — but the absence is of the adapter, not only of the remote
service.

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| INT-01 | Jira and Azure DevOps import, sync and write-back | Should | R3 | N/A | Needs a Jira or ADO instance. No client, query importer, field mapper or write-back exists. In its place: a prose panel on the Pipeline describing how the import "is configured" |
| INT-02 | ServiceNow creates Incident items above a severity threshold | Should | R3 | N/A | Needs a ServiceNow instance. No polling, webhook or severity mapper. In its place: an Incident work type with severity-driven priority, an incident reserve and an on-call rota, with incidents typed in by hand |
| INT-03 | HR or leave system imported nightly as availability | Should | R2 | N/A | Needs an HR system. No importer and no scheduled job. In its place: `availability.source` accepts the value `hr`, and leave is entered manually |
| INT-04 | Microsoft 365 out-of-office read; committed assignments published as an iCalendar feed | Should | R2 | N/A | Needs an M365 tenant for the read half. No Graph calls exist. **The publish half needs no tenant and is also absent — there is no iCalendar output anywhere, which is why VIEW-09's calendar half fails too** |
| INT-05 | Timesheets imported as actual effort | Could | R3 | N/A | Needs a timesheet system. No importer. In its place: `work_items.actual_effort_days` and `stability_weeks.actual_load_pct` are real columns feeding the accuracy and load reports, populated by the seed and by manual entry |
| INT-06 | Microsoft Teams cards for proposals, approvals and digests, with accept and reject | Should | R2 | N/A | Needs a Teams tenant. No webhook, adaptive card or action handler. In its place: a `teams` boolean in `notification_prefs` that users can toggle and nothing reads |
| INT-07 | Public REST API (OpenAPI 3.1) and outbound webhooks | Should | R2 | Not done | This one needs no external system and is still absent: no OpenAPI document, no versioned resource paths, no webhook subscriptions or dispatcher. `docs/API.md` documents the internal `POST {"action": …}` convention, which is not a public REST contract |

### 2.15 Mobile (MOB)

The client is one Flutter codebase built **for web only**. `mobile/` contains `web/` and no `android/`
or `ios/` directory, `mobile/build/` contains only `web`, and `pubspec.yaml` carries no platform
plugin — no `local_auth`, no `firebase_messaging`. The phone experience is a responsive layout below
700 px in the same web build. Judged on that basis:

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| MOB-01 | Native iOS and Android apps with parity for My week, item, proposals, add work, notifications and self-service | Must | R2 | Not done | No native app exists, and Flutter could have targeted one. In its place: a responsive web phone layout with bottom tabs (My week, Pipeline, Changes, More) that does cover the whole parity list — proposal review and approval included — because every route renders at every width |
| MOB-02 | Schedule read-only on tablets, simplified per person on phones | Should | R2 | Partial | `_phoneBody` gives a person picker and that person's block list, and drag-planning is gated to desktop, so a tablet width is read-only. In its place: browser viewport width, not a tablet device |
| MOB-03 | Offline reading of My week, items and proposals; actions queued and confirmed on reconnect | Should | R2 | Partial | `services/my_week_cache.dart` caches the last My week payload with a staleness banner. **Items and proposals are not cached and there is no offline action queue at all** |
| MOB-04 | Push through APNs and FCM with deep links | Must | R2 | Not done | No APNs, FCM, service worker or token registration; the `push` preference is stored and never read. In its place: in-app links (`/items/{ref}`, `/changes/{id}`) and an unread badge |
| MOB-05 | Biometric unlock; sessions follow conditional access | Must | R2 | Not done | No biometric unlock (no `local_auth`), and conditional access needs Entra. In its place: a seven-day HS256 JWT in `shared_preferences` restored silently on launch — weaker than the requirement, not a variant of it |
| MOB-06 | Platform conventions respected while keeping one visual identity | Must | R2 | Partial | Material 3, light and dark themes, bottom tabs on phone and one visual identity throughout. **Browser conventions, not platform ones: no native back gesture, no share sheet, and Flutter's canvas rendering ignores the OS text-size setting** |
| MOB-07 | Distributed through Intune and the public stores | Must | R2 | N/A | Needs an Intune tenant and store accounts. In its place: `flutter build web --release` served from `http://localhost:8090/mobile/build/web/` — distribution is a URL, not a managed app |

## 3 Non-functional requirements

Most of the eighteen are claims about hosting, operations or assurance that a single-box local
implementation cannot make, whatever the code does. Three are structural — they depend on how the
system is built rather than where it runs — and those are the ones worth judging.

### Structurally met

- **NFR-DATA-01 (personal data minimisation).** Met, and deliberately so. `availability` carries a
  type and a fraction and no reason, `add_availability` discards any reason in the request, and the
  schema says so in a comment. Only name, work email, role, skills, working pattern and availability
  type are held. The UK-residency and DPIA halves are hosting and process matters, not applicable here.
- **NFR-SEC-02 (role-based access in the API, row-level tenancy by workspace).** Met for both clauses
  that are about code: seven ranked roles enforced by `require_role()` on every mutating action and
  re-read per request, and `workspace_id` on every tenant-scoped table with every query filtering on
  it. The OWASP ASVS level 2 verification and the dependency and container scanning are not done.
- **NFR-I18N-01 (British English, configurable dates, currency and working week).** Largely met:
  British English throughout, and `workspaces` carries time zone, working days, hours per day and
  currency, all honoured by the engine and the client. The "translation-ready" clause is not met —
  there are no `flutter_localizations`, no ARB files and no extracted strings.

### Partly met, and measurable here

- **NFR-PERF-01 (API reads within 300 ms at p95).** Mostly met on the demo: worst of three
  measurements was 31 ms for `changes.php current`, 51 ms for `plan.php schedule`, 80 ms for
  `work_items.php list` and 328 ms for `overview.php get`, which builds the watch list on each call.
  The 1.5 s first-paint target is untested, and a Flutter web release bundle is not obviously going to
  meet it on a cold load.
- **NFR-PERF-02 (heuristic preview within 2 s).** Met at demo scale — 0.47 s end-to-end for a
  person-away what-if over 8 people and 42 items — but **not tested at the stated scale of 50 people
  and 500 open items**, and the heuristic's cost model re-simulates the grid per candidate, so the
  scaling is not obviously linear.
- **NFR-PERF-03 (50 lanes over 26 weeks without lag).** Not verified. The demo has 8 lanes; the
  months zoom does render 26 weeks.
- **NFR-SCAL-01 (200 people, 5,000 items, 24 months of history, 20 workspaces).** Not verified, and
  the last clause is contradicted by ADM-07 — one workspace is seeded and a user belongs to one.
- **NFR-DATA-02 (audit kept 7 years, plan versions 24 months configurable).** Half met by accident:
  nothing is ever purged, so the audit trail is retained indefinitely. There is no retention
  configuration and no purge job, so the "configurable" clause fails (see ADM-05).
- **NFR-ACC-01 (WCAG 2.2 AA).** Partly, and by design rather than by verification. Colour is never the
  only carrier of meaning — size stamps, lock glyphs, hatching, dashed borders and text labels all
  accompany it — and reduced motion is respected in `mwMotion()`. But `Semantics` appears in only
  eight files, `textScalerOf` is consulted in one place, there is no keyboard interaction model for the
  schedule (drag is pointer-only), and Flutter web's canvas rendering is a standing obstacle to
  assistive technology. No audit has been run.
- **NFR-OBS-02 (every plan version reproducible from its stored inputs and policy version).** Partly:
  `policy_version` and a SHA-256 `inputs_hash` are stored on every version, along with the objective
  score and solver statistics. **But only the hash is kept, not the inputs** — `model_inputs_hash()`
  hashes the model and discards it — so a version can be shown to have had different inputs, and
  cannot be re-solved from what is stored.

### Hosting and operations claims, out of scope here

**NFR-AVAIL-01** and **NFR-AVAIL-02** (99.5% availability, RPO 1 hour, RTO 4 hours, geo-redundant UK
backups), **NFR-SEC-01** (Entra conditional access, TLS 1.2+, encryption at rest with customer-managed
keys), **NFR-SEC-03** (Azure Key Vault, managed identities — locally the equivalent is a gitignored
`api/config.php`), **NFR-OBS-01** (structured logs, traces, metrics and dashboards — the only thing in
this family that exists is solver duration recorded per plan version), **NFR-MAINT-01** (Terraform
environments and blue-green deployment with rollback), and **NFR-COMP-01** (browser matrix untested;
iOS and Android have no app at all). **NFR-USE-01** (a delivery lead completes the weekly review in
under 20 minutes) is a usability target that needs a pilot, not a code check; the review flow it
depends on — open proposal, accept all passing, commit — is in place.

## 4 What is actually verified

The verification bar in `CLAUDE.md` is real and it passes. Every PHP suite ran green during this
audit (engine; workspace config, people and skills; work items, estimates and benefits; overview,
reports and watch list; the plan, proposals and changes HTTP smoke; and the policy switches,
notifications and urgent cycle), re-seeding before and after.
The assertions are requirement-aware rather than cosmetic: the change budget holding at the limit, an
improvement below the threshold being held as information, the rota person's reserve rising to the
rota percentage while everyone else holds the standard percentage back, every watch-list entry
carrying a suggestion, nothing outside the freeze horizon being labelled committed, and every lane
header carrying a load percentage. `tests/policy_notifications_test.php` holds each policy switch to
the same standard — every one is asserted with it on and again with it off — and follows an urgent
trigger through to the scoped proposal it produces, a turned-off preference through to the
notification row that is consequently never written, and an incident's priority breakdown through to
the score it has to add up to.

`engine/test_solver.py` checks the CP-SAT model's hard constraints against a hand-built model: level-4
work going to the only qualified person, nobody over 100% on any day, an unqualified item reported
unscheduled and assigned to no one, successors starting after predecessors, committed work inside the
freeze horizon keeping both its person and its start day, planned work staying inside capacity minus
reserve, and an out-of-scope person's committed work being left alone on a scoped cycle.

`mobile/test/screens_smoke_test.dart` renders all fifteen screens at desktop, tablet and phone widths
and in dark theme against the live API. What it does not do is exercise a single interaction: it
proves the screens draw, not that any button works. Nothing in the repository tests the client's
behaviour, which is exactly where most of this audit's Partial verdicts sit.

## 5 What would need doing next

In the order that buys the most, if someone picked this up tomorrow.

1. **Connect the endpoints the client already has but never calls.** This is the single biggest
   discrepancy between what the system can do and what a user can do, and almost all of it is client
   work against APIs that are finished and tested. In rough value order: dependency add and remove
   (PIP-05, a Must in R1), plan version history and restore (CHG-05, Must R1), the incident rota
   editor (TEAM-08, Must R1), day rates (EST-05, and it unblocks half of ADM-06), scenarios
   (SCH-11), bulk actions (PIP-10), and `deactivate` (ADM-03). Each is one screen affordance.

2. **Give the notification set a delivery channel.** All seven kinds now fire and `notify()` reads
   `notification_prefs` (NOT-01 closed, NOT-02 and NOT-03 given something real to sit on), but in-app
   is still the only route: `channel` says `digest` or `teams` when a user asks for it and nothing
   sends either. A weekly digest job (NOT-04) is the cheapest thing that would make the preference
   mean something; push (MOB-04) and Teams (INT-06) need a tenant.

3. **Give `reestimate_class_threshold` a Settings control.** The four switches that were inert now
   all do what their label says, but this one can still only be set through the API, so an
   administrator cannot reach the behaviour at all. Also worth doing: teach the CP-SAT solver the
   `small` flag, which only the PHP planner currently reads (STAB-10).

4. **Make the approval roles configurable (CHG-07).** Who may approve inside the horizon and who may
   override a guardrail are still `require_role('delivery_lead')` and `has_role('admin')` in code.
   The auto-apply half of the requirement is done; this half is the remainder.

5. **Close the Must-priority client gaps in configuration and intake.** `earliest_start` has no
   control anywhere despite the scheduler honouring it, and tags are missing from the add form
   (PIP-01); the benefits register has no filters (BEN-05); work types cannot have their default
   size set (CFG-02); the schedule cannot be grouped (VIEW-04); and objective weights are shown but
   not editable (SCH-02).

Below that line, in descending value: a retention policy and purge job (ADM-05, and it is the only
Must in R1 with a compliance edge); the work-type dimension on estimate accuracy and reports
(EST-07, REP-01); metric definitions beyond the four on the Reports screen (REP-04); the requirements
tab as an editable, formatted field with an admin-editable template (REQ-03); PDF and iCalendar export
(VIEW-09, which also gives INT-04 its publish half for nothing); and a first integration — ServiceNow
intake is the one the demo's own journey leans on hardest.

Two things worth saying plainly to whoever picks this up. First, the Settings → Integrations panel
should be made honestly inert or removed: as it stands it shows six cards, two of them labelled
"Connected", backed by a `const` list that queries nothing. Second, `dev_login` takes a user id and
issues a token for them with no secret. That is correct for a local demo and is gated by
`dev_login_enabled`, but it is the first thing that must be provably unreachable before this goes
anywhere near a real tenant.
